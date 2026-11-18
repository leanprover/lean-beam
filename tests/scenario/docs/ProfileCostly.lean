import Lean

open Lean Elab Tactic

private def earlyScopes : Nat → TacticM Unit
  | 0 => IO.sleep 2
  | n + 1 => withTraceNode `profile.early (fun _ => pure "early") (earlyScopes n)

elab "profile_costly" : tactic => do
  -- Eight nested scopes share each wait: 1,088 early timed nodes without 1,088 sleeps.
  for _ in [:136] do earlyScopes 8
  withTraceNode `profile.late (fun _ => pure "late") (IO.sleep 100 : TacticM Unit) (tag := "late-step")

def anchor := 0
