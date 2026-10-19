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

elab "guard_universe " name:ident : tactic => do
  unless (← Term.getLevelNames).contains name.getId do
    throwError "missing universe parameter {name.getId}"

-- Exercise the synthesis phase after `evalTactic` returns, using Lean's postponement API.
elab "postpone_exact " value:term : tactic => withMainContext do
  unless (← Term.getLetRecsToLift).isEmpty do
    throwError "postponement control already contains recursive declarations"
  let proof ← Term.postponeElabTerm value (some (← getMainTarget))
  (← getMainGoal).assign proof
  replaceMainGoal []

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

universe u v

theorem universeGoal : ([] : List (ULift.{u} Nat)).length = 0 := by
  rfl -- probe:universe

theorem explicitUniverseGoal.{w, z} : ([] : List (ULift.{w} (ULift.{z} Nat))).length = 0 := by
  rfl -- probe:explicit-universe

theorem ambientUniverseGoal : True := by
  trivial -- probe:ambient-universe

theorem clearedUniverseGoal.{q} (_α : Type q) : True := by
  clear _α
  trivial -- probe:cleared-universe

theorem localUniverseGoal.{w} (_α : Type w) : True := by
  trivial -- probe:local-universe

theorem universeGrindGoal (α : Type u) (f : α → α) (a b : α) (h : a = b) : f a = f b := by
  exact congrArg f h -- probe:universe-grind

theorem rollbackGoal : (8 : Nat) = 8 := by
  rfl -- probe:rollback

class LocalValue where
  value : Nat

theorem instanceGoal : ∃ n : Nat, n = 7 := by
  exact ⟨7, rfl⟩ -- probe:instance

theorem instanceRollbackGoal : ∃ n : Nat, n = 7 := by
  exact ⟨7, rfl⟩ -- probe:instance-rollback

theorem documentInstanceGoal : ∃ n : Nat, n = 7 := by
  letI : LocalValue := ⟨7⟩
  exact ⟨LocalValue.value, rfl⟩ -- probe:document-instance

theorem recursiveGoal (offset : Nat) : ∃ _f : Nat → Nat, True := by
  exact ⟨fun _ => offset, trivial⟩ -- probe:recursive

theorem postponedGoal (offset : Nat) : ∃ _f : Nat → Nat, True := by
  exact ⟨fun _ => offset, trivial⟩ -- probe:postponed

theorem dependentGoal (n : Nat) (xs : Fin n → Nat) : ∀ i : Fin n, xs i ≤ xs i + n := by
  intro i; exact Nat.le_add_right (xs i) n -- probe:dependent

theorem nativeGoal : (List.range 20).foldl (· + ·) 0 = 190 := by
  rfl -- probe:native

theorem convGoal (f : Nat → Nat) : (fun x => f (0 + x) + 0) = f := by
  funext x; simp -- probe:conv

theorem bitvectorGoal (x y : BitVec 8) : x + y = y + x := by
  exact BitVec.add_comm x y -- probe:bitvector

theorem bitvectorSolverGoal (x : BitVec 8) (h : x ≠ BitVec.allOnes 8) : x < x + 1 := by
  exact BitVec.lt_add_one h -- probe:bitvector-solver

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
    `RunAtAuxiliaryDeclarations.universeGoal,
    `RunAtAuxiliaryDeclarations.explicitUniverseGoal,
    `RunAtAuxiliaryDeclarations.ambientUniverseGoal,
    `RunAtAuxiliaryDeclarations.clearedUniverseGoal,
    `RunAtAuxiliaryDeclarations.localUniverseGoal,
    `RunAtAuxiliaryDeclarations.universeGrindGoal,
    `RunAtAuxiliaryDeclarations.rollbackGoal,
    `RunAtAuxiliaryDeclarations.instanceGoal,
    `RunAtAuxiliaryDeclarations.instanceRollbackGoal,
    `RunAtAuxiliaryDeclarations.documentInstanceGoal,
    `RunAtAuxiliaryDeclarations.recursiveGoal,
    `RunAtAuxiliaryDeclarations.postponedGoal,
    `RunAtAuxiliaryDeclarations.dependentGoal,
    `RunAtAuxiliaryDeclarations.nativeGoal,
    `RunAtAuxiliaryDeclarations.convGoal,
    `RunAtAuxiliaryDeclarations.bitvectorGoal,
    `RunAtAuxiliaryDeclarations.bitvectorSolverGoal,
    `RunAtAuxiliaryDeclarations.handleGoal
  ]
  for (name, _) in ((← getEnv).setExporting false).constants.toList do
    let name := privateToUserName name.eraseMacroScopes
    if roots.any (fun root => name != root && root.isPrefixOf name) ||
        (`commandAuxProbe).isPrefixOf name || (`recursiveCommandProbe).isPrefixOf name then
      throwError "speculative auxiliary leaked into the document: {name}"

#check Nat -- probe:command
