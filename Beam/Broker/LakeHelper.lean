/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Errors
import Beam.ProcessJob
import Beam.System

open Lean

namespace Beam.Broker

structure LakeHelperEnvRequest where
  root : String
  deriving FromJson, ToJson

structure LeanServerLakeEnv where
  env : Array (String × Option String)
  moreServerArgs : Array String
  deriving FromJson, ToJson

structure LakeHelperSaveRequest where
  root : String
  path : String
  sourceHash : String
  sourceMTimeSec : Int
  sourceMTimeNsec : Nat
  deriving FromJson, ToJson

structure LakeHelperWriteTraceRequest where
  root : String
  oleanPath : String
  oleanServerPath? : Option String := none
  oleanPrivatePath? : Option String := none
  ileanPath : String
  irPath? : Option String := none
  irSigPath? : Option String := none
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

structure LakeHelperControl where
  cancelRef? : Option (IO.Ref Bool) := none
  timeoutMs : Nat := 30000

namespace LakeHelperJob

def requestPath (directory : System.FilePath) : System.FilePath := directory / "request.json"
def responsePath (directory : System.FilePath) : System.FilePath := directory / "response.json"

/-- Private one-shot messages have a size bound and never share project stdout. -/
def readJson (path : System.FilePath) : IO Json := do
  let metadata ← path.symlinkMetadata
  unless metadata.type == .file do
    throw <| IO.userError "target Lake helper message is not a regular file"
  if metadata.byteSize > 16 * 1024 * 1024 then
    throw <| IO.userError "target Lake helper message exceeds 16 MiB"
  IO.ofExcept <| Json.parse (← IO.FS.readFile path)

/-- Publishing this file commits a completed response; the owner still terminates/reaps the job. -/
def publish (directory : System.FilePath) (response : Response) : IO Unit := do
  let temporary := directory / "response.tmp"
  IO.FS.writeFile temporary (toJson response).compress
  IO.FS.rename temporary (responsePath directory)

end LakeHelperJob

private def helperStdio : IO.Process.StdioConfig := {
  stdin := .piped, stdout := .null, stderr := .null
}

private def helperCancelled (control : LakeHelperControl) : IO Bool := do
  match control.cancelRef? with
  | some ref => ref.get
  | none => pure false

private def cancelledHelper : BrokerFailure := {
  code := .requestCancelled, message := "target Lake helper request cancelled"
}

private def helperInterruption? (control : LakeHelperControl) (deadline : Nat) :
    IO (Option BrokerFailure) := do
  if ← helperCancelled control then return some cancelledHelper
  if (← IO.monoMsNow) >= deadline then
    return some {
      code := .internalError
      message := s!"target Lake helper timed out after {control.timeoutMs} ms"
    }
  pure none

private partial def awaitHelperResponse
    (child : IO.Process.Child helperStdio)
    (directory : System.FilePath)
    (control : LakeHelperControl)
    (deadline : Nat)
    (owned : IO.Ref Bool) : IO (Except BrokerFailure Response) := do
  if let some failure ← helperInterruption? control deadline then return .error failure
  let responsePath := LakeHelperJob.responsePath directory
  if ← responsePath.pathExists then
    let response ← IO.ofExcept <| fromJson? (← LakeHelperJob.readJson responsePath)
    if let some failure ← helperInterruption? control deadline then return .error failure
    return .ok response
  match ← Beam.ProcessJob.poll child with
  | .running =>
      IO.sleep 10
      awaitHelperResponse child directory control deadline owned
  | .exited =>
      pure <| .error {
        code := .workerExited, message := "target Lake helper exited before completing its response"
      }
  | .notChild =>
      -- Another reaper has invalidated ownership. Never signal a potentially recycled PID.
      owned.set false
      pure <| .error {
        code := .internalError, message := "target Lake helper child ownership was lost"
      }

/-- Execute one request against an already admitted helper, retaining ownership through reaping. -/
def runLakeHelperRequest [ToJson α] [FromJson β]
    (helper : System.FilePath)
    (operation : LakeHelperOperation)
    (request : α)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure β) := do
  let response ←
    try
      if ← helperCancelled control then return .error cancelledHelper
      let deadline := (← IO.monoMsNow) + control.timeoutMs
      IO.FS.withTempDir fun temporary => do
        let directory := temporary / "job"
        Beam.ensurePrivateDir "target Lake helper job directory" directory
        IO.FS.writeFile (LakeHelperJob.requestPath directory) (toJson request).compress
        let child ← IO.Process.spawn {
          toStdioConfig := helperStdio
          cmd := helper.toString
          args := #["lake-helper", operation.key, directory.toString]
          setsid := true
        }
        let owned ← IO.mkRef true
        Beam.ProcessJob.withChild child owned.get do
          if let some failure ← helperInterruption? control deadline then return .error failure
          -- The helper cannot evaluate project code until its Windows job is assigned.
          child.stdin.putStr "go\n"
          child.stdin.flush
          awaitHelperResponse child directory control deadline owned
    catch error =>
      return .error {
        code := .internalError
        message := s!"target Lake helper '{operation.key}' failed: {error}"
      }
  let response ← match response with
    | .error failure => return .error failure
    | .ok response => pure response
  match response with
  | .successResult result _ =>
      match fromJson? result with
      | .ok decoded => pure <| .ok decoded
      | .error err =>
          pure <| .error {
            code := .internalError
            message := s!"target Lake helper '{operation.key}' returned an invalid result: {err}"
          }
  | .errorResult failure =>
      let error := failure.error
      let some code := BrokerFailureCode.ofName? error.code
        | return .error {
            code := .internalError
            message :=
              s!"target Lake helper '{operation.key}' returned unknown error code '{error.code}'"
          }
      pure <| .error { code, message := error.message, data? := error.data? }

/-- Ask the target-built helper for the Lean server environment. -/
def runLakeHelperServerEnv
    (helper : System.FilePath)
    (request : LakeHelperEnvRequest)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanServerLakeEnv) :=
  runLakeHelperRequest helper .serverEnv request control

/-- Ask the target-built helper for an exact zero-build save specification. -/
def runLakeHelperPrepareSave
    (helper : System.FilePath)
    (request : LakeHelperSaveRequest)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LakeHelperSaveSpec) :=
  runLakeHelperRequest helper .prepareSave request control

/-- Ask the target-built helper to publish one save trace. -/
def runLakeHelperWriteSaveTrace
    (helper : System.FilePath)
    (request : LakeHelperWriteTraceRequest)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LakeHelperAck) :=
  runLakeHelperRequest helper .writeSaveTrace request control

end Beam.Broker
