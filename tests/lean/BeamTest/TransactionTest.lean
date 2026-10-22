/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Transaction

namespace BeamTest.TransactionTest

private inductive Fault where
  | operation | cancelled | recovery (index : Nat)
  deriving BEq, Repr

private def require (message : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError message

private def action (events : IO.Ref (Array Nat)) (index : Nat)
    (fail : Bool := false) : EIO Fault Unit := do
  events.modify (·.push index)
  if fail then throw (.recovery index)

private def requireFailures (label : String)
    (actual : Array (Beam.Transaction.ActionFailure Fault)) (expected : Array Nat) : IO Unit := do
  require s!"{label}: wrong recovery failures" (actual.map (·.actionIndex) == expected)
  for failure in actual do
    require s!"{label}: lost typed recovery failure"
      (failure.error == .recovery failure.actionIndex)

private def testCommit : IO Unit := do
  let events ← IO.mkRef (#[] : Array Nat)
  let outcome ← Beam.Transaction.run (pure (17 : Nat) : EIO Fault Nat)
    (rollback := #[action events 99])
    (cleanup := #[action events 0 true, action events 1 true, action events 2])
  match outcome with
  | .committed value failures =>
      require "commit: lost successful result" (value == 17)
      requireFailures "commit" failures #[1, 0]
  | .aborted .. => throw <| IO.userError "cleanup failure incorrectly aborted committed work"
  require "commit: wrong cleanup order or rollback ran" ((← events.get) == #[2, 1, 0])

private def testAbort (fault : Fault) (changeState failRecovery : Bool) : IO Unit := do
  let state ← IO.mkRef (0 : Nat)
  let events ← IO.mkRef (#[] : Array Nat)
  let operation : EIO Fault Unit := do
    if changeState then state.set 1
    throw fault
  let restore : EIO Fault Unit := do
    state.set 0
    action events 0
  let outcome ← Beam.Transaction.run operation
    (rollback := #[restore, action events 1 failRecovery, action events 2])
    (cleanup := #[action events 99])
  match outcome with
  | .aborted error failures =>
      require "abort: lost original typed failure" (error == fault)
      requireFailures "abort" failures (if failRecovery then #[1] else #[])
  | .committed .. => throw <| IO.userError "failed operation incorrectly committed"
  require "abort: rollback stopped early, ran out of order, or cleanup ran"
    ((← events.get) == #[2, 1, 0])
  require "abort: recovery did not restore the beforeimage" ((← state.get) == 0)

private def testEmpty : IO Unit := do
  match ← Beam.Transaction.run (pure () : EIO Fault Unit) with
  | .committed () failures => require "empty commit: unexpected failure" failures.isEmpty
  | .aborted .. => throw <| IO.userError "empty transaction failed"
  match ← Beam.Transaction.run (throw Fault.operation : EIO Fault Unit) with
  | .aborted error failures =>
      require "empty abort: lost failure" (error == .operation && failures.isEmpty)
  | .committed .. => throw <| IO.userError "empty abort incorrectly committed"

/-- Recovery ordering and typed error preservation, independently of filesystem publication. -/
def run : IO Unit := do
  testCommit
  testAbort .operation false false
  testAbort .operation true false
  testAbort .operation true true
  testAbort .cancelled true true
  testEmpty
  IO.println "transaction scope tests passed"

end BeamTest.TransactionTest
