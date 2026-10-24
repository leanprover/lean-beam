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

/-- Prepared target metadata and output paths; the broker owns trace finalization. -/
structure LeanSaveSpec extends LeanSaveOutputs where
  moduleName : String
  traceMetadata : Json
  deriving FromJson, ToJson

namespace LakeHelperResponse

/-- Encode at the private file boundary; helper execution keeps failures typed. -/
def encode [ToJson α] : Except BrokerFailure α → Json
  | .ok result => Json.mkObj [("ok", toJson true), ("result", toJson result)]
  | .error failure => Json.mkObj [("ok", toJson false), ("error", toJson failure)]

/-- Accept exactly one success or failure envelope, including field presence with null values. -/
def decode [FromJson α] (json : Json) : Except String (Except BrokerFailure α) := do
  Beam.requireOnlyJsonFields "target Lake helper response" #["ok", "result", "error"] json
  if ← json.getObjValAs? Bool "ok" then
    if (json.getObjVal? "error").isOk then
      throw "target Lake helper response with ok=true must not include 'error'"
    pure <| .ok (← Beam.requiredField (α := α) json "result")
  else
    if (json.getObjVal? "result").isOk then
      throw "target Lake helper response with ok=false must not include 'result'"
    pure <| .error (← Beam.requiredField (α := BrokerFailure) json "error")

end LakeHelperResponse

inductive LakeHelperOperation where
  | serverEnv
  | prepareSave
  deriving BEq, Repr

def LakeHelperOperation.key : LakeHelperOperation → String
  | .serverEnv => "server-env"
  | .prepareSave => "prepare-save"

def LakeHelperOperation.ofString? : String → Option LakeHelperOperation
  | "server-env" => some .serverEnv
  | "prepare-save" => some .prepareSave
  | _ => none

structure LakeHelperControl where
  cancelRef? : Option (IO.Ref Bool) := none
  /-- A capability borrowed for this helper, retired when the helper scope ends. -/
  output? : Option Beam.WorkspaceOutput.Publisher := none

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
def publish [ToJson α] (directory : System.FilePath) (response : Except BrokerFailure α) : IO Unit := do
  let temporary := directory / "response.tmp"
  IO.FS.writeFile temporary (LakeHelperResponse.encode response).compress
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

private partial def awaitHelperResponse [FromJson α]
    (scope : Beam.ProcessJob.Scope)
    (directory : System.FilePath)
    (control : LakeHelperControl)
    (observedResponse : IO.Ref (Option Json)) : IO (Except BrokerFailure α) := do
  if ← helperCancelled control then return .error cancelledHelper
  let responsePath := LakeHelperJob.responsePath directory
  if ← responsePath.pathExists then
    let response ← LakeHelperJob.readJson responsePath
    -- Diagnostic evidence is independent of decoding, cancellation, and cleanup outcomes.
    observedResponse.set (some response)
    let decoded := LakeHelperResponse.decode response
    if ← helperCancelled control then return .error cancelledHelper
    return ← IO.ofExcept decoded
  match ← scope.poll with
  | .running =>
      IO.sleep 10
      awaitHelperResponse scope directory control observedResponse
  | .exited =>
      pure <| .error {
        code := .workerExited, message := "target Lake helper exited before completing its response"
        data? := some <| workerRecoveryData .newHelper
      }
  | .notChild =>
      pure <| .error {
        code := .internalError, message := "target Lake helper child ownership was lost"
      }

namespace LakeHelperJob

/-- A typed operation receipt survives every owned cleanup phase. -/
structure Completion (α : Type) where
  operation : Except IO.Error (Except BrokerFailure α)
  jobCleanup : Except IO.Error Unit
  directoryCleanup : Except IO.Error Unit
  outputCleanup : Except IO.Error Unit := .ok ()
  /-- Raw observed JSON is diagnostic evidence only, never an accepted operation result. -/
  observedResponse? : Option Json := none

namespace Internal

/-- Capture directory removal after the job outcome, including setup failure before spawning.
The concrete finalizer argument allows deterministic failure tests without permission races. -/
def complete (action : IO (Beam.ProcessJob.Completion (Except BrokerFailure α)))
    (removeDirectory : IO Unit) : BaseIO (Completion α) := do
  let (operation, jobCleanup) ← match ← action.toBaseIO with
    | .ok job => pure (job.operation, job.cleanup)
    | .error error => pure (.error error, .ok ())
  let directoryCleanup ← removeDirectory.toBaseIO
  return { operation, jobCleanup, directoryCleanup }

/-- Render only after every owned cleanup attempt. A cleanup error is an overall failure even
when the operation succeeded; its receipt does not imply rollback or that retry is safe. -/
def projectCompletion (operation : LakeHelperOperation)
    (completion : Completion α) : Except BrokerFailure α := Id.run do
  let result : Except BrokerFailure α := match completion.operation with
    | .error error => .error {
        code := .internalError
        message := s!"target Lake helper '{operation.key}' failed: {error}"
      }
    | .ok result => result
  let cleanupFields :=
    (match completion.jobCleanup with
    | .ok () => []
    | .error error => [("processJob", toJson error.toString)]) ++
    (match completion.directoryCleanup with
    | .ok () => []
    | .error error => [("temporaryDirectory", toJson error.toString)]) ++
    (match completion.outputCleanup with
    | .ok () => []
    | .error error => [("outputCapture", toJson error.toString)])
  if cleanupFields.isEmpty then return result
  let operationOutcome := match result with
    | .ok _ => Json.mkObj [("status", toJson "succeeded")]
    | .error failure => Json.mkObj [
        ("status", toJson "failed"), ("error", toJson failure)]
  let responseFields := match completion.observedResponse? with
    | some response => [("operationResponse", response)]
    | none => []
  return .error {
    code := .internalError
    message := s!"target Lake helper '{operation.key}' cleanup failed; its operation outcome is recorded separately"
    data? := some <| Json.mkObj <|
      [("reason", toJson "helperCleanupFailed"),
       ("operation", toJson operation.key),
       ("operationOutcome", operationOutcome),
       ("cleanup", Json.mkObj cleanupFields)] ++ responseFields
  }

end Internal

/-- Internal owned-job primitive; production callers use the typed operation wrappers below. -/
def runRequest [ToJson α] [FromJson β]
    (helper : System.FilePath)
    (operation : LakeHelperOperation)
    (request : α)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure β) := do
  let publisher ← match control.output? with
    | some publisher => pure publisher
    | none => do
        let buffer ← Beam.WorkspaceOutput.Buffer.create
        let some publisher ← buffer.borrow
          | throw <| IO.userError "new helper output buffer was already closed"
        pure publisher
  let capture ← IO.mkRef (none : Option Beam.WorkspaceOutput.Capture)
  let observedResponse ← IO.mkRef (none : Option Json)
  let completion : Completion β ← try
      if ← helperCancelled control then
        pure { operation := .ok (.error cancelledHelper), jobCleanup := .ok (), directoryCleanup := .ok () }
      else
        let temporary ← IO.FS.createTempDir
        Internal.complete (do
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
            if ← helperCancelled control then return .error cancelledHelper
            -- The helper cannot evaluate project code until its Windows job is assigned.
            child.stdin.putStr "go\n"
            child.stdin.flush
            awaitHelperResponse scope directory control observedResponse)
          (IO.FS.removeDirAll temporary)
    catch error => pure {
      operation := .error error, jobCleanup := .ok (), directoryCleanup := .ok () }
  -- Pipe capture settles only after the process job; its failure cannot replace that receipt.
  let outputCleanup ← (do
    try
      if let some capture ← capture.get then discard <| capture.finish
    finally
      publisher.retire).toBaseIO
  return Internal.projectCompletion operation { completion with
    outputCleanup, observedResponse? := ← observedResponse.get }

end LakeHelperJob

/-- Ask the target-built helper for the Lean server environment. -/
def runLakeHelperServerEnv
    (helper : System.FilePath)
    (request : LakeHelperEnvRequest)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanServerLakeEnv) :=
  LakeHelperJob.runRequest helper .serverEnv request control

/-- Ask the target-built helper for an exact zero-build save specification. -/
def runLakeHelperPrepareSave
    (helper : System.FilePath)
    (request : LakeHelperSaveRequest)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanSaveSpec) :=
  LakeHelperJob.runRequest helper .prepareSave request control

end Beam.Broker
