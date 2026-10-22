/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.System
import Std.Sync.Mutex

namespace Beam

/--
A best-effort stderr sink returns whether it should receive another chunk. Sink callbacks must
complete within a caller-appropriate bound: disabling a sink waits for any callback already in
progress so it can report a stable failure state.
-/
abbrev StderrSink := ByteArray → IO Bool

/-- The bounded result of waiting for an owned stderr drain. -/
inductive StderrCaptureOutcome where
  /-- The source reached EOF. This does not establish that its writer exited. -/
  | drained
  /-- The drain stopped with a source I/O error. -/
  | sourceFailed (error : IO.Error)
  /-- The drain did not finish within the bound; some process may still hold the pipe open. -/
  | pipeStillOpen

private structure StderrSinkState where
  sink? : Option StderrSink
  failure? : Option IO.Error := none

/--
One owned stderr drain. Source failures remain task failures; sink failures are recorded and disable
only that sink, so a broken evidence file can never stop the pipe drain and deadlock its child.
-/
structure StderrCapture where
  private tail : Std.Mutex ByteArray
  private sinkState : Std.Mutex StderrSinkState
  private drainTask : Task (Except IO.Error Unit)

private def isUtf8ContinuationByte (byte : UInt8) : Bool :=
  decide (128 ≤ byte.toNat ∧ byte.toNat < 192)

private def utf8BoundaryAtOrAfter (bytes : ByteArray) (offset : Nat) : Nat :=
  let rec loop (offset : Nat) : Nat → Nat
    | 0 => offset
    | fuel + 1 =>
        if h : offset < bytes.size then
          if isUtf8ContinuationByte bytes[offset] then
            loop (offset + 1) fuel
          else
            offset
        else
          offset
  loop offset 3

private def appendBoundedTail
    (tail : Std.Mutex ByteArray)
    (limit : Nat)
    (chunk : ByteArray) : IO Unit := do
  tail.atomically do
    let combined := (← get) ++ chunk
    if combined.size > limit then
      let start := utf8BoundaryAtOrAfter combined (combined.size - limit)
      set <| combined.extract start combined.size
    else
      set combined

private partial def drainStderr
    (source : IO.FS.Handle)
    (tail : Std.Mutex ByteArray)
    (tailLimit : Nat)
    (sinkState : Std.Mutex StderrSinkState)
    (readSize : USize) : IO Unit := do
  let chunk ← source.read readSize
  unless chunk.isEmpty do
    appendBoundedTail tail tailLimit chunk
    sinkState.atomically do
      let state ← get
      if let some sink := state.sink? then
        try
          unless ← sink chunk do
            set { state with sink? := none }
        catch err =>
          set { state with
            sink? := none
            failure? := state.failure? <|> some err
          }
    drainStderr source tail tailLimit sinkState readSize

def StderrCapture.start
    (source : IO.FS.Handle)
    (tailLimit : Nat)
    (sink? : Option StderrSink := none)
    (readSize : USize := 8192) : IO StderrCapture := do
  if readSize == 0 then throw <| IO.userError "stderr capture read size must be positive"
  let tail ← Std.Mutex.new ByteArray.empty
  let sinkState ← Std.Mutex.new ({ sink? } : StderrSinkState)
  let drainTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    drainStderr source tail tailLimit sinkState readSize
  pure { tail, sinkState, drainTask }

def StderrCapture.snapshot (capture : StderrCapture) : IO String := do
  let bytes ← capture.tail.atomically get
  pure <| (String.fromUTF8? bytes).getD "<stderr tail is not valid UTF-8>"

/--
Stop persisting stderr and wait for any write already in progress. The returned failure is stable:
no later sink write can begin after this operation returns.
-/
def StderrCapture.disableSinkAndAwaitCurrentWrite
    (capture : StderrCapture) : IO (Option IO.Error) :=
  capture.sinkState.atomically do
    let state ← get
    set { state with sink? := none }
    pure state.failure?

/--
Wait within a bound for the drain task to finish, independently of any process wait. Completion
observes EOF or a source error; it does not establish that the writer exited. This operation never
tries to cancel the blocking pipe read: Lean task cancellation cannot interrupt synchronous
`Handle.read`. An unfinished drain returns `pipeStillOpen` and remains active.
-/
def StderrCapture.awaitCompletion
    (capture : StderrCapture)
    (timeoutMs : Nat := 1000) : IO StderrCaptureOutcome := do
  match ← Beam.waitTaskWithTimeout capture.drainTask timeoutMs with
  | some (.ok ()) => pure .drained
  | some (.error err) => pure <| .sourceFailed err
  | none => pure .pipeStillOpen

end Beam
