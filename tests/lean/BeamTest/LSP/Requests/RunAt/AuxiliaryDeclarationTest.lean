/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.AuxiliaryDeclarationTest

private def probePosition (line : Nat) : Lean.Lsp.Position :=
  { line, character := 2 }

def run : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/RunAtAuxiliaryDeclarations.lean"
  let ordinaryDiagnostics ← collectDiagnostics doc
  if ordinaryDiagnostics.diagnostics.any (fun diagnostic => diagnostic.severity? == some .error) then
    throw <| IO.userError
      s!"ordinary auxiliary-declaration fixture failed: {(toJson ordinaryDiagnostics).compress}"

  -- LSP coordinates are zero-based: these point at the first tactic character on each line.
  requireRunAtSolvesProof "omega inside a namespaced theorem" doc (probePosition 6) "omega"
  requireRunAtSolvesProof "grind inside a namespaced theorem" doc (probePosition 9) "grind"

  requireRunAtSolvesProof "decide +kernel inside a closed theorem" doc
    (probePosition 15) "decide +kernel"

  -- A second independent probe of the same goal must not depend on the first run's aux lemma.
  requireRunAtSolvesProof "repeat decide +kernel independently" doc
    (probePosition 15) "decide +kernel"

  -- A stored snapshot must retain the declaration context for its later tactic continuation.
  let partialReq ← sendRunAt doc {
    line := 18
    character := 2
    text := "first | constructor; decide +kernel | skip"
    storeHandle := true
  }
  let partialResult : Beam.LSP.RunAt.Result ← awaitResponseAs partialReq
  unless partialResult.success do
    throw <| IO.userError s!"partial kernel-proof runAt failed: {(toJson partialResult).compress}"
  unless partialResult.proofState?.map (·.goals.size) == some 1 do
    throw <| IO.userError s!"partial kernel-proof runAt should retain one goal: {(toJson partialResult).compress}"
  let some handle := partialResult.handle?
    | throw <| IO.userError "partial kernel-proof runAt did not retain its proof handle"
  let continuation ← runWithHandle doc handle { text := "decide +kernel" }
  let continued ← requireRunAtResponseSuccess
    "decide +kernel in a stored proof continuation" continuation
  unless continued.proofState?.map (·.goals.isEmpty) == some true do
    throw <| IO.userError s!"handle continuation left goals: {(toJson continued).compress}"

  -- Command-mode elaboration establishes the ordinary declaration prefix itself.
  let commandReq ← sendRunAt doc {
    line := 24
    character := 0
    text := "theorem commandAuxProbe : 0 + 0 = 0 := by\n  decide +kernel"
  }
  discard <| requireRunAtResponseSuccess "command-mode decide +kernel" commandReq

  -- The speculative proof auxiliary stays out of the document environment.
  let isolationReq ← sendRunAt doc {
    line := 24
    character := 0
    text := "run_meta do\n  let env ← getEnv\n  let targetPrefix := `RunAtAuxiliaryDeclarations.closedGoal\n  if env.constants.toList.any (fun (name, _) => name != targetPrefix && targetPrefix.isPrefixOf name) then\n    throwError \"speculative proof auxiliary leaked into the document\"\n  if env.contains `commandAuxProbe then\n    throwError \"speculative command declaration leaked into the document\""
  }
  discard <| requireRunAtResponseSuccess "speculative auxiliary isolation" isolationReq

  if let some finalDiagnostics ← collectDiagnostics? doc then
    unless finalDiagnostics.diagnostics == ordinaryDiagnostics.diagnostics do
      throw <| IO.userError
        s!"runAt auxiliary probes changed document diagnostics: before={(toJson ordinaryDiagnostics.diagnostics).compress}, after={(toJson finalDiagnostics.diagnostics).compress}"
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.AuxiliaryDeclarationTest
