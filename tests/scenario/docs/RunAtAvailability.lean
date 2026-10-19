import Lean
open Lean Elab Tactic

elab "await_test_gate " entered:str release:str " then " finish:tactic : tactic => do
  IO.FS.writeFile entered.getString "entered"
  let started ← IO.monoMsNow
  while !(← (System.FilePath.mk release.getString).pathExists) do
    if (← IO.monoMsNow) - started > 30000 then
      throwError "availability fixture gate expired"
    IO.sleep 5
  evalTactic finish

elab "guard_command_universe" : tactic => do
  unless (← Term.getLevelNames).contains `u do
    throwError "missing command universe u"

theorem proofInUniverse.{v} (_ : Type v) : True := True.intro

universe u

set_option Elab.async false in
theorem synchronousGoal : True := by
  skip -- probe:sync
  trivial -- gate:sync

set_option Elab.async true in
theorem asynchronousGoal : True := by
  skip -- probe:async
  trivial -- gate:async

set_option Elab.async false in
theorem synchronousBodyUniverse.{v} : True := by
  skip -- probe:body
  exact proofInUniverse.{v} (ULift.{v} Nat) -- gate:body

#check Nat
