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
  let positions := source.splitOn "\n" |>.zipIdx |>.filter fun (line, _) =>
    line.endsWith s!" -- probe:{marker}"
  let [(line, lineNo)] := positions
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
    ("nested", "fresh_aux decide +kernel"),
    ("universe", "fresh_aux decide +kernel"),
    ("explicit-universe", "fresh_aux decide +kernel"),
    ("ambient-universe", "first | guard_universe v; trivial"),
    ("cleared-universe", "first | guard_universe q; trivial"),
    ("local-universe", "first | have h : ([] : List (ULift.{w} Nat)).length = 0 := (by fresh_aux decide +kernel); trivial"),
    ("universe-grind", "fresh_aux grind"),
    ("rollback", "first | (guard_aux_count 0; fresh_aux decide +kernel; fail \"rollback after auxiliary\") | (guard_aux_count 0; fresh_aux decide +kernel; guard_aux_count 1)"),
    ("instance", "first | letI valueInstance : LocalValue := ⟨7⟩; exact ⟨LocalValue.value, by simp [LocalValue.value, valueInstance]⟩"),
    ("instance-rollback", "first | (letI : LocalValue := ⟨9⟩; fail \"rollback instance\") | ((fail_if_success have _ : LocalValue := inferInstance); exact ⟨7, rfl⟩)"),
    ("document-instance", "exact ⟨LocalValue.value, by rfl⟩"),
    ("recursive", "first | (let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1; fail \"rollback recursion\") | exact ⟨fun _ => offset, trivial⟩"),
    ("postponed", "postpone_exact ⟨fun _ => offset, trivial⟩"),
    ("dependent", "induction n with | zero => intro i; exact Fin.elim0 i | succ n ih => intro i; omega"),
    ("native", "fresh_aux native_decide"),
    ("conv", "first | (conv => lhs; intro x; arg 1; rw [Nat.zero_add]); funext x; simp"),
    ("bitvector", "bv_decide (config := { timeout := 5 })"),
    ("bitvector-solver", "fresh_aux bv_decide (config := { timeout := 5 })")
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

def checkContextHandles (doc : DocHandle) (source : String) : ScenarioM Unit := do
  for (marker, seed, finish) in [
      ("explicit-universe", "skip", "fresh_aux decide +kernel"),
      ("universe", "skip", "postpone_exact (by fresh_aux decide +kernel)"),
      ("ambient-universe", "skip", "first | guard_universe v; trivial"),
      ("native", "skip", "fresh_aux native_decide")
    ] do
    let (position, _) ← probeAt source marker
    let req ← sendRunAt doc {
      line := position.line, character := position.character, text := seed, storeHandle := true
    }
    let seeded ← requireRunAtResponseSuccess s!"store {marker} context" req
    requireGoalCount marker 1 seeded
    let root ← requireHandle marker seeded
    -- Reusing the same root must preserve both its context and its unmodified environment.
    for _ in [:2] do
      let continuation ← runWithHandle doc root { text := finish }
      let result ← requireRunAtResponseSuccess s!"resume {marker} context" continuation
      requireGoalCount marker 0 result
    releaseHandle doc root

def checkInstanceHandles (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, _) ← probeAt source "instance"
  let req ← sendRunAt doc {
    line := position.line, character := position.character
    text := "letI : LocalValue := ⟨7⟩", storeHandle := true
  }
  let seeded ← requireRunAtResponseSuccess "store a local instance" req
  requireGoalCount "local instance seed" 1 seeded
  let root ← requireHandle "local instance seed" seeded
  let branchReq ← runWithHandle doc root {
    text := "first | letI : LocalValue := ⟨9⟩; have : LocalValue.value = 9 := (by rfl)"
    storeHandle := true
  }
  let branchResult ← requireRunAtResponseSuccess "shadow an instance in a sibling" branchReq
  requireGoalCount "shadowed instance" 1 branchResult
  let branch ← requireHandle "shadowed instance" branchResult
  for (handle, text) in [
      (root, "exact ⟨LocalValue.value, by rfl⟩"),
      (branch, "first | have : LocalValue.value = 9 := (by rfl); exact ⟨7, rfl⟩"),
      (root, "exact ⟨LocalValue.value, by rfl⟩")
    ] do
    let continuation ← runWithHandle doc handle { text }
    let result ← requireRunAtResponseSuccess "local instances stay in their own branch" continuation
    requireGoalCount "completed instance branch" 0 result
  releaseHandle doc root
  releaseHandle doc branch
  requireRunAtFailureMessage "a stored instance does not enter the document" doc position
    "exact ⟨LocalValue.value, by rfl⟩" "failed to synthesize"

def checkDependentHandles (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, _) ← probeAt source "dependent"
  let req ← sendRunAt doc {
    line := position.line, character := position.character
    text := "induction n", storeHandle := true
  }
  let seeded ← requireRunAtResponseSuccess "store dependent induction branches" req
  requireGoalCount "dependent induction" 2 seeded
  let root ← requireHandle "dependent induction" seeded
  let zeroReq ← runWithHandle doc root {
    text := "case zero => intro i; exact Fin.elim0 i", storeHandle := true
  }
  let zeroResult ← requireRunAtResponseSuccess "close the named zero case" zeroReq
  requireGoalCount "remaining successor case" 1 zeroResult
  unless zeroResult.proofState?.map (fun state => state.goals[0]?.bind (·.userName?)) ==
      some (some "succ") do
    throw <| IO.userError s!"dependent induction lost its case name: {(toJson zeroResult).compress}"
  let successor ← requireHandle "remaining successor case" zeroResult
  let finishReq ← runWithHandle doc successor {
    text := "case succ n ih => intro i; omega", linear := true
  }
  let finished ← requireRunAtResponseSuccess "resume the dependent successor case" finishReq
  requireGoalCount "completed dependent induction" 0 finished
  let unchangedReq ← runWithHandle doc root { text := "skip" }
  let unchanged ← requireRunAtResponseSuccess "the induction root remains unchanged" unchangedReq
  unless toJson unchanged.proofState? == toJson seeded.proofState? do
    throw <| IO.userError "dependent induction continuations changed their root"
  releaseHandle doc root

-- A tactic fragment cannot perform Lean's enclosing-declaration finalization for `let rec`.
-- Valid ordinary proofs are deliberately rejected here too, until that path is supported.
def checkLocalRecursionBoundary (doc : DocHandle) (source : String) : ScenarioM Unit := do
  let (position, original) ← probeAt source "recursive"
  let cases := [
    ("tactic let rec", "first | let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1; exact ⟨count, trivial⟩", false),
    ("term let rec under refine", "first | refine ⟨(let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1; count), ?_⟩; trivial", false),
    ("let rec inside have", "first | have h : ∃ _f : Nat → Nat, True := (by let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1; exact ⟨count, trivial⟩); exact h", false),
    ("postponed let rec", "postpone_exact (by let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1; exact ⟨count, trivial⟩)", false),
    ("nonterminating let rec", "first | let rec loop (n : Nat) : Nat := loop n; exact ⟨loop, trivial⟩", true)
  ]
  let initial ← requireRunAtSuccess "recursive boundary initial state" doc position "skip"
  for (label, text, ordinaryFails) in cases do
    let req ← sendRunAt doc {
      line := position.line, character := position.character, text, storeHandle := true
    }
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    unless !result.success && result.handle?.isNone && result.messages.any (fun msg =>
        msg.severity == .error && msg.text.contains "Local recursive declarations are not supported") do
      throw <| IO.userError s!"{label}: expected explicit unsupported result: {(toJson result).compress}"
    unless toJson result.proofState? == toJson initial.proofState? do
      throw <| IO.userError s!"{label}: failed recursion did not restore the original proof state"
    changeDoc doc { line := position.line, character := position.character, delete := original, insert := text }
    let ordinary ← collectDiagnostics doc
    if ordinaryFails then
      unless ordinary.diagnostics.any (fun diagnostic => diagnostic.severity? == some .error &&
          diagnostic.message.contains "termination") do
        throw <| IO.userError s!"{label}: ordinary Lean did not reject nontermination: {(toJson ordinary).compress}"
    else
      requireNoErrors s!"{label}: ordinary Lean control" ordinary
    changeDoc doc { line := position.line, character := position.character, delete := text, insert := original }
    requireNoErrors s!"{label}: restore ordinary Lean" (← collectDiagnostics doc)

  let rootReq ← sendRunAt doc {
    line := position.line, character := position.character, text := "skip", storeHandle := true
  }
  let root ← requireHandle "recursive boundary root" (← requireRunAtResponseSuccess "recursive boundary root" rootReq)
  for (label, text, _) in cases do
    let failedReq ← runWithHandle doc root { text, storeHandle := true }
    let failed : Beam.LSP.RunAt.Result ← awaitResponseAs failedReq
    unless !failed.success && failed.handle?.isNone && failed.messages.any (fun msg =>
        msg.text.contains "Local recursive declarations are not supported") do
      throw <| IO.userError s!"{label}: recursive continuation escaped the boundary: {(toJson failed).compress}"
    unless toJson failed.proofState? == toJson initial.proofState? do
      throw <| IO.userError s!"{label}: recursive continuation did not restore the original proof state"
  let retryReq ← runWithHandle doc root { text := original, linear := true }
  requireGoalCount "retry a handle after rejecting recursion" 0
    (← requireRunAtResponseSuccess "retry a handle after rejecting recursion" retryReq)

  let (commandPosition, _) ← probeAt source "command"
  let command ← requireRunAtSuccess "command probes finalize local recursive definitions" doc commandPosition
    "theorem recursiveCommandProbe (offset : Nat) : ∃ _f : Nat → Nat, True := by\n  let rec count (n : Nat) : Nat := match n with | 0 => offset | n + 1 => count n + 1\n  exact ⟨count, trivial⟩"
  if command.proofState?.isSome then
    throw <| IO.userError "recursive command unexpectedly used a tactic basis"
  requireRunAtFailureMessage "command probes check local recursive termination" doc commandPosition
    "theorem recursiveCommandProbe : ∃ _f : Nat → Nat, True := by\n  let rec loop (n : Nat) : Nat := loop n\n  exact ⟨loop, trivial⟩" "termination"

def checkRejectedProofs (doc : DocHandle) (source : String) : ScenarioM Unit := do
  for (marker, text, needle, retry, expectedGoals) in [
      ("postponed", "postpone_exact (by fail \"delayed elaboration failure\")",
        "delayed elaboration failure", "postpone_exact ⟨fun _ => offset, trivial⟩", 0),
      ("native", "have h : (1 : Nat) = 2 := by native_decide", "is false", "fresh_aux native_decide", 1),
      ("bitvector", "have h : x + y = x := by bv_decide (config := { timeout := 5 })",
        "counterexample", "bv_decide (config := { timeout := 5 })", 1)
    ] do
    let (position, original) ← probeAt source marker
    let req ← sendRunAt doc {
      line := position.line, character := position.character, text, storeHandle := true
    }
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    unless !result.success && result.handle?.isNone && result.messages.any (fun msg =>
        msg.severity == .error && msg.text.contains needle) do
      throw <| IO.userError s!"{marker}: missing proof rejection without a handle: {(toJson result).compress}"
    -- A postponed term can assign its placeholder before Lean logs its elaboration error.
    -- It must still return semantic failure without a reusable handle.
    requireGoalCount marker expectedGoals result
    changeDoc doc { line := position.line, character := position.character, delete := original, insert := text }
    let ordinary ← collectDiagnostics doc
    unless ordinary.diagnostics.any (fun diagnostic => diagnostic.severity? == some .error &&
        diagnostic.message.contains needle) do
      throw <| IO.userError s!"{marker}: ordinary Lean did not reproduce the proof rejection: {(toJson ordinary).compress}"
    changeDoc doc { line := position.line, character := position.character, delete := text, insert := original }
    requireNoErrors s!"{marker}: restore after proof rejection" (← collectDiagnostics doc)
    requireRunAtSolvesProof s!"{marker}: retry after proof rejection" doc position retry

  let (position, _) ← probeAt source "native"
  let failedReq ← sendRunAt doc {
    line := position.line, character := position.character
    text := "first | guard_aux_count 0; fresh_aux native_decide; fail \"failure after auxiliary\""
    storeHandle := true
  }
  requireAuxFailure "failure after native auxiliary creation" (← awaitResponseAs failedReq)
  requireRunAtSolvesProof "native retry starts from a clean environment" doc position
    "first | guard_aux_count 0; fresh_aux native_decide"

def run : ScenarioM Unit := do
  let source ← IO.FS.readFile fixturePath
  let doc ← openDoc fixturePath
  let ordinaryDiagnostics ← collectDiagnostics doc
  requireNoErrors "ordinary auxiliary-declaration fixture" ordinaryDiagnostics
  checkDocumentIsolation doc source
  checkAuxiliaryHandles doc source
  checkAuxiliaryFailureIsolation doc source
  checkContextHandles doc source
  checkInstanceHandles doc source
  checkDependentHandles doc source
  checkLocalRecursionBoundary doc source
  checkRejectedProofs doc source
  checkDocumentIsolation doc source
  if let some finalDiagnostics ← collectDiagnostics? doc then
    unless finalDiagnostics.diagnostics == ordinaryDiagnostics.diagnostics do
      throw <| IO.userError "auxiliary probes changed document diagnostics"
  checkAuxiliaryConformance doc source
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.AuxiliaryDeclarationTest
