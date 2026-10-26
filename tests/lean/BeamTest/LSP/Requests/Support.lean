/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Scenario

open Lean
open BeamTest.LSP.Scenario

namespace BeamTest.LSP.Requests.Support

def contentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

def expectFileExists (label : String) (path : System.FilePath) : ScenarioM Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"{label}: expected file {path} to exist"

def requireSingleGoalTarget (label expectedNeedle : String) (state : Beam.LSP.Lib.ProofState) :
    ScenarioM Unit := do
  let some goal := state.goals[0]?
    | throw <| IO.userError s!"{label}: expected one goal"
  unless goal.target.contains expectedNeedle do
    throw <| IO.userError s!"{label}: expected target to contain '{expectedNeedle}', got '{goal.target}'"

def requireTodoKind (label : String) (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) :
    ScenarioM Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"{label}: expected todo kind {kind.key}, got {(toJson result).compress}"
  pure item

def requireNoTodoKind (label : String) (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) :
    ScenarioM Unit := do
  if result.items.any (fun item => item.kind == kind) then
    throw <| IO.userError s!"{label}: unexpected todo kind {kind.key}: {(toJson result).compress}"

def countTodoKind (kind : Beam.LSP.Todo.TodoKind) (result : Beam.LSP.Todo.TodoResult) : Nat :=
  result.items.foldl (init := 0) fun count item =>
    if item.kind == kind then count + 1 else count

def requireTodoKindCount
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (expected : Nat)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  let actual := countTodoKind kind result
  unless actual == expected do
    throw <| IO.userError
      s!"{label}: expected {expected} todo items of kind {kind.key}, got {actual}: {(toJson result).compress}"

def requireTodoKindAtLeast
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (expected : Nat)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  let actual := countTodoKind kind result
  unless expected <= actual do
    throw <| IO.userError
      s!"{label}: expected at least {expected} todo items of kind {kind.key}, got {actual}: {(toJson result).compress}"

def requireRangeEq (label : String) (expected actual : Lean.Lsp.Range) : ScenarioM Unit := do
  unless actual == expected do
    throw <| IO.userError s!"{label}: expected range {repr expected}, got {repr actual}"

def todoMessageContains (needle : String) (item : Beam.LSP.Todo.TodoItem) : Bool :=
  match item.message? with
  | some message => message.contains needle
  | none => false

def requireTodoKindWithMessage
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (needle : String)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind && todoMessageContains needle item)
    | throw <| IO.userError
        s!"{label}: expected todo kind {kind.key} with message containing '{needle}', got {(toJson result).compress}"
  pure item

def requireDiagnosticSeverity
    (label : String)
    (severity : Lean.Lsp.DiagnosticSeverity)
    (result : Beam.LSP.Todo.TodoResult) : ScenarioM Unit := do
  unless result.items.any (fun item => item.kind == .diagnostic && item.severity? == some severity) do
    throw <| IO.userError
      s!"{label}: expected diagnostic severity {(toJson severity).compress}, got {(toJson result).compress}"

def requireRunAtPosition (label : String) (item : Beam.LSP.Todo.TodoItem) :
    ScenarioM Lean.Lsp.Position := do
  let some position := item.runAtPosition?
    | throw <| IO.userError s!"{label}: expected a runAt position, got {(toJson item).compress}"
  pure position

def requireRunAtSuccess
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String) : ScenarioM Beam.LSP.RunAt.Result := do
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
  unless result.success do
    throw <| IO.userError s!"{label}: expected runAt success, got {(toJson result).compress}"
  pure result

def requireRunAtResponseSuccess
    (label : String)
    (req : ReqHandle) : ScenarioM Beam.LSP.RunAt.Result := do
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
  unless result.success do
    throw <| IO.userError s!"{label}: expected runAt success, got {(toJson result).compress}"
  pure result

def requireRunAtSolvesProof
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String) : ScenarioM Unit := do
  let result ← requireRunAtSuccess label doc position text
  let some proofState := result.proofState?
    | throw <| IO.userError s!"{label}: expected proofState, got {(toJson result).compress}"
  unless proofState.goals.isEmpty do
    throw <| IO.userError s!"{label}: expected solved proof state, got {(toJson proofState).compress}"

def requireRunAtFailureMessage
    (label : String)
    (doc : DocHandle)
    (position : Lean.Lsp.Position)
    (text : String)
    (needle : String) : ScenarioM Unit := do
  let req ← sendRunAt doc {
    line := position.line
    character := position.character
    text
  }
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
  if result.success then
    throw <| IO.userError s!"{label}: expected runAt failure, got {(toJson result).compress}"
  unless result.messages.any (fun msg => msg.severity == MessageSeverity.error && msg.text.contains needle) do
    throw <| IO.userError
      s!"{label}: expected error message containing '{needle}', got {(toJson result).compress}"

def mkTmpDir (stem : String) : ScenarioM System.FilePath := do
  let dir := System.FilePath.mk s!"/tmp/{stem}-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  pure dir

def expectContentModified (req : ReqHandle) : ScenarioM Unit :=
  expectErrorContains req contentModifiedJson

def invalidateWithWhitespacePrefixEdit (doc : DocHandle) : ScenarioM Unit := do
  BeamTest.LSP.Requests.Interference.syncWhitespacePrefixEdit doc

end BeamTest.LSP.Requests.Support
