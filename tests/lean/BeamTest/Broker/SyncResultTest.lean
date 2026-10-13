/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.SyncResult
import BeamTest.Broker.JsonAssert
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.SyncResultTest

private def lspPos (line character : Nat) : Lsp.Position :=
  { line, character }

private def lspRange (line startCharacter endCharacter : Nat) : Lsp.Range :=
  { start := lspPos line startCharacter, «end» := lspPos line endCharacter }

private def diagnostic
    (line startCharacter endCharacter : Nat)
    (severity? : Option DiagnosticSeverity)
    (message : String) : Diagnostic :=
  let range := lspRange line startCharacter endCharacter
  {
    range
    fullRange? := some range
    severity?
    message
  }

private def blockingEvidence (diagnostic : Diagnostic) : SyncBlockingDiagnostic := {
  range := diagnostic.fullRange
  severity? := diagnostic.severity?
  message := diagnostic.message
  saveBlocking := true
  completionBlocking := false
}

private def commandEvidence (message : String) : SyncBlockingCommandMessage := {
  message
  saveBlocking := true
  completionBlocking := false
}

private def checkFirstSyncResult : IO Unit := do
  let warning := diagnostic 0 0 1 (some .warning) "warning only"
  let readiness : SyncSaveReadiness := {
    saveReady := true
    saveReadyReason := "ok"
  }
  let result := mkSyncFileResult "Demo.lean" ⟨"test-session", 1⟩ #[warning] readiness

  require "first sync path and snapshot" (result.path == "Demo.lean" && result.snapshot == ⟨"test-session", 1⟩)
  require "first sync records warning count"
    (result.diagnostics.counts.warning == 1 && result.diagnostics.counts.total == 1)
  require "first sync readiness is current verdict"
    (result.readiness.saveReady && result.readiness.reason == "ok")

private def checkCurrentCountsAndReadinessEvidence : IO Unit := do
  let duplicate := diagnostic 0 0 1 (some .warning) "duplicated warning"
  let added := diagnostic 1 0 1 (some .error) "new error"
  let readiness : SyncSaveReadiness := {
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence added]
    blockingCommandMessages := #[commandEvidence "new error"]
  }
  let result := mkSyncFileResult "Demo.lean" ⟨"test-session", 3⟩ #[duplicate, duplicate, added] readiness

  require "duplicate diagnostic current counts"
    (result.diagnostics.counts.warning == 2 &&
      result.diagnostics.counts.error == 1 &&
      result.diagnostics.counts.total == 3)
  require "readiness current verdict reflects blocking evidence"
    (result.readiness.blockingErrorCount == 1 &&
      result.readiness.blockingDiagnostics.size == 1 &&
      result.readiness.blockingMessages.size == 1 &&
      !result.readiness.saveReady)

private def checkEffectiveSeverityCounts : IO Unit := do
  let message := "Failed to build module dependencies."
  let currentDiagnostic := diagnostic 0 0 1 (some .error) message
  let readiness : SyncSaveReadiness := {
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence currentDiagnostic]
  }
  let result := mkSyncFileResult "Demo.lean" ⟨"test-session", 5⟩ #[currentDiagnostic] readiness

  require "effective severity counts incomplete-barrier diagnostic as error"
    (result.diagnostics.counts.error == 1 &&
      result.diagnostics.counts.unknown == 0)

private def checkDiagnosticErrorsDoNotOverrideReadiness : IO Unit := do
  let interactiveDiagnostic := diagnostic 0 0 1 (some .error) "interactive-only diagnostic"
  let readiness : SyncSaveReadiness := {
    saveReady := true
    saveReadyReason := "ok"
  }
  let result := mkSyncFileResult "Demo.lean" ⟨"test-session", 6⟩ #[interactiveDiagnostic] readiness

  require "diagnostic severity counts report current Lean diagnostics"
    (result.diagnostics.counts.error == 1 &&
      result.diagnostics.counts.total == 1)
  require "diagnostics do not override Lean save-readiness"
    (result.readiness.blockingErrorCount == 0 &&
      result.readiness.saveReady &&
      result.readiness.reason == "ok")
  require "result does not synthesize save-blocking evidence while Lean is ready"
    (result.readiness.blockingDiagnostics.isEmpty &&
      result.readiness.blockingMessages.isEmpty)

private def checkSaveBlockingEvidenceProjection : IO Unit := do
  let blockingDiagnostic := diagnostic 0 0 1 (some .error) "save-blocking diagnostic"
  let readiness : SyncSaveReadiness := {
    saveReady := false
    saveReadyReason := "documentErrors"
    blockingDiagnostics := #[blockingEvidence blockingDiagnostic]
    blockingCommandMessages := #[commandEvidence "save-blocking command message"]
  }
  let result := mkSyncFileResult "Demo.lean" ⟨"test-session", 7⟩ #[blockingDiagnostic] readiness

  require "save-blocking evidence appears in readiness result"
    (result.readiness.blockingDiagnostics.size == 1 &&
      result.readiness.blockingDiagnostics[0]?.map (·.saveBlocking) == some true &&
      result.readiness.blockingMessages.size == 1 &&
      result.readiness.blockingMessages[0]?.map (·.saveBlocking) == some true)

def main : IO Unit := do
  checkFirstSyncResult
  checkCurrentCountsAndReadinessEvidence
  checkEffectiveSeverityCounts
  checkDiagnosticErrorsDoNotOverrideReadiness
  checkSaveBlockingEvidenceProjection

end BeamTest.Broker.SyncResultTest

def main := BeamTest.Broker.SyncResultTest.main
