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

private def moduleOutputIsModuleName : Name :=
  .str (.str (.str .anonymous "Lake") "ModuleOutputDescrs") "isModule"

private def moduleOutputOptionalCName : Name :=
  .str (.str (.str .anonymous "Lake") "ModuleOutputDescrs") "c?"

-- Lake v4.30 added `ModuleOutputDescrs.isModule`; older supported Lake versions do not have it.
-- Lake in nightly-2026-10-13 made `c` optional to support postponed code generation. Beam saves
-- generated C, so that record shape must carry `some c` rather than leave the output absent.
-- Select the record shape at elaboration time so save traces work across the supported range.
elab "mkModuleOutputDescrsCompat(" isModule:term ", " olean:term ", " oleanServer:term ", "
    oleanPrivate:term ", " ilean:term ", " ir:term ", " c:term ", " bc:term ")" : term => do
  if (← getEnv).contains moduleOutputOptionalCName then
    Lean.Elab.Term.elabTerm (← `(term| ({
      isModule := $isModule
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      c? := some $c
      bc? := $bc
    } : ModuleOutputDescrs))) none
  else if (← getEnv).contains moduleOutputIsModuleName then
    Lean.Elab.Term.elabTerm (← `(term| ({
      isModule := $isModule
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      c := $c
      bc? := $bc
    } : ModuleOutputDescrs))) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (
    let _ := $isModule
    {
      olean := $olean
      oleanServer? := $oleanServer
      oleanPrivate? := $oleanPrivate
      ilean := $ilean
      ir? := $ir
      c := $c
      bc? := $bc
    } : ModuleOutputDescrs))) none

inductive LeanSaveTracePlan where
  | inProcess (depTrace : BuildTrace)
  | targetProcess (helper : FilePath) (request : LakeHelperWriteTraceRequest)

structure LeanSaveSpec where
  relPath : String
  moduleName : String
  unsupportedSetupReason? : Option String := none
  oleanPath : FilePath
  oleanServerPath? : Option FilePath := none
  oleanPrivatePath? : Option FilePath := none
  ileanPath : FilePath
  irPath? : Option FilePath := none
  cPath : FilePath
  bcPath? : Option FilePath := none
  tracePath : FilePath
  tracePlan : LeanSaveTracePlan

structure SourceSnapshot where
  hash : Hash
  mtime : MTime

private def traceOptions (opts : LeanOptions) (caption := "opts") : BuildTrace :=
  opts.values.foldl (init := .nil caption) fun t n v =>
    let opt := s!"-D{n}={v.asCliFlagValue}"
    t.mix <| .ofHash (pureHash opt) opt

-- Lean/Lake v4.28 compatibility shim: newer Lake versions let `addPureTrace` hash any `Hashable`
-- value directly, but v4.28 lacks that generic `ComputeHash` instance. When we drop v4.28 support,
-- replace this helper with the upstream-style `addPureTrace mod.name` / `addPureTrace mod.pkg.id?`.
private def hashOfHashable [Hashable α] (a : α) : Hash :=
  Hash.mix Hash.nil <| Hash.mk <| hash a

private def addHashablePureTrace [ToString α] [Hashable α] (a : α) (caption := "pure") : JobM PUnit :=
  addTrace <| .ofHash (hashOfHashable a) s!"{caption}: {toString a}"

private def unsupportedZeroBuildSaveReason? (mod : Lake.Module) : Option String :=
  if !mod.leanArgs.isEmpty then
    some "Lake module uses batch-only moreLeanArgs"
  else
    none

private def quietTraceConfig : BuildConfig :=
  { verbosity := .quiet }

private def sourceTrace (path : FilePath) (snapshot : SourceSnapshot) : BuildTrace :=
  {
    caption := path.toString
    hash := snapshot.hash
    mtime := snapshot.mtime
  }

private def buildDepTraceJob
    (mod : Lake.Module)
    (snapshot : SourceSnapshot) : FetchM (Job (BuildTrace × Bool × Option String)) := do
    let setupJob ← mod.setup.fetch
    setupJob.mapM (sync := true) fun setup => do
      addLeanTrace
      addTrace <| sourceTrace mod.leanFile snapshot
      addTrace <| traceOptions setup.options "options"
      addPureTrace setup.isModule "isModule"
      addHashablePureTrace mod.name "Module.name"
      addHashablePureTrace mod.pkg.id? "Package.id?"
      addPureTrace mod.leanArgs "Module.leanArgs"
      setTraceCaption s!"{mod.name.toString}:leanArts"
      return (← getTrace, setup.isModule, unsupportedZeroBuildSaveReason? mod)

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
    (snapshot : SourceSnapshot) : IO (Except BrokerFailure (BuildTrace × Bool × Option String)) := do
  match ← ensureSaveTraceReady ws root path mod snapshot with
  | .error failure => pure <| .error failure
  | .ok () =>
      try
        .ok <$> ws.runBuild (cfg := quietTraceConfig) (buildDepTraceJob mod snapshot)
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
              "lean-beam save requires the target and broker to use the same Lean build; " ++
              "use lake build instead"
          }
    let some mod := ws.findModuleBySrc? path
      | return .error {
          code := .saveTargetNotModule
          message :=
            s!"could not resolve a Lake module for {path}. " ++
            "lean-beam save only works for synced files that belong to the current Lake workspace package graph."
        }
    let depTraceResult ← buildDepTrace ws root path mod snapshot
    let (depTrace, isModule, unsupportedSetupReason?) ←
      match depTraceResult with
      | .ok result => pure result
      | .error failure => return .error failure
    let relPath := Beam.pathRelativeToRootOrSelf root path
    pure <| .ok {
      relPath
      moduleName := mod.name.toString
      unsupportedSetupReason?
      oleanPath := mod.oleanFile
      oleanServerPath? := if isModule then some mod.oleanServerFile else none
      oleanPrivatePath? := if isModule then some mod.oleanPrivateFile else none
      ileanPath := mod.ileanFile
      irPath? := if isModule then some mod.irFile else none
      cPath := mod.cFile
      bcPath? := if Lean.Internal.hasLLVMBackend () then some mod.bcFile else none
      tracePath := mod.traceFile
      tracePlan := .inProcess depTrace
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
    cPath := FilePath.mk spec.cPath
    bcPath? := spec.bcPath?.map FilePath.mk
    tracePath := FilePath.mk spec.tracePath
    tracePlan := .targetProcess helper spec.toLakeHelperWriteTraceRequest
  }

private def mkLeanSaveSpecWithHelper
    (helper root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd : String) : IO (Except BrokerFailure LeanSaveSpec) := do
  let request : LakeHelperSaveRequest := {
    root := root.toString
    path := path.toString
    leanCmd
    sourceHash := snapshot.hash.toString
    sourceMTimeSec := snapshot.mtime.sec
    sourceMTimeNsec := snapshot.mtime.nsec.toNat
  }
  match ← runLakeHelperPrepareSave helper request with
  | .error failure => pure <| .error failure
  | .ok spec => pure <| .ok (leanSaveSpecOfHelperSpec helper spec)

def mkLeanSaveSpec
    (root path : FilePath)
    (snapshot : SourceSnapshot)
    (leanCmd? : Option String := none)
    (lakeHelper? : Option FilePath := none) : IO (Except BrokerFailure LeanSaveSpec) := do
  match lakeHelper?, leanCmd? with
  | some helper, some leanCmd =>
      mkLeanSaveSpecWithHelper helper root path snapshot leanCmd
  | _, _ =>
      mkLeanSaveSpecInProcess root path snapshot leanCmd?

private def hashDescr (path : FilePath) (ext : String) : IO ArtifactDescr :=
  return artifactWithExt (← computeHash path) ext

private def leanSaveOutputs
    (oleanPath : FilePath)
    (oleanServerPath? oleanPrivatePath? : Option FilePath)
    (ileanPath : FilePath)
    (irPath? : Option FilePath)
    (cPath : FilePath)
    (bcPath? : Option FilePath) : IO ModuleOutputDescrs := do
  let isModule := oleanServerPath?.isSome
  let olean ← hashDescr oleanPath "olean"
  let oleanServer? ← oleanServerPath?.mapM (fun path => hashDescr path "olean.server")
  let oleanPrivate? ← oleanPrivatePath?.mapM (fun path => hashDescr path "olean.private")
  let ilean ← hashDescr ileanPath "ilean"
  let ir? ← irPath?.mapM (fun path => hashDescr path "ir")
  let c ← hashDescr cPath "c"
  let bc? ← bcPath?.mapM (fun path => hashDescr path "bc")
  pure <| mkModuleOutputDescrsCompat(
    isModule, olean, oleanServer?, oleanPrivate?, ilean, ir?, c, bc?)

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
    (FilePath.mk request.cPath)
    (request.bcPath?.map FilePath.mk)
  let metadata := { metadata with outputs? := some <| toJson outputs }
  let tracePath := FilePath.mk request.tracePath
  writeTraceAtomically tracePath fun stagedTrace =>
    BuildMetadata.writeFile stagedTrace metadata

def writeLeanSaveTrace (spec : LeanSaveSpec) : IO (Except BrokerFailure Unit) := do
  try
    match spec.tracePlan with
    | .inProcess depTrace =>
        let outputs ← leanSaveOutputs spec.oleanPath spec.oleanServerPath?
          spec.oleanPrivatePath? spec.ileanPath spec.irPath? spec.cPath spec.bcPath?
        writeTraceAtomically spec.tracePath fun stagedTrace =>
          writeBuildTrace stagedTrace depTrace outputs {}
        pure (.ok ())
    | .targetProcess helper request =>
        match ← runLakeHelperWriteSaveTrace helper request with
        | .ok _ => pure (.ok ())
        | .error failure => pure (.error failure)
  catch e =>
    pure <| .error {
      code := .internalError
      message := e.toString
    }

def lakeHelperSaveSpec
    (request : LakeHelperSaveRequest) : IO (Except BrokerFailure LakeHelperSaveSpec) := do
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
      (FilePath.mk request.root) (FilePath.mk request.path) snapshot (some request.leanCmd) with
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
        relPath := spec.relPath
        moduleName := spec.moduleName
        unsupportedSetupReason? := spec.unsupportedSetupReason?
        oleanPath := spec.oleanPath.toString
        oleanServerPath? := spec.oleanServerPath?.map (·.toString)
        oleanPrivatePath? := spec.oleanPrivatePath?.map (·.toString)
        ileanPath := spec.ileanPath.toString
        irPath? := spec.irPath?.map (·.toString)
        cPath := spec.cPath.toString
        bcPath? := spec.bcPath?.map (·.toString)
        tracePath := spec.tracePath.toString
        traceMetadata
      }

def lakeHelperWriteLeanSaveTrace (request : LakeHelperWriteTraceRequest) : IO Unit :=
  writeLeanSaveTraceWithMetadata request

end Beam.Broker
