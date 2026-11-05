/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Requests
import Beam.LSP.RunAt.ProofSnapshot

open Lean
open Lean.Server
open Lean.Server.RequestM

/-
Stored continuation handles for the `$/lean/runAt` request family.

Handles are not a cross-family LSP concept; they are minted, consumed, and released only by
`runAt`, `runWith`, and `releaseHandle`.
-/
namespace Beam.LSP.RunAt

/-- Opaque follow-up handle returned by the server. -/
structure Handle where
  value : String
  deriving FromJson, ToJson

inductive StoredHandleState where
  | command (snapshot : Snapshots.Snapshot)
  | proof (snapshot : ProofSnapshot)

structure StoredHandle where
  uri : Lean.Lsp.DocumentUri
  version : Nat
  state : StoredHandleState
  /-- Lean may capture profiler options in deferred declaration contexts in this state. -/
  profiled : Bool

structure HandleStore where
  nextId : Nat := 0
  handles : Std.TreeMap String StoredHandle := {}
  staleHandles : Std.TreeSet String compare := {}
  deriving Inhabited

initialize handleStoreRef : IO.Ref HandleStore ← IO.mkRef {}
initialize workerToken : String ← do
  let pid ← IO.Process.getPID
  let startedAt ← IO.monoNanosNow
  pure s!"{pid}-{startedAt}"

def docHandleKey (uri : Lean.Lsp.DocumentUri) : String :=
  s!"{hash uri}"

structure ParsedHandle where
  docKey : String
  workerKey : String

def parseHandle? (handle : Handle) : Option ParsedHandle :=
  match handle.value.splitOn ":" with
  | ["runAt", docKey, workerKey, _id] => some { docKey, workerKey }
  | _ => none

def mkHandleString (uri : Lean.Lsp.DocumentUri) (id : Nat) : String :=
  s!"runAt:{docHandleKey uri}:{workerToken}:{id}"

def eraseStoredHandle (handle : Handle) : BaseIO Unit := do
  handleStoreRef.modify fun store =>
    {
      store with
      handles := store.handles.erase handle.value
      staleHandles := store.staleHandles.erase handle.value
    }

def markStoredHandleStale (handle : Handle) : BaseIO Unit := do
  handleStoreRef.modify fun store =>
    {
      store with
      handles := store.handles.erase handle.value
      staleHandles := store.staleHandles.insert handle.value
    }

def pruneDocHandles (uri : Lean.Lsp.DocumentUri) (version : Nat) : BaseIO Unit := do
  handleStoreRef.modify fun store =>
    Id.run do
      let mut handles := store.handles
      let mut staleHandles := store.staleHandles
      for (key, stored) in store.handles.toList do
        if stored.uri == uri && stored.version != version then
          handles := handles.erase key
          staleHandles := staleHandles.insert key
      return { store with handles, staleHandles }

def syncHandleStoreForCurrentDoc : RequestM Unit := do
  let doc ← RequestM.readDoc
  pruneDocHandles doc.meta.uri doc.meta.version

def isKnownStaleHandle (handle : Handle) : BaseIO Bool := do
  return (← handleStoreRef.get).staleHandles.contains handle.value

def validateHandleForCurrentDoc (handle : Handle) : RequestM Unit := do
  let doc ← RequestM.readDoc
  let some parsed := parseHandle? handle
    | throw <| RequestError.invalidParams s!"malformed handle '{handle.value}'"
  if parsed.docKey != docHandleKey doc.meta.uri then
    throw <| RequestError.invalidParams s!"handle '{handle.value}' does not belong to this document"
  if parsed.workerKey != workerToken then
    throw RequestError.fileChanged
  syncHandleStoreForCurrentDoc
  if ← isKnownStaleHandle handle then
    throw RequestError.fileChanged

def mintHandle (state : StoredHandleState) (profiled : Bool) : RequestM Handle := do
  syncHandleStoreForCurrentDoc
  let doc ← RequestM.readDoc
  handleStoreRef.modifyGet fun store =>
    let handle : Handle := { value := mkHandleString doc.meta.uri store.nextId }
    let stored : StoredHandle := {
      uri := doc.meta.uri
      version := doc.meta.version
      state
      profiled
    }
    (handle, {
      nextId := store.nextId + 1
      handles := store.handles.insert handle.value stored
      staleHandles := store.staleHandles.erase handle.value
    })

def releaseStoredHandle (handle : Handle) : RequestM Unit := do
  validateHandleForCurrentDoc handle
  let removed ← handleStoreRef.modifyGet fun store =>
    let existed := (store.handles.get? handle.value).isSome
    (existed, { store with handles := store.handles.erase handle.value })
  if !removed then
    throw <| RequestError.invalidParams s!"unknown handle '{handle.value}'"

def withStoredHandle (handle : Handle) (linear profile : Bool)
    (k : StoredHandle → RequestM α) : RequestM α := do
  validateHandleForCurrentDoc handle
  let doc ← RequestM.readDoc
  let stored ← handleStoreRef.modifyGet fun store =>
    let stored? := store.handles.get? handle.value
    let handles :=
      -- Reject an incompatible continuation without consuming even a linear handle. Keep the
      -- lookup, compatibility decision, and optional consumption in one store operation.
      if linear && stored?.all (fun stored => !stored.profiled || profile) then
        store.handles.erase handle.value
      else
        store.handles
    (stored?, { store with handles })
  let some stored := stored
    | throw <| RequestError.invalidParams s!"unknown handle '{handle.value}'"
  if stored.uri != doc.meta.uri then
    markStoredHandleStale handle
    throw <| RequestError.invalidParams s!"handle '{handle.value}' does not belong to this document"
  if stored.version != doc.meta.version then
    markStoredHandleStale handle
    throw RequestError.fileChanged
  if stored.profiled && !profile then
    throw <| RequestError.invalidParams
      "This handle was created with profiling enabled; continuations require profile: true (CLI: --profile). For an unprofiled probe, start a new runAt from the document. The handle has not been consumed."
  k stored

end Beam.LSP.RunAt
