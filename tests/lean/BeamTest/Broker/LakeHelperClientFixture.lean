/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeHelper
import BeamTest.Broker.HelperOutcomeTest

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
    let completed ← Beam.ProcessJob.withChild child fun scope => do
      child.stdin.putStr "exit\n"
      child.stdin.flush
      awaitExited scope
      for _ in [:2] do
        unless (← scope.poll) == .exited do
          throw <| IO.userError "exit observation consumed the retained child identity"
      return scope
    discard <| IO.ofExcept completed.cleanup
    let scope ← IO.ofExcept completed.operation
    -- An escaped observation cannot touch the old PID after scope teardown.
    let rejected ← try scope.poll *> pure false catch _ => pure true
    unless rejected do throw <| IO.userError "closed process scope still allowed observation"
  if !System.Platform.isWindows then
    let child ← IO.Process.spawn {
      cmd := (← IO.appPath).toString, args := #["--process-job-exit"]
      stdin := .piped, stdout := .null, stderr := .null, setsid := true
    }
    let completed ← Beam.ProcessJob.withChild child fun scope => do
      child.stdin.putStr "exit\n"
      child.stdin.flush
      awaitExited scope
      discard <| child.wait -- Deliberately simulate an external reaper in this fixture only.
      for _ in [:2] do
        unless (← scope.poll) == .notChild do
          throw <| IO.userError "lost ownership was not retained by the process scope"
    discard <| IO.ofExcept completed.cleanup
    discard <| IO.ofExcept completed.operation
  let child ← IO.Process.spawn {
    cmd := (← IO.appPath).toString, args := #["--process-job-exit"]
    stdin := .piped, stdout := .null, stderr := .null, setsid := true
  }
  -- This child waits for permission forever unless exceptional teardown kills and waits for it.
  let completed ← Beam.ProcessJob.withChild child fun _ =>
    (throw <| IO.userError "fixture action failed" : IO Unit)
  discard <| IO.ofExcept completed.cleanup
  match completed.operation with
  | .error (.userError "fixture action failed") => pure ()
  | _ => throw <| IO.userError "process scope lost its action failure"
  IO.println "process scopes: retained exit, lost ownership, and closed observation passed"

private def runHelper (args : List String) : IO Unit := do
  let helper :: operation :: options := args
    | throw <| IO.userError "expected HELPER OPERATION [CANCEL-FILE]"
  let some operation := LakeHelperOperation.ofString? operation
    | throw <| IO.userError "invalid fixture operation"
  let request ← IO.ofExcept <| Json.parse (← (← IO.getStdin).readToEnd)
  let cancelled ← IO.mkRef false
  let output ← Beam.WorkspaceOutput.Buffer.create
  let some publisher ← output.borrow
    | throw <| IO.userError "new fixture output buffer was closed"
  let done ← IO.mkRef false
  let watcher? ← options.head?.mapM fun path =>
    IO.asTask (prio := Task.Priority.dedicated) do
      repeat
        if ← done.get then break
        if ← (System.FilePath.mk path).pathExists then
          cancelled.set true
          break
        IO.sleep 10
  let result : Except BrokerFailure Json ← try
    LakeHelperJob.runRequest helper operation request {
      cancelRef? := some cancelled, output? := some publisher }
  finally
    done.set true
    if let some watcher := watcher? then discard <| IO.wait watcher
  output.seal
  -- This fixture retains the bounded tail until completion; live pipe delivery is
  -- checked by the gated producer in the existing CLI daemon test executable.
  let stderr ← IO.getStderr
  while true do
    match ← output.poll with
    | .chunk chunk => stderr.putStr chunk.text
    | .closed => break
    | .waiting _ => throw <| IO.userError "sealed fixture output was still waiting"
  stderr.flush
  let response := match result with
    | .ok value => Response.success value
    | .error failure => failure.toResponse
  IO.println (toJson response).compress

/-- Exercise a real post-response temporary-directory cleanup failure without a production hook. -/
private def cleanupFaultHelper (directory : System.FilePath) : IO Unit := do
  let stdin ← IO.getStdin
  unless (← stdin.getLine).trimAscii == "go" do
    throw <| IO.userError "fixture helper expected assignment before project code"
  let owner ← IO.asTask (prio := Task.Priority.dedicated) do
    try discard <| stdin.readToEnd finally Beam.ProcessJob.parentLost
  let request ← LakeHelperJob.readJson (LakeHelperJob.requestPath directory)
  let response ← IO.ofExcept <| request.getObjValAs? Response "response"
  let marker ← IO.ofExcept <| request.getObjValAs? System.FilePath "marker"
  let receipt ← IO.ofExcept <| request.getObjValAs? System.FilePath "receipt"
  let obstacle := directory / "cleanup-denied"
  IO.FS.createDir obstacle
  IO.FS.writeFile (obstacle / "owned") "fixture-owned cleanup obstacle\n"
  IO.FS.writeFile receipt (Json.mkObj [
    ("directory", toJson obstacle), ("pid", toJson (← IO.Process.getPID).toNat)]).compress
  IO.setAccessRights obstacle {}
  IO.FS.writeFile marker "operation finished\n"
  LakeHelperJob.publish directory response
  -- The real client owns termination and reaping, including owner-loss handling.
  discard <| IO.wait owner

/-- Non-shipped client for exercising owned helper messages and retained-child cleanup. -/
def main (args : List String) : IO Unit := do
  match args with
  | ["lake-helper", "server-env", directory] => cleanupFaultHelper directory
  | ["--helper-outcomes"] => BeamTest.Broker.HelperOutcomeTest.run
  | ["--process-job-exit"] => do
      unless (← (← IO.getStdin).getLine).trimAscii == "exit" do
        throw <| IO.userError "fixture expected exit permission after job assignment"
  | ["--process-job-exited-groups"] => checkExitedGroups
  | _ => runHelper args
