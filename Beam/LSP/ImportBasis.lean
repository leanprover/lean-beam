/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Beam.LSP.Lib.Request

open Lean
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
Import basis of a file worker: the Lake traces of the direct imports as they were when the worker
loaded its header environment.

Lake writes a module's trace from the inputs it handed to Lean. A checkpoint of this document must
likewise describe the imports the worker elaborated against, not whatever is on disk when the
checkpoint is written. Lake folds each import's own transitive trace into an importer's trace, so
the direct imports' traces identify the whole loaded basis.

The broker sends `capture` requests right after it opens or changes a document, so a new header
environment is fingerprinted as soon as it is loaded. Save sends `check` requests, which never
capture: a header environment without an early fingerprint has an unknown basis.
-/
namespace Beam.LSP.ImportBasis

def method : String := "$/beam/importBasis"

structure Params where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  /-- Record the basis of a newly loaded header environment instead of checking it. -/
  capture : Bool := false
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource Params where
  fileSource p := p.textDocument.uri

inductive Status where
  /-- The direct imports' traces still match the loaded basis. -/
  | current
  /-- Some direct import's trace changed after the worker loaded it. -/
  | changed
  /-- No basis was captured when this header environment was loaded. -/
  | unknown
  deriving BEq, Repr

instance : ToJson Status where
  toJson
    | .current => "current"
    | .changed => "changed"
    | .unknown => "unknown"

instance : FromJson Status where
  fromJson?
    | .str "current" => .ok .current
    | .str "changed" => .ok .changed
    | .str "unknown" => .ok .unknown
    | j => .error s!"expected import basis status, got {j.compress}"

structure Result where
  status : Status
  /-- Direct imports whose trace differs from the loaded basis. -/
  changedImports : Array String := #[]
  deriving FromJson, ToJson

/-- A direct import and its Lake trace fingerprint; `none` when it has no trace, as for toolchain
modules. -/
private structure ImportTrace where
  module : Name
  fingerprint? : Option String
  deriving BEq

private structure Basis where
  env : Environment
  imports : Array ImportTrace

private initialize basisRef : IO.Ref (Option Basis) ← IO.mkRef none

private unsafe def sameEnvImpl (a b : Environment) : Bool :=
  ptrAddrUnsafe a == ptrAddrUnsafe b

/-- Lean reuses the header environment object while the header is unchanged. -/
@[implemented_by sameEnvImpl]
private opaque sameEnv (a b : Environment) : Bool

/-- The inputs and outputs Lake recorded for a module; the rest of a trace is informational. -/
private def traceFingerprint (contents : String) : String :=
  match Json.parse contents with
  | .ok json =>
      Json.compress <| Json.mkObj [
        ("depHash", json.getObjValD "depHash"),
        ("outputs", json.getObjValD "outputs")
      ]
  | .error _ => contents

private def readImportTrace (module : Name) : IO ImportTrace := do
  let some path ← (← searchPathRef.get).findWithExt "trace" module
    | return { module, fingerprint? := none }
  try
    return { module, fingerprint? := some (traceFingerprint (← IO.FS.readFile path)) }
  catch _ =>
    -- A vanished or unreadable trace differs from any recorded fingerprint.
    return { module, fingerprint? := some "" }

private def directImports (header : Lean.Elab.HeaderSyntax) : Array Name :=
  (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
    let module := info.module.toName
    if acc.contains module then acc else acc.push module

private def readImportTraces (modules : Array Name) : IO (Array ImportTrace) :=
  modules.mapM readImportTrace

private def capture (env : Environment) (modules : Array Name) : IO Unit := do
  if (← basisRef.get).any (sameEnv ·.env env) then
    return
  let imports ← readImportTraces modules
  basisRef.modify fun cached? =>
    if cached?.any (sameEnv ·.env env) then cached? else some { env, imports }

private def check (env : Environment) : IO Result := do
  let some basis ← basisRef.get
    | return { status := .unknown }
  unless sameEnv basis.env env do
    return { status := .unknown }
  let current ← readImportTraces (basis.imports.map (·.module))
  let changed := (basis.imports.zip current).filterMap fun (loaded, now) =>
    if loaded == now then none else some loaded.module.toString
  return { status := if changed.isEmpty then .current else .changed, changedImports := changed }

def handle (p : Params) : RequestM (RequestTask Result) := do
  let doc ← readDoc
  unless p.capture do
    requireDocumentVersion p.textDocument
  let some parsed := doc.initSnap.result?
    | return RequestTask.pure { status := .unknown }
  let modules := directImports ⟨doc.initSnap.stx⟩
  RequestM.mapTaskCheap parsed.processedSnap.task.asServerTask fun processed => do
    let some state := processed.result?
      | return { status := .unknown }
    let env := state.cmdState.env
    if p.capture then
      capture env modules
      return { status := .current }
    check env

end Beam.LSP.ImportBasis
