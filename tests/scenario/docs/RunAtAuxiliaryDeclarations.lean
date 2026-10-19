import Lean
open Lean Elab Tactic

namespace RunAtAuxiliaryDeclarations

private def auxNames : TacticM (List Name) := do
  let some parent ← Term.getDeclName?
    | throwError "missing enclosing declaration context"
  let parent := privateToUserName parent.eraseMacroScopes
  return ((← getEnv).setExporting false).constants.toList.filterMap fun (name, _) =>
    let userName := privateToUserName name.eraseMacroScopes
    if userName != parent && parent.isPrefixOf userName then some name else none

-- Inventory declarations under the theorem without assuming generated name suffixes.
elab "guard_aux_count " expected:num : tactic => do
  let actual := (← auxNames).length
  unless actual == expected.getNat do
    throwError "expected {expected.getNat} auxiliary declarations, got {actual}"

-- A cached lemma must not make a declaration-creation regression pass accidentally.
elab "fresh_aux " t:tactic : tactic => do
  let before ← auxNames
  evalTactic t
  let after ← auxNames
  unless after.any (fun name => !before.contains name) do
    throwError "tactic did not create a fresh auxiliary declaration"

end RunAtAuxiliaryDeclarations

theorem auxiliaryTopLevel : (4 : Nat) = 4 := by
  rfl -- probe:top-level

namespace RunAtAuxiliaryDeclarations

theorem omegaGoal (n m k : Nat) (h1 : n ≤ m) (h2 : m ≤ k) : n ≤ k := by
  exact Nat.le_trans h1 h2 -- probe:omega

theorem grindGoal (f : Nat → Nat) (a b : Nat) (h : a = b) : f a = f b := by
  exact congrArg f h -- probe:grind

theorem closedGoal : 0 + 0 = 0 := by
  rfl -- probe:decide

private theorem privateGoal : (5 : Nat) = 5 := by
  rfl -- probe:private

theorem nestedGoal : (6 : Nat) = 6 := by
  have h : (6 : Nat) = 6 := by
    rfl -- probe:nested
  exact h

theorem localDecideGoal (n : Nat) : n = n := by
  rfl -- probe:local-decide

theorem handleGoal : (1 : Nat) = 1 ∧ (2 : Nat) = 2 ∧ (3 : Nat) = 3 := by
  constructor -- probe:handle
  · rfl
  · constructor
    · rfl
    · rfl

end RunAtAuxiliaryDeclarations

elab "#guard_aux_document_clean" : command => do
  let roots := [
    `auxiliaryTopLevel,
    `RunAtAuxiliaryDeclarations.omegaGoal,
    `RunAtAuxiliaryDeclarations.grindGoal,
    `RunAtAuxiliaryDeclarations.closedGoal,
    `RunAtAuxiliaryDeclarations.privateGoal,
    `RunAtAuxiliaryDeclarations.nestedGoal,
    `RunAtAuxiliaryDeclarations.localDecideGoal,
    `RunAtAuxiliaryDeclarations.handleGoal
  ]
  for (name, _) in ((← getEnv).setExporting false).constants.toList do
    let name := privateToUserName name.eraseMacroScopes
    if roots.any (fun root => name != root && root.isPrefixOf name) ||
        `commandAuxProbe.isPrefixOf name then
      throwError "speculative auxiliary leaked into the document: {name}"

#check Nat -- probe:command
