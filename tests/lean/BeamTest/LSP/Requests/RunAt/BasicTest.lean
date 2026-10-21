/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.BasicTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def requestCancelledJson : Json :=
  Json.mkObj [("code", toJson "requestCancelled")]

def checkRunAtTacticPositions : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TacticPositionProof.lean"
  syncDoc doc

  -- At the start of simp, its replacement must handle the unsimplified goal.
  requireRunAtFailureMessage "runAt at simp start" doc { line := 1, character := 2 }
    "exact h" "0 + a = b"
  let simplified ← requireRunAtSuccess "rerun simp at its start" doc
    { line := 1, character := 2 } "simp"
  unless simplified.proofState?.map (·.goals.map (·.target)) == some #["a = b"] do
    throw <| IO.userError s!"simp should leave a = b, got {(toJson simplified).compress}"

  -- Moving inside simp or to its end selects the state after it.
  for character in [3, 6] do
    requireRunAtSolvesProof "runAt inside/at end of simp" doc { line := 1, character }
      "exact h"

  -- Zero-based line 2 is exact h; its before-state already includes simp's effect.
  requireRunAtSolvesProof "runAt at exact start" doc { line := 2, character := 2 } "exact h"
  requireRunAtFailureMessage "simp at exact start" doc { line := 2, character := 2 }
    "simp" "made no progress"
  requireRunAtFailureMessage "runAt inside exact" doc { line := 2, character := 3 }
    "exact h" "No goals to be solved"

  -- Explicit goal queries expose both states without changing later probes.
  for (useAfter, target) in [(false, "0 + a = b"), (true, "a = b")] do
    let req ← sendGoals doc { line := 1, character := 2, useAfter }
    let state : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    unless state.goals.map (·.target) == #[target] do
      throw <| IO.userError s!"goals useAfter={useAfter}: expected {target}, got {(toJson state).compress}"
  requireRunAtFailureMessage "runAt still uses simp's before-state" doc
    { line := 1, character := 2 } "exact h" "0 + a = b"

  -- A real LSP replacement agrees with the probe at the tactic's start.
  changeDoc doc { line := 1, character := 2, delete := "simp", insert := "exact h" }
  let diagnostics ← collectDiagnostics doc
  unless diagnostics.diagnostics.any (fun diagnostic =>
      diagnostic.severity? == some .error && diagnostic.range.start.line == 1 &&
      diagnostic.message.contains "0 + a = b") do
    throw <| IO.userError s!"expected replacement type mismatch, got {(toJson diagnostics).compress}"
  closeDoc doc

def checkRunAtTacticSequences : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TacticPositionProof.lean"
  syncDoc doc
  let simpStart : Lean.Lsp.Position := { line := 1, character := 2 }

  requireRunAtSolvesProof "newline-separated tactics" doc simpStart "simp\nexact h"
  requireRunAtSolvesProof "semicolon-separated tactics" doc simpStart "simp; exact h"
  requireRunAtSolvesProof "uniformly indented tactics" doc simpStart "  simp\n  exact h"
  -- A more indented line still continues the previous tactic's arguments, as in a `by` block.
  requireRunAtSolvesProof "indented argument continuation" doc simpStart
    "revert a b\n  h\nintro a b\nsimp"
  -- Parsed as one tactic, `intro a⏎omega` would introduce `b` under the name `omega` and succeed
  -- without running `omega`, leaving the goal open.
  requireRunAtSolvesProof "line break ends tactic arguments" doc { line := 4, character := 2 }
    "intro a\nomega"
  closeDoc doc

def checkRunAtOneCommandOnly : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt command sequence" doc { line := 8, character := 0 }
    "def runAtOneCommandA : Nat := 1\n\n#check runAtOneCommandA"
    "runAtSupportsOneCommandOnly"
  closeDoc doc

def checkRunAtTheoremProofFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem proof failure" doc { line := 8, character := 0 }
    "theorem runAtImpossibleProbe : False := by\n  trivial"
    "False"
  closeDoc doc

def checkRunAtTheoremSuccessOmitsSilentMessages : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  let req ← sendRunAt doc {
    line := 8
    character := 0
    text := "theorem runAtCompletedProbe : True := by\n  trivial"
  }
  let result ← requireRunAtResponseSuccess "runAt completed theorem" req
  if result.messages.any (fun message => message.text.contains "Goals accomplished") then
    throw <| IO.userError
      s!"runAt completed theorem leaked a silent lifecycle message: {(toJson result).compress}"
  closeDoc doc

def checkRunAtTheoremTacticFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TopLevelTheoremRunAtFailure.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem tactic failure" doc { line := 7, character := 0 }
    "theorem runAtTacticFailureProbe : True := by\n  runat_fail_tac"
    "runAt custom tactic failure"
  closeDoc doc

def checkRunAtInvalidPositionLine : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 99, character := 0, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtInvalidPositionCharacter : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 0, character := 200, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtStaleEdit : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"

  let staleReq ← sendRunAt doc { line := 1, character := 2, text := "exact trivial" }
  invalidateWithWhitespacePrefixEdit doc

  expectContentModified staleReq

  closeDoc doc

def checkRunAtStaleVersion : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc

  let staleReq ← sendRunAt doc {
    version? := some 0
    line := 1
    character := 2
    text := "exact trivial"
  }
  expectContentModified staleReq

  closeDoc doc

def checkRunAtStaleEditConcurrentRequest : ScenarioM Unit := do
  let staleDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let survivorDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let staleReq ← sendRunAt staleDoc { line := 1, character := 2, text := "exact trivial" }
  let survivorReq ← sendRunAt survivorDoc { line := 1, character := 2, text := "exact trivial" }

  invalidateWithWhitespacePrefixEdit staleDoc

  expectContentModified staleReq
  discard <| requireRunAtResponseSuccess "runAt concurrent request after stale edit" survivorReq

  closeDoc staleDoc
  closeDoc survivorDoc

def checkRunAtCancellation : ScenarioM Unit := do
  let slowDoc ← openDoc "tests/scenario/docs/SlowClose.lean"
  let fastDoc ← openDoc "tests/scenario/docs/CommandB.lean"

  let slowReq ← sendRunAt slowDoc { line := 8, character := 2, text := "exact trivial" }
  let fastReq ← sendRunAt fastDoc { line := 0, character := 2, text := "#check Nat" }

  cancelReq slowReq

  let fastResult ← requireRunAtResponseSuccess "runAt cancellation survivor" fastReq
  unless fastResult.messages.any (fun msg =>
      msg.severity == MessageSeverity.information && msg.text.contains "Nat : Type") do
    throw <| IO.userError
      s!"runAt cancellation survivor: expected Nat information message, got {(toJson fastResult).compress}"

  expectErrorContains slowReq requestCancelledJson

  closeDoc slowDoc
  closeDoc fastDoc

def checkRunAtWithStandardLspInterference : ScenarioM Unit := do
  let runAtDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let runAtReq ← sendRunAt runAtDoc { line := 1, character := 2, text := "exact trivial" }
  syncWhitespacePrefixEdit editDoc

  discard <| requireRunAtResponseSuccess "runAt with LSP interference" runAtReq

  closeDoc runAtDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkRunAtTacticPositions
  checkRunAtTacticSequences
  checkRunAtOneCommandOnly
  checkRunAtTheoremSuccessOmitsSilentMessages
  checkRunAtTheoremProofFailure
  checkRunAtTheoremTacticFailure
  checkRunAtInvalidPositionLine
  checkRunAtInvalidPositionCharacter
  checkRunAtStaleEdit
  checkRunAtStaleVersion
  checkRunAtStaleEditConcurrentRequest
  checkRunAtCancellation
  checkRunAtWithStandardLspInterference

end BeamTest.LSP.Requests.RunAt.BasicTest
