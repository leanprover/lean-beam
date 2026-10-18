/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.BackendProcess
import Beam.System

open Beam.Broker

namespace BeamTest.Broker.BackendProcessTest

private def require (label : String) (condition : Bool) : IO Unit := do
  unless condition do throw <| IO.userError label

private def requireExit (label : String) (exit? : Option BackendExit) : IO Unit := do
  match exit? with
  | some (.exited 23) => pure ()
  | _ => throw <| IO.userError s!"{label}: original exit status was lost"

private def awaitSignal (signal : IO.Promise Unit) : IO Unit := do
  let some (some ()) ← Beam.waitTaskWithTimeout signal.result? 5000
    | throw <| IO.userError "process-owner fixture did not reach its controlled operation"

private def awaitExit (task : Task (Except IO.Error (Option BackendExit))) : IO Unit := do
  match ← Beam.waitTaskWithTimeout task 5000 with
  | some (.ok exit?) => requireExit "competing process cleanup" exit?
  | some (.error error) => throw error
  | none => throw <| IO.userError "competing process cleanup did not finish"

private inductive FirstOperation where
  | observe
  | terminate
  deriving BEq

/-- Overlap the callers inside a raw process operation, rather than after a whole cleanup finishes. -/
private def checkCompetingOperations (first : FirstOperation) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let competingStarted ← IO.Promise.new
  let polls ← IO.mkRef (0 : Nat)
  let kills ← IO.mkRef (0 : Nat)
  let killing ← IO.mkRef false
  let process ← BackendProcess.create 0
    (do
      require "process polling cannot overlap a signal" (!(← killing.get))
      let count ← polls.get
      polls.set (count + 1)
      if first == .terminate && count == 0 then return none
      require "terminal process status must be consumed only once"
        (count == if first == .terminate then 1 else 0)
      if first == .observe then
        entered.resolve ()
        discard <| IO.wait release.result?
      pure (some 23))
    (do
      kills.modify (· + 1)
      require "an observed exit forbids signalling" (first == .terminate)
      killing.set true
      entered.resolve ()
      discard <| IO.wait release.result?
      killing.set false)
  let firstTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    if first == .observe then process.observe else process.terminate 0
  let competingTask? ← IO.mkRef (none : Option (Task (Except IO.Error (Option BackendExit))))
  try
    awaitSignal entered
    let competingTask ← IO.asTask (prio := Task.Priority.dedicated) do
      competingStarted.resolve ()
      if first == .observe then process.terminate 0 else process.observe
    competingTask?.set (some competingTask)
    awaitSignal competingStarted
    release.resolve ()
    awaitExit firstTask
    awaitExit competingTask
    requireExit "repeated observation" (← process.observe)
    requireExit "repeated termination" (← process.terminate 0)
    require "all callers share one terminal wait"
      ((← polls.get) == if first == .terminate then 2 else 1)
    require "cleanup never signals after reaping"
      ((← kills.get) == if first == .terminate then 1 else 0)
  finally
    release.resolve ()
    discard <| Beam.waitTaskWithTimeout firstTask 5000
    if let some task ← competingTask?.get then
      discard <| Beam.waitTaskWithTimeout task 5000

private def checkRetainedWaitFailure : IO Unit := do
  let polls ← IO.mkRef (0 : Nat)
  let kills ← IO.mkRef (0 : Nat)
  let process ← BackendProcess.create 0
    (do
      polls.modify (· + 1)
      throw <| IO.userError "controlled process wait failure")
    (kills.modify (· + 1))
  for observation in [process.observe, process.terminate 0, process.waitForExit 0] do
    match ← observation with
    | some (.waitFailed (.userError "controlled process wait failure")) => pure ()
    | _ => throw <| IO.userError "process owner changed its retained typed wait failure"
  require "a failed wait is never retried" ((← polls.get) == 1)
  require "a failed wait never authorizes a PID signal" ((← kills.get) == 0)

def check : IO Unit := do
  checkCompetingOperations .observe
  checkCompetingOperations .terminate
  checkRetainedWaitFailure

end BeamTest.Broker.BackendProcessTest
