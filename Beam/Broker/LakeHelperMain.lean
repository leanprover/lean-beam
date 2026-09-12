/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeEnv
import Beam.Broker.LakeSave

open Lean

namespace Beam.Broker.LakeHelperMain

private def readRequest [FromJson α] : IO α := do
  let input ← (← IO.getStdin).readToEnd
  let json ← IO.ofExcept <| Json.parse input
  IO.ofExcept <| fromJson? json

private def writeResponse [ToJson α] (response : Except BrokerFailure α) : IO Unit := do
  IO.println (LakeHelperResponse.encode response).compress

private def writeFailure (failure : BrokerFailure) : IO Unit :=
  writeResponse (α := Json) <| .error failure

private def runServerEnv : IO Unit := do
  let request : LakeHelperEnvRequest ← readRequest
  let serverEnv ← leanServerLakeEnv
    (System.FilePath.mk request.root) (some request.leanCmd)
  writeResponse <| .ok serverEnv

private def runPrepareSave : IO Unit := do
  let request : LakeHelperSaveRequest ← readRequest
  match ← lakeHelperSaveSpec request with
  | .ok spec => writeResponse <| .ok spec
  | .error failure => writeFailure failure

private def runWriteSaveTrace : IO Unit := do
  let request : LakeHelperWriteTraceRequest ← readRequest
  lakeHelperWriteLeanSaveTrace request
  writeResponse <| .ok ({} : LakeHelperAck)

def main (args : List String) : IO Unit := do
  try
    match args with
    | [operation] =>
        match LakeHelperOperation.ofString? operation with
        | some .serverEnv => runServerEnv
        | some .prepareSave => runPrepareSave
        | some .writeSaveTrace => runWriteSaveTrace
        | none => throw <| IO.userError "invalid target Lake helper operation"
    | _ => throw <| IO.userError "invalid target Lake helper operation"
  catch error =>
    writeFailure {
      code := .internalError
      message := error.toString
    }

end Beam.Broker.LakeHelperMain
