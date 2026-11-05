import Lean

open Lean Elab Command

deriving instance TypeName for Lean.Name
deriving instance TypeName for Bool

macro "profile_guard_alias" : command =>
  `(command| /-- trace: [debug] hello -/
    #guard_msgs in
    set_option trace.debug true in
    run_cmd trace[debug] "hello")

def profileContractsAnchor : Nat := 0
