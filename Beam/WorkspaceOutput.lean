/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Std.Sync.Mutex
import Std.Data.TreeSet
import Beam.StderrCapture
import Beam.WorkspaceOutput.Types

namespace Beam.WorkspaceOutput

private structure State where
  ready : IO.Promise Unit
  pending : Array Chunk := #[]
  bytes : Nat := 0
  activity : Nat := 0
  accepting : Bool := true
  nextPublisher : Nat := 0
  publishers : Std.TreeSet Nat := {}

/-- One request's ephemeral output. It contains no document or broker authority. -/
structure Buffer where
  private state : Std.Mutex State

/-- A helper may publish while its own capability and the enclosing request are live. -/
structure Publisher where
  private buffer : Buffer
  private id : Nat

def Buffer.create : IO Buffer := do
  let ready ← IO.Promise.new
  return ⟨← Std.Mutex.new { ready }⟩

def Buffer.borrow (buffer : Buffer) : IO (Option Publisher) :=
  buffer.state.atomically do
    let state ← get
    unless state.accepting do return none
    let id := state.nextPublisher
    set { state with nextPublisher := id + 1, publishers := state.publishers.insert id }
    return some ⟨buffer, id⟩

/-- An observation token for accepted text, including text later omitted under pressure.
It is not a work counter. Draining the buffer does not change the token. -/
def Buffer.activity (buffer : Buffer) : IO Nat :=
  buffer.state.atomically do pure (← get).activity

private def State.append (state : State) (source : Source) (text : String)
    (omittedBefore : Bool) : State := Id.run do
  let mut pending := state.pending
  let mut bytes := state.bytes + text.utf8ByteSize
  if let some last := pending.back? then
    if !omittedBefore && last.source == source &&
        last.text.utf8ByteSize + text.utf8ByteSize ≤ chunkLimit then
      pending := pending.set! (pending.size - 1) { last with text := last.text ++ text }
    else
      pending := pending.push { source, text, omittedBefore }
  else
    pending := pending.push { source, text, omittedBefore }
  let mut omitted := false
  while bytes > byteLimit || pending.size > recordLimit do
    bytes := bytes - pending[0]!.text.utf8ByteSize
    pending := pending.extract 1 pending.size
    omitted := true
  if omitted && !pending.isEmpty then
    pending := pending.set! 0 { pending[0]! with omittedBefore := true }
  return { state with pending, bytes, activity := state.activity + 1 }

private def Publisher.offerChunk (publisher : Publisher) (source : Source) (text : String)
    (omittedBefore : Bool) : IO Unit := do
  let ready? ← publisher.buffer.state.atomically do
    let state ← get
    if state.accepting && state.publishers.contains publisher.id then
      set <| state.append source text omittedBefore
      return if state.pending.isEmpty then some state.ready else none
    return none
  -- Promise consumers may attach synchronous task mappings. Never resolve under the lock.
  if let some ready := ready? then ready.resolve ()

/-- Offer bounded pieces without waiting for a consumer. No callback runs under the buffer lock.
`omittedBefore` preserves a gap reported by an upstream bounded transport buffer. -/
def Publisher.offer (publisher : Publisher) (source : Source) (text : String)
    (omittedBefore : Bool := false) : IO Unit := do
  if text.isEmpty then return
  if text.utf8ByteSize ≤ chunkLimit then
    publisher.offerChunk source text omittedBefore
    return
  let mut chunk := ""
  let mut omittedBefore := omittedBefore
  for char in text do
    let scalar := String.singleton char
    if chunk.utf8ByteSize + scalar.utf8ByteSize > chunkLimit then
      publisher.offerChunk source chunk omittedBefore
      omittedBefore := false
      chunk := ""
    chunk := chunk ++ scalar
  unless chunk.isEmpty do publisher.offerChunk source chunk omittedBefore

/-- Retiring a helper preserves its accepted output and other helpers' publishers. -/
def Publisher.retire (publisher : Publisher) : IO Unit :=
  publisher.buffer.state.atomically do
    modify fun state => { state with publishers := state.publishers.erase publisher.id }

/-- A claim or a read-only readiness task, obtained in the same atomic observation. -/
inductive Read where
  | chunk (value : Chunk)
  | waiting (ready : Task (Option Unit))
  | closed

/-- Observe this generation without claiming text, for a consumer sharing a wakeup with
other queues. Only that consumer may call `poll`. Publication, seal and discard resolve it. -/
def Buffer.readiness (buffer : Buffer) : IO (Task (Option Unit)) :=
  buffer.state.atomically do pure (← get).ready.result?

/-- One delivery owner claims directly from the request buffer; no second optional queue is needed. -/
def Buffer.poll (buffer : Buffer) : IO Read :=
  buffer.state.atomically do
    let state ← get
    let some chunk := state.pending[0]?
      | return if state.accepting then .waiting state.ready.result? else .closed
    let pending := state.pending.extract 1 state.pending.size
    let ready ← if pending.isEmpty && state.accepting then IO.Promise.new else pure state.ready
    set { state with
      pending, ready
      bytes := state.bytes - chunk.text.utf8ByteSize }
    return .chunk chunk

/-- Normal completion freezes the full bounded tail; late publishers become inert. -/
def Buffer.seal (buffer : Buffer) : IO Unit := do
  let ready ← buffer.state.atomically do
    let state ← get
    set { state with accepting := false, publishers := {} }
    return state.ready
  ready.resolve ()

/-- Cancellation/disconnect release pending text and permanently close publishing. -/
def Buffer.discard (buffer : Buffer) : IO Unit := do
  let ready ← buffer.state.atomically do
    let state ← get
    set { state with accepting := false, pending := #[], bytes := 0, publishers := {} }
    return state.ready
  ready.resolve ()

private structure Decoder where
  pending : ByteArray := .empty
  expected : Nat := 0

private def sequenceSize (byte : UInt8) : Nat :=
  if byte < 128 then 1
  else if 194 ≤ byte && byte < 224 then 2
  else if 224 ≤ byte && byte < 240 then 3
  else if 240 ≤ byte && byte < 245 then 4
  else 0

private def Decoder.startByte (byte : UInt8) : Decoder × String :=
  match sequenceSize byte with
  | 0 => ({}, "�")
  | 1 => ({}, String.singleton (Char.ofNat byte.toNat))
  | count => ({ pending := ByteArray.empty.push byte, expected := count }, "")

private def Decoder.push (decoder : Decoder) (byte : UInt8) : Decoder × String :=
  if decoder.expected == 0 then
    Decoder.startByte byte
  else if 128 ≤ byte && byte < 192 then
    let pending := decoder.pending.push byte
    if pending.size == decoder.expected then
      ({}, (String.fromUTF8? pending).getD "�")
    else
      ({ decoder with pending }, "")
  else
    -- A non-continuation starts a fresh scalar after replacing the unfinished one.
    let (next, text) := Decoder.startByte byte
    (next, "�" ++ text)

private structure StreamCapture where
  drain : Beam.StderrCapture
  decoder : IO.Ref Decoder
  source : Source

private def StreamCapture.start (handle : IO.FS.Handle) (source : Source)
    (publisher : Publisher) : IO StreamCapture := do
  let decoder ← IO.mkRef ({} : Decoder)
  let sink : Beam.StderrSink := fun bytes => do
    for byte in bytes do
      let (next, text) := (← decoder.get).push byte
      decoder.set next
      unless text.isEmpty do publisher.offer source text
    return true
  -- Handle.read waits for the requested count. A one-byte read exposes short flushed
  -- fragments promptly; the buffer coalesces scalars into bounded presentation chunks.
  let drain ← Beam.StderrCapture.start handle 0 (some sink) 1
  return { drain, decoder, source }

private def StreamCapture.finish (capture : StreamCapture) (publisher : Publisher) :
    IO Beam.StderrCaptureOutcome := do
  let outcome ← capture.drain.awaitCompletion
  discard <| capture.drain.disableSinkAndAwaitCurrentWrite
  -- The sink is now disabled and no decoder write can still be in progress.
  if (← capture.decoder.get).expected != 0 then publisher.offer capture.source "�"
  return outcome

/-- Two pipe drains owned by one helper; neither calls a presentation callback. -/
structure Capture where
  private stdout : StreamCapture
  private stderr : StreamCapture
  private publisher : Publisher

def Capture.start (stdout stderr : IO.FS.Handle) (publisher : Publisher) : IO Capture := do
  let out ← StreamCapture.start stdout .stdout publisher
  try
    let err ← StreamCapture.start stderr .stderr publisher
    return ⟨out, err, publisher⟩
  catch error =>
    publisher.retire
    discard <| out.drain.disableSinkAndAwaitCurrentWrite
    throw error

/-- Call after terminating the process job. EOF does not establish process cleanup. -/
def Capture.finish (capture : Capture) :
    IO (Beam.StderrCaptureOutcome × Beam.StderrCaptureOutcome) := do
  try
    let stdout ← capture.stdout.finish capture.publisher
    let stderr ← capture.stderr.finish capture.publisher
    return (stdout, stderr)
  finally
    capture.publisher.retire

end Beam.WorkspaceOutput
