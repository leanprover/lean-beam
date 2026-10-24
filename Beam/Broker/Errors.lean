/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol

open Lean

namespace Beam.Broker

inductive BrokerFailureCode where
  | invalidParams
  | requestCancelled
  | contentModified
  | workerExited
  | syncBarrierIncomplete
  | saveTraceStale
  | saveImportsChanged
  | saveUnsupportedSetup
  | saveTargetNotModule
  | internalError
  deriving Inhabited, BEq, Repr

def BrokerFailureCode.name : BrokerFailureCode → String
  | .invalidParams => "invalidParams"
  | .requestCancelled => "requestCancelled"
  | .contentModified => "contentModified"
  | .workerExited => "workerExited"
  | .syncBarrierIncomplete => syncBarrierIncompleteCode
  | .saveTraceStale => saveTraceStaleCode
  | .saveImportsChanged => saveImportsChangedCode
  | .saveUnsupportedSetup => saveUnsupportedSetupCode
  | .saveTargetNotModule => saveTargetNotModuleCode
  | .internalError => "internalError"

def BrokerFailureCode.all : Array BrokerFailureCode := #[
  .invalidParams,
  .requestCancelled,
  .contentModified,
  .workerExited,
  .syncBarrierIncomplete,
  .saveTraceStale,
  .saveImportsChanged,
  .saveUnsupportedSetup,
  .saveTargetNotModule,
  .internalError
]

def BrokerFailureCode.ofName? (name : String) : Option BrokerFailureCode :=
  BrokerFailureCode.all.find? fun code => code.name == name

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited

def BrokerFailure.toResponseFailure (failure : BrokerFailure) : ResponseFailure :=
  {
    error := {
      code := failure.code.name
      message := failure.message
      data? := failure.data?
    }
  }

def BrokerFailure.toResponse (failure : BrokerFailure) : Response :=
  failure.toResponseFailure.toResponse

def responseFailureFor
    (code : BrokerFailureCode)
    (message : String := "")
    (data? : Option Json := none) : ResponseFailure :=
  ({ code, message, data? } : BrokerFailure).toResponseFailure

def errorResponseFor
    (code : BrokerFailureCode)
    (message : String := "")
    (data? : Option Json := none) : Response :=
  (responseFailureFor code message data?).toResponse

/-- Recovery supported by the boundary that observed a worker failure. It never replays work. -/
inductive WorkerRecovery where
  | newHelper
  | newBackend
  | restartWorkspace
  | sync (uri : String)
  deriving BEq, Repr

instance : ToJson WorkerRecovery where
  toJson
    | .newHelper => Json.mkObj [("kind", toJson "newHelper")]
    | .newBackend => Json.mkObj [("kind", toJson "newBackend")]
    | .restartWorkspace => Json.mkObj [("kind", toJson "restartWorkspace")]
    | .sync uri => Json.mkObj [("kind", toJson "sync"), ("uri", toJson uri)]

instance : FromJson WorkerRecovery where
  fromJson? json := do
    match ← json.getObjValAs? String "kind" with
    | "newHelper" => pure .newHelper
    | "newBackend" => pure .newBackend
    | "restartWorkspace" => pure .restartWorkspace
    | "sync" => .sync <$> json.getObjValAs? String "uri"
    | kind => throw s!"unknown worker recovery '{kind}'"

def workerRecoveryData (recovery : WorkerRecovery) (originalData? : Option Json := none) : Json :=
  Json.mkObj <| [("recovery", toJson recovery)] ++
    originalData?.toList.map (fun data => ("originalData", data))

def ResponseFailure.withWorkerRecovery (failure : ResponseFailure)
    (recovery : WorkerRecovery) : ResponseFailure :=
  { failure with error.data? := some <| workerRecoveryData recovery failure.error.data? }

def documentVersionMismatchErrorData
    (expectedVersion acceptedVersion : Nat)
    (currentVersion? : Option Nat := none)
    (uri? : Option String := none) : Json :=
  Json.mkObj <|
    [
      ("reason", toJson "documentVersionMismatch"),
      ("expectedVersion", toJson expectedVersion),
      ("acceptedVersion", toJson acceptedVersion)
    ] ++
    (match currentVersion? with
    | some currentVersion => [("currentVersion", toJson currentVersion)]
    | none => []) ++
    (match uri? with
    | some uri => [("uri", toJson uri)]
    | none => [])

def errorCodeName : JsonRpc.ErrorCode → String
  | .parseError => "parseError"
  | .invalidRequest => "invalidRequest"
  | .methodNotFound => "methodNotFound"
  | .invalidParams => "invalidParams"
  | .internalError => "internalError"
  | .serverNotInitialized => "serverNotInitialized"
  | .unknownErrorCode => "unknownErrorCode"
  | .contentModified => "contentModified"
  | .requestCancelled => "requestCancelled"
  | .rpcNeedsReconnect => "rpcNeedsReconnect"
  | .workerExited => "workerExited"
  | .workerCrashed => "workerCrashed"

/-- Preserve a typed error received from an underlying JSON-RPC backend. -/
def backendResponseFailure
    (code : JsonRpc.ErrorCode)
    (message : String := "")
    (data? : Option Json := none) : ResponseFailure :=
  { error := { code := errorCodeName code, message, data? } }

/-- Attach file-specific recovery only to explicit typed file-worker failures. -/
def fileWorkerResponseFailure
    (code : JsonRpc.ErrorCode)
    (message : String)
    (uri? : Option String)
    (data? : Option Json := none) : ResponseFailure :=
  let failure := backendResponseFailure code message data?
  match code, uri? with
  | .workerExited, some uri | .workerCrashed, some uri =>
      failure.withWorkerRecovery (.sync uri)
  | _, _ => failure

end Beam.Broker
