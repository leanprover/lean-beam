/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Todo

namespace BeamTest.Fixtures.TodoFixture

-- Coordinates below track the checked-in files under `tests/save_olean_project`.

def repoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoSmoke.lean"

def codeActionRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoCodeActionSmoke.lean"

def complexRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoComplexSmoke.lean"

def progressRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoProgressSmoke.lean"

def brokerPath : String :=
  "TodoSmoke.lean"

def startLine : Nat := 0
def startCharacter : Nat := 0
def endLine : Nat := 17
def endCharacter : Nat := 0

def skippedSorryEndLine : Nat := 12

def sorryLine : Nat := 13
def sorryCharacter : Nat := 2

def sorryPosition : Lean.Lsp.Position := {
  line := sorryLine
  character := sorryCharacter
}

def codeActionLine : Nat := 22
def codeActionStartCharacter : Nat := 28
def codeActionEndCharacter : Nat := 29

def codeActionRange : Lean.Lsp.Range := {
  start := { line := codeActionLine, character := codeActionStartCharacter }
  «end» := { line := codeActionLine, character := codeActionEndCharacter }
}

def complexStartLine : Nat := 0
def complexStartCharacter : Nat := 0
def complexEndLine : Nat := 66
def complexEndCharacter : Nat := 0

def complexFalsePositiveStartLine : Nat := 24
def complexFalsePositiveEndLine : Nat := 34

def complexCodeActionLine : Nat := 43
def complexCodeActionStartCharacter : Nat := 35
def complexCodeActionEndCharacter : Nat := 36

def complexSorryStartLine : Nat := 45
def complexSorryEndLine : Nat := 48

def complexIncompleteOneStartLine : Nat := 53
def complexIncompleteOneEndLine : Nat := 56

def complexBranchSkipStartLine : Nat := 59
def complexBranchSkipEndLine : Nat := 60

def complexDiagnosticLine : Nat := 61
def complexDiagnosticEndCharacter : Nat := 42

-- `TodoProgressSmoke.lean`: complete proofs occupy lines before `progressCompleteEndLine`; each
-- open proof leaves one goal at the end of a `skip`.
def progressCompleteEndLine : Nat := 31
def progressEndLine : Nat := 44

def progressOpenPositions : Array Lean.Lsp.Position := #[
  { line := 36, character := 8 },
  { line := 41, character := 21 },
  { line := 43, character := 62 }
]

def agentRepoPath : System.FilePath :=
  System.FilePath.mk "tests/save_olean_project/TodoAgentSmoke.lean"

/-- One expected item of a whole-document todo request on `TodoAgentSmoke.lean`. -/
structure AgentItem where
  kind : Beam.LSP.Todo.TodoKind
  start : Lean.Lsp.Position
  runAt : Lean.Lsp.Position
  /-- Whether `runAt` at `runAt` starts from the item's goals; false when no position selects them. -/
  selectable : Bool := true
  /-- Goal targets of the item's proof state; empty when the item has none. -/
  goals : Array String := #[]
  /-- Text that `runAt` at the item's position must use to close every goal. -/
  solution? : Option String := none

def agentItems : Array AgentItem := #[
  { kind := .sorry, start := ⟨7, 4⟩, runAt := ⟨7, 4⟩, goals := #["True"], solution? := some "trivial" },
  { kind := .diagnostic, start := ⟨10, 8⟩, runAt := ⟨10, 2⟩, goals := #["n + 0 = n"],
    solution? := some "simp" },
  { kind := .diagnostic, start := ⟨13, 2⟩, runAt := ⟨13, 2⟩, goals := #["2 + 2 = 5"] },
  { kind := .diagnostic, start := ⟨16, 2⟩, runAt := ⟨16, 2⟩, goals := #["n * n ≥ n + 1"] },
  { kind := .sorry, start := ⟨19, 24⟩, runAt := ⟨19, 24⟩, goals := #["n + 0 = n"],
    solution? := some "exact Nat.add_zero n" },
  { kind := .incompleteProof, start := ⟨23, 2⟩, runAt := ⟨23, 9⟩, goals := #["n = n"],
    solution? := some "rfl" },
  { kind := .sorry, start := ⟨27, 13⟩, runAt := ⟨27, 13⟩, goals := #["a = b"], solution? := some "exact h" },
  { kind := .incompleteProof, start := ⟨32, 17⟩, runAt := ⟨32, 21⟩, goals := #["0 + (n + 1) = n + 1"],
    solution? := some "omega" },
  { kind := .incompleteProof, start := ⟨35, 2⟩, runAt := ⟨35, 17⟩, goals := #["Nat", "?refine_1 = 3"],
    solution? := some "exact 3\nrfl" },
  { kind := .hole, start := ⟨39, 50⟩, runAt := ⟨39, 50⟩, goals := #["Nat"], solution? := some "exact 0" },
  { kind := .sorry, start := ⟨41, 65⟩, runAt := ⟨41, 65⟩, goals := #["q"], solution? := some "exact hq" },
  { kind := .diagnostic, start := ⟨43, 36⟩, runAt := ⟨43, 36⟩ },
  -- The `?_` became a goal that the `sorry` tactic fills: one item, not a hole as well.
  { kind := .sorry, start := ⟨52, 2⟩, runAt := ⟨52, 2⟩, goals := #["k = 4"], solution? := some "omega" },
  -- The failed `exact` left its goal open; the hole that made it fail is the one item.
  { kind := .hole, start := ⟨55, 13⟩, runAt := ⟨55, 13⟩, goals := #["q"], solution? := some "exact hq" },
  -- `skip` ran once per goal: both goals are reported, but `runAt` at its end selects only one run.
  { kind := .incompleteProof, start := ⟨58, 18⟩, runAt := ⟨58, 22⟩, selectable := false,
    goals := #["p", "q"] },
  -- The goal left after a bullet has no source position whose state `runAt` selects.
  { kind := .incompleteProof, start := ⟨62, 2⟩, runAt := ⟨62, 12⟩, selectable := false,
    goals := #["q"] },
  -- `rwaDone`, `simpaDone`, and `refineRwa` are complete: their closing steps solve the goals.
  -- The bullet's own goal, which Lean admits after the bullet stops early, is not reported again;
  -- `rw` records its closing `rfl` attempt at `]`, the narrowest tactic ending where `rw` ends.
  { kind := .incompleteProof, start := ⟨76, 20⟩, runAt := ⟨76, 21⟩, goals := #["n = 0"],
    solution? := some "exact h" },
  -- `all_goals` runs `skip` once per goal, as `<;>` does.
  { kind := .incompleteProof, start := ⟨81, 12⟩, runAt := ⟨81, 16⟩, selectable := false,
    goals := #["p", "q"] },
  -- `try` recovered from `exact hp` on `q`; the narrowest tactic ending there left it open.
  { kind := .incompleteProof, start := ⟨85, 16⟩, runAt := ⟨85, 24⟩, selectable := false,
    goals := #["q"] },
  -- The inner `skip` ran once per goal of every outer run: one item for all three goals.
  { kind := .incompleteProof, start := ⟨91, 14⟩, runAt := ⟨91, 18⟩, selectable := false,
    goals := #["p", "q", "r"] },
  -- `focus` restores the unfocused `q` after its body left `p`: two tactics, one goal each.
  { kind := .incompleteProof, start := ⟨95, 2⟩, runAt := ⟨95, 12⟩, selectable := false,
    goals := #["q"] },
  { kind := .incompleteProof, start := ⟨95, 8⟩, runAt := ⟨95, 12⟩, goals := #["p"] },
  -- `sorry` ran once per goal: one item with both goals, like `seqSkip`.
  { kind := .sorry, start := ⟨98, 18⟩, runAt := ⟨98, 18⟩, selectable := false, goals := #["p", "q"] }
  -- `firstBacktracks` is complete: the goals of its abandoned `constructor` branch are not reported.
]

end BeamTest.Fixtures.TodoFixture
