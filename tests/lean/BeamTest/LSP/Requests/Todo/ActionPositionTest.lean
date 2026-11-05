/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean BeamTest.LSP.Scenario BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.Todo.ActionPositionTest

private structure Case where
  name : String
  source : String
  goals : Array String
  solution : String

/-- Each body ends inside a proof, after the tactic whose inner work is complete. -/
private def cases : Array Case := #[
  { name := "have", goals := #["r ∧ p ∧ q"], solution := "exact ⟨hr, h⟩"
    source := "theorem sample (p q r : Prop) (hp : p) (hq : q) (hr : r) : r ∧ (p ∧ q) := by\n  have h : p ∧ q := by\n    constructor\n    · exact hp\n    · exact hq" },
  { name := "suffices", goals := #["p ∧ q"], solution := "exact ⟨hp, hq⟩"
    source := "theorem sample (p q : Prop) (hp : p) (hq : q) : q ∧ p := by\n  suffices h : p ∧ q by\n    constructor\n    · exact h.2\n    · exact h.1" },
  { name := "nestedBullet", goals := #["r"], solution := "exact hr"
    source := "theorem sample (p q r : Prop) (hp : p) (hq : q) (hr : r) : (p ∧ q) ∧ r := by\n  constructor\n  · constructor\n    · exact hp\n    · exact hq" },
  { name := "bullet", goals := #["q"], solution := "exact hq"
    source := "theorem sample (p q : Prop) (hp : p) (hq : q) : p ∧ q := by\n  constructor\n  · exact hp" },
  { name := "aggregate", goals := #["p", "q"], solution := "all_goals assumption"
    source := "theorem sample (p q : Prop) (hp : p) (hq : q) : p ∧ q := by\n  constructor <;> skip" }
]

private def checkCase (doc : DocHandle) (c : Case) (hasNextLine : Bool) : ScenarioM Unit := do
  syncDoc doc
  let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs <|
    ← sendTodoWholeDocument doc (some #[.incompleteProof])
  requireTodoKindCount c.name .incompleteProof 1 todos
  let item ← requireTodoKind c.name .incompleteProof todos
  unless item.proofState?.map (·.goals.map (·.target)) == some c.goals do
    throw <| IO.userError s!"{c.name}: unexpected goals: {(toJson item).compress}"
  if !hasNextLine then
    unless item.runAtPosition?.isNone do
      throw <| IO.userError s!"{c.name}: no matching adjacent position without final newline: {(toJson item).compress}"
    return
  let position ← requireRunAtPosition c.name item
  let expected : Lean.Lsp.Position := { line := (c.source.splitOn "\n").length + 2, character := 0 }
  unless position == expected && item.range.«end».line < position.line do
    throw <| IO.userError s!"{c.name}: expected following-line action outside unchanged item range: {(toJson item).compress}"
  let selected ← requireRunAtResponseSuccess c.name <| ← sendRunAt doc {
    line := position.line, character := position.character, text := "skip", storeHandle := true }
  unless toJson selected.proofState? == toJson item.proofState? do
    throw <| IO.userError s!"{c.name}: advertised state differs from runAt: {(toJson selected).compress}"
  let some handle := selected.handle? | throw <| IO.userError s!"{c.name}: no retained action"
  let solved ← requireRunAtResponseSuccess c.name <| ← runWithHandle doc handle { text := c.solution }
  unless solved.proofState?.any (·.goals.isEmpty) do
    throw <| IO.userError s!"{c.name}: continuation did not solve advertised goals: {(toJson solved).compress}"
  let reused ← requireRunAtResponseSuccess c.name <| ← runWithHandle doc handle { text := "skip" }
  unless toJson reused.proofState? == toJson item.proofState? do
    throw <| IO.userError s!"{c.name}: continuation changed its parent"
  let after : Beam.LSP.Todo.TodoResult ← awaitResponseAs <|
    ← sendTodoWholeDocument doc (some #[.incompleteProof])
  unless toJson after == toJson todos do
    throw <| IO.userError s!"{c.name}: speculation changed todo"

  -- Selection belongs to the item's syntax range, not to its possibly adjacent action position.
  let point : Beam.LSP.Todo.TodoResult ← awaitResponseAs <| ← sendTodo doc {
    startLine := item.range.start.line, startCharacter := item.range.start.character
    endLine := item.range.start.line, endCharacter := item.range.start.character
    kinds? := some #[.incompleteProof] }
  unless point.items.any (fun found => toJson found == toJson item) do
    throw <| IO.userError s!"{c.name}: point query lost the item or changed its action"
  let atAction : Beam.LSP.Todo.TodoResult ← awaitResponseAs <| ← sendTodo doc {
    startLine := position.line, startCharacter := position.character
    endLine := position.line, endCharacter := position.character
    kinds? := some #[.incompleteProof] }
  unless atAction.items.isEmpty do
    throw <| IO.userError s!"{c.name}: adjacent action must not extend the item range"
  expectContentModified (← sendRunAt doc {
    version? := some 0, line := position.line, character := position.character, text := "skip" })
  changeDoc doc { line := 0, character := 0, insert := "-- new version\n" }
  expectContentModified (← runWithHandle doc handle { text := "skip" })

private def checkEqualLookingGoals (root : System.FilePath) : ScenarioM Unit := do
  let path := root / "same-goals.lean"
  IO.FS.writeFile path "theorem sample (p : Prop) : p ∧ p := by\n  constructor\n  focus skip\n"
  let doc ← openDoc path
  try
    syncDoc doc
    let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs <|
      ← sendTodoWholeDocument doc (some #[.incompleteProof])
    requireTodoKindCount "equal-looking goals" .incompleteProof 2 todos
    unless todos.items.all (·.proofState?.any (·.goals.map (·.target) == #["p"])) &&
        (todos.items.filter (·.runAtPosition?.isSome)).size == 1 do
      throw <| IO.userError s!"distinct p goals must not share one action: {(toJson todos).compress}"
  finally
    closeDoc doc

private def checkPlaceholder (root : System.FilePath) : ScenarioM Unit := do
  let path := root / "placeholder.lean"
  let source := "theorem sample (p q : Prop) (hp : p) (hq : q) : p ∧ q := ⟨hp, sorry⟩\n"
  IO.FS.writeFile path source
  let doc ← openDoc path
  try
    syncDoc doc
    let todos : Beam.LSP.Todo.TodoResult ← awaitResponseAs <|
      ← sendTodoWholeDocument doc (some #[.sorry])
    let item ← requireTodoKind "placeholder" .sorry todos
    let position ← requireRunAtPosition "placeholder" item
    unless position == item.range.start do
      throw <| IO.userError "placeholder action must keep its original position"
    let selected ← requireRunAtSuccess "placeholder" doc position "skip"
    unless toJson selected.proofState? == toJson item.proofState? do
      throw <| IO.userError "placeholder action changed its goal"
    requireRunAtSolvesProof "placeholder" doc position "exact hq"
  finally
    closeDoc doc

def run : ScenarioM Unit := do
  let root ← mkTmpDir "beam-todo-action-positions"
  try
    for c in cases do
      for (ending, suffix) in [
          ("newline", "\n"), ("nextCommand", "\n\n#check Nat\n"),
          ("comment", "\n-- separator\n#check Nat\n"), ("crlf", "\n"),
          ("noNewline", "")] do
        let path := root / s!"{c.name}-{ending}.lean"
        let source := s!"import Lean\n/- 😀 -/\n{c.source}{suffix}"
        IO.FS.writeFile path (if ending == "crlf" then source.replace "\n" "\r\n" else source)
        let doc ← openDoc path
        try
          checkCase doc c (ending != "noNewline")
        finally
          closeDoc doc
    checkEqualLookingGoals root
    checkPlaceholder root
  finally
    IO.FS.removeDirAll root

end BeamTest.LSP.Requests.Todo.ActionPositionTest
