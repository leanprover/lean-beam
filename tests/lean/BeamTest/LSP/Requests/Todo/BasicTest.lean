/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Fixtures.TodoFixture
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.Todo.BasicTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

def checkTodoRequest : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  syncDoc doc

  let allReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    suggest? := some .basic
  }
  let allTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs allReq
  if allTodos.items.any (fun item =>
      item.message?.any (fun message => message.contains "Goals accomplished")) then
    throw <| IO.userError
      s!"todo all leaked a silent lifecycle diagnostic: {(toJson allTodos).compress}"
  let sorryItem ← requireTodoKind "todo all" .sorry allTodos
  if countTodoKind .sorry allTodos != 1 then
    throw <| IO.userError s!"todo all: expected one actionable sorry, got {(toJson allTodos).compress}"
  if sorryItem.range.start != BeamTest.Fixtures.TodoFixture.sorryPosition then
    throw <| IO.userError
      s!"todo all: expected sorry token range at {BeamTest.Fixtures.TodoFixture.sorryPosition}, got {(toJson sorryItem).compress}"
  let holeItem ← requireTodoKind "todo all" .hole allTodos
  if holeItem.runAtText?.isSome then
    throw <| IO.userError s!"todo all: expected hole to omit runAtText, got {(toJson holeItem).compress}"
  let incomplete ← requireTodoKind "todo all" .incompleteProof allTodos
  if countTodoKind .incompleteProof allTodos != 1 then
    throw <| IO.userError s!"todo all: expected one incomplete proof item, got {(toJson allTodos).compress}"
  if incomplete.runAtText? != some "exact ?_" then
    throw <| IO.userError s!"todo all: expected incomplete proof runAtText, got {(toJson incomplete).compress}"
  let some proofState := incomplete.proofState?
    | throw <| IO.userError s!"todo all: expected incomplete proofState, got {(toJson incomplete).compress}"
  requireSingleGoalTarget "todo incomplete proof" "True" proofState

  let pointIncompleteReq ← sendTodo doc {
    startLine := incomplete.runAtPosition.line
    startCharacter := incomplete.runAtPosition.character
    endLine := incomplete.runAtPosition.line
    endCharacter := incomplete.runAtPosition.character
    kinds? := some #[.incompleteProof]
    suggest? := some .none
  }
  let pointIncompleteTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs pointIncompleteReq
  let pointIncomplete ← requireTodoKind "todo point incomplete proof" .incompleteProof pointIncompleteTodos
  if countTodoKind .incompleteProof pointIncompleteTodos != 1 then
    throw <| IO.userError
      s!"todo point incomplete proof: expected one item, got {(toJson pointIncompleteTodos).compress}"
  if pointIncomplete.runAtText?.isSome then
    throw <| IO.userError
      s!"todo point incomplete proof: expected suggest=none to omit runAtText, got {(toJson pointIncomplete).compress}"
  let some pointProofState := pointIncomplete.proofState?
    | throw <| IO.userError s!"todo point incomplete proof: expected proofState, got {(toJson pointIncomplete).compress}"
  requireSingleGoalTarget "todo point incomplete proof" "True" pointProofState

  let skippedSorryReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.skippedSorryEndLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    kinds? := some #[.sorry]
  }
  let skippedSorryTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs skippedSorryReq
  if !skippedSorryTodos.items.isEmpty then
    throw <| IO.userError s!"todo skipped sorry text: expected no actionable sorry, got {(toJson skippedSorryTodos).compress}"

  let sorryReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    kinds? := some #[.sorry]
    suggest? := some .none
  }
  let sorryTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs sorryReq
  discard <| requireTodoKind "todo sorry filter" .sorry sorryTodos
  if countTodoKind .sorry sorryTodos != 1 then
    throw <| IO.userError s!"todo sorry filter: expected one actionable sorry, got {(toJson sorryTodos).compress}"
  requireNoTodoKind "todo sorry filter" .hole sorryTodos
  requireNoTodoKind "todo sorry filter" .incompleteProof sorryTodos

  requireRunAtSolvesProof "todo/runAt sorry composition" doc sorryItem.runAtPosition "exact trivial"
  requireRunAtSolvesProof "todo/runAt incomplete composition" doc incomplete.runAtPosition "exact trivial"

  let starterReq ← sendRunAt doc {
    line := incomplete.runAtPosition.line
    character := incomplete.runAtPosition.character
    text := incomplete.runAtText?.getD "exact ?_"
  }
  let starterOutcome ← awaitReq starterReq
  if starterOutcome.result?.isNone then
    throw <| IO.userError
      s!"todo/runAt starter composition: expected normal runAt result, got {starterOutcome.errorCode?.getD "unknown"}: {starterOutcome.errorMessage}"

  closeDoc doc

def checkTodoInvalidRange : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  syncDoc doc

  let reversedReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.endLine
    startCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    endLine := BeamTest.Fixtures.TodoFixture.startLine
    endCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
  }
  expectErrorContains reversedReq invalidParamsJson

  closeDoc doc

def checkTodoStaleVersion : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  syncDoc doc

  let staleReq ← sendTodo doc {
    version? := some 0
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
  }
  expectContentModified staleReq

  closeDoc doc

def checkTodoRequestWithStandardLspInterference : ScenarioM Unit := do
  let todoDoc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  syncDoc todoDoc

  let todoReq ← sendTodo todoDoc {
    startLine := BeamTest.Fixtures.TodoFixture.startLine
    startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
    endLine := BeamTest.Fixtures.TodoFixture.endLine
    endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
    suggest? := some .basic
  }

  syncWhitespacePrefixEdit editDoc

  let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs todoReq
  requireTodoKindCount "todo with LSP interference sorries" .sorry 1 todos
  requireTodoKindCount "todo with LSP interference incomplete proofs" .incompleteProof 1 todos
  let incomplete ← requireTodoKind "todo with LSP interference incomplete proof" .incompleteProof todos
  if incomplete.runAtText? != some "exact ?_" then
    throw <| IO.userError
      s!"todo with LSP interference: expected incomplete proof runAtText, got {(toJson incomplete).compress}"
  let some proofState := incomplete.proofState?
    | throw <| IO.userError
        s!"todo with LSP interference: expected proofState, got {(toJson incomplete).compress}"
  requireSingleGoalTarget "todo with LSP interference incomplete proof" "True" proofState

  closeDoc todoDoc
  closeDoc editDoc

def checkTodoRequestWithMixedConcurrency : ScenarioM Unit := do
  let todoDoc ← openDoc BeamTest.Fixtures.TodoFixture.repoPath
  let slowDoc ← openDoc "tests/scenario/docs/RunWithMixedConcurrencyProof.lean"
  let goalsDoc ← openDoc "tests/save_olean_project/GoalSmoke.lean"
  let cmdDoc ← openDoc "tests/scenario/docs/CommandB.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"
  syncDoc todoDoc

  let slowReqs ← (List.range 3).mapM fun _ =>
    sendRunAt slowDoc { line := 9, character := 2, text := "mixed_sleep_exact" }
  let todoReqs ← (List.range 4).mapM fun _ =>
    sendTodo todoDoc {
      startLine := BeamTest.Fixtures.TodoFixture.startLine
      startCharacter := BeamTest.Fixtures.TodoFixture.startCharacter
      endLine := BeamTest.Fixtures.TodoFixture.endLine
      endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
      suggest? := some .basic
    }
  let goalsPrevReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := false }
  let goalsAfterReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := true }
  let cmdReqs ← (List.range 6).mapM fun _ =>
    sendRunAt cmdDoc { line := 0, character := 2, text := "#check Nat" }

  syncWhitespacePrefixEdit editDoc

  for req in todoReqs do
    let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs req
    requireTodoKindCount "todo mixed concurrency sorries" .sorry 1 todos
    requireTodoKindCount "todo mixed concurrency incomplete proofs" .incompleteProof 1 todos
    let incomplete ← requireTodoKind "todo mixed concurrency incomplete proof" .incompleteProof todos
    let some proofState := incomplete.proofState?
      | throw <| IO.userError
          s!"todo mixed concurrency: expected proofState, got {(toJson incomplete).compress}"
    requireSingleGoalTarget "todo mixed concurrency incomplete proof" "True" proofState
  for req in goalsPrevReqs do
    let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    unless goalsPrev.goals.size == 1 do
      throw <| IO.userError
        s!"todo mixed concurrency goalsPrev: expected one goal, got {goalsPrev.goals.size}"
    requireSingleGoalTarget "todo mixed concurrency goalsPrev" "True" goalsPrev
  for req in goalsAfterReqs do
    let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    unless goalsAfter.goals.isEmpty do
      throw <| IO.userError
        s!"todo mixed concurrency goalsAfter: expected solved proof state, got {goalsAfter.goals.size} goals"
  for req in slowReqs do
    discard <| requireRunAtResponseSuccess "todo mixed concurrency slow runAt" req
  for req in cmdReqs do
    discard <| requireRunAtResponseSuccess "todo mixed concurrency command runAt" req

  closeDoc todoDoc
  closeDoc slowDoc
  closeDoc goalsDoc
  closeDoc cmdDoc
  closeDoc editDoc

def checkTodoCodeActions : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.codeActionRepoPath
  syncDoc doc

  let codeActionReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.codeActionLine
    startCharacter := BeamTest.Fixtures.TodoFixture.codeActionStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.codeActionLine
    endCharacter := BeamTest.Fixtures.TodoFixture.codeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let codeActionTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs codeActionReq
  let actionItem ← requireTodoKind "todo code action fixture" .codeAction codeActionTodos
  if countTodoKind .codeAction codeActionTodos != 1 then
    throw <| IO.userError
      s!"todo code action fixture: expected one code action, got {(toJson codeActionTodos).compress}"
  requireRangeEq "todo code action fixture"
    BeamTest.Fixtures.TodoFixture.codeActionRange actionItem.range
  if actionItem.runAtPosition != BeamTest.Fixtures.TodoFixture.codeActionRange.start then
    throw <| IO.userError
      s!"todo code action fixture: expected runAtPosition to track the code-action range start, got {(toJson actionItem).compress}"
  if actionItem.message? != some "Replace fixture hole with zero" then
    throw <| IO.userError
      s!"todo code action fixture: expected code action title message, got {(toJson actionItem).compress}"
  let some action := actionItem.codeAction?
    | throw <| IO.userError s!"todo code action fixture: expected embedded codeAction payload, got {(toJson actionItem).compress}"
  if action.title != "Replace fixture hole with zero" then
    throw <| IO.userError s!"todo code action fixture: unexpected code action title {action.title}"
  if action.kind? != some "quickfix" then
    throw <| IO.userError s!"todo code action fixture: expected quickfix action, got {(toJson action).compress}"
  if action.edit?.isNone then
    throw <| IO.userError s!"todo code action fixture: expected edit payload, got {(toJson action).compress}"
  if action.data?.isNone then
    throw <| IO.userError s!"todo code action fixture: expected resolve data, got {(toJson action).compress}"

  closeDoc doc

def checkComplexTodoFalsePositives (doc : DocHandle) : ScenarioM Unit := do
  let falsePositiveReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexFalsePositiveStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexFalsePositiveEndLine
    endCharacter := 0
    kinds? := some #[.sorry]
  }
  let falsePositiveTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs falsePositiveReq
  if !falsePositiveTodos.items.isEmpty then
    throw <| IO.userError
      s!"todo complex false positives: expected no actionable sorry in comments/strings/quoted identifiers, got {(toJson falsePositiveTodos).compress}"

def checkComplexTodoSemanticItems (doc : DocHandle) : ScenarioM Unit := do
  let semanticReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexStartLine
    startCharacter := BeamTest.Fixtures.TodoFixture.complexStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.complexEndLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexEndCharacter
    kinds? := some #[.sorry, .hole]
  }
  let semanticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs semanticReq
  requireTodoKindCount "todo complex semantic sorries" .sorry 2 semanticTodos
  requireTodoKindCount "todo complex semantic holes" .hole 3 semanticTodos
  requireNoTodoKind "todo complex semantic filter" .diagnostic semanticTodos
  requireNoTodoKind "todo complex semantic filter" .codeAction semanticTodos
  requireNoTodoKind "todo complex semantic filter" .incompleteProof semanticTodos

  let sorryItem ← requireTodoKind "todo complex sorry/runAt composition" .sorry semanticTodos
  requireRunAtSolvesProof "todo complex sorry/runAt composition" doc sorryItem.runAtPosition "exact trivial"

def checkComplexTodoIncompleteProofs (doc : DocHandle) : ScenarioM Unit := do
  let incompleteReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexIncompleteOneStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexIncompleteOneEndLine
    endCharacter := 0
    kinds? := some #[.incompleteProof]
    suggest? := some .basic
  }
  let incompleteTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs incompleteReq
  requireTodoKindCount "todo complex single incomplete proof" .incompleteProof 1 incompleteTodos
  let incomplete ← requireTodoKind "todo complex single incomplete proof" .incompleteProof incompleteTodos
  if incomplete.runAtText? != some "exact ?_" then
    throw <| IO.userError
      s!"todo complex single incomplete proof: expected basic runAtText, got {(toJson incomplete).compress}"
  let some proofState := incomplete.proofState?
    | throw <| IO.userError
        s!"todo complex single incomplete proof: expected proofState, got {(toJson incomplete).compress}"
  requireSingleGoalTarget "todo complex single incomplete proof" "True" proofState
  requireRunAtSolvesProof "todo complex incomplete/runAt composition" doc incomplete.runAtPosition "exact trivial"

  let branchReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexBranchSkipStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexBranchSkipEndLine
    endCharacter := 0
    kinds? := some #[.incompleteProof]
    suggest? := some .none
  }
  let branchTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs branchReq
  requireTodoKindCount "todo complex branch incomplete proof" .incompleteProof 1 branchTodos
  let branch ← requireTodoKind "todo complex branch incomplete proof" .incompleteProof branchTodos
  if branch.runAtText?.isSome then
    throw <| IO.userError
      s!"todo complex branch incomplete proof: expected suggest=none to omit runAtText, got {(toJson branch).compress}"
  let some branchProofState := branch.proofState?
    | throw <| IO.userError
        s!"todo complex branch incomplete proof: expected proofState, got {(toJson branch).compress}"
  requireSingleGoalTarget "todo complex branch incomplete proof" "True" branchProofState
  requireRunAtSolvesProof "todo complex branch/runAt composition" doc branch.runAtPosition "exact trivial"

def checkComplexTodoDiagnostics (doc : DocHandle) : ScenarioM Unit := do
  let warningReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexSorryStartLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexSorryEndLine
    endCharacter := 0
    kinds? := some #[.diagnostic]
  }
  let warningTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs warningReq
  requireTodoKindAtLeast "todo complex warning diagnostic" .diagnostic 1 warningTodos
  requireDiagnosticSeverity "todo complex warning diagnostic" .warning warningTodos

  let diagnosticReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexDiagnosticLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexDiagnosticLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexDiagnosticEndCharacter
    kinds? := some #[.diagnostic]
  }
  let diagnosticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs diagnosticReq
  requireTodoKindAtLeast "todo complex error diagnostic" .diagnostic 1 diagnosticTodos
  requireDiagnosticSeverity "todo complex error diagnostic" .error diagnosticTodos
  discard <| requireTodoKindWithMessage "todo complex error diagnostic"
    .diagnostic "Type mismatch" diagnosticTodos

def checkTodoInteractiveOnlyDiagnostic : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  syncDoc doc

  let diagnosticReq ← sendTodo doc {
    startLine := 20
    startCharacter := 0
    endLine := 21
    endCharacter := 0
    kinds? := some #[.diagnostic]
  }
  let diagnosticTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs diagnosticReq
  requireTodoKindAtLeast "todo interactive-only diagnostic" .diagnostic 1 diagnosticTodos
  requireDiagnosticSeverity "todo interactive-only diagnostic" .error diagnosticTodos
  discard <| requireTodoKindWithMessage "todo interactive-only diagnostic"
    .diagnostic "interactive-only diagnostic from child snapshot" diagnosticTodos

  closeDoc doc

def checkComplexTodoCodeActions (doc : DocHandle) : ScenarioM Unit := do
  let codeActionReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.complexCodeActionLine
    startCharacter := BeamTest.Fixtures.TodoFixture.complexCodeActionStartCharacter
    endLine := BeamTest.Fixtures.TodoFixture.complexCodeActionLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexCodeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let codeActionTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs codeActionReq
  let actionItem ← requireTodoKindWithMessage "todo complex code action"
    .codeAction "Fill complex fixture hole with zero" codeActionTodos
  let some action := actionItem.codeAction?
    | throw <| IO.userError
        s!"todo complex code action: expected embedded codeAction payload, got {(toJson actionItem).compress}"
  if action.edit?.isNone then
    throw <| IO.userError
      s!"todo complex code action: expected edit payload, got {(toJson action).compress}"

  -- Earlier holes in the range report errors in other commands. Lean runs providers only on the
  -- command at the range end, and its resolve data should carry only that command's diagnostics.
  let broadReq ← sendTodo doc {
    startLine := 0
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.complexCodeActionLine
    endCharacter := BeamTest.Fixtures.TodoFixture.complexCodeActionEndCharacter
    kinds? := some #[.codeAction]
  }
  let broadTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs broadReq
  let broadItem ← requireTodoKindWithMessage "todo broad code action"
    .codeAction "Fill complex fixture hole with zero" broadTodos
  let some broadData := broadItem.codeAction?.bind (·.data?)
    | throw <| IO.userError
        s!"todo broad code action: expected resolve data, got {(toJson broadItem).compress}"
  let resolveData ← IO.ofExcept <|
    (fromJson? broadData : Except String Lean.Server.CodeActionResolveData)
  let forwarded := resolveData.params.context.diagnostics
  if forwarded.isEmpty ||
      forwarded.any (·.range.start.line != BeamTest.Fixtures.TodoFixture.complexCodeActionLine) then
    throw <| IO.userError
      s!"todo broad code action: expected only diagnostics of the selected command, got {(toJson forwarded).compress}"

  -- Without a range there is no command to run providers on: code actions are omitted by default
  -- and refused when requested.
  let wholeTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs (← sendTodoWholeDocument doc)
  requireNoTodoKind "todo whole document" .codeAction wholeTodos
  requireTodoKindAtLeast "todo whole document" .hole 1 wholeTodos
  expectErrorContains (← sendTodoWholeDocument doc (kinds? := some #[.codeAction])) invalidParamsJson

def checkComplexTodoRequest : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.complexRepoPath
  syncDoc doc

  checkComplexTodoFalsePositives doc
  checkComplexTodoSemanticItems doc
  checkComplexTodoIncompleteProofs doc
  checkComplexTodoDiagnostics doc
  checkComplexTodoCodeActions doc

  closeDoc doc

def checkTodoProofProgress : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.progressRepoPath
  syncDoc doc

  let completeReq ← sendTodo doc {
    startLine := 0
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.progressCompleteEndLine
    endCharacter := 0
  }
  let completeTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs completeReq
  requireNoTodoKind "todo complete proofs" .incompleteProof completeTodos

  let openReq ← sendTodo doc {
    startLine := BeamTest.Fixtures.TodoFixture.progressCompleteEndLine
    startCharacter := 0
    endLine := BeamTest.Fixtures.TodoFixture.progressEndLine
    endCharacter := 0
    kinds? := some #[.incompleteProof]
  }
  let openTodos : Beam.LSP.Todo.TodoResult ← awaitResponseAs openReq
  let positions := openTodos.items.map (·.runAtPosition)
  if positions != BeamTest.Fixtures.TodoFixture.progressOpenPositions then
    throw <| IO.userError
      s!"todo open proofs: expected one item at the end of each open skip, got {(toJson openTodos).compress}"
  for item in openTodos.items do
    let some proofState := item.proofState?
      | throw <| IO.userError s!"todo open proofs: expected proofState, got {(toJson item).compress}"
    if proofState.goals.size != 1 then
      throw <| IO.userError s!"todo open proofs: expected one open goal, got {(toJson item).compress}"
  let some bullet := openTodos.items[0]?
    | throw <| IO.userError "todo open proofs: missing bullet item"
  requireRunAtSolvesProof "todo open bullet/runAt composition" doc bullet.runAtPosition "exact trivial"

  closeDoc doc

/--
Each mistake in the agent corpus yields exactly one item, whose proof state is the goal `runAt` uses
at the item's position: the expected solution closes it there.
-/
def checkTodoAgentCorpus : ScenarioM Unit := do
  let doc ← openDoc BeamTest.Fixtures.TodoFixture.agentRepoPath
  syncDoc doc

  let req ← sendTodoWholeDocument doc
  let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs req
  let expected := BeamTest.Fixtures.TodoFixture.agentItems
  let actual := todos.items.map fun item =>
    (item.kind, item.range.start, item.runAtPosition,
      (item.proofState?.map (·.goals.map (·.target))).getD #[])
  let wanted := expected.map fun item => (item.kind, item.start, item.runAt, item.goals)
  if actual != wanted then
    throw <| IO.userError
      s!"todo agent corpus: expected {(toJson wanted).compress}, got {(toJson todos).compress}"
  for item in expected do
    if let some solution := item.solution? then
      requireRunAtSolvesProof s!"todo agent corpus {item.start}" doc item.runAt solution

  -- Tactics at a placeholder may leave goals; the handle continues them.
  let some hole := expected.find? (·.kind == .hole)
    | throw <| IO.userError "todo agent corpus: missing hole item"
  let partialReq ← sendRunAt doc {
    line := hole.runAt.line
    character := hole.runAt.character
    text := "refine ?_ + 1"
    storeHandle := true
  }
  let partialResult : Beam.LSP.RunAt.Result ← awaitResponseAs partialReq
  let some handle := partialResult.handle?
    | throw <| IO.userError
        s!"todo agent corpus: expected a handle for a partial proof, got {(toJson partialResult).compress}"
  let goals := (partialResult.proofState?.map (·.goals.map (·.target))).getD #[]
  if goals != #["Nat"] then
    throw <| IO.userError
      s!"todo agent corpus: expected the remaining hole as the goal, got {(toJson partialResult).compress}"
  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs
    (← runWithHandle doc handle { text := "exact 0" })
  unless continued.success && continued.proofState?.any (·.goals.isEmpty) do
    throw <| IO.userError
      s!"todo agent corpus: expected the handle to finish the proof, got {(toJson continued).compress}"

  closeDoc doc

def run : ScenarioM Unit := do
  checkTodoRequest
  checkTodoInvalidRange
  checkTodoStaleVersion
  checkTodoRequestWithStandardLspInterference
  checkTodoRequestWithMixedConcurrency
  checkTodoCodeActions
  checkComplexTodoRequest
  checkTodoProofProgress
  checkTodoInteractiveOnlyDiagnostic
  checkTodoAgentCorpus

end BeamTest.LSP.Requests.Todo.BasicTest
