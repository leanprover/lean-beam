/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.Save
import BeamTest.LSP.Scenario

open Lean
open Lean.Lsp
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Scenario.ParallelGrindBatchTest

private def fixturePath : System.FilePath :=
  System.FilePath.mk "tests/scenario/docs/ParallelGrind10.lean"

private def sorryWarning : String :=
  "declaration uses `sorry`"

private def insertedText : String :=
  "slow_grind"

private def reportJson
    (runAtBatchWallTimeUs changeBatchILeansWallTimeUs : Nat)
    (todoSorryCount declarationSorryDiagnosticCount finalDiagnosticCount remainingSorryCount : Nat)
    (saveReady : Beam.LSP.Save.SaveReadinessResult) : Json :=
  Json.mkObj [
    ("kind", toJson ("parallelGrindBatchReport" : String)),
    ("fixture", toJson fixturePath.toString),
    ("runAtBatchWallTimeUs", toJson runAtBatchWallTimeUs),
    ("changeBatchILeansWallTimeUs", toJson changeBatchILeansWallTimeUs),
    ("todoSorryCount", toJson todoSorryCount),
    ("declarationSorryDiagnosticCount", toJson declarationSorryDiagnosticCount),
    ("finalDiagnosticCount", toJson finalDiagnosticCount),
    ("remainingSorryDiagnosticCount", toJson remainingSorryCount),
    ("saveReady", toJson saveReady.saveReady),
    ("saveReadyReason", toJson saveReady.saveReadyReason)
  ]

private structure TodoPlan where
  item : Beam.LSP.Todo.TodoItem
  change : ChangeSpec

private def sortPlansDescending (plans : Array TodoPlan) : Array TodoPlan :=
  plans.qsort fun a b =>
    if a.change.line == b.change.line then
      a.change.character > b.change.character
    else
      a.change.line > b.change.line

private def endLineOf (source : String) : Nat :=
  source.foldl (init := 0) fun count ch =>
    if ch == '\n' then count + 1 else count

private def fixtureEndLine : IO Nat := do
  return endLineOf (← IO.FS.readFile fixturePath)

private def requestSorryTodos (doc : DocHandle) (endLine : Nat) : ScenarioM Beam.LSP.Todo.TodoResult := do
  let req ← sendTodo doc {
    startLine := 0
    startCharacter := 0
    endLine
    endCharacter := 0
    kinds? := some #[.sorry]
    suggest? := some .none
  }
  awaitResponseAs req

private def extractTodoPlans
    (result : Beam.LSP.Todo.TodoResult)
    (diagnostics : PublishDiagnosticsParams) :
    ScenarioM (Array TodoPlan) := do
  let sorryDiags := diagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning)
  if sorryDiags.size != 10 then
    throw <| IO.userError s!"expected exactly 10 sorry diagnostics, got {sorryDiags.size}"
  if result.items.size != 100 then
    throw <| IO.userError s!"expected exactly 100 todo sorry items, got {result.items.size}: {(toJson result).compress}"
  let mut plans := #[]
  for h : i in [:result.items.size] do
    let item := result.items[i]
    if item.kind != .sorry then
      throw <| IO.userError s!"expected todo item {i} to be a sorry, got {(toJson item).compress}"
    if item.runAtText?.isSome then
      throw <| IO.userError s!"expected suggest=none to omit runAtText, got {(toJson item).compress}"
    plans := plans.push {
      item
      change := {
        line := item.range.start.line
        character := item.range.start.character
        endLine? := some item.range.«end».line
        endCharacter? := some item.range.«end».character
        delete := "sorry"
        insert := insertedText
      }
    }
  pure <| sortPlansDescending plans

private def expectSolvedGrind (index : Nat) (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
  if !result.success then
    throw <| IO.userError s!"parallel grind {index} did not succeed: {(toJson result).compress}"
  let some proofState := result.proofState?
    | throw <| IO.userError s!"parallel grind {index} did not return proofState"
  if proofState.goals.size != 0 then
    throw <| IO.userError
      s!"parallel grind {index} left {proofState.goals.size} goals: {(toJson result).compress}"
  if result.messages.size != 0 then
    throw <| IO.userError s!"parallel grind {index} emitted messages: {(toJson result).compress}"

def main : IO Unit := do
  let report ← BeamTest.LSP.Scenario.run do
    let endLine ← fixtureEndLine
    let doc ← openDoc fixturePath

    let initialDiagnostics ← waitForILeansDiagnostics doc
    let todoResult ← requestSorryTodos doc endLine
    let plans ← extractTodoPlans todoResult initialDiagnostics
    let todoSorryCount := plans.size
    let diagnosticSorryCount :=
      initialDiagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning) |>.size

    let runAtStartedAt ← IO.monoNanosNow
    let requests ← plans.mapM fun plan => do
      let some position := plan.item.runAtPosition?
        | throw <| IO.userError s!"todo sorry without a runAt position: {(toJson plan.item).compress}"
      sendRunAt doc {
        line := position.line
        character := position.character
        text := insertedText
      }

    for h : i in [:requests.size] do
      let result : Beam.LSP.RunAt.Result ← awaitResponseAs requests[i]
      expectSolvedGrind i result
    let runAtFinishedAt ← IO.monoNanosNow

    let changeStartedAt ← IO.monoNanosNow
    let edits := plans.map (fun plan => plan.change)
    changeDocBatch doc edits
    let finalDiagnostics ← waitForILeansDiagnostics doc
    let changeILeansFinishedAt ← IO.monoNanosNow

    let remainingSorryDiags :=
      finalDiagnostics.diagnostics.filter (fun diag => diag.message.contains sorryWarning)
    if remainingSorryDiags.size != 0 then
      throw <| IO.userError
        s!"expected no remaining sorry diagnostics after the atomic grind edit batch, got {(toJson finalDiagnostics).compress}"

    let readinessReq ← sendSaveReadiness doc
    let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
    if !readiness.saveReady then
      throw <| IO.userError s!"expected saveReadiness = true after the grind batch, got {(toJson readiness).compress}"
    if readiness.saveReadyReason != "ok" then
      throw <| IO.userError s!"expected saveReadiness reason = ok, got {(toJson readiness).compress}"
    unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
      throw <| IO.userError s!"expected no save-blocking evidence, got {(toJson readiness).compress}"

    closeDoc doc
    pure <| reportJson
      ((runAtFinishedAt - runAtStartedAt) / 1000)
      ((changeILeansFinishedAt - changeStartedAt) / 1000)
      todoSorryCount
      diagnosticSorryCount
      finalDiagnostics.diagnostics.size
      remainingSorryDiags.size
      readiness
  IO.println report.pretty

end BeamTest.LSP.Scenario.ParallelGrindBatchTest

def main := BeamTest.LSP.Scenario.ParallelGrindBatchTest.main
