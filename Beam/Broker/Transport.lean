/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
-- Use the UV socket API directly to cancel the exact pending receive on interruption or timeout.
import Std.Internal.UV.TCP
import Std.Net.Addr

open Lean

namespace Beam.Broker.Transport

open Std.Net
open Std.Internal.UV

def maxFrameBytes : Nat :=
  16 * 1024 * 1024

private def maxFrameHeaderBytes : Nat :=
  20

inductive Endpoint where
  | tcp (port : UInt16)
  deriving Repr, BEq

inductive Connection where
  | tcp (client : TCP.Socket)

inductive Listener where
  | tcp (server : TCP.Socket)

def localhost (port : UInt16) : SocketAddress :=
  SocketAddressV4.mk (.ofParts 127 0 0 1) port

def endpointDescription : Endpoint → String
  | .tcp port => s!"tcp://127.0.0.1:{port.toNat}"

private def waitTcpPromise (promise : IO.Promise (Except IO.Error α)) (failureMessage : String) :
    IO α := do
  let some result := promise.result?.get
    | throw <| IO.userError failureMessage
  match result with
  | .ok value => pure value
  | .error err => throw err

inductive DeadlineResult (α : Type) where
  | completed (value : α)
  | timedOut

inductive InterruptResult (α : Type) where
  | completed (value : α)
  | interrupted

inductive InterruptibleDeadlineResult (α : Type) where
  | completed (value : α)
  | timedOut
  | interrupted

private inductive WaitStop where
  | timedOut
  | interrupted

private partial def waitTcpPromiseWithStop
    {stop : Type}
    (promise : IO.Promise (Except IO.Error α))
    (shouldStop : IO (Option stop))
    (failureMessage : String)
    (pollMs : Nat := 10) : IO (Except stop α) := do
  let resultTask := promise.result?
  let rec loop : IO (Except stop α) := do
    if ← IO.hasFinished resultTask then
      let some result ← IO.wait resultTask
        | throw <| IO.userError failureMessage
      match result with
      | .ok value => pure <| .ok value
      | .error err => throw err
    else if let some stopped ← shouldStop then
      pure <| .error stopped
    else
      IO.sleep pollMs.toUInt32
      loop
  loop

private def waitTcpReceivePromise
    {stop : Type}
    (client : TCP.Socket)
    (promise : IO.Promise (Except IO.Error α))
    (shouldStop : IO (Option stop))
    (failureMessage : String) : IO (Except stop α) := do
  let result ← waitTcpPromiseWithStop promise shouldStop failureMessage
  match result with
  | .ok value => pure <| .ok value
  | .error stopped =>
      -- The caller abandons this receive after the bounded wait returns. Cancel the exact pending
      -- UV read first so it cannot remain attached to the socket.
      TCP.Socket.cancelRecv client
      pure <| .error stopped

def connect (endpoint : Endpoint) : IO Connection := do
  match endpoint with
  | .tcp port =>
      let addr := localhost port
      let client ← TCP.Socket.new
      let promise ← TCP.Socket.connect client addr
      waitTcpPromise promise "Beam daemon connection failed before TCP connect completed"
      pure <| .tcp client

private def abandonTcpSocket (client : TCP.Socket) : IO Unit := do
  try
    TCP.Socket.cancelRecv client
  catch _ =>
    pure ()
  try
    -- Supported Lean UV versions do not expose cancellation for connect or send. Start shutdown
    -- without waiting for queued writes; dropping this connection must never hold an interrupted
    -- or timed-out caller behind that queue.
    discard <| TCP.Socket.shutdown client
  catch _ =>
    pure ()

private def connectTcpUsing
    {stop : Type}
    (port : UInt16)
    (shouldStop : IO (Option stop)) : IO (Except stop Connection) := do
  let client ← TCP.Socket.new
  let promise ← TCP.Socket.connect client (localhost port)
  match ← waitTcpPromiseWithStop promise shouldStop
      "Beam daemon connection failed before TCP connect completed" with
  | .ok () => pure <| .ok (.tcp client)
  | .error stopped =>
      abandonTcpSocket client
      pure <| .error stopped

def connectUntil (endpoint : Endpoint) (deadlineNanos : Nat) : IO (DeadlineResult Connection) := do
  match endpoint with
  | .tcp port =>
      let result ← connectTcpUsing port do
        if (← IO.monoNanosNow) >= deadlineNanos then
          pure <| some ()
        else
          pure none
      match result with
      | .ok client => pure <| .completed client
      | .error () => pure .timedOut

def connectInterruptibly
    (endpoint : Endpoint)
    (interrupted : IO Bool) : IO (InterruptResult Connection) := do
  match endpoint with
  | .tcp port =>
      let result ← connectTcpUsing port do
        if ← interrupted then
          pure <| some ()
        else
          pure none
      match result with
      | .ok client => pure <| .completed client
      | .error () => pure .interrupted

def bindAndListen (endpoint : Endpoint) (backlog : UInt32 := 16) : IO Listener := do
  match endpoint with
  | .tcp port =>
      let server ← TCP.Socket.new
      TCP.Socket.bind server (localhost port)
      TCP.Socket.listen server backlog
      pure <| .tcp server

/-- Return the concrete endpoint selected for a bound listener, including an OS-assigned port. -/
def listenerEndpoint (listener : Listener) : IO Endpoint := do
  match listener with
  | .tcp server =>
      pure <| .tcp (← TCP.Socket.getSockName server).port

def accept (listener : Listener) : IO Connection := do
  match listener with
  | .tcp server =>
      let promise ← TCP.Socket.accept server
      pure <| .tcp (← waitTcpPromise promise "Beam daemon listener closed before TCP accept completed")

def closeConnection (conn : Connection) : IO Unit := do
  match conn with
  | .tcp client =>
      try
        let promise ← TCP.Socket.shutdown client
        waitTcpPromise promise "Beam daemon connection closed before TCP shutdown completed"
      catch _ =>
        pure ()

def closeListener (listener : Listener) : IO Unit := do
  match listener with
  | .tcp server =>
      try
        TCP.Socket.cancelAccept server
      catch _ =>
        pure ()

private def framedMessage (msg : String) : IO (Array ByteArray) := do
  let bytes := msg.toUTF8
  if bytes.size > maxFrameBytes then
    throw <| IO.userError s!"Beam daemon frame exceeds {maxFrameBytes} bytes"
  let header := s!"{bytes.size}\n".toUTF8
  pure #[header, bytes]

private def sendMsgTcp (client : TCP.Socket) (msg : String) : IO Unit := do
  let promise ← TCP.Socket.send client (← framedMessage msg)
  waitTcpPromise promise "Beam daemon connection closed before TCP send completed"

private def sendMsgTcpUsing
    {stop : Type}
    (client : TCP.Socket)
    (msg : String)
    (shouldStop : IO (Option stop)) : IO (Except stop Unit) := do
  let promise ← TCP.Socket.send client (← framedMessage msg)
  let result ← waitTcpPromiseWithStop promise shouldStop
    "Beam daemon connection closed before TCP send completed"
  match result with
  | .ok () => pure <| .ok ()
  | .error stopped =>
      abandonTcpSocket client
      pure <| .error stopped

private def receiveTcp (client : TCP.Socket) (size : UInt64) : IO (Except Empty (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  .ok <$> waitTcpPromise promise "Beam daemon connection closed during TCP receive"

private def receiveTcpUntil
    (client : TCP.Socket)
    (size : UInt64)
    (deadlineNanos : Nat) : IO (Except Unit (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  waitTcpReceivePromise client promise (do
    if (← IO.monoNanosNow) >= deadlineNanos then
      pure <| some ()
    else
      pure none) "Beam daemon connection closed during TCP receive"

private def receiveTcpInterruptibly
    (client : TCP.Socket)
    (size : UInt64)
    (interrupted : IO Bool) : IO (Except Unit (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  waitTcpReceivePromise client promise (do
    if ← interrupted then
      pure <| some ()
    else
      pure none) "Beam daemon connection closed during TCP receive"

private def receiveTcpInterruptiblyUntil
    (client : TCP.Socket)
    (size : UInt64)
    (deadlineNanos : Nat)
    (interrupted : IO Bool) : IO (Except WaitStop (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  waitTcpReceivePromise client promise (do
    if ← interrupted then
      pure <| some WaitStop.interrupted
    else if (← IO.monoNanosNow) >= deadlineNanos then
      pure <| some WaitStop.timedOut
    else
      pure none) "Beam daemon connection closed during TCP receive"

private def recvMsgTcpUsing
    (receive : UInt64 → IO (Except stop (Option ByteArray))) :
    IO (Except stop String) := do
  let mut header := ByteArray.empty
  repeat
    match ← receive 1 with
    | .error stopped => return .error stopped
    | .ok none => throw <| IO.userError "Beam daemon connection closed"
    | .ok (some chunk) =>
        if chunk.isEmpty then
          throw <| IO.userError "Beam daemon received an empty header chunk"
        if chunk[0]! == '\n'.toUInt8 then
          break
        if header.size >= maxFrameHeaderBytes then
          throw <| IO.userError "Beam daemon frame header is too long"
        header := header ++ chunk
  let some lenStr := String.fromUTF8? header
    | throw <| IO.userError "invalid Beam daemon header"
  let some len := lenStr.toNat?
    | throw <| IO.userError "invalid Beam daemon length"
  if len > maxFrameBytes then
    throw <| IO.userError s!"Beam daemon frame exceeds {maxFrameBytes} bytes"
  let mut payload := ByteArray.empty
  while payload.size < len do
    match ← receive (len - payload.size).toUInt64 with
    | .error stopped => return .error stopped
    | .ok none => throw <| IO.userError "Beam daemon connection closed"
    | .ok (some chunk) =>
        if chunk.isEmpty then
          throw <| IO.userError "Beam daemon received an empty payload chunk"
        payload := payload ++ chunk
  let some msg := String.fromUTF8? payload
    | throw <| IO.userError "invalid Beam daemon UTF-8"
  pure <| .ok msg

private def recvMsgTcp (client : TCP.Socket) : IO String := do
  match ← recvMsgTcpUsing (receiveTcp client) with
  | .ok msg => pure msg
  | .error stopped => nomatch stopped

private def recvMsgTcpUntil (client : TCP.Socket) (deadlineNanos : Nat) : IO (Option String) := do
  match ← recvMsgTcpUsing (receiveTcpUntil client · deadlineNanos) with
  | .ok msg => pure (some msg)
  | .error () => pure none

private def recvMsgTcpInterruptibly
    (client : TCP.Socket)
    (interrupted : IO Bool) : IO (InterruptResult String) := do
  match ← recvMsgTcpUsing (receiveTcpInterruptibly client · interrupted) with
  | .ok msg => pure <| .completed msg
  | .error () => pure .interrupted

private def recvMsgTcpInterruptiblyUntil
    (client : TCP.Socket)
    (deadlineNanos : Nat)
    (interrupted : IO Bool) : IO (InterruptibleDeadlineResult String) := do
  match ← recvMsgTcpUsing (receiveTcpInterruptiblyUntil client · deadlineNanos interrupted) with
  | .ok msg => pure <| .completed msg
  | .error .timedOut => pure .timedOut
  | .error .interrupted => pure .interrupted

def sendMsg (conn : Connection) (msg : String) : IO Unit := do
  match conn with
  | .tcp client => sendMsgTcp client msg

def sendMsgUntil
    (conn : Connection)
    (msg : String)
    (deadlineNanos : Nat) : IO (DeadlineResult Unit) := do
  match conn with
  | .tcp client =>
      let result ← sendMsgTcpUsing client msg do
        if (← IO.monoNanosNow) >= deadlineNanos then
          pure <| some ()
        else
          pure none
      match result with
      | .ok () => pure <| .completed ()
      | .error () => pure .timedOut

def sendMsgInterruptibly
    (conn : Connection)
    (msg : String)
    (interrupted : IO Bool) : IO (InterruptResult Unit) := do
  match conn with
  | .tcp client =>
      let result ← sendMsgTcpUsing client msg do
        if ← interrupted then
          pure <| some ()
        else
          pure none
      match result with
      | .ok () => pure <| .completed ()
      | .error () => pure .interrupted

def recvMsg (conn : Connection) : IO String := do
  match conn with
  | .tcp client => recvMsgTcp client

/-- Receive one framed message by an absolute monotonic deadline, returning `none` on timeout. -/
def recvMsgUntil (conn : Connection) (deadlineNanos : Nat) : IO (Option String) := do
  match conn with
  | .tcp client => recvMsgTcpUntil client deadlineNanos

/-- Receive one complete frame while preserving partial-frame state until completion or interrupt. -/
def recvMsgInterruptibly
    (conn : Connection)
    (interrupted : IO Bool) : IO (InterruptResult String) := do
  match conn with
  | .tcp client => recvMsgTcpInterruptibly client interrupted

/-- Receive one frame until either interruption or an absolute monotonic deadline wins. -/
def recvMsgInterruptiblyUntil
    (conn : Connection)
    (deadlineNanos : Nat)
    (interrupted : IO Bool) : IO (InterruptibleDeadlineResult String) := do
  match conn with
  | .tcp client => recvMsgTcpInterruptiblyUntil client deadlineNanos interrupted

end Beam.Broker.Transport
