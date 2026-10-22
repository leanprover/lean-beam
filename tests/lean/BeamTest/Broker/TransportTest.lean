/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Transport

open Beam.Broker

namespace BeamTest.Broker.TransportTest

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def expectIoErrorMessage (label : String) (act : IO α) : IO String := do
  let result ←
    try
      pure <| Except.ok (← act)
    catch err =>
      pure <| Except.error err
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected IO error"
  | .error err =>
      pure err.toString

private def expectIoErrorContains (label needle : String) (act : IO α) : IO Unit := do
  let msg ← expectIoErrorMessage label act
  unless msg.contains needle do
    throw <| IO.userError s!"{label}: expected error containing {needle}, got {msg}"

private def withBrokerListener
    (act : Transport.Listener → Transport.Endpoint → IO α)
    (backlog : UInt32 := 2) : IO α := do
  let listener ← Transport.bindAndListen (.tcp 0) backlog
  try
    let endpoint ← Transport.listenerEndpoint listener
    act listener endpoint
  finally
    Transport.closeListener listener

private inductive FrameStop where
  | interrupted
  | timedOut
  deriving BEq, Repr

private structure FrameFixture where
  pending : IO.Ref Transport.Framing.Buffer
  chunks : IO.Ref (List ByteArray)
  requests : IO.Ref (Array UInt64)

private def frameFixture (chunks : Array ByteArray) : IO FrameFixture := do
  let pending ← IO.mkRef <| Transport.Framing.Buffer.ofBytes ByteArray.empty
  let chunks ← IO.mkRef chunks.toList
  let requests ← IO.mkRef #[]
  pure { pending, chunks, requests }

private def FrameFixture.receive (fixture : FrameFixture) (size : UInt64) :
    IO (Except FrameStop (Option ByteArray)) := do
  fixture.requests.modify (·.push size)
  match ← fixture.chunks.get with
  | [] => pure (.ok none)
  | chunk :: rest =>
      let count := min size.toNat chunk.size
      fixture.chunks.set <| if count < chunk.size then
        chunk.extract count chunk.size :: rest else rest
      pure <| .ok (some (chunk.extract 0 count))

private def FrameFixture.read (fixture : FrameFixture)
    (stop : IO (Option FrameStop) := pure none) : IO (Except FrameStop String) :=
  Transport.Framing.recvMsgUsing fixture.pending fixture.receive stop

private def frameBytes (text : String) : ByteArray :=
  s!"{text.toUTF8.size}\n".toUTF8 ++ text.toUTF8

private def requireFrame (fixture : FrameFixture) (expected : String) : IO Unit := do
  match ← fixture.read with
  | .ok actual => require "buffered frame payload" (actual == expected)
  | .error stop => throw <| IO.userError s!"unexpected frame stop: {repr stop}"

private def requireFrameStop (label : String) (expected : FrameStop)
    (result : Except FrameStop String) : IO Unit := do
  match result with
  | .error actual => require label (actual == expected)
  | .ok _ => throw <| IO.userError label

private def checkBufferedFraming : IO Unit := do
  -- A complete burst performs one receive, not one receive/poll per header character.
  let messages := #["", "λ🙂"] ++ Array.replicate 20 (String.ofList (List.replicate 128 'x'))
  let burst := messages.foldl (fun bytes text => bytes ++ frameBytes text) ByteArray.empty
  let fixture ← frameFixture #[burst]
  for text in messages do
    requireFrame fixture text
  require "ready frame burst should need one underlying receive"
    ((← fixture.requests.get) == #[4096])
  require "consuming the burst should release its backing buffer"
    ((← fixture.pending.get) == .ofBytes ByteArray.empty)

  -- Coalesced frames span several lookahead fills; preserve every payload and receive bound.
  let messages := (List.range 96).toArray.map fun i =>
    s!"{i}:" ++ String.ofList (List.replicate 128 'x') ++ "λ🙂"
  let burst := messages.foldl (fun bytes text => bytes ++ frameBytes text) ByteArray.empty
  require "multi-fill fixture must cross the read-ahead boundary" (burst.size > 3 * 4096)
  let fixture ← frameFixture #[burst]
  for text in messages do
    requireFrame fixture text
  require "small coalesced frames should use bounded lookahead receives"
    ((← fixture.requests.get) == Array.replicate ((burst.size + 4095) / 4096) 4096)
  require "all refill storage should be released after consumption"
    ((← fixture.pending.get) == .ofBytes ByteArray.empty)

  -- Put the 4 KiB refill inside the next header, at its newline, and inside its UTF-8 payload.
  for prefixSize in #[4086, 4087, 4088, 4089, 4090] do
    let leadingText := String.ofList (List.replicate prefixSize 'x')
    let next := "λ🙂" ++ String.ofList (List.replicate 120 'y')
    let fixture ← frameFixture #[frameBytes leadingText ++ frameBytes next ++ frameBytes "tail"]
    requireFrame fixture leadingText
    requireFrame fixture next
    requireFrame fixture "tail"
    require "boundary frames should use exactly two bounded refills"
      ((← fixture.requests.get) == #[4096, 4096])
    require "boundary frames must consume all buffered bytes"
      ((← fixture.pending.get) == .ofBytes ByteArray.empty)

  -- Force every header/payload boundary, including splits inside multibyte UTF-8.
  let text := String.ofList (List.replicate 120 'x') ++ "λ🙂"
  let bytes := frameBytes text
  for split in [1:bytes.size] do
    let fragmented ← frameFixture #[bytes.extract 0 split, bytes.extract split bytes.size]
    requireFrame fragmented text
  let byteChunks := (List.range bytes.size).toArray.map fun i => ByteArray.mk #[bytes[i]!]
  requireFrame (← frameFixture byteChunks) text

  -- Retain a following frame without assigning it to the previous payload.
  let leftovers ← frameFixture #[frameBytes "first" ++ frameBytes "second"]
  requireFrame leftovers "first"
  require "next frame bytes must remain owned by the connection"
    ((← leftovers.pending.get).unreadBytes == frameBytes "second")
  requireFrame leftovers "second"
  require "next frame should not issue another receive" ((← leftovers.requests.get).size == 1)

  -- Large payloads ask for the remaining body, rather than refilling 4 KiB at a time.
  let largeText := String.ofList (List.replicate (128 * 1024) 'x')
  let large ← frameFixture #[frameBytes largeText]
  requireFrame large largeText
  let headerBytes := s!"{largeText.toUTF8.size}\n".toUTF8.size
  require "large body should use one lookahead read and one full remaining-body read"
    ((← large.requests.get) == #[4096, (largeText.toUTF8.size - (4096 - headerBytes)).toUInt64])

  -- A large-body receive must not absorb the following small frame, in either order.
  for messages in #[#[largeText, "small", "λ🙂"], #["small", largeText, "tail"]] do
    let bytes := messages.foldl (fun bytes text => bytes ++ frameBytes text) ByteArray.empty
    let fixture ← frameFixture #[bytes]
    for text in messages do
      requireFrame fixture text
    let precedingBytes := if messages[0]! == largeText then 0 else (frameBytes "small").size
    let remaining := largeText.toUTF8.size - (4096 - precedingBytes - headerBytes)
    require "mixed frames must retain full-body reads without consuming the next frame"
      ((← fixture.requests.get) == #[4096, remaining.toUInt64, 4096])
    require "mixed frames must release the exhausted buffer"
      ((← fixture.pending.get) == .ofBytes ByteArray.empty)

  for (input, needle) in #[
      ("00000000000000000000\n", ""), -- exactly 20 header bytes: valid empty frame
      ("000000000000000000000\n", "header is too long"),
      ("x\n", "invalid Beam daemon length"),
      ("-1\n", "invalid Beam daemon length"),
      (s!"{Transport.maxFrameBytes}\n", "connection closed"),
      (s!"{Transport.maxFrameBytes + 1}\n", "frame exceeds"),
      ("12", "connection closed"),
      ("5\nab", "connection closed")] do
    let invalid ← frameFixture #[input.toUTF8]
    if needle.isEmpty then requireFrame invalid ""
    else expectIoErrorContains "framing bounds/EOF" needle invalid.read
  expectIoErrorContains "EOF before header" "connection closed" (← frameFixture #[]).read
  let invalidHeader ← frameFixture #[ByteArray.mk #[255, 10]]
  expectIoErrorContains "invalid header UTF-8" "invalid Beam daemon header" invalidHeader.read
  let invalidPayload ← frameFixture #[ByteArray.mk #[49, 10, 255]]
  expectIoErrorContains "invalid payload UTF-8" "invalid Beam daemon UTF-8" invalidPayload.read
  for input in #[ByteArray.empty, "1\n".toUTF8] do
    let emptyChunk ← frameFixture #[input, ByteArray.empty]
    expectIoErrorContains "empty received chunk" "empty" emptyChunk.read

  for stop in #[FrameStop.interrupted, .timedOut] do
    -- A stopped partial frame is discarded by its caller, never reinterpreted as a new frame.
    for input in #["12", "5\nab"] do
      let incomplete ← frameFixture #[input.toUTF8]
      let receive := fun size => do
        if (← incomplete.chunks.get).isEmpty then pure (.error stop)
        else incomplete.receive size
      let result ← Transport.Framing.recvMsgUsing incomplete.pending receive (pure none)
      requireFrameStop "partial-frame stop must remain typed" stop result
    let body ← frameFixture #[frameBytes "abcde"]
    let checks ← IO.mkRef 0
    let result ← body.read do
      checks.modify (· + 1)
      pure <| if (← checks.get) == 2 then some stop else none
    requireFrameStop "stop before consuming a buffered payload" stop result
    require "stopped buffered payload must remain intact" ((← body.pending.get).unreadBytes == "abcde".toUTF8)
    let buffered ← frameFixture #[frameBytes "first" ++ frameBytes "second"]
    requireFrame buffered "first"
    let before ← buffered.pending.get
    requireFrameStop "buffered frame must observe stop before consuming bytes" stop
      (← buffered.read (pure (some stop)))
    require "buffered stop must leave bytes owned by this connection"
      ((← buffered.pending.get) == before && (← buffered.requests.get).size == 1)

  -- Fresh UV receives retain completion-first precedence; buffered consumption checks stops.
  let ready ← frameFixture #[frameBytes ""]
  let stopCalls ← IO.mkRef 0
  let result ← ready.read do
    stopCalls.modify (· + 1)
    pure (some .interrupted)
  requireFrameStop "buffered newline must check interruption even after a completed read"
    .interrupted result
  require "only the buffered newline should invoke the stop check" ((← stopCalls.get) == 1)

private def withTcpPair
    (act : Transport.Connection → Transport.Connection → IO Unit) : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let accepted ← IO.asTask (prio := Task.Priority.dedicated) <|
      Transport.accept listener
    try
      let deadline := (← IO.monoNanosNow) + 5000 * 1000000
      let .completed client ← Transport.connectUntil endpoint deadline
        | throw <| IO.userError "TCP fixture connection timed out"
      try
        let server ← IO.ofExcept (← IO.wait accepted)
        act client server
      finally
        Transport.closeConnection client
    finally
      -- Even setup failure must cancel/join the accept and close any accepted connection.
      Transport.closeListener listener
      if let .ok server ← IO.wait accepted then
        Transport.closeConnection server

private def checkBufferedTcpStops : IO Unit := do
  withTcpPair fun client server => do
    -- With no bytes consumed, exercise raw UV cancellation independently of partial framing.
    let deadline := (← IO.monoNanosNow) + 20 * 1000000
    require "idle receive should time out"
      (← Transport.recvMsgUntil client deadline).isNone
    Transport.sendMsg server "first"
    let deadline := (← IO.monoNanosNow) + 5000 * 1000000
    match ← Transport.recvMsgInterruptiblyUntil client deadline (pure false) with
    | .completed text => require "receive after cancelled UV read" (text == "first")
    | _ => throw <| IO.userError "receive after cancelled UV read did not complete"
    -- Explicitly seed ready leftovers so stop/deadline precedence is scheduling independent.
    let .tcp _ pending := client
    pending.set <| .ofBytes (frameBytes "buffered")
    require "expired deadline must stop ready buffered data"
      (← Transport.recvMsgUntil client 0).isNone
    match ← Transport.recvMsgInterruptibly client (pure true) with
    | .interrupted => pure ()
    | .completed _ => throw <| IO.userError "buffered bytes bypassed interruption"
    match ← Transport.recvMsgInterruptiblyUntil client 0 (pure true) with
    | .interrupted => pure ()
    | _ => throw <| IO.userError "interruption should precede deadline on buffered data"
    match ← Transport.recvMsgInterruptiblyUntil client 0 (pure false) with
    | .timedOut => pure ()
    | _ => throw <| IO.userError "buffered data bypassed deadline"
    -- These stops consumed zero bytes. This is not a partial-frame resumption guarantee.
    let deadline := (← IO.monoNanosNow) + 5000 * 1000000
    require "untouched buffered payload should remain available after stopped calls"
      ((← Transport.recvMsgUntil client deadline) == some "buffered")

  for partialFrame in #["12", "5\nab"] do
    withTcpPair fun client _ => do
      let .tcp _ pending := client
      pending.set <| .ofBytes partialFrame.toUTF8
      let pendingReadStops ← IO.mkRef 0
      let deadline := (← IO.monoNanosNow) + 5000 * 1000000
      let result ← Transport.recvMsgInterruptiblyUntil client deadline do
        -- Buffered checks see a nonempty cursor. Only after the partial frame has been consumed
        -- does receiveBuffered post the real UV read and poll this callback with an empty buffer.
        if (← pending.get) == .ofBytes ByteArray.empty then
          pendingReadStops.modify (· + 1)
          pure true
        else
          pure false
      match result with
      | .interrupted => pure ()
      | _ => throw <| IO.userError "partial frame did not stop at the pending UV receive"
      require "partial-frame stop must reach exactly one pending UV read"
        ((← pendingReadStops.get) == 1)
      -- Discard this connection now: header/body bytes were consumed before the stop.

def check : IO Unit := do
  checkBufferedFraming
  checkBufferedTcpStops

end BeamTest.Broker.TransportTest

def main : IO Unit := do
  BeamTest.Broker.TransportTest.check
  IO.println "TCP framing and cancellation tests passed"
