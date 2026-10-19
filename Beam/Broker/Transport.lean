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
  | tcp (client : TCP.Socket) (pending : IO.Ref ByteArray)

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
      pure <| .tcp client (← IO.mkRef ByteArray.empty)

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
  | .ok () => pure <| .ok (.tcp client (← IO.mkRef ByteArray.empty))
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
      let client ← waitTcpPromise promise "Beam daemon listener closed before TCP accept completed"
      pure <| .tcp client (← IO.mkRef ByteArray.empty)

def closeConnection (conn : Connection) : IO Unit := do
  match conn with
  | .tcp client _ =>
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

private def receiveTcpUsing
    (client : TCP.Socket)
    (shouldStop : IO (Option stop))
    (size : UInt64) : IO (Except stop (Option ByteArray)) := do
  let promise ← TCP.Socket.recv? client size
  waitTcpReceivePromise client promise shouldStop
    "Beam daemon connection closed during TCP receive"

-- Small reads may fetch the next frame too; retain only a bounded lookahead. Large bodies
-- still request their full remaining size, rather than paying a polling wait for each small chunk.
private def readAheadBytes : UInt64 := 4096

private def receiveBuffered
    (pending : IO.Ref ByteArray)
    (receive : UInt64 → IO (Except stop (Option ByteArray)))
    (shouldStop : IO (Option stop))
    (size : UInt64) : IO (Except stop (Option ByteArray)) := do
  let buffered ← pending.get
  let chunk ← if buffered.isEmpty then do
    match ← receive (max size readAheadBytes) with
    | .error stopped => return .error stopped
    | .ok none => return .ok none
    | .ok (some chunk) => pure chunk
  else do
    -- Pending UV receives retain completion-first precedence. Buffered bytes have no pending
    -- promise: check the caller's stop condition before consuming them, including between frames.
    if let some stopped ← shouldStop then
      return .error stopped
    pure buffered
  let count := min size.toNat chunk.size
  pending.set (chunk.extract count chunk.size)
  pure <| .ok (some (chunk.extract 0 count))

namespace Framing

/-- Internal framing core, with injectable reads for deterministic chunk/receive-count tests.
The buffer belongs to one connection and one receive owner; callers discard a stopped frame. -/
def recvMsgUsing
    (pending : IO.Ref ByteArray)
    (receive : UInt64 → IO (Except stop (Option ByteArray)))
    (shouldStop : IO (Option stop)) :
    IO (Except stop String) := do
  let receive := receiveBuffered pending receive shouldStop
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

end Framing

private def recvMsgTcp (client : TCP.Socket) (pending : IO.Ref ByteArray) : IO String := do
  match ← Framing.recvMsgUsing pending (receiveTcp client) (pure none) with
  | .ok msg => pure msg
  | .error stopped => nomatch stopped

private def recvMsgTcpUntil
    (client : TCP.Socket)
    (pending : IO.Ref ByteArray)
    (deadlineNanos : Nat) : IO (Option String) := do
  let shouldStop : IO (Option Unit) := do
    pure <| if (← IO.monoNanosNow) >= deadlineNanos then some () else none
  match ← Framing.recvMsgUsing pending (receiveTcpUsing client shouldStop) shouldStop with
  | .ok msg => pure (some msg)
  | .error () => pure none

private def recvMsgTcpInterruptibly
    (client : TCP.Socket)
    (pending : IO.Ref ByteArray)
    (interrupted : IO Bool) : IO (InterruptResult String) := do
  let shouldStop : IO (Option Unit) := do
    pure <| if ← interrupted then some () else none
  match ← Framing.recvMsgUsing pending (receiveTcpUsing client shouldStop) shouldStop with
  | .ok msg => pure <| .completed msg
  | .error () => pure .interrupted

private def recvMsgTcpInterruptiblyUntil
    (client : TCP.Socket)
    (pending : IO.Ref ByteArray)
    (deadlineNanos : Nat)
    (interrupted : IO Bool) : IO (InterruptibleDeadlineResult String) := do
  let shouldStop : IO (Option WaitStop) := do
    if ← interrupted then pure (some WaitStop.interrupted)
    else if (← IO.monoNanosNow) >= deadlineNanos then pure (some WaitStop.timedOut)
    else pure none
  match ← Framing.recvMsgUsing pending (receiveTcpUsing client shouldStop) shouldStop with
  | .ok msg => pure <| .completed msg
  | .error WaitStop.timedOut => pure .timedOut
  | .error WaitStop.interrupted => pure .interrupted

def sendMsg (conn : Connection) (msg : String) : IO Unit := do
  match conn with
  | .tcp client _ => sendMsgTcp client msg

def sendMsgUntil
    (conn : Connection)
    (msg : String)
    (deadlineNanos : Nat) : IO (DeadlineResult Unit) := do
  match conn with
  | .tcp client _ =>
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
  | .tcp client _ =>
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
  | .tcp client pending => recvMsgTcp client pending

/-- Receive one framed message by an absolute monotonic deadline, returning `none` on timeout.
A timeout may follow partial frame consumption. On `none`, discard the connection; a later
receive does not resume the interrupted frame. A completed socket read takes precedence over
the deadline check; buffered bytes check the deadline before consumption. -/
def recvMsgUntil (conn : Connection) (deadlineNanos : Nat) : IO (Option String) := do
  match conn with
  | .tcp client pending => recvMsgTcpUntil client pending deadlineNanos

/-- Receive one complete frame, retaining partial-frame state while waiting.
On `.interrupted`, discard the connection: some frame bytes may already have been consumed,
and a later receive does not resume that frame. A completed socket read takes precedence over
interruption; buffered bytes check interruption before consumption. -/
def recvMsgInterruptibly
    (conn : Connection)
    (interrupted : IO Bool) : IO (InterruptResult String) := do
  match conn with
  | .tcp client pending => recvMsgTcpInterruptibly client pending interrupted

/-- Receive one frame until interruption or an absolute monotonic deadline stops the read.
On `.interrupted` or `.timedOut`, discard the connection: a partially consumed frame cannot
be resumed by a later receive. A completed socket read takes precedence over stop checks;
buffered bytes check interruption first, then the deadline, before consumption. -/
def recvMsgInterruptiblyUntil
    (conn : Connection)
    (deadlineNanos : Nat)
    (interrupted : IO Bool) : IO (InterruptibleDeadlineResult String) := do
  match conn with
  | .tcp client pending => recvMsgTcpInterruptiblyUntil client pending deadlineNanos interrupted

end Beam.Broker.Transport
