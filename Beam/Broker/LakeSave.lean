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

inductive LeanSaveTracePlan where
  | inProcess (depTrace : BuildTrace)
  | targetProcess (helper root : FilePath) (traceMetadata : Json)

structure LeanSaveSpec where
  relPath : String
  moduleName : String
  unsupportedSetupReason? : Option String := none
  oleanPath : FilePath
  oleanServerPath? : Option FilePath := none
  oleanPrivatePath? : Option FilePath := none
  ileanPath : FilePath
  irPath? : Option FilePath := none
  irSigPath? : Option FilePath := none
  cPath : FilePath
  bcPath? : Option FilePath := none
  tracePath : FilePath
  tracePlan : LeanSaveTracePlan

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
  unsupportedSetupReason? : Option String
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
        unsupportedSetupReason? := unsupportedZeroBuildSaveReason? mod
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

private def mkLeanSaveSpecInProcess
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd? : Option String := none) : IO (Except BrokerFailure LeanSaveSpec) := do
  try
    let root ← Beam.resolveExistingPath root
    let path ← Beam.resolvePathAgainstRoot root path
    let ws ←
      match ← loadWorkspaceForRoot root leanCmd? with
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
    let depTraceResult ← buildDepTrace ws root path mod snapshot
    let inputs ←
      match depTraceResult with
      | .ok result => pure result
      | .error failure => return .error failure
    let relPath := Beam.pathRelativeToRootOrSelf root path
    pure <| .ok {
      relPath
      moduleName := mod.name.toString
      unsupportedSetupReason? := inputs.unsupportedSetupReason?
      oleanPath := mod.oleanFile
      oleanServerPath? := if inputs.isModule then some mod.oleanServerFile else none
      oleanPrivatePath? := if inputs.isModule then some mod.oleanPrivateFile else none
      ileanPath := mod.ileanFile
      irPath? := if inputs.isModule then some mod.irFile else none
      irSigPath? := if inputs.isModule then some mod.irSigFile else none
      cPath := mod.cFile
      bcPath? := if Lean.Internal.hasLLVMBackend () then some mod.bcFile else none
      tracePath := mod.traceFile
      tracePlan := .inProcess inputs.trace
    }
  catch e =>
    pure <| .error {
      code := .internalError
      message := e.toString
    }

private def leanSaveSpecOfHelperSpec
    (helper : FilePath)
    (spec : LakeHelperSaveSpec) : LeanSaveSpec := {
    relPath := spec.relPath
    moduleName := spec.moduleName
    unsupportedSetupReason? := spec.unsupportedSetupReason?
    oleanPath := FilePath.mk spec.oleanPath
    oleanServerPath? := spec.oleanServerPath?.map FilePath.mk
    oleanPrivatePath? := spec.oleanPrivatePath?.map FilePath.mk
    ileanPath := FilePath.mk spec.ileanPath
    irPath? := spec.irPath?.map FilePath.mk
    irSigPath? := spec.irSigPath?.map FilePath.mk
    cPath := FilePath.mk spec.cPath
    bcPath? := spec.bcPath?.map FilePath.mk
    tracePath := FilePath.mk spec.tracePath
    tracePlan := .targetProcess helper (FilePath.mk spec.root) spec.traceMetadata
  }

private def mkLeanSaveSpecWithHelper
    (helper root path : FilePath)
    (snapshot : SourceSnapshot)
    (control : LakeHelperControl) : IO (Except BrokerFailure LeanSaveSpec) := do
  let request : LakeHelperSaveRequest := {
    root := root.toString
    path := path.toString
    sourceHash := snapshot.hash.toString
    sourceMTimeSec := snapshot.mtime.sec
    sourceMTimeNsec := snapshot.mtime.nsec.toNat
  }
  match ← runLakeHelperPrepareSave helper request control with
  | .error failure => pure <| .error failure
  | .ok spec => pure <| .ok (leanSaveSpecOfHelperSpec helper spec)

def mkLeanSaveSpec
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd? : Option String := none)
    (lakeHelper? : Option FilePath := none)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanSaveSpec) := do
  match lakeHelper?, leanCmd? with
  | some helper, some _ =>
      mkLeanSaveSpecWithHelper helper root path snapshot control
  | _, _ =>
      mkLeanSaveSpecInProcess root path snapshot leanCmd?

private def hashDescr (path : FilePath) (ext : String) : IO ArtifactDescr :=
  return artifactWithExt (← computeHash path) ext

private def leanSaveOutputs
    (oleanPath : FilePath)
    (oleanServerPath? oleanPrivatePath? : Option FilePath)
    (ileanPath : FilePath)
    (irPath? irSigPath? : Option FilePath)
    (cPath : FilePath)
    (bcPath? : Option FilePath) : IO ModuleOutputDescrs := do
  let isModule := oleanServerPath?.isSome
  let olean ← hashDescr oleanPath "olean"
  let oleanServer? ← oleanServerPath?.mapM (fun path => hashDescr path "olean.server")
  let oleanPrivate? ← oleanPrivatePath?.mapM (fun path => hashDescr path "olean.private")
  let ilean ← hashDescr ileanPath "ilean"
  let ir? ← irPath?.mapM (fun path => hashDescr path "ir")
  let irSig? ← irSigPath?.mapM (fun path => hashDescr path "ir.sig")
  let c ← hashDescr cPath "c"
  let bc? ← bcPath?.mapM (fun path => hashDescr path "bc")
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

/-- Remove metadata for the prior artifact family before a new family can be published. -/
def invalidateLeanSaveTrace (spec : LeanSaveSpec) : IO Unit := do
  if ← spec.tracePath.isDir then
    throw <| IO.userError s!"Lake save trace path is a directory: {spec.tracePath}"
  if ← spec.tracePath.pathExists then
    IO.FS.removeFile spec.tracePath

private def writeLeanSaveTraceWithMetadata
    (request : LakeHelperWriteTraceRequest) : IO Unit := do
  let metadata : BuildMetadata ← IO.ofExcept <| fromJson? request.traceMetadata
  let outputs ← leanSaveOutputs
    (FilePath.mk request.oleanPath)
    (request.oleanServerPath?.map FilePath.mk)
    (request.oleanPrivatePath?.map FilePath.mk)
    (FilePath.mk request.ileanPath)
    (request.irPath?.map FilePath.mk)
    (request.irSigPath?.map FilePath.mk)
    (FilePath.mk request.cPath)
    (request.bcPath?.map FilePath.mk)
  let metadata := { metadata with outputs? := some <| toJson outputs }
  let tracePath := FilePath.mk request.tracePath
  writeTraceAtomically tracePath fun stagedTrace =>
    BuildMetadata.writeFile stagedTrace metadata

def writeLeanSaveTrace (spec : LeanSaveSpec) (control : LakeHelperControl := {}) :
    IO (Except BrokerFailure Unit) := do
  try
    match spec.tracePlan with
    | .inProcess depTrace =>
        let outputs ← leanSaveOutputs spec.oleanPath spec.oleanServerPath?
          spec.oleanPrivatePath? spec.ileanPath spec.irPath? spec.irSigPath? spec.cPath spec.bcPath?
        writeTraceAtomically spec.tracePath fun stagedTrace =>
          writeBuildTrace stagedTrace depTrace outputs {}
        pure (.ok ())
    | .targetProcess helper root traceMetadata =>
        let request : LakeHelperWriteTraceRequest := {
          root := root.toString
          oleanPath := spec.oleanPath.toString
          oleanServerPath? := spec.oleanServerPath?.map (·.toString)
          oleanPrivatePath? := spec.oleanPrivatePath?.map (·.toString)
          ileanPath := spec.ileanPath.toString
          irPath? := spec.irPath?.map (·.toString)
          irSigPath? := spec.irSigPath?.map (·.toString)
          cPath := spec.cPath.toString
          bcPath? := spec.bcPath?.map (·.toString)
          tracePath := spec.tracePath.toString
          traceMetadata
        }
        match ← runLakeHelperWriteSaveTrace helper request control with
        | .ok _ => pure (.ok ())
        | .error failure => pure (.error failure)
  catch e =>
    pure <| .error {
      code := .internalError
      message := e.toString
    }

def lakeHelperSaveSpec
    (request : LakeHelperSaveRequest) (leanCmd : String) : IO (Except BrokerFailure LakeHelperSaveSpec) := do
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
  match ← mkLeanSaveSpecInProcess
      (FilePath.mk request.root) (FilePath.mk request.path) snapshot (some leanCmd) with
  | .error failure => pure <| .error failure
  | .ok spec =>
      let traceMetadata ←
        match spec.tracePlan with
        | .inProcess depTrace => pure <| toJson (BuildMetadata.ofBuild depTrace Json.null {})
        | .targetProcess .. =>
            return .error {
              code := .internalError
              message := "target Lake helper unexpectedly produced a delegated save trace"
            }
      pure <| .ok {
        root := request.root
        relPath := spec.relPath
        moduleName := spec.moduleName
        unsupportedSetupReason? := spec.unsupportedSetupReason?
        oleanPath := spec.oleanPath.toString
        oleanServerPath? := spec.oleanServerPath?.map (·.toString)
        oleanPrivatePath? := spec.oleanPrivatePath?.map (·.toString)
        ileanPath := spec.ileanPath.toString
        irPath? := spec.irPath?.map (·.toString)
        irSigPath? := spec.irSigPath?.map (·.toString)
        cPath := spec.cPath.toString
        bcPath? := spec.bcPath?.map (·.toString)
        tracePath := spec.tracePath.toString
        traceMetadata
      }

def lakeHelperWriteLeanSaveTrace (request : LakeHelperWriteTraceRequest) : IO Unit :=
  writeLeanSaveTraceWithMetadata request

end Beam.Broker
