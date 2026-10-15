import Lean

open Lean Elab Tactic Command

elab "profile_left" : tactic => do
  withTraceNode `beam.profile.left (fun _ => pure "left") do
    IO.sleep 15

elab "profile_right" : tactic => do
  withTraceNode `beam.profile.right (fun _ => pure "right") do
    IO.sleep 15

elab "profile_check_off" : tactic => do
  let opts ← getOptions
  if trace.profiler.get opts || (trace.profiler.output.get? opts).isSome then
    throwError "profiling options leaked into continuation"

elab "profile_check_command" : command => do
  let opts ← getOptions
  if trace.profiler.get opts || (trace.profiler.output.get? opts).isSome then
    throwError "profiling options leaked into command continuation"

def profileAnchor : Nat := 0

example : True := by
  trivial

theorem existingProfiledDeclaration : True ∧ True := by
  constructor
  · profile_left
    trivial
  · profile_right
    trivial
