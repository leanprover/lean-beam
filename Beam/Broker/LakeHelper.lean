/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Errors
import Beam.ProcessJob
import Beam.System
import Beam.WorkspaceOutput

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

/-- Output paths shared across local Lake preparation and serialized helper messages. -/
structure LeanSaveOutputs where
  oleanPath : System.FilePath
  oleanServerPath? : Option System.FilePath := none
  oleanPrivatePath? : Option System.FilePath := none
  ileanPath : System.FilePath
  irPath? : Option System.FilePath := none
  irSigPath? : Option System.FilePath := none
  cPath : System.FilePath
  bcPath? : Option System.FilePath := none
  tracePath : System.FilePath
  deriving BEq, FromJson, ToJson

structure LakeHelperWriteTraceRequest extends LeanSaveOutputs where
  root : System.FilePath
  traceMetadata : Json
  deriving FromJson, ToJson

structure LakeHelperSaveSpec extends LakeHelperWriteTraceRequest where
  moduleName : String
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

/-- Lake loading follows its request owner; trace publication retains a bounded response wait. -/
inductive LakeHelperWaitPolicy where
  | cancellable
  | timeout (milliseconds : Nat)
  deriving BEq, Repr

def LakeHelperOperation.waitPolicy : LakeHelperOperation → LakeHelperWaitPolicy
  | .serverEnv | .prepareSave => .cancellable
  | .writeSaveTrace => .timeout 30000

structure LakeHelperControl where
  cancelRef? : Option (IO.Ref Bool) := none
  /-- A capability borrowed for this helper, retired when the helper scope ends. -/
  output? : Option Beam.WorkspaceOutput.Publisher := none

private structure HelperDeadline where
  timeoutMs : Nat
  expiresAtMs : Nat

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
  stdin := .piped, stdout := .piped, stderr := .piped
}

private def helperCancelled (control : LakeHelperControl) : IO Bool := do
  match control.cancelRef? with
  | some ref => ref.get
  | none => pure false

private def cancelledHelper : BrokerFailure := {
  code := .requestCancelled, message := "target Lake helper request cancelled"
}

private def helperInterruption? (control : LakeHelperControl) (deadline? : Option HelperDeadline) :
    IO (Option BrokerFailure) := do
  if ← helperCancelled control then return some cancelledHelper
  if let some deadline := deadline? then
    if (← IO.monoMsNow) >= deadline.expiresAtMs then
      return some {
        code := .internalError
        message := s!"target Lake helper timed out after {deadline.timeoutMs} ms"
      }
  pure none

private partial def awaitHelperResponse
    (scope : Beam.ProcessJob.Scope)
    (directory : System.FilePath)
    (control : LakeHelperControl)
    (deadline? : Option HelperDeadline) : IO (Except BrokerFailure Response) := do
  if let some failure ← helperInterruption? control deadline? then return .error failure
  let responsePath := LakeHelperJob.responsePath directory
  if ← responsePath.pathExists then
    let response ← IO.ofExcept <| fromJson? (← LakeHelperJob.readJson responsePath)
    if let some failure ← helperInterruption? control deadline? then return .error failure
    return .ok response
  match ← scope.poll with
  | .running =>
      IO.sleep 10
      awaitHelperResponse scope directory control deadline?
  | .exited =>
      pure <| .error {
        code := .workerExited, message := "target Lake helper exited before completing its response"
      }
  | .notChild =>
      pure <| .error {
        code := .internalError, message := "target Lake helper child ownership was lost"
      }

namespace LakeHelperJob

/-- Internal owned-job primitive. Explicit wait policies support bounded fixture requests;
production callers use the typed operation wrappers below. -/
def runRequest [ToJson α] [FromJson β]
    (helper : System.FilePath)
    (operation : LakeHelperOperation)
    (request : α)
    (waitPolicy : LakeHelperWaitPolicy)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure β) := do
  let publisher ← match control.output? with
    | some publisher => pure publisher
    | none => do
        let buffer ← Beam.WorkspaceOutput.Buffer.create
        let some publisher ← buffer.borrow
          | throw <| IO.userError "new helper output buffer was already closed"
        pure publisher
  let capture ← IO.mkRef (none : Option Beam.WorkspaceOutput.Capture)
  let operationResponse ← IO.mkRef (none : Option Response)
  let response ←
    try
      if ← helperCancelled control then return .error cancelledHelper
      let deadline? : Option HelperDeadline ← match waitPolicy with
        | .cancellable => pure none
        | .timeout milliseconds => pure <| some {
            timeoutMs := milliseconds
            expiresAtMs := (← IO.monoMsNow) + milliseconds
          }
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
        Beam.ProcessJob.withChild child fun scope => do
          -- Establish both drains before allowing configuration code to write either pipe.
          capture.set (some (← Beam.WorkspaceOutput.Capture.start child.stdout child.stderr publisher))
          if let some failure ← helperInterruption? control deadline? then return .error failure
          -- The helper cannot evaluate project code until its Windows job is assigned.
          child.stdin.putStr "go\n"
          child.stdin.flush
          let response ← awaitHelperResponse scope directory control deadline?
          if let .ok completed := response then operationResponse.set (some completed)
          return response
    catch error =>
      return .error {
        code := .internalError
        message := s!"target Lake helper '{operation.key}' failed: {error}"
        -- Publication may already have committed. Preserve the typed operation receipt
        -- when later process-job or temporary-directory cleanup fails.
        data? := (← operationResponse.get).map fun response =>
          Json.mkObj [("operationResponse", toJson response)]
      }
    finally
      try
        if let some capture ← capture.get then discard <| capture.finish
      finally
        publisher.retire
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

end LakeHelperJob

private def runLakeHelperRequest [ToJson α] [FromJson β]
    (helper : System.FilePath)
    (operation : LakeHelperOperation)
    (request : α)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure β) :=
  LakeHelperJob.runRequest helper operation request operation.waitPolicy control

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
