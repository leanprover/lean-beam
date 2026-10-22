/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Commands
import BeamTest.TestHarness

namespace BeamTest.Broker.InterruptWatcherTest

private def require (label : String) (condition : Bool) : IO Unit := do
  unless condition do throw <| IO.userError label

private def startWaiter (watcher : Beam.Cli.InterruptWatcher) :
    IO (Task (Except IO.Error Unit)) := do
  require "fresh watcher already interrupted" (!(← watcher.interrupted))
  let started ← IO.Promise.new
  let waiter ← IO.asTask (prio := .dedicated) do
    started.resolve ()
    watcher.awaitInterrupt
  let some _ ← IO.wait started.result?
    | throw <| IO.userError "waiter startup promise dropped"
  return waiter

private def awaitWaiter (waiter : Task (Except IO.Error Unit)) : IO (Except IO.Error Unit) := do
  let some result ← Beam.waitTaskWithTimeout waiter 2000
    | throw <| IO.userError "interrupt waiter survived watcher teardown"
  return result

private def requireReleased (waiter : Task (Except IO.Error Unit)) : IO Unit := do
  match ← awaitWaiter waiter with
  | .error (.userError "interrupt watcher promise dropped") => pure ()
  | .error err => throw err
  | .ok () => throw <| IO.userError "teardown delivered a signal that was never sent"

private def checkReturn : IO Unit := do
  let waiter ← Beam.Cli.withRequestInterruptWatcher startWaiter
  requireReleased waiter

private def checkThrow : IO Unit := do
  let savedWaiter ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
  let failed ← try
    Beam.Cli.withOwnerInterruptWatcher fun watcher => do
      savedWaiter.set (some (← startWaiter watcher))
      throw <| IO.userError "intentional watcher action failure"
    pure false
  catch
    | .userError "intentional watcher action failure" => pure true
    | err => throw err
  require "watcher swallowed the action failure" failed
  let some waiter ← savedWaiter.get
    | throw <| IO.userError "failed action did not start its waiter"
  requireReleased waiter

private def sendSignal (name : String) : IO Unit := do
  let result ← IO.Process.output {
    cmd := "kill"
    args := #["-" ++ name, toString (← IO.Process.getPID)]
  }
  require s!"cannot send {name}: {result.stderr}" (result.exitCode == 0)

private def checkDelivery (name : String) : IO Unit :=
  Beam.Cli.withOwnerInterruptWatcher fun watcher => do
    let waiter ← startWaiter watcher
    sendSignal name
    IO.ofExcept (← awaitWaiter waiter)
    require s!"delivered {name} not visible to polling" (← watcher.interrupted)
    -- Waiting again observes the same latched stop, without requiring another signal.
    watcher.awaitInterrupt
    require s!"completed waiter lost the owner's {name} stop" (← watcher.interrupted)

-- The parent sends repeated signals while this scope remains open, then kills the fixture.
-- Keeping teardown separate prevents a delayed test signal from racing restored default behavior.
private def holdOwnerScope : IO Unit :=
  Beam.Cli.withOwnerInterruptWatcher fun watcher => do
    IO.println "owner watcher ready"
    (← IO.getStdout).flush
    watcher.awaitInterrupt
    IO.println "owner stop latched"
    (← IO.getStdout).flush
    while true do IO.sleep 50

-- Resolve behind an explicit gate so cancellation is latched before acquisition returns.
-- The task owns the real daemon; join it before asserting or disposing of its control directory.
private def cancelledOwnerAcquisition : IO UInt32 := IO.FS.withTempDir fun temporary => do
  let root ← IO.currentDir
  let suffix := if System.Platform.isWindows then ".exe" else ""
  let runtime : Beam.Runtime.Description := {
    command := "lean", plugin := ← BeamTest.TestHarness.pluginPath
    daemonBin := root / ".lake/build/bin" / ("beam-daemon-fixture" ++ suffix)
    toolchain := "library fixture", identity := ⟨root, "library fixture"⟩
  }
  let control := temporary / "session"
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let stopped ← IO.mkRef false
  let ready ← IO.mkRef false
  let retained ← IO.mkRef (none : Option Beam.Cli.ProjectDaemonOwner)
  let watcher : Beam.Cli.InterruptWatcher := {
    interrupted := stopped.get, awaitInterrupt := pure ()
  }
  let task ← IO.asTask (prio := .dedicated) <|
    (Beam.Cli.withProjectDaemonOwner (fun _ => do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| Beam.Cli.CliFailure.internal (IO.userError "owner acquisition gate dropped")
      pure { root, runtime }) root (some control) fun owner => do
        retained.set (some owner)
        Beam.Cli.ensureProjectSession watcher root owner.client
        ready.set true
        IO.println "unexpected readiness").run
  let outcome ← try
      let some (some _) ← Beam.waitTaskWithTimeout entered.result? 2000
        | throw <| IO.userError "owner acquisition did not reach its gate"
      stopped.set true
      release.resolve ()
      IO.wait task
    finally
      stopped.set true
      release.resolve ()
      discard <| IO.wait task
  require "cancelled acquisition published readiness" (!(← ready.get))
  let some owner ← retained.get
    | throw <| IO.userError "acquisition did not hand off an owned daemon"
  require "cancelled acquisition did not reap its daemon" ((← owner.exitCode?) == some 0)
  match ← Beam.Daemon.readRegistryAt (control / "beam-daemon.json") with
  | .absent => pure ()
  | _ => throw <| IO.userError "cancelled acquisition left a session descriptor"
  match outcome with
  | .ok (.error failure) => Beam.Cli.run (throw failure)
  | .ok (.ok ()) => throw <| IO.userError "cancelled acquisition succeeded"
  | .error error => throw error

/-- Run a child fixture: ordinary cases release their watchers; held scopes require parent cleanup. -/
def child (mode : String) : IO UInt32 := do
  if mode == "owner-acquisition" then return ← cancelledOwnerAcquisition
  match mode with
  | "return" => checkReturn
  | "throw-INT" | "throw-TERM" | "throw-HUP" => checkThrow
  | "signal-INT" => checkDelivery "INT"
  | "signal-TERM" => checkDelivery "TERM"
  | "signal-HUP" => checkDelivery "HUP"
  | "owner-held" => holdOwnerScope
  | _ => throw <| IO.userError s!"unknown interrupt watcher test mode: {mode}"
  Beam.Cli.withRequestInterruptWatcher fun watcher => do
    require "a later watcher inherited an earlier interrupt" (!(← watcher.interrupted))
  IO.println "watcher cleanup complete"
  (← IO.getStdout).flush
  unless System.Platform.isWindows do
    let name := if mode.endsWith "-TERM" then "TERM" else if mode.endsWith "-HUP" then "HUP" else "INT"
    sendSignal name
    throw <| IO.userError s!"watcher teardown did not restore default {name} behavior"
  pure 0

end BeamTest.Broker.InterruptWatcherTest
