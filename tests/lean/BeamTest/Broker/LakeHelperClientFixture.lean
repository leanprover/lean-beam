/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeHelper

open Lean Beam.Broker

private def awaitExited (scope : Beam.ProcessJob.Scope) : IO Unit := do
  let deadline := (← IO.monoMsNow) + 5000
  repeat
    match ← scope.poll with
    | .exited => return
    | .notChild => throw <| IO.userError "fixture lost its unreaped child"
    | .running =>
        if (← IO.monoMsNow) >= deadline then
          throw <| IO.userError "fixture child did not exit"
        IO.sleep 10

/-- Keep an exited session leader unreaped: its remaining group may contain only zombies. -/
private def checkExitedGroups : IO Unit := do
  for _ in [:16] do
    let child ← IO.Process.spawn {
      cmd := (← IO.appPath).toString
      args := #["--process-job-exit"]
      stdin := .piped, stdout := .null, stderr := .null
      setsid := true
    }
    let scope ← Beam.ProcessJob.withChild child fun scope => do
      child.stdin.putStr "exit\n"
      child.stdin.flush
      awaitExited scope
      for _ in [:2] do
        unless (← scope.poll) == .exited do
          throw <| IO.userError "exit observation consumed the retained child identity"
      return scope
    -- An escaped observation cannot touch the old PID after scope teardown.
    let rejected ← try scope.poll *> pure false catch _ => pure true
    unless rejected do throw <| IO.userError "closed process scope still allowed observation"
  if !System.Platform.isWindows then
    let child ← IO.Process.spawn {
      cmd := (← IO.appPath).toString, args := #["--process-job-exit"]
      stdin := .piped, stdout := .null, stderr := .null, setsid := true
    }
    Beam.ProcessJob.withChild child fun scope => do
      child.stdin.putStr "exit\n"
      child.stdin.flush
      awaitExited scope
      discard <| child.wait -- Deliberately simulate an external reaper in this fixture only.
      for _ in [:2] do
        unless (← scope.poll) == .notChild do
          throw <| IO.userError "lost ownership was not retained by the process scope"
  let child ← IO.Process.spawn {
    cmd := (← IO.appPath).toString, args := #["--process-job-exit"]
    stdin := .piped, stdout := .null, stderr := .null, setsid := true
  }
  -- This child waits for permission forever unless exceptional teardown kills and waits for it.
  let failed ← try
    Beam.ProcessJob.withChild child fun _ => (throw <| IO.userError "fixture action failed" : IO Unit)
    pure false
  catch error =>
    unless error.toString.contains "fixture action failed" do throw error
    pure true
  unless failed do throw <| IO.userError "process scope lost its action failure"
  IO.println "process scopes: retained exit, lost ownership, and closed observation passed"

private def runHelper (args : List String) : IO Unit := do
  let helper :: operation :: options := args
    | throw <| IO.userError "expected HELPER OPERATION [TIMEOUT-MS [CANCEL-FILE]]"
  let some operation := LakeHelperOperation.ofString? operation
    | throw <| IO.userError "invalid fixture operation"
  let request ← IO.ofExcept <| Json.parse (← (← IO.getStdin).readToEnd)
  let timeoutMs ← match options.head? with
    | none => pure 30000
    | some value => match value.toNat? with
      | some timeout => pure timeout
      | none => throw <| IO.userError "invalid fixture timeout"
  let cancelled ← IO.mkRef false
  let done ← IO.mkRef false
  let watcher? ← (options[1]?).mapM fun path =>
    IO.asTask (prio := Task.Priority.dedicated) do
      repeat
        if ← done.get then break
        if ← (System.FilePath.mk path).pathExists then
          cancelled.set true
          break
        IO.sleep 10
  let result : Except BrokerFailure Json ← try
    runLakeHelperRequest helper operation request { cancelRef? := some cancelled, timeoutMs }
  finally
    done.set true
    if let some watcher := watcher? then discard <| IO.wait watcher
  let response := match result with
    | .ok value => Response.success value
    | .error failure => failure.toResponse
  IO.println (toJson response).compress

/-- Non-shipped client for exercising owned helper messages and retained-child cleanup. -/
def main (args : List String) : IO Unit := do
  match args with
  | ["--process-job-exit"] => do
      unless (← (← IO.getStdin).getLine).trimAscii == "exit" do
        throw <| IO.userError "fixture expected exit permission after job assignment"
  | ["--process-job-exited-groups"] => checkExitedGroups
  | _ => runHelper args
