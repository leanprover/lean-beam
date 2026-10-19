import Lean
open Lean Elab Tactic

theorem proofInUniverse.{u} (_ : Type u) : True := True.intro
theorem proofInTwoUniverses.{u, v} (_ : Type u) (_ : Type v) : True := True.intro
theorem unrelatedUniverse.{leaked} (_ : Type leaked) : True := True.intro

elab "guard_universe_absent " name:ident : tactic => do
  if (← Term.getLevelNames).contains name.getId then
    throwError "unexpected universe {name.getId}"

set_option Elab.async false -- option:async

theorem bodyUniverse.{v} : True := by
  run_tac
    let _ ← `(command| theorem quoted.{leaked} : True := by trivial)
    pure ()
  exact proofInUniverse.{v} (ULift.{v} Nat) -- probe:top

namespace HeaderUniverseScope

private theorem privateUniverse.{v} : True := by
  exact proofInUniverse.{v} (ULift.{v} Nat) -- probe:private

theorem nestedUniverse.{v} : True := by
  have h : True := by
    exact proofInUniverse.{v} (ULift.{v} Nat) -- probe:nested
  exact h

mutual
  theorem mutualFirst.{u, v} : True := by
    exact proofInTwoUniverses.{u, v} (ULift.{u} Nat) (ULift.{v} Nat) -- probe:mutual-first
  theorem mutualSecond.{u, v} : True := by
    exact proofInTwoUniverses.{v, u} (ULift.{v} Nat) (ULift.{u} Nat) -- probe:mutual-second
end

end HeaderUniverseScope

#check Nat
