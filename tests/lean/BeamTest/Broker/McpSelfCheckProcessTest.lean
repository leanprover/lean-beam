/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.SelfCheck

open Lean
open Beam.Broker

namespace BeamTest.Broker.McpSelfCheckProcessTest

-- Exercise the private scope without production fault-injection options or real PID operations.
local macro "selfCheckPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Mcp.SelfCheck name.getId)

private abbrev Scope := selfCheckPrivate% Beam.Mcp.SelfCheck.ChildScope

private def withScope (process : BackendProcess) (action : Scope → IO α) :=
  (selfCheckPrivate% Beam.Mcp.SelfCheck.withChildScope) process 0 action

private def observe (scope : Scope) :=
  (selfCheckPrivate% Beam.Mcp.SelfCheck.ChildScope.observe) scope

private def waitForExit (scope : Scope) :=
  (selfCheckPrivate% Beam.Mcp.SelfCheck.ChildScope.waitForExit) scope 0

private def require (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError label

private def requireClosed (scope : Scope) : IO Unit := do
  match ← (observe scope).toBaseIO with
  | .error (.userError "self-check child scope is closed") => pure ()
  | _ => throw <| IO.userError "an escaped self-check capability remained usable"

private def checkNormalExit : IO Unit := do
  let polls ← IO.mkRef (0 : Nat)
  let signals ← IO.mkRef (0 : Nat)
  let process ← BackendProcess.create 0
    (do polls.modify (· + 1); pure (some 23))
    (signals.modify (· + 1))
  let (outcome, cleanup) ← withScope process fun scope => do
    match ← waitForExit scope with
    | some (.exited 23) => pure scope
    | _ => throw <| IO.userError "self-check lost its observed exit"
  let scope ← IO.ofExcept outcome
  match cleanup with
  | .ok (.exited 23) => pure ()
  | _ => throw <| IO.userError "scope cleanup lost the original exit"
  requireClosed scope
  require "one terminal observation serves the action and cleanup" ((← polls.get) == 1)
  require "normal exit never signals the child" ((← signals.get) == 0)

private def checkTimeout : IO Unit := do
  let signals ← IO.mkRef (0 : Nat)
  let signalled ← IO.mkRef false
  let escaped ← IO.mkRef (none : Option Scope)
  let process ← BackendProcess.create 0
    (do pure <| if (← signalled.get) then some 23 else none)
    (do signals.modify (· + 1); signalled.set true)
  let (outcome, cleanup) ← withScope (α := Unit) process fun scope => do
    escaped.set (some scope)
    require "zero-budget wait observes the still-running child" (← waitForExit scope).isNone
    throw <| IO.userError "controlled self-check timeout"
  match outcome, cleanup with
  | .error (.userError "controlled self-check timeout"), .ok (.exited 23) => pure ()
  | _, _ => throw <| IO.userError "timeout failed to preserve its error and terminate its child"
  let some scope ← escaped.get | throw <| IO.userError "scope was not captured"
  requireClosed scope
  require "timeout signals its live owned child" ((← signals.get) == 1)

private def awaitSignal (promise : IO.Promise Unit) : IO Unit := do
  let some (some ()) ← Beam.waitTaskWithTimeout promise.result? 5000
    | throw <| IO.userError "self-check scope fixture did not reach its barrier"

private def checkObserverDuringClosure : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let polls ← IO.mkRef (0 : Nat)
  let signals ← IO.mkRef (0 : Nat)
  let process ← BackendProcess.create 0
    (do
      polls.modify (· + 1)
      entered.resolve ()
      discard <| IO.wait release.result?
      pure (some 23))
    (signals.modify (· + 1))
  let task ← IO.asTask (prio := Task.Priority.dedicated) <| withScope process fun scope => do
    let observer ← IO.asTask (prio := Task.Priority.dedicated) <| observe scope
    awaitSignal entered
    pure (scope, observer)
  try
    awaitSignal entered
    release.resolve ()
    let some (.ok (outcome, cleanup)) ← Beam.waitTaskWithTimeout task 5000
      | throw <| IO.userError "scope cleanup failed to finish after its observer"
    let (scope, observer) ← IO.ofExcept outcome
    match ← IO.wait observer, cleanup with
    | .ok (some (.exited 23)), .ok (.exited 23) => pure ()
    | _, _ => throw <| IO.userError "observer and scope cleanup did not share the exit"
    requireClosed scope
    require "scope closure never reaps twice" ((← polls.get) == 1)
    require "scope closure cannot signal after the observer reaps" ((← signals.get) == 0)
  finally
    release.resolve ()
    discard <| Beam.waitTaskWithTimeout task 5000

private def checkWaitFailure : IO Unit := do
  let polls ← IO.mkRef (0 : Nat)
  let signals ← IO.mkRef (0 : Nat)
  let process ← BackendProcess.create 0
    (do polls.modify (· + 1); throw <| IO.userError "controlled wait failure")
    (signals.modify (· + 1))
  let (outcome, cleanup) ← withScope (α := Unit) process fun scope => do
    match ← waitForExit scope with
    | some (.waitFailed error) => throw error
    | _ => throw <| IO.userError "self-check discarded its wait failure"
  match outcome, cleanup with
  | .error (.userError "controlled wait failure"),
      .ok (.unconfirmed (some (.userError "controlled wait failure")) none) => pure ()
  | _, _ => throw <| IO.userError "scope confused failed observation with confirmed exit"
  require "wait failure is retained once" ((← polls.get) == 1)
  require "wait failure forbids signalling" ((← signals.get) == 0)

private def checkFailureReporting : IO Unit := do
  let finish := selfCheckPrivate% Beam.Mcp.SelfCheck.finishCheck
  let primary := IO.userError "controlled operation failure"
  match ← (finish (.error primary) (.ok (.exited 23)) (.ok true) (.ok none)).toBaseIO with
  | .error (.userError "controlled operation failure") => pure ()
  | _ => throw <| IO.userError "successful cleanup replaced the original typed error"
  let result ← (finish (.error primary)
    (.ok (.unconfirmed (some (IO.userError "controlled wait failure"))
      (some (IO.userError "controlled signal failure")))) (.ok false)
    (.ok (some (.sourceFailed (IO.userError "controlled stderr failure"), "controlled tail")))).toBaseIO
  match result with
  | .error error =>
      for message in ["controlled operation failure", "controlled wait failure",
          "controlled signal failure", "controlled stderr failure", "controlled tail",
          "protocol task did not finish"] do
        require s!"combined self-check failure omitted {message}" (error.toString.contains message)
  | .ok () => throw <| IO.userError "combined failures incorrectly reported success"
  match ← (finish (.ok ()) (.ok (.unconfirmed none none)) (.ok true) (.ok none)).toBaseIO with
  | .error _ => pure ()
  | .ok () => throw <| IO.userError "unconfirmed cleanup incorrectly reported success"

def run : IO Unit := do
  checkNormalExit
  checkTimeout
  checkObserverDuringClosure
  checkWaitFailure
  checkFailureReporting

end BeamTest.Broker.McpSelfCheckProcessTest
