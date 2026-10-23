/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Config.InstallPath
import Lake.Load.Workspace
import Lake.Build.Run
import Lake.Build.Targets
import Lake.Build.Job.Monad
import Lake.Build.Common
import Lake.Build.InitFacets
import Lean.Elab.Term
import Beam.Broker.Config
import Beam.Broker.Errors
import Beam.Broker.LakeEnv
import Beam.Broker.LakeHelper
import Beam.Path

open Lean
open System
open Std

namespace Beam.Broker

open Lake

private def moduleOutputOptionalCName : Name :=
  .str (.str (.str .anonymous "Lake") "ModuleOutputDescrs") "c?"

-- Lake 4.36 (starting with v4.36.0-rc1) makes `c` optional for postponed code generation. Beam saves
-- generated C, so that record shape must carry `some c` rather than leave the output absent.
-- Select the record shape at elaboration time so save traces work across the supported range.
elab "mkModuleOutputDescrsCompat(" isModule:term ", " olean:term ", " oleanServer:term ", "
    oleanPrivate:term ", " ilean:term ", " ir:term ", " irSig:term ", " c:term ", " bc:term ")" : term => do
  let outputs ← if (← getEnv).contains moduleOutputOptionalCName then
    `(term| ({
      isModule := $isModule
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      irSig? := $irSig
      c? := some $c
      bc? := $bc
    } : ModuleOutputDescrs))
  else
    `(term| ({
      isModule := $isModule
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      irSig? := $irSig
      c := $c
      bc? := $bc
    } : ModuleOutputDescrs))
  Lean.Elab.Term.elabTerm outputs none

/-- Helper-local preparation retains live Lake values, with no delegated alternative. -/
structure LocalLeanSaveSpec extends LeanSaveOutputs where
  moduleName : String
  depTrace : BuildTrace

structure SourceSnapshot where
  hash : Hash
  mtime : MTime

private def unsupportedZeroBuildSaveReason? (mod : Lake.Module) : Option String :=
  if !mod.leanArgs.isEmpty then
    some "Lake module uses batch-only moreLeanArgs"
  else
    none

private def quietTraceConfig : BuildConfig :=
  { verbosity := .quiet }

private structure SaveTraceInputs where
  trace : BuildTrace
  isModule : Bool
  sourceMatchesSnapshot : Bool

private def buildDepTraceJob
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : FetchM (Job SaveTraceInputs) := do
    let setupJob ← mod.presetup.fetch
    setupJob.mapM (sync := true) fun setup => do
      let input ← (← mod.input.fetch).await
      return {
        trace := setup.trace
        isModule := setup.isModule
        sourceMatchesSnapshot := input.trace.hash == snapshot.hash &&
          input.trace.mtime.sec == snapshot.mtime.sec &&
          input.trace.mtime.nsec == snapshot.mtime.nsec
      }

private def saveTraceStaleMessage (root path : FilePath) : String :=
  let relPath := Beam.pathRelativeToRootOrSelf root path
  s!"Lake save trace is stale for {relPath}. " ++
  "A dependency or build input would need to rebuild before Beam can save this module safely. " ++
  "Save stale direct dependencies with lean-beam save, or run lake build and retry."

private def ensureSaveTraceReady
    (ws : Workspace)
    (root path : FilePath)
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : IO (Except BrokerFailure Unit) := do
  -- Lake's no-build `runBuild` mode is CLI-oriented and may exit the process.
  -- The daemon must convert stale traces into an ordinary request
  -- error before running the trace job for real.
  unless ← ws.checkNoBuild (buildDepTraceJob mod snapshot) do
    return .error {
      code := .saveTraceStale
      message := saveTraceStaleMessage root path
    }
  pure (.ok ())

private def buildDepTrace
    (ws : Workspace)
    (root path : FilePath)
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : IO (Except BrokerFailure SaveTraceInputs) := do
  match ← ensureSaveTraceReady ws root path mod snapshot with
  | .error failure => pure <| .error failure
  | .ok () =>
      try
        let inputs ← ws.runBuild (cfg := quietTraceConfig) (buildDepTraceJob mod snapshot)
        if !inputs.sourceMatchesSnapshot then
          return .error {
            code := .contentModified
            message := "source changed while preparing its Lake save trace"
          }
        return .ok inputs
      catch e =>
        pure <| .error {
          code := .internalError
          message := e.toString
        }

def computeSaveSpecification
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd : String) : IO (Except BrokerFailure LocalLeanSaveSpec) := do
  try
    let root ← Beam.resolveExistingPath root
    let path ← Beam.resolvePathAgainstRoot root path
    let ws ←
      match ← loadWorkspaceForRoot root leanCmd with
      | .loaded ws => pure ws
      | .leanBuildMismatch =>
          return .error {
            code := .saveUnsupportedSetup
            message :=
              "lean-beam save requires matching compiler revisions for Beam's compiled code, " ++
              "its loaded Lean runtime, and the target compiler; " ++
              "rebuild or reinstall Beam for the target Lean build, or use lake build instead"
          }
    let some mod := ws.findModuleBySrc? path
      | return .error {
          code := .saveTargetNotModule
          message :=
            s!"could not resolve a Lake module for {path}. " ++
            "lean-beam save only works for synced files that belong to the current Lake workspace package graph."
        }
    let relPath := Beam.pathRelativeToRootOrSelf root path
    -- Configuration already determines support. Do not fetch dependencies, even in no-build
    -- mode, for a snapshot whose setup cannot represent batch compilation.
    if let some reason := unsupportedZeroBuildSaveReason? mod then
      return .error {
        code := .saveUnsupportedSetup
        message :=
          s!"lean-beam save cannot reuse the Lean server snapshot for {relPath}: {reason}. " ++
          "Move shared -D settings from moreLeanArgs to leanOptions so Lake applies them to both " ++
          "the language server and batch compilation. If the arguments are intentionally batch-only, " ++
          "run lake build for this module instead."
        data? := some <| Json.mkObj [("reason", toJson reason), ("path", toJson relPath)]
      }
    let depTraceResult ← buildDepTrace ws root path mod snapshot
    let inputs ←
      match depTraceResult with
      | .ok result => pure result
      | .error failure => return .error failure
    pure <| .ok {
      moduleName := mod.name.toString
      oleanPath := mod.oleanFile
      oleanServerPath? := if inputs.isModule then some mod.oleanServerFile else none
      oleanPrivatePath? := if inputs.isModule then some mod.oleanPrivateFile else none
      ileanPath := mod.ileanFile
      irPath? := if inputs.isModule then some mod.irFile else none
      irSigPath? := if inputs.isModule then some mod.irSigFile else none
      cPath := mod.cFile
      bcPath? := if Lean.Internal.hasLLVMBackend () then some mod.bcFile else none
      tracePath := mod.traceFile
      depTrace := inputs.trace
    }
  catch e =>
    pure <| .error {
      code := .internalError
      message := e.toString
    }

/-- Broker-side preparation always requests the admitted helper. -/
def requestSaveSpecification
    (helper root path : FilePath)
    (snapshot : SourceSnapshot)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanSaveSpec) := do
  let request : LakeHelperSaveRequest := {
    root := root.toString
    path := path.toString
    sourceHash := snapshot.hash.toString
    sourceMTimeSec := snapshot.mtime.sec
    sourceMTimeNsec := snapshot.mtime.nsec.toNat
  }
  runLakeHelperPrepareSave helper request control

private def hashDescr (path : FilePath) (ext : String) : IO ArtifactDescr :=
  return artifactWithExt (← computeHash path) ext

private def leanSaveOutputs (outputs : LeanSaveOutputs) : IO ModuleOutputDescrs := do
  let isModule := outputs.oleanServerPath?.isSome
  let olean ← hashDescr outputs.oleanPath "olean"
  let oleanServer? ← outputs.oleanServerPath?.mapM (fun path => hashDescr path "olean.server")
  let oleanPrivate? ← outputs.oleanPrivatePath?.mapM (fun path => hashDescr path "olean.private")
  let ilean ← hashDescr outputs.ileanPath "ilean"
  let ir? ← outputs.irPath?.mapM (fun path => hashDescr path "ir")
  let irSig? ← outputs.irSigPath?.mapM (fun path => hashDescr path "ir.sig")
  let c ← hashDescr outputs.cPath "c"
  let bc? ← outputs.bcPath?.mapM (fun path => hashDescr path "bc")
  pure <| mkModuleOutputDescrsCompat(
    isModule, olean, oleanServer?, oleanPrivate?, ilean, ir?, irSig?, c, bc?)

private def stagedTracePath (tracePath : FilePath) : IO FilePath := do
  let pid ← IO.Process.getPID
  pure <| FilePath.mk s!"{tracePath}.beam-save-trace-tmp-{pid}-{← IO.monoNanosNow}"

private def writeTraceAtomically
    (tracePath : FilePath)
    (writeStaged : FilePath → IO Unit) : IO Unit := do
  let stagedTrace ← stagedTracePath tracePath
  try
    writeStaged stagedTrace
    IO.FS.rename stagedTrace tracePath
  catch e =>
    try
      if ← stagedTrace.pathExists then
        IO.FS.removeFile stagedTrace
    catch _ =>
      pure ()
    throw e

/-- Finalize the target-prepared trace locally after the artifact producer has settled.
The supported Lake trace schema and artifact hashes are qualified across supported SDKs. -/
def writeLeanSaveTrace (spec : LeanSaveSpec) : IO Unit := do
  let schema ← IO.ofExcept <| spec.traceMetadata.getObjValAs? String "schemaVersion"
  let expectedSchema ← IO.ofExcept <|
    (toJson (BuildMetadata.ofStub (Hash.ofNat 0))).getObjValAs? String "schemaVersion"
  unless schema == expectedSchema do
    throw <| IO.userError s!"unsupported Lake trace schema '{schema}'; use lake build instead"
  let outputs ← leanSaveOutputs spec.toLeanSaveOutputs
  -- Preserve the target's dependency metadata; only completed output descriptors change.
  let metadata := spec.traceMetadata.setObjVal! "outputs" (toJson outputs)
  writeTraceAtomically spec.tracePath fun stagedTrace => do
    IO.FS.createDirAll (stagedTrace.parent.getD ".")
    IO.FS.writeFile stagedTrace metadata.pretty

def lakeHelperSaveSpec
    (request : LakeHelperSaveRequest) (leanCmd : String) : IO (Except BrokerFailure LeanSaveSpec) := do
  let some sourceHash := Hash.ofString? request.sourceHash
    | return .error {
        code := .invalidParams
        message := "target Lake helper received an invalid source hash"
      }
  unless request.sourceMTimeNsec < UInt32.size do
    return .error {
      code := .invalidParams
      message := "target Lake helper received an invalid source modification time"
    }
  let snapshot : SourceSnapshot := {
    hash := sourceHash
    mtime := { sec := request.sourceMTimeSec, nsec := request.sourceMTimeNsec.toUInt32 }
  }
  match ← computeSaveSpecification
      (FilePath.mk request.root) (FilePath.mk request.path) snapshot leanCmd with
  | .error failure => pure <| .error failure
  | .ok spec =>
      let traceMetadata := toJson (BuildMetadata.ofBuild spec.depTrace Json.null {})
      pure <| .ok {
        moduleName := spec.moduleName
        toLeanSaveOutputs := spec.toLeanSaveOutputs
        traceMetadata
      }

end Beam.Broker
