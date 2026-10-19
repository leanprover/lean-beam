import Lean
open Lean

namespace RunAtAuxiliaryDeclarations

theorem omegaGoal (n : Nat) : n + 0 = n := by
  omega

theorem grindGoal (n : Nat) : n + 0 = n := by
  grind

theorem ordinaryDecide : 0 + 0 = 0 := by
  decide +kernel

theorem closedGoal : 0 + 0 = 0 := by
  simp

theorem nestedGoal : (1 : Nat) = 1 ∧ (2 : Nat) = 2 := by
  constructor
  · rfl
  · rfl

end RunAtAuxiliaryDeclarations

#check Nat
