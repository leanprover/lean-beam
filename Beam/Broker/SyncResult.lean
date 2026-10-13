/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.DocumentState
import Beam.Broker.Protocol
import Beam.Broker.SyncSaveSupport

open Lean
open Lean.Lsp

namespace Beam.Broker

private def diagnosticCounts (diagnostics : Array Diagnostic) : SyncDiagnosticCounts :=
  diagnostics.foldl (init := {}) fun counts diagnostic =>
    match effectiveSyncDiagnosticSeverity diagnostic with
    | some .error => { counts with error := counts.error + 1 }
    | some .warning => { counts with warning := counts.warning + 1 }
    | some .information => { counts with information := counts.information + 1 }
    | some .hint => { counts with hint := counts.hint + 1 }
    | none => { counts with unknown := counts.unknown + 1 }

/--
Compute `blockingErrorCount` from save-blocking evidence, falling back to diagnostic errors only
when a non-ready verdict did not provide evidence.
-/
private def blockingErrorCount
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : Nat :=
  if readiness.saveReady then
    0
  else
    let diagnosticCount :=
      readiness.blockingDiagnostics.foldl (init := 0) fun count diagnostic =>
        if diagnostic.saveBlocking then count + 1 else count
    let commandCount :=
      readiness.blockingCommandMessages.foldl (init := 0) fun count message =>
        if message.saveBlocking then count + 1 else count
    if diagnosticCount > 0 then
      diagnosticCount
    else if commandCount > 0 then
      commandCount
    else
      syncErrorCount diagnostics

def syncResultReadiness
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness) : SyncResultReadiness :=
  {
    saveReady := readiness.saveReady
    reason := readiness.saveReadyReason
    blockingErrorCount := blockingErrorCount diagnostics readiness
    blockingDiagnostics := readiness.blockingDiagnostics
    blockingMessages := readiness.blockingCommandMessages
  }

def mkSyncFileResult
    (path : String)
    (snapshot : SnapshotRef)
    (diagnostics : Array Diagnostic)
    (readiness : SyncSaveReadiness)
    (items? : Option (Array StreamDiagnostic) := none) : SyncFileResult :=
  let diagnostics := Beam.LSP.Lib.userVisibleDiagnostics diagnostics
  let readiness := normalizeSyncSaveReadiness diagnostics readiness
  {
    path
    snapshot
    diagnostics := {
      counts := diagnosticCounts diagnostics
      items?
    }
    readiness := syncResultReadiness diagnostics readiness
  }

end Beam.Broker
