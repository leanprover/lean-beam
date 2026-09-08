/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Save
import Beam.Broker.LakeSave
import Beam.Broker.Protocol
import Beam.Path

open Lean
open Lean.Lsp

namespace Beam.Broker

def isIncompleteBarrierDiagnostic (diagnostic : Diagnostic) : Bool :=
  diagnostic.message.contains "Failed to build module dependencies." ||
    diagnostic.message.contains "error: target is out-of-date and needs to be rebuilt" ||
    diagnostic.message.contains "Imports are out of date and should be rebuilt"

private def isFileWorkerSetupProgressRange (range : Range) : Bool :=
  range.start.line == 0 &&
    range.start.character == 0 &&
    range.«end».line == 1 &&
    range.«end».character == 0

private def lakeBuildMonitorPrefixes : Array String :=
  #["✔ [", "✖ [", "⚠ [", "ℹ ["]

private def lakeBuildMonitorVerbs : Array String :=
  #[
    "Ran", "Running",
    "Reused", "Reusing",
    "Replayed", "Replaying",
    "Unpacked", "Unpacking",
    "Fetched", "Fetching",
    "Built", "Building"
  ]

private def isLakeBuildMonitorLine (message : String) : Bool :=
  let line := message.trimAscii.toString
  lakeBuildMonitorPrefixes.any (fun linePrefix => line.startsWith linePrefix) &&
    lakeBuildMonitorVerbs.any (fun verb => line.contains s!" {verb} ")

/--
Best-effort recognizer for Lean file-worker `lake setup-file` progress.

Lean currently exposes this as ordinary information diagnostics, so Beam has to match the
temporary diagnostic envelope and Lake build-monitor line shape. Keep this narrow until Lean
exposes typed setup/build progress.
-/
private def isLakeSetupFileProgress
    (severity? : Option DiagnosticSeverity)
    (range : Range)
    (message : String) : Bool :=
  match severity? with
  | some .information =>
      isFileWorkerSetupProgressRange range &&
        isLakeBuildMonitorLine message
  | _ =>
      false

def isLakeSetupFileProgressDiagnostic (diagnostic : Diagnostic) : Bool :=
  isLakeSetupFileProgress diagnostic.severity? diagnostic.range diagnostic.message

def isLakeSetupFileProgressStreamDiagnostic (diagnostic : StreamDiagnostic) : Bool :=
  isLakeSetupFileProgress diagnostic.severity? diagnostic.range diagnostic.message

def effectiveSyncDiagnosticSeverity (diagnostic : Diagnostic) :
    Option DiagnosticSeverity :=
  if isIncompleteBarrierDiagnostic diagnostic then
    some .error
  else
    diagnostic.severity?

def isSyncErrorDiagnostic (diagnostic : Diagnostic) : Bool :=
  match effectiveSyncDiagnosticSeverity diagnostic with
  | some .error => true
  | _ => false

def filterSyncDiagnostics (diagnosticScope : DiagnosticScope) (diagnostics : Array Diagnostic) :
    Array Diagnostic :=
  let diagnostics := Beam.LSP.Lib.userVisibleDiagnostics diagnostics
  if diagnosticScope == .all then
    diagnostics
  else
    let completionBlocking := diagnostics.filter isIncompleteBarrierDiagnostic
    if !completionBlocking.isEmpty then
      completionBlocking
    else
      diagnostics.filter fun diagnostic =>
        isSyncErrorDiagnostic diagnostic ||
          isLakeSetupFileProgressDiagnostic diagnostic

def diagnosticDisplayPath (root : System.FilePath) (uri : DocumentUri) : String :=
  match System.Uri.fileUriToPath? uri with
  | some path => Beam.pathRelativeToRootOrSelf root path
  | none =>
      uri

def streamDiagnosticOfDiagnostic
    (root : System.FilePath)
    (uri : DocumentUri)
    (snapshot? : Option SnapshotRef)
    (diagnostic : Diagnostic) : StreamDiagnostic := {
  path := diagnosticDisplayPath root uri
  uri
  snapshot?
  severity? := effectiveSyncDiagnosticSeverity diagnostic
  range := diagnostic.fullRange
  message := diagnostic.message
  completionBlocking := isIncompleteBarrierDiagnostic diagnostic
}

def streamDiagnosticsForReply
    (root : System.FilePath)
    (uri : DocumentUri)
    (snapshot : SnapshotRef)
    (diagnosticScope : DiagnosticScope)
    (diagnostics : Array Diagnostic) : Array StreamDiagnostic :=
  (filterSyncDiagnostics diagnosticScope diagnostics).map fun diagnostic =>
    streamDiagnosticOfDiagnostic root uri (some snapshot) diagnostic

def syncErrorCount (diagnostics : Array Diagnostic) : Nat :=
  diagnostics.foldl (init := 0) fun count diagnostic =>
    if isSyncErrorDiagnostic diagnostic then
      count + 1
    else
      count

structure SyncSaveReadiness where
  /-- Current backend diagnostics for reporting; `saveReady` remains the readiness authority. -/
  currentDiagnostics : Array Diagnostic := #[]
  saveReady : Bool := true
  saveReadyReason : String := "ok"
  saveReadyMessage? : Option String := none
  blockingDiagnostics : Array SyncBlockingDiagnostic := #[]
  blockingCommandMessages : Array SyncBlockingCommandMessage := #[]
  deriving Inhabited

private def syncBlockingDiagnosticOfResult
    (diagnostic : Beam.LSP.Save.SaveBlockingDiagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.range
  severity? := diagnostic.severity?
  message := diagnostic.message
  saveBlocking := diagnostic.saveBlocking
  completionBlocking := diagnostic.completionBlocking
}

private def syncBlockingCommandMessageOfResult
    (message : Beam.LSP.Save.SaveBlockingCommandMessage) : SyncBlockingCommandMessage := {
  message := message.message
  saveBlocking := message.saveBlocking
  completionBlocking := message.completionBlocking
}

def syncSaveReadinessOfResult
    (result : Beam.LSP.Save.SaveReadinessResult) : SyncSaveReadiness :=
  {
    currentDiagnostics := result.currentDiagnostics
    saveReady := result.saveReady
    saveReadyReason := result.saveReadyReason
    saveReadyMessage? := result.saveReadyMessage?
    blockingDiagnostics := result.blockingDiagnostics.map syncBlockingDiagnosticOfResult
    blockingCommandMessages := result.blockingCommandMessages.map syncBlockingCommandMessageOfResult
  }

def syncBlockingDiagnosticOfDiagnostic
    (saveBlocking completionBlocking : Bool)
    (diagnostic : Diagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.fullRange
  severity? := effectiveSyncDiagnosticSeverity diagnostic
  message := diagnostic.message
  saveBlocking
  completionBlocking
}

def completionBlockingDiagnostics (diagnostics : Array Diagnostic) : Array SyncBlockingDiagnostic :=
  diagnostics.filterMap fun diagnostic =>
    if isIncompleteBarrierDiagnostic diagnostic then
      some <| syncBlockingDiagnosticOfDiagnostic false true diagnostic
    else
      none

def saveBlockingFallbackDiagnostics (diagnostics : Array Diagnostic) : Array SyncBlockingDiagnostic :=
  diagnostics.filterMap fun diagnostic =>
    if isSyncErrorDiagnostic diagnostic then
      some <| syncBlockingDiagnosticOfDiagnostic true false diagnostic
    else
      none

def normalizeSyncSaveReadiness
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncSaveReadiness :=
  if readiness.saveReady ||
      !readiness.blockingDiagnostics.isEmpty ||
      !readiness.blockingCommandMessages.isEmpty then
    readiness
  else
    { readiness with blockingDiagnostics := saveBlockingFallbackDiagnostics diagnostics }

def diagnosticsIndicateIncompleteBarrier (diagnostics : Array Diagnostic) : Bool :=
  diagnostics.any isIncompleteBarrierDiagnostic

def incompleteBarrierProgress (progress? : Option SyncFileProgress := none) : SyncFileProgress :=
  match progress? with
  | some progress => { progress with done := false }
  | none => { done := false }

def syncBarrierIncompleteMessage
    (uri : DocumentUri)
    (version : Nat)
    (progress? : Option SyncFileProgress) : String :=
  let progress := incompleteBarrierProgress progress?
  s!"Lean diagnostics barrier did not complete for {uri} at version {version}; " ++
    s!"fileProgress={toJson progress |>.compress}. An imported target may be stale or broken, " ++
    s!"or the Lean worker may have exited. Run `lake build` or fix the upstream module first."

def syncBarrierIncomplete?
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic := #[]) : Bool :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    true
  else
    match progress? with
    | some progress => !progress.done
    | none => false

def effectiveSyncBarrierProgress
    (priorProgress? : Option SyncFileProgress)
    (progress? : Option SyncFileProgress)
    (diagnostics : Array Diagnostic) : Option SyncFileProgress :=
  if diagnosticsIndicateIncompleteBarrier diagnostics then
    some <| incompleteBarrierProgress (progress?.or priorProgress?)
  else
    match progress? with
    | some progress =>
        some progress
    | none =>
        some <| priorProgress?.getD {}

def leanSaveResult
    (spec : LeanSaveSpec)
    (sourceHash : Lake.Hash)
    (sync : SyncFileResult) : SaveOleanResult := {
  module := spec.moduleName
  sourceHash := sourceHash.toString
  olean := spec.oleanPath.toString
  ilean := spec.ileanPath.toString
  c := spec.cPath.toString
  trace := spec.tracePath.toString
  oleanServer? := spec.oleanServerPath?.map (·.toString)
  oleanPrivate? := spec.oleanPrivatePath?.map (·.toString)
  ir? := spec.irPath?.map (·.toString)
  bc? := spec.bcPath?.map (·.toString)
  sync
}

end Beam.Broker
