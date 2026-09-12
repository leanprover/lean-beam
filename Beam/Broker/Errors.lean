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
  | .saveUnsupportedSetup => saveUnsupportedSetupCode
  | .saveTargetNotModule => saveTargetNotModuleCode
  | .internalError => "internalError"

instance : ToJson BrokerFailureCode where
  toJson code := toJson code.name

instance : FromJson BrokerFailureCode where
  fromJson?
    | .str "invalidParams" => pure .invalidParams
    | .str "requestCancelled" => pure .requestCancelled
    | .str "contentModified" => pure .contentModified
    | .str "workerExited" => pure .workerExited
    | .str "syncBarrierIncomplete" => pure .syncBarrierIncomplete
    | .str "saveTraceStale" => pure .saveTraceStale
    | .str "saveUnsupportedSetup" => pure .saveUnsupportedSetup
    | .str "saveTargetNotModule" => pure .saveTargetNotModule
    | .str "internalError" => pure .internalError
    | json => throw s!"expected Beam broker failure code, got {json.compress}"

structure BrokerFailure where
  code : BrokerFailureCode
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

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

end Beam.Broker
