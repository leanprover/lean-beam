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

private def fixturePath : System.FilePath :=
  "tests/scenario/docs/RunAtAuxiliaryDeclarations.lean"

-- Markers tie tactic positions and ordinary document replacements to the same fixture text.
private def probeAt (source marker : String) : ScenarioM (Lsp.Position × String) := do
  let matches := source.splitOn "\n" |>.zipIdx |>.filter fun (line, _) =>
    line.endsWith s!" -- probe:{marker}"
  let [(line, lineNo)] := matches
    | throw <| IO.userError s!"expected exactly one fixture marker {marker}"
  let some code := (line.splitOn " -- probe:").head?
    | throw <| IO.userError s!"missing tactic at fixture marker {marker}"
  let character := (line.toList.takeWhile (· == ' ')).length
  pure ({ line := lineNo, character }, code.trimAscii.toString)

private def requireGoalCount (label : String) (count : Nat) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Unit := do
  unless result.proofState?.map (·.goals.size) == some count do
    throw <| IO.userError s!"{label}: expected {count} goals, got {(toJson result).compress}"

private def requireHandle (label : String) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Beam.LSP.RunAt.Handle := do
  let some handle := result.handle?
    | throw <| IO.userError s!"{label}: missing proof handle"
  pure handle

private def requireNoErrors (label : String) (diagnostics : Lsp.PublishDiagnosticsParams) :
    ScenarioM Unit := do
  if diagnostics.diagnostics.any (fun diagnostic => diagnostic.severity? == some .error) then
    throw <| IO.userError s!"{label}: {(toJson diagnostics).compress}"

private def requireAuxFailure (label : String) (result : Beam.LSP.RunAt.Result) :
    ScenarioM Unit := do
  if result.success || result.handle?.isSome then
    throw <| IO.userError s!"{label}: expected failure without a successor handle, got {(toJson result).compress}"
  unless result.messages.any (fun msg =>
      msg.severity == MessageSeverity.error && msg.text.contains "failure after auxiliary") do
    throw <| IO.userError s!"{label}: missing deliberate failure: {(toJson result).compress}"
  requireGoalCount label 1 result

private def checkDocumentIsolation (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, _) ← probeAt source "command"
  let result ← requireRunAtSuccess "document auxiliary isolation" doc position
    "#guard_aux_document_clean"
  if result.proofState?.isSome then
    throw <| IO.userError "document isolation query unexpectedly ran as a tactic"

-- Each case runs identical text through speculative execution and a real LSP document edit.
def checkAuxiliaryConformance (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let cases := [
    ("top-level", "fresh_aux decide +kernel"),
    ("omega", "fresh_aux omega"),
    ("grind", "fresh_aux grind"),
    ("decide", "fresh_aux decide +kernel"),
    ("private", "fresh_aux decide +kernel"),
    ("nested", "fresh_aux decide +kernel")
  ]
  let mut edits := #[]
  for (label, text) in cases do
    let (position, original) ← probeAt source label
    -- Both requests start from the document before either result is observed.
    let first ← sendRunAt doc { line := position.line, character := position.character, text }
    let second ← sendRunAt doc { line := position.line, character := position.character, text }
    for req in [first, second] do
      let result ← requireRunAtResponseSuccess s!"fresh auxiliary in {label}" req
      requireGoalCount label 0 result
    edits := edits.push {
      line := position.line, character := position.character, delete := original, insert := text
      : ChangeSpec
    }
  checkDocumentIsolation doc source
  changeDocBatch doc edits
  requireNoErrors "ordinary Lean replacements disagree with successful runAt probes"
    (← collectDiagnostics doc)

  -- Kernel decide rejects free variables in ordinary Lean too; preserve that boundary.
  let (position, original) ← probeAt source "local-decide"
  requireRunAtFailureMessage "kernel decide with a local variable" doc position
    "decide +kernel" "free variables"
  changeDoc doc {
    line := position.line, character := position.character, delete := original, insert := "decide +kernel"
  }
  let diagnostics ← collectDiagnostics doc
  unless diagnostics.diagnostics.any (fun diagnostic =>
      diagnostic.severity? == some .error && diagnostic.range.start.line == position.line &&
      diagnostic.message.contains "free variables") do
    throw <| IO.userError s!"ordinary Lean did not reproduce kernel decide's local-variable error: {(toJson diagnostics).compress}"
  changeDoc doc {
    line := position.line, character := position.character, delete := "decide +kernel", insert := original
  }
  requireNoErrors "restore ordinary Lean after the negative control" (← collectDiagnostics doc)

private def branchWithAux (doc : DocHandle) (root : Beam.LSP.RunAt.Handle) :
    ScenarioM Beam.LSP.RunAt.Result := do
  let req ← runWithHandle doc root {
    text := "first | guard_aux_count 1; constructor; fresh_aux decide +kernel; guard_aux_count 2"
    storeHandle := true
  }
  let result ← requireRunAtResponseSuccess "branch creates its own second auxiliary" req
  requireGoalCount "branched proof" 1 result
  pure result

def checkAuxiliaryHandles (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, _) ← probeAt source "handle"
  let seedText := "first | guard_aux_count 0; constructor; fresh_aux decide +kernel; guard_aux_count 1"
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text := seedText
    storeHandle := true
  }
  let result ← requireRunAtResponseSuccess "store proof after creating an auxiliary" req
  requireGoalCount "stored proof" 1 result
  let root ← requireHandle "stored proof" result
  let left ← requireHandle "left branch" (← branchWithAux doc root)
  let rightResult ← branchWithAux doc root
  let right ← requireHandle "right branch" rightResult

  let failedReq ← runWithHandle doc right {
    text := "first | guard_aux_count 2; fresh_aux decide +kernel; fail \"failure after auxiliary\""
    storeHandle := true
  }
  let failed ← awaitResponseAs failedReq
  requireAuxFailure "failed auxiliary continuation" failed
  unless failed.proofState?.map (·.goals.map (·.target)) ==
      rightResult.proofState?.map (·.goals.map (·.target)) do
    throw <| IO.userError "failed auxiliary continuation did not restore its original goals"

  -- Both branches create the third lemma independently; the failed attempt is discarded.
  for (handle, linear) in [(left, true), (right, false)] do
    let continuation ← runWithHandle doc handle {
      text := "first | guard_aux_count 2; fresh_aux decide +kernel; guard_aux_count 3"
      linear
    }
    let continued ← requireRunAtResponseSuccess "fresh auxiliary after resuming a branch" continuation
    requireGoalCount "completed branch" 0 continued

  let rootReq ← runWithHandle doc root { text := "guard_aux_count 1" }
  let rootResult ← requireRunAtResponseSuccess "branching leaves the root snapshot intact" rootReq
  requireGoalCount "unchanged root" 1 rootResult
  releaseHandle doc root
  releaseHandle doc right
  let independent ← requireRunAtSuccess "stored handles leave document proof state intact" doc
    position seedText
  unless independent.proofState?.map (·.goals.map (·.target)) ==
      result.proofState?.map (·.goals.map (·.target)) do
    throw <| IO.userError "stored handles changed the document proof state"

def checkAuxiliaryFailureIsolation (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, _) ← probeAt source "decide"
  requireRunAtFailureMessage "freshness assertion rejects a proof without new declarations" doc position
    "fresh_aux rfl" "did not create a fresh auxiliary declaration"
  let failedReq ← sendRunAt doc {
    line := position.line
    character := position.character
    text := "first | guard_aux_count 0; fresh_aux decide +kernel; fail \"failure after auxiliary\""
    storeHandle := true
  }
  requireAuxFailure "failed auxiliary runAt" (← awaitResponseAs failedReq)
  requireRunAtSolvesProof "independent retry starts without the failed auxiliary" doc position
    "first | guard_aux_count 0; fresh_aux decide +kernel"

  let (commandPosition, _) ← probeAt source "command"
  let command ← requireRunAtSuccess "command elaboration also creates a fresh auxiliary" doc
    commandPosition "theorem commandAuxProbe : (7 : Nat) = 7 := by\n  fresh_aux decide +kernel"
  if command.proofState?.isSome then
    throw <| IO.userError "command theorem unexpectedly ran as a tactic"

def run : ScenarioM Unit := do
  let source ← IO.FS.readFile fixturePath
  let doc ← openDoc fixturePath
  let ordinaryDiagnostics ← collectDiagnostics doc
  requireNoErrors "ordinary auxiliary-declaration fixture" ordinaryDiagnostics
  checkDocumentIsolation doc source
  checkAuxiliaryHandles doc source
  checkAuxiliaryFailureIsolation doc source
  checkDocumentIsolation doc source
  if let some finalDiagnostics ← collectDiagnostics? doc then
    unless finalDiagnostics.diagnostics == ordinaryDiagnostics.diagnostics do
      throw <| IO.userError "auxiliary probes changed document diagnostics"
  checkAuxiliaryConformance doc source
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.AuxiliaryDeclarationTest
