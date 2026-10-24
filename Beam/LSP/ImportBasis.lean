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
Import basis of a file worker: the Lake traces of every workspace module its header environment
loaded, as they were when the worker loaded it.

Lake writes a module's trace from the inputs it handed to Lean. A checkpoint of this document must
likewise describe the modules the worker elaborated against, not whatever is on disk when the
checkpoint is written. The basis covers the whole transitive import closure: a non-`module` importer
loads private artifacts of module-system dependencies that its direct imports' traces do not cover.
Comparing every loaded module is conservative for `module` importers, which may refresh more often
than strictly necessary.

The broker sends `capture` requests right after it opens or changes a document, so a new header
environment is fingerprinted as soon as it is loaded. Save sends `check` requests, which never
capture: a header environment without an early fingerprint has an unknown basis, as does one with a
module whose trace cannot be located unambiguously. Each capture also records the broker event
sequence of the notification that loaded it, so a check refuses modules that Beam itself saved at or
after that point, whichever trace the capture observed.

Requests complete in the order the worker accepted them. A body edit reuses the header environment
and sends another capture with a later sequence; running captures in order means the first capture
of an environment always records it, so a later one can never advance its load boundary. A check
likewise waits for every capture accepted before it.

The capture mode is temporary: Lean receives the exact import artifacts from `lake setup-file` but
does not retain them after loading. An external build racing the import load can still go
unobserved. Once a worker exposes the loaded artifacts, save can compare them directly and the
capture request goes away (https://github.com/leanprover/lean-beam/issues/370).
-/
namespace Beam.LSP.ImportBasis

def method : String := "$/beam/importBasis"

/-- A module Beam saved, with the broker event sequence of that save. -/
structure SavedModule where
  module : String
  eventSeq : Nat
  deriving FromJson, ToJson

structure Params where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  /-- Record the basis of a newly loaded header environment instead of checking it. -/
  capture : Bool := false
  /-- Capture: broker event sequence when it sent the notification that loads this environment. -/
  eventSeq : Nat := 0
  /-- Check: modules Beam saved in this session. -/
  savedModules : Array SavedModule := #[]
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource Params where
  fileSource p := p.textDocument.uri

inductive Status where
  /-- Every loaded module's trace still matches the loaded basis. -/
  | current
  /-- Some loaded module changed after the worker loaded it. -/
  | changed
  /-- No complete basis was captured when this header environment was loaded. -/
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
  /-- Loaded modules that changed after the worker loaded them. -/
  changedImports : Array String := #[]
  /-- Loaded modules whose trace could not be located or read unambiguously at capture. -/
  unresolvedImports : Array String := #[]
  deriving FromJson, ToJson

/-- A loaded workspace module, its unique Lake trace, and that trace's fingerprint. -/
private structure ModuleTrace where
  module : Name
  path : System.FilePath
  fingerprint : String

private structure Basis where
  env : Environment
  /-- Broker event sequence of the notification that loaded `env`. -/
  eventSeq : Nat
  traces : Array ModuleTrace
  unresolved : Array Name

private initialize basisRef : IO.Ref (Option Basis) ← IO.mkRef none

/-- Completion of the last accepted capture. The worker accepts requests one at a time. -/
private initialize capturesRef : IO.Ref (ServerTask Unit) ← IO.mkRef (.pure ())

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

private inductive TraceLocation where
  /-- A module of the running toolchain: immutable, and without a Lake trace. -/
  | toolchain
  | trace (path : System.FilePath)
  | unresolved

/--
Lake may give several packages directories for the same root namespace, so the first matching
search root need not own a module. Require exactly one trace file; an inherited search path can
name the same directory twice.
-/
private def locateTrace (sp : SearchPath) (toolchainLib : System.FilePath) (module : Name) :
    IO TraceLocation := do
  let mut candidates : Array System.FilePath := #[]
  for root in sp do
    let path := modToFilePath root module "trace"
    if ← path.pathExists then
      let path ← IO.FS.realPath path
      unless candidates.contains path do
        candidates := candidates.push path
  match candidates with
  | #[path] => return .trace path
  | #[] =>
      if ← (modToFilePath toolchainLib module "olean").pathExists then return .toolchain
      return .unresolved
  | _ => return .unresolved

private def readFingerprint? (path : System.FilePath) : IO (Option String) := do
  try return some (traceFingerprint (← IO.FS.readFile path))
  catch _ => return none

private def collectBasis (env : Environment) (eventSeq : Nat) : IO Basis := do
  let sp ← searchPathRef.get
  let toolchainLib ← getLibDir (← getBuildDir)
  let mut traces := #[]
  let mut unresolved := #[]
  for module in env.header.moduleNames do
    match ← locateTrace sp toolchainLib module with
    | .toolchain => pure ()
    | .unresolved => unresolved := unresolved.push module
    | .trace path =>
        match ← readFingerprint? path with
        | some fingerprint => traces := traces.push { module, path, fingerprint }
        | none => unresolved := unresolved.push module
  return { env, eventSeq, traces, unresolved }

private def capture (env : Environment) (eventSeq : Nat) : IO Unit := do
  if (← basisRef.get).any (sameEnv ·.env env) then
    return
  basisRef.set (some (← collectBasis env eventSeq))

private def check (env : Environment) (saved : Array SavedModule) : IO Result := do
  let some basis ← basisRef.get
    | return { status := .unknown }
  unless sameEnv basis.env env do
    return { status := .unknown }
  unless basis.unresolved.isEmpty do
    return { status := .unknown, unresolvedImports := basis.unresolved.map (·.toString) }
  let savedSince := saved.filter (·.eventSeq ≥ basis.eventSeq) |>.map (·.module)
  let mut changed := #[]
  for trace in basis.traces do
    let module := trace.module.toString
    if savedSince.contains module || (← readFingerprint? trace.path) != some trace.fingerprint then
      changed := changed.push module
  return { status := if changed.isEmpty then .current else .changed, changedImports := changed }

/-- The loaded header environment, or none if the header failed to parse or load. -/
private def headerEnv (doc : Lean.Server.FileWorker.EditableDocument) :
    ServerTask (Option Environment) :=
  match doc.initSnap.result? with
  | none => .pure none
  | some parsed =>
      parsed.processedSnap.task.asServerTask.mapCheap (·.result?.map (·.cmdState.env))

def handle (p : Params) : RequestM (RequestTask Result) := do
  let doc ← readDoc
  unless p.capture do
    requireDocumentVersion p.textDocument
  let previous ← capturesRef.get
  let env := previous.bindCheap fun _ => headerEnv doc
  if p.capture then
    -- Not a request task: an edit cancelling the request must not skip or reorder the capture.
    let captured ← ServerTask.BaseIO.mapTaskCheap (t := env) fun
      | some env => (capture env p.eventSeq).catchExceptions fun _ => basisRef.set none
      | none => basisRef.set none
    capturesRef.set captured
    return captured.mapCheap fun _ => .ok { status := .current }
  RequestM.mapTaskCheap env fun
    | some env => check env p.savedModules
    | none => return { status := .unknown }

end Beam.LSP.ImportBasis
