/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Workspace

abbrev WorkspaceId := String

def validWorkspaceId (workspaceId : WorkspaceId) : Bool :=
  !workspaceId.isEmpty

/--
Client-visible description of a local Lean workspace.

The descriptor is carried by every workspace-bound MCP request. Its root is resolved and
canonicalized before the server derives a private broker workspace id, so clients never select or
depend on the broker's process-local cache keys.
-/
structure Descriptor where
  root : String
  deriving BEq, Repr

instance : ToJson Descriptor where
  toJson descriptor := Json.mkObj [("root", toJson descriptor.root)]

instance : FromJson Descriptor where
  fromJson?
    | json@(.obj fields) => do
        let hasUnexpectedField := fields.foldl (init := false) fun found field _ =>
          found || field != "root"
        if hasUnexpectedField then
          throw "workspace descriptor accepts only the 'root' field"
        pure { root := ← json.getObjValAs? String "root" }
    | other =>
        throw s!"workspace descriptor must be an object, got {other.compress}"

/-- Decode a required workspace descriptor at a JSON boundary. -/
def decodeDescriptorField
    (json : Json)
    (field : String := "workspace") : Except String Descriptor := do
  let value ←
    match json.getObjVal? field with
    | .ok value => pure value
    | .error _ => throw s!"{field} is required"
  match fromJson? (α := Descriptor) value with
  | .ok descriptor => pure descriptor
  | .error err => throw s!"invalid '{field}': {err}"

def Descriptor.ofRoot (root : System.FilePath) : Descriptor :=
  { root := root.toString }

/-- Private, deterministic broker cache key for a canonical local workspace root. -/
def Descriptor.cacheKey (descriptor : Descriptor) : WorkspaceId :=
  "local:" ++ descriptor.root

/-- Decode and validate a required workspace-id field at a JSON boundary. -/
def decodeWorkspaceIdField
    (json : Json)
    (field : String := "workspace_id") : Except String WorkspaceId := do
  let value ←
    match json.getObjVal? field with
    | .ok value => pure value
    | .error _ => throw s!"{field} is required"
  let workspaceId ←
    match fromJson? (α := WorkspaceId) value with
    | .ok workspaceId => pure workspaceId
    | .error err => throw s!"invalid '{field}': {err}"
  unless validWorkspaceId workspaceId do
    throw s!"{field} must be non-empty"
  pure workspaceId

private def optionalField? [FromJson α] (json : Json) (field : String) : Except String (Option α) := do
  match json.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

inductive InitMode where
  | set
  | verify
  | reset
  deriving BEq, Repr

def InitMode.key : InitMode → String
  | .set => "set"
  | .verify => "verify"
  | .reset => "reset"

def InitMode.all : Array InitMode :=
  #[.set, .verify, .reset]

def InitMode.fromKey? (key : String) : Option InitMode :=
  InitMode.all.find? (fun mode => mode.key == key)

instance : ToJson InitMode where
  toJson mode := toJson mode.key

instance : FromJson InitMode where
  fromJson?
    | .str key =>
        match InitMode.fromKey? key with
        | some mode => .ok mode
        | none =>
            .error <|
              s!"expected init workspace mode 'set', 'verify', or 'reset', got {toJson key |>.compress}"
    | j => .error s!"expected init workspace mode 'set', 'verify', or 'reset', got {j.compress}"

structure InitResult where
  workspaceId : WorkspaceId
  root : System.FilePath
  mode : InitMode
  runtimeReused : Bool
  previousRoot? : Option System.FilePath := none
  invalidatedHandles : Bool := false

instance : ToJson InitResult where
  toJson result :=
    Json.mkObj <|
      [
        ("workspace_id", toJson result.workspaceId),
        ("root", toJson result.root.toString),
        ("initialized", toJson true),
        ("mode", toJson result.mode),
        ("runtime_reused", toJson result.runtimeReused),
        ("invalidated_handles", toJson result.invalidatedHandles)
      ] ++
      match result.previousRoot? with
      | some previousRoot => [("previous_root", toJson previousRoot.toString)]
      | none => []

instance : FromJson InitResult where
  fromJson? json := do
    let workspaceId ← decodeWorkspaceIdField json
    let root ← json.getObjValAs? String "root"
    let initialized ← json.getObjValAs? Bool "initialized"
    unless initialized do
      throw "workspace initialization result must have initialized=true"
    let mode ← json.getObjValAs? InitMode "mode"
    let runtimeReused ← json.getObjValAs? Bool "runtime_reused"
    let previousRoot? ← optionalField? (α := String) json "previous_root"
    let invalidatedHandles ← json.getObjValAs? Bool "invalidated_handles"
    pure {
      workspaceId
      root := System.FilePath.mk root
      mode
      runtimeReused
      previousRoot? := previousRoot?.map System.FilePath.mk
      invalidatedHandles
    }

/-- One initialized workspace reported by the broker lifecycle surface. -/
structure ListEntry where
  workspaceId : WorkspaceId
  root : System.FilePath
  leanActive : Bool

instance : ToJson ListEntry where
  toJson entry := Json.mkObj [
    ("workspace_id", toJson entry.workspaceId),
    ("root", toJson entry.root.toString),
    ("lean_active", toJson entry.leanActive)
  ]

instance : FromJson ListEntry where
  fromJson? json := do
    let workspaceId ← decodeWorkspaceIdField json
    let root ← json.getObjValAs? String "root"
    let leanActive ← json.getObjValAs? Bool "lean_active"
    pure { workspaceId, root := System.FilePath.mk root, leanActive }

structure ListResult where
  workspaces : Array ListEntry := #[]
  deriving FromJson, ToJson

/-- Typed result for an idempotent workspace drop. -/
structure DropResult where
  workspaceId : WorkspaceId
  dropped : Bool
  invalidatedHandles : Bool := false
  reason? : Option String := none

instance : ToJson DropResult where
  toJson result := Json.mkObj <|
    [
      ("workspace_id", toJson result.workspaceId),
      ("dropped", toJson result.dropped),
      ("invalidated_handles", toJson result.invalidatedHandles)
    ] ++
    match result.reason? with
    | some reason => [("reason", toJson reason)]
    | none => []

instance : FromJson DropResult where
  fromJson? json := do
    let workspaceId ← decodeWorkspaceIdField json
    let dropped ← json.getObjValAs? Bool "dropped"
    let invalidatedHandles ←
      match ← optionalField? (α := Bool) json "invalidated_handles" with
      | some invalidated => pure invalidated
      | none => pure false
    let reason? ← optionalField? (α := String) json "reason"
    pure { workspaceId, dropped, invalidatedHandles, reason? }

end Beam.Workspace
