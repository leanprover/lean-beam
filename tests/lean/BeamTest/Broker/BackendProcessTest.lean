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

private def requireExit (label : String) (outcome : BackendTermination) : IO Unit := do
  match outcome with
  | .exited 23 => pure ()
  | _ => throw <| IO.userError s!"{label}: original exit status was lost"

private def observeExit (process : BackendProcess) : IO BackendTermination := do
  let some exit ← process.observe
    | throw <| IO.userError "fixture expected a terminal observation"
  pure exit.toTermination

private def awaitSignal (signal : IO.Promise Unit) : IO Unit := do
  let some (some ()) ← Beam.waitTaskWithTimeout signal.result? 5000
    | throw <| IO.userError "process-owner fixture did not reach its controlled operation"

private def awaitExit (task : Task (Except IO.Error BackendTermination)) : IO Unit := do
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
    if first == .observe then observeExit process else process.terminate 0
  let competingTask? ← IO.mkRef (none : Option (Task (Except IO.Error BackendTermination)))
  try
    awaitSignal entered
    let competingTask ← IO.asTask (prio := Task.Priority.dedicated) do
      competingStarted.resolve ()
      if first == .observe then process.terminate 0 else observeExit process
    competingTask?.set (some competingTask)
    awaitSignal competingStarted
    release.resolve ()
    awaitExit firstTask
    awaitExit competingTask
    requireExit "repeated observation" (← observeExit process)
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
  for observation in [process.observe, process.waitForExit 0] do
    match ← observation with
    | some (.waitFailed (.userError "controlled process wait failure")) => pure ()
    | _ => throw <| IO.userError "process owner changed its retained typed wait failure"
  match ← process.terminate 0 with
  | .unconfirmed (some (.userError "controlled process wait failure")) none => pure ()
  | _ => throw <| IO.userError "a failed wait was mistaken for confirmed termination"
  require "a failed wait is never retried" ((← polls.get) == 1)
  require "a failed wait never authorizes a PID signal" ((← kills.get) == 0)

private def checkTerminationOutcomes : IO Unit := do
  for signalFails in [false, true] do
    for exits in [false, true] do
      let signalled ← IO.mkRef false
      let process ← BackendProcess.create 0
        (do pure <| if (← signalled.get) && exits then some 23 else none)
        (do
          signalled.set true
          if signalFails then throw <| IO.userError "controlled signal failure")
      match exits, signalFails, ← process.terminate 0 with
      | true, _, .exited 23 => pure ()
      | false, false, .unconfirmed none none => pure ()
      | false, true, .unconfirmed none (some (.userError "controlled signal failure")) => pure ()
      | _, _, _ => throw <| IO.userError "termination changed its confirmed-exit or signal-failure outcome"
      require "termination attempts a signal for a running child" (← signalled.get)
  let signalled ← IO.mkRef false
  let process ← BackendProcess.create 0
    (do
      if ← signalled.get then throw <| IO.userError "wait after signal failed"
      pure none)
    (do
      signalled.set true
      throw <| IO.userError "signal before wait failed")
  match ← process.terminate 0 with
  | .unconfirmed (some (.userError "wait after signal failed"))
      (some (.userError "signal before wait failed")) => pure ()
  | _ => throw <| IO.userError "termination did not preserve both typed process failures"

def check : IO Unit := do
  checkCompetingOperations .observe
  checkCompetingOperations .terminate
  checkRetainedWaitFailure
  checkTerminationOutcomes

end BeamTest.Broker.BackendProcessTest
