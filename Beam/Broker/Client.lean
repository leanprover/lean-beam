/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Broker.Transport
import Beam.WorkspaceOutput

open Lean

namespace Beam.Broker

structure StreamCallbacks where
  /-- Borrowed bounded destination; receiving text never waits for presentation. -/
  output? : Option Beam.WorkspaceOutput.Publisher := none
  onFileProgress : SyncFileProgress → IO Unit := fun _ => pure ()
  onDiagnostic : StreamDiagnostic → IO Unit := fun _ => pure ()

abbrev Endpoint := Transport.Endpoint

/-- Which server protocol must be observed before a request may be disclosed. -/
inductive ServerExpectation where
  /-- Internal standalone brokers do not emit a wrapper-generation greeting. -/
  | standalone
  /-- Wrapper brokers must prove the descriptor-selected generation on this connection. -/
  | wrapper (identity : DaemonIdentity)
  deriving Repr, BEq

/-- The transport operation that produced a typed broker client failure. -/
inductive BrokerTransportOperation where
  | connect
  | send
  | receive
  deriving Repr, BEq

private def BrokerTransportOperation.label : BrokerTransportOperation → String
  | .connect => "connect"
  | .send => "send"
  | .receive => "receive"

/-- Keep broker client failures typed until a CLI or transport presentation boundary. -/
inductive BrokerClientFailure where
  | transport (operation : BrokerTransportOperation) (error : IO.Error)
  | invalidResponse (detail : String)
  | streamCallback (error : IO.Error)
  | requestTimeout (timeoutMs : Nat)
  | interrupted

def BrokerClientFailure.detail : BrokerClientFailure → String
  | .transport operation error =>
      s!"Beam daemon {operation.label} failed: {error}"
  | .streamCallback error => error.toString
  | .invalidResponse detail => detail
  | .requestTimeout timeoutMs =>
      s!"Beam daemon request timed out after {timeoutMs} ms"
  | .interrupted => "Beam request interrupted"

instance : Repr BrokerClientFailure where
  reprPrec failure _ := Std.Format.text <|
    match failure with
    | .transport operation error => s!"BrokerClientFailure.transport {repr operation} {error}"
    | .invalidResponse detail => s!"BrokerClientFailure.invalidResponse {detail}"
    | .streamCallback error => s!"BrokerClientFailure.streamCallback {error}"
    | .requestTimeout timeoutMs => s!"BrokerClientFailure.requestTimeout {timeoutMs}"
    | .interrupted => "BrokerClientFailure.interrupted"

private def decodeStreamMessage (msg : String) : Except String StreamMessage := do
  match Json.parse msg with
  | .error err => throw s!"invalid Beam daemon response json: {err}"
  | .ok json =>
      match fromJson? (α := StreamMessage) json with
      | .ok stream => pure stream
      | .error err => throw s!"invalid Beam daemon response payload: {err}"

private def captureClientFailure
    (failure : IO.Error → BrokerClientFailure)
    (action : IO α) : IO (Except BrokerClientFailure α) := do
  try
    pure <| .ok (← action)
  catch e =>
    pure <| .error (failure e)

private structure RequestDeadline where
  timeoutMs : Nat
  deadlineNanos : Nat

private inductive RequestWait where
  | deadline (deadline : RequestDeadline)
  | interruptible (interrupted : IO Bool)

private def serverHelloTimeoutMs : Nat :=
  2000

/-- Verify the selected wrapper generation before disclosing capability-bound request contents. -/
private def verifyServerHello
    (client : Transport.Connection)
    (expectedIdentity : DaemonIdentity)
    (wait : RequestWait) : IO (Except BrokerClientFailure Unit) := do
  let greeting ←
    match wait with
    | .deadline deadline =>
        match ← captureClientFailure (.transport .receive) <|
            Transport.recvMsgUntil client deadline.deadlineNanos with
        | .ok (some greeting) => pure greeting
        | .ok none => return .error (.requestTimeout deadline.timeoutMs)
        | .error failure => return .error failure
    | .interruptible interrupted =>
        let deadlineNanos := (← IO.monoNanosNow) + serverHelloTimeoutMs * 1000000
        match ← captureClientFailure (.transport .receive) <|
            Transport.recvMsgInterruptiblyUntil client deadlineNanos interrupted with
        | .ok (.completed greeting) => pure greeting
        | .ok .timedOut => return .error (.requestTimeout serverHelloTimeoutMs)
        | .ok .interrupted => return .error .interrupted
        | .error failure => return .error failure
  match ServerHello.decode expectedIdentity greeting with
  | .ok () => pure <| .ok ()
  | .error detail => pure <| .error (.invalidResponse detail)

/-- Send one request while preserving transport, response, callback, and timeout failures. -/
private partial def sendRequestWithStreamResultCore
    (endpoint : Endpoint)
    (req : Request)
    (onStream : StreamMessage → IO Unit)
    (wait : RequestWait)
    (server : ServerExpectation) :
    IO (Except BrokerClientFailure Response) := do
  let requestText := (toJson req).compress
  let client ←
    match wait with
    | .deadline deadline =>
      match ← captureClientFailure (.transport .connect) <|
          Transport.connectUntil endpoint deadline.deadlineNanos with
      | .ok (.completed client) => pure client
      | .ok .timedOut => return .error (.requestTimeout deadline.timeoutMs)
      | .error failure => return .error failure
    | .interruptible interrupted =>
      match ← captureClientFailure (.transport .connect) <|
          Transport.connectInterruptibly endpoint interrupted with
      | .ok (.completed client) => pure client
      | .ok .interrupted => return .error .interrupted
      | .error failure => return .error failure
  let abandoned ← IO.mkRef false
  try
    if let .wrapper expectedIdentity := server then
      match ← verifyServerHello client expectedIdentity wait with
      | .ok () => pure ()
      | .error failure => return .error failure
    let sendResult ←
      match wait with
      | .deadline deadline =>
          match ← captureClientFailure (.transport .send) <|
              Transport.sendMsgUntil client requestText deadline.deadlineNanos with
          | .ok (.completed ()) => pure <| Except.ok ()
          | .ok .timedOut =>
              abandoned.set true
              pure <| Except.error (.requestTimeout deadline.timeoutMs)
          | .error failure => pure <| Except.error failure
      | .interruptible interrupted =>
          match ← captureClientFailure (.transport .send) <|
              Transport.sendMsgInterruptibly client requestText interrupted with
          | .ok (.completed ()) => pure <| Except.ok ()
          | .ok .interrupted =>
              abandoned.set true
              pure <| Except.error .interrupted
          | .error failure => pure <| Except.error failure
    match sendResult with
    | .ok () => pure ()
    | .error failure => return .error failure
    let rec receiveResponse : IO (Except BrokerClientFailure Response) := do
      let msg ←
        match wait with
        | .interruptible interrupted =>
            match ← captureClientFailure (.transport .receive) <|
                Transport.recvMsgInterruptibly client interrupted with
            | .ok (.completed msg) => pure msg
            | .ok .interrupted => return .error .interrupted
            | .error failure => return .error failure
        | .deadline deadline =>
            match ← captureClientFailure (.transport .receive) <|
                Transport.recvMsgUntil client deadline.deadlineNanos with
            | .ok (some msg) => pure msg
            | .ok none => return .error (.requestTimeout deadline.timeoutMs)
            | .error failure => return .error failure
      let stream ←
        match decodeStreamMessage msg with
        | .ok stream => pure stream
        | .error detail => return .error (.invalidResponse detail)
      unless stream.clientRequestId? == req.clientRequestId? do
        return .error <| .invalidResponse <|
          s!"Beam daemon stream request id {stream.clientRequestId?} does not match request id {req.clientRequestId?}"
      match ← captureClientFailure .streamCallback (onStream stream) with
      | .ok () => pure ()
      | .error failure => return .error failure
      match stream with
      | .response _ response =>
          pure <| .ok response
      | .fileProgress .. | .diagnostic .. | .workspaceOutput .. =>
          receiveResponse
    receiveResponse
  finally
    if ← abandoned.get then
      pure ()
    else
      Transport.closeConnection client

/-- Send one request with one absolute timeout across connect, greeting, send, and response. -/
partial def sendRequestWithStreamTimeoutResult
    (endpoint : Endpoint)
    (req : Request)
    (timeoutMs : Nat)
    (onStream : StreamMessage → IO Unit)
    (server : ServerExpectation) : IO (Except BrokerClientFailure Response) := do
  let deadline : RequestDeadline := {
    timeoutMs
    deadlineNanos := (← IO.monoNanosNow) + timeoutMs * 1000000
  }
  sendRequestWithStreamResultCore endpoint req onStream (.deadline deadline) server

/-- Send one request with one absolute timeout and structured progress callbacks. -/
partial def sendRequestWithCallbacksTimeoutResult
    (endpoint : Endpoint)
    (req : Request)
    (timeoutMs : Nat)
    (callbacks : StreamCallbacks := {})
    (server : ServerExpectation) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamTimeoutResult endpoint req timeoutMs (server := server) fun stream => do
    match stream with
    | .response .. =>
        pure ()
    | .fileProgress _ progress =>
        callbacks.onFileProgress progress
    | .diagnostic _ diagnostic =>
        callbacks.onDiagnostic diagnostic
    | .workspaceOutput _ chunk =>
        if let some publisher := callbacks.output? then
          publisher.offer chunk.source chunk.text chunk.omittedBefore

/-- Send one request whose owning client may interrupt the exact in-flight connection. -/
partial def sendRequestWithCallbacksInterruptiblyResult
    (endpoint : Endpoint)
    (req : Request)
    (interrupted : IO Bool)
    (callbacks : StreamCallbacks := {})
    (server : ServerExpectation) : IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamResultCore endpoint req (fun stream => do
    match stream with
    | .response .. =>
        pure ()
    | .fileProgress _ progress =>
        callbacks.onFileProgress progress
    | .diagnostic _ diagnostic =>
        callbacks.onDiagnostic diagnostic
    | .workspaceOutput _ chunk =>
        if let some publisher := callbacks.output? then
          publisher.offer chunk.source chunk.text chunk.omittedBefore) (.interruptible interrupted) server

end Beam.Broker
