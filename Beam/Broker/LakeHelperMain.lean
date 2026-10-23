/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeEnv
import Beam.Broker.LakeSave
import Beam.Runtime

open Lean

namespace Beam.Broker.LakeHelperMain

private def readRequest [FromJson α] (directory : System.FilePath) : IO α := do
  let json ← LakeHelperJob.readJson (LakeHelperJob.requestPath directory)
  for field in ["leanCmd", "leanPlugin", "beamCli"] do
    if (json.getObjVal? field).isOk then
      throw <| IO.userError "Lake helper components are fixed by its installation"
  IO.ofExcept <| fromJson? json

private def runServerEnv (resolve : System.FilePath → IO Beam.Runtime.Description)
    (directory : System.FilePath) : IO Response := do
  let request : LakeHelperEnvRequest ← readRequest directory
  let runtime ← resolve (System.FilePath.mk request.root)
  let serverEnv ← computeServerEnvironment (System.FilePath.mk request.root) runtime.command
  pure <| Response.success (toJson serverEnv)

private def runPrepareSave (resolve : System.FilePath → IO Beam.Runtime.Description)
    (directory : System.FilePath) : IO Response := do
  let request : LakeHelperSaveRequest ← readRequest directory
  let runtime ← resolve (System.FilePath.mk request.root)
  match ← lakeHelperSaveSpec request runtime.command with
  | .ok spec => pure <| Response.success (toJson spec)
  | .error failure => pure failure.toResponse

/-- Arm owner-loss handling before installation binding or arbitrary Lake configuration code. -/
def main (bind : IO (System.FilePath → IO Beam.Runtime.Description))
    (args : List String) : IO Unit := do
  let [operation, directory] := args
    | throw <| IO.userError "invalid target Lake helper invocation"
  let some operation := LakeHelperOperation.ofString? operation
    | throw <| IO.userError "invalid target Lake helper operation"
  let stdin ← IO.getStdin
  unless (← stdin.getLine).trimAscii == "go" do Beam.ProcessJob.parentLost
  let owner ← IO.asTask (prio := Task.Priority.dedicated) do
    try discard <| stdin.readToEnd finally Beam.ProcessJob.parentLost
  let directory := System.FilePath.mk directory
  let response ← try
    Beam.requirePrivateDir "target Lake helper job directory" directory
      (← Beam.observePrivateDir directory)
    let resolve ← bind
    match operation with
    | .serverEnv => runServerEnv resolve directory
    | .prepareSave => runPrepareSave resolve directory
  catch error => pure <| BrokerFailure.toResponse {
    code := .internalError, message := error.toString
  }
  LakeHelperJob.publish directory response
  -- Keep the unreaped leader alive after publication. Its owner terminates the whole job
  -- before reaping, including descendants that retained unrelated descriptors.
  discard <| IO.wait owner

end Beam.Broker.LakeHelperMain
