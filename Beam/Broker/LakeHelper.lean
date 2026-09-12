/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Errors

open Lean

namespace Beam.Broker

structure LakeHelperEnvRequest where
  root : String
  leanCmd : String
  deriving FromJson, ToJson

structure LeanServerLakeEnv where
  env : Array (String × Option String)
  moreServerArgs : Array String
  deriving FromJson, ToJson

structure LakeHelperSaveRequest where
  root : String
  path : String
  leanCmd : String
  sourceHash : String
  sourceMTimeSec : Int
  sourceMTimeNsec : Nat
  deriving FromJson, ToJson

structure LakeHelperWriteTraceRequest where
  oleanPath : String
  oleanServerPath? : Option String := none
  oleanPrivatePath? : Option String := none
  ileanPath : String
  irPath? : Option String := none
  cPath : String
  bcPath? : Option String := none
  tracePath : String
  traceMetadata : Json
  deriving FromJson, ToJson

structure LakeHelperSaveSpec extends LakeHelperWriteTraceRequest where
  relPath : String
  moduleName : String
  unsupportedSetupReason? : Option String := none
  deriving FromJson, ToJson

structure LakeHelperAck where
  deriving FromJson, ToJson

private def requireOnlyResponseFields
    (allowed : Array String) : Json → Except String Unit
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"target Lake helper response accepts no undeclared fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"target Lake helper response must be an object, got {other.compress}"

namespace LakeHelperResponse

/-- Encode one typed result on the private target-built Lake helper boundary. -/
def encode [ToJson α] : Except BrokerFailure α → Json
  | .ok result => Json.mkObj [
        ("ok", toJson true),
        ("result", toJson result)
      ]
  | .error failure => Json.mkObj [
        ("ok", toJson false),
        ("error", toJson failure)
      ]

/-- Decode one typed result from the private target-built Lake helper boundary. -/
def decode [FromJson α] (json : Json) : Except String (Except BrokerFailure α) := do
  requireOnlyResponseFields #["ok", "result", "error"] json
  let ok ← json.getObjValAs? Bool "ok"
  if ok then
    if (json.getObjVal? "error").isOk then
      throw "target Lake helper response with ok=true must not include 'error'"
    pure <| .ok (← json.getObjValAs? α "result")
  else
    if (json.getObjVal? "result").isOk then
      throw "target Lake helper response with ok=false must not include 'result'"
    pure <| .error (← json.getObjValAs? BrokerFailure "error")

end LakeHelperResponse

inductive LakeHelperOperation where
  | serverEnv
  | prepareSave
  | writeSaveTrace
  deriving BEq, Repr

def LakeHelperOperation.key : LakeHelperOperation → String
  | .serverEnv => "server-env"
  | .prepareSave => "prepare-save"
  | .writeSaveTrace => "write-save-trace"

def LakeHelperOperation.ofString? : String → Option LakeHelperOperation
  | "server-env" => some .serverEnv
  | "prepare-save" => some .prepareSave
  | "write-save-trace" => some .writeSaveTrace
  | _ => none

private def helperOutputSummary (stdout stderr : String) : String :=
  let stderr := stderr.trimAscii.toString
  let stdout := stdout.trimAscii.toString
  if !stderr.isEmpty then stderr else if !stdout.isEmpty then stdout else "(no output)"

private def runLakeHelperRequest [ToJson α] [FromJson β]
    (helper : System.FilePath)
    (operation : LakeHelperOperation)
    (request : α) : IO (Except BrokerFailure β) := do
  let out ←
    try
      IO.Process.output {
        cmd := helper.toString
        args := #["lake-helper", operation.key]
      } (some (toJson request).compress)
    catch error =>
      return .error {
        code := .internalError
        message := s!"could not start target Lake helper '{operation.key}': {error}"
      }
  if out.exitCode != 0 then
    return .error {
      code := .internalError
      message :=
        s!"target Lake helper '{operation.key}' exited with code {out.exitCode}: " ++
          helperOutputSummary out.stdout out.stderr
    }
  let response ←
    match Json.parse out.stdout >>= LakeHelperResponse.decode (α := β) with
    | .ok response => pure response
    | .error err =>
        return .error {
          code := .internalError
          message :=
            s!"target Lake helper '{operation.key}' returned an invalid response: {err}: " ++
              helperOutputSummary out.stdout out.stderr
        }
  pure response

/-- Ask the target-built helper for the Lean server environment. -/
def runLakeHelperServerEnv
    (helper : System.FilePath)
    (request : LakeHelperEnvRequest) : IO (Except BrokerFailure LeanServerLakeEnv) :=
  runLakeHelperRequest helper .serverEnv request

/-- Ask the target-built helper for an exact zero-build save specification. -/
def runLakeHelperPrepareSave
    (helper : System.FilePath)
    (request : LakeHelperSaveRequest) : IO (Except BrokerFailure LakeHelperSaveSpec) :=
  runLakeHelperRequest helper .prepareSave request

/-- Ask the target-built helper to publish one save trace. -/
def runLakeHelperWriteSaveTrace
    (helper : System.FilePath)
    (request : LakeHelperWriteTraceRequest) : IO (Except BrokerFailure LakeHelperAck) :=
  runLakeHelperRequest helper .writeSaveTrace request

end Beam.Broker
