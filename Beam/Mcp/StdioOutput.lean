/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Std.Sync.Mutex

namespace Beam.Mcp.StdioOutput

/-- Internal transport limits; queued and in-flight messages share these bounds. -/
structure Limits where
  messages : Nat := 128
  bytes : Nat := 32 * 1024 * 1024
  frameBytes : Nat := 8 * 1024 * 1024

/-- Serialized protocol data and its diagnostic label; no request execution authority. -/
structure Frame where
  text : String
  label : String := ""

private structure Message where
  frame : Frame
  done : IO.Promise (Except IO.Error Unit)

private inductive Phase where
  | accepting
  | draining
  | failed (error : IO.Error)

private structure State where
  phase : Phase := .accepting
  pending : Array Message := #[]
  inFlight? : Option Message := none
  bytes : Nat := 0

/-- One writer owns physical output. Its queue holds only framed text and delivery promises. -/
structure Writer where
  private limits : Limits
  private state : Std.Mutex State
  private available : Std.Condvar
  private failure : IO.Promise IO.Error
  private finished : IO.Promise (Except IO.Error Unit)

def Writer.failureTask (writer : Writer) : Task (Option IO.Error) := writer.failure.result?

def Writer.finishedTask (writer : Writer) : Task (Option (Except IO.Error Unit)) :=
  writer.finished.result?

private def failState (error : IO.Error) : Std.AtomicT State IO (Option (Array Message)) := do
  let current ← get
  match current.phase with
  | .failed _ => pure none
  | _ =>
      set ({ phase := .failed error } : State)
      pure <| some <| current.pending ++ current.inFlight?.toArray

private def Writer.publishFailure (writer : Writer) (error : IO.Error)
    (messages : Array Message) : IO Unit := do
  for message in messages do
    message.done.resolve (.error error)
  writer.failure.resolve error
  writer.available.notifyAll

/-- Fail pending delivery without waiting for a potentially blocked physical write. -/
def Writer.fail (writer : Writer) (error : IO.Error) : IO Unit := do
  let some messages ← writer.state.atomically (failState error) | return
  writer.publishFailure error messages

private def Writer.take (writer : Writer) : IO (Option Message) :=
  writer.state.atomicallyOnce writer.available
    (do
      let current ← get
      match current.phase with
      | .accepting => pure (!current.pending.isEmpty)
      | _ => pure true)
    (do
      let current ← get
      match current.phase with
      | .failed error => throw error
      | _ =>
          if let some message := current.pending[0]? then
            set { current with
              pending := current.pending.extract 1 current.pending.size
              inFlight? := some message }
            pure (some message)
          else
            pure none)

private partial def Writer.run (writer : Writer) (write : Frame → IO Unit) : IO Unit := do
  let some message ← writer.take | return
  -- No queue lock is held during client IO.
  write message.frame
  let result ← writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => pure (.error error)
    | _ =>
        set { current with inFlight? := none, bytes := current.bytes - (message.frame.text.utf8ByteSize + message.frame.label.utf8ByteSize) }
        pure (.ok ())
  message.done.resolve result
  writer.run write

/-- Start a serialized transport writer. The supplied action performs only framed transport IO. -/
def start (write : Frame → IO Unit) (limits : Limits := {}) : IO Writer := do
  let writer : Writer := {
    limits, state := ← Std.Mutex.new {}, available := ← Std.Condvar.new
    failure := ← IO.Promise.new, finished := ← IO.Promise.new
  }
  try
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      let result ← try
        writer.run write
        pure (.ok ())
      catch error =>
        writer.fail error
        pure (.error error)
      writer.finished.resolve result
    pure writer
  catch error =>
    writer.fail error
    throw error

/-- Submit one complete frame without waiting for delivery or queue space. -/
def Writer.submit (writer : Writer) (frame : Frame) : IO (Task (Option (Except IO.Error Unit))) := do
  let done ← IO.Promise.new
  let size := frame.text.utf8ByteSize + frame.label.utf8ByteSize
  let failure? ← writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | .draining => throw <| IO.userError "MCP output is draining"
    | .accepting =>
        let count := current.pending.size + if current.inFlight?.isSome then 1 else 0
        let error? :=
          if size > writer.limits.frameBytes then
            some <| IO.userError "MCP response exceeds the output frame limit"
          else if count >= writer.limits.messages || current.bytes + size > writer.limits.bytes then
            some <| IO.userError "MCP output capacity exhausted"
          else none
        if let some error := error? then
          let messages? ← failState error
          pure <| some (error, messages?.getD #[])
        else
          set { current with pending := current.pending.push { frame, done }, bytes := current.bytes + size }
          pure none
  if let some (error, messages) := failure? then
    writer.publishFailure error messages
    throw error
  writer.available.notifyOne
  pure done.result?

/-- Stop accepting frames and finish the already accepted queue. This does not wait for stdout. -/
def Writer.finish (writer : Writer) : IO Unit := do
  writer.state.atomically do
    let current ← get
    match current.phase with
    | .accepting => set { current with phase := .draining }
    | _ => pure ()
  writer.available.notifyAll

end Beam.Mcp.StdioOutput
