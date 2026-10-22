/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.Broker.Transport
import Beam.WorkspaceOutput

open Lean

namespace Beam.Broker.Output

-- Preserve the existing per-frame diagnostic allowance across bounded pending delivery.
private def diagnosticBytes : Nat := Transport.maxFrameBytes
private def diagnosticRecords : Nat := 64
private def progressBytes : Nat := 64 * 1024

private structure Frame where
  value : StreamMessage
  bytes : Nat

private inductive Phase where
  | accepting
  | cancelled
  | closed
  deriving BEq

private structure State where
  ready : IO.Promise Unit
  diagnostics : Array Frame := #[]
  bytes : Nat := 0
  progress? : Option Frame := none
  phase : Phase := .accepting
  failure? : Option IO.Error := none

/-- One connection's notifications. The text buffer is consumed directly, never copied here. -/
structure Queue where
  private state : Std.Mutex State
  text : Beam.WorkspaceOutput.Buffer

def Queue.create (text : Beam.WorkspaceOutput.Buffer) : IO Queue := do
  pure { state := ← Std.Mutex.new { ready := ← IO.Promise.new }, text }

private def State.empty (state : State) : Bool :=
  state.diagnostics.isEmpty && state.progress?.isNone

private def Queue.offer (queue : Queue) (message : StreamMessage) (progress : Bool) : IO Unit := do
  let frame : Frame := { value := message, bytes := (toJson message).compress.utf8ByteSize }
  let ready? ← queue.state.atomically do
    let state ← get
    if state.phase == .closed || state.failure?.isSome ||
        (progress && state.phase == .cancelled) then return none
    let failure? :=
      if frame.bytes > (if progress then progressBytes else diagnosticBytes) then
        some <| IO.userError "broker notification exceeds its frame budget"
      else if !progress && (state.diagnostics.size >= diagnosticRecords ||
          state.bytes + frame.bytes > diagnosticBytes) then
        some <| IO.userError "broker required diagnostic capacity exhausted"
      else none
    if let some error := failure? then
      set { state with failure? := some error, diagnostics := #[], bytes := 0, progress? := none }
      return some state.ready
    if progress then
      set { state with progress? := some frame }
    else
      set { state with
        diagnostics := state.diagnostics.push frame
        bytes := state.bytes + frame.bytes }
    return if state.empty then some state.ready else none
  if let some ready := ready? then ready.resolve ()

def Queue.progress (queue : Queue) (id? : Option String) (progress : SyncFileProgress) : IO Unit :=
  queue.offer (.fileProgress id? progress) true

def Queue.diagnostic (queue : Queue) (id? : Option String) (diagnostic : StreamDiagnostic) : IO Unit :=
  queue.offer (.diagnostic id? diagnostic) false

def Queue.failed (queue : Queue) : IO Bool :=
  queue.state.atomically do pure (← get).failure?.isSome

/-- Cancellation drops optional presentation, independently of required diagnostics. -/
def Queue.cancelOptional (queue : Queue) : IO Unit := do
  queue.text.discard
  let ready ← queue.state.atomically do
    let state ← get
    let next := { state with
      progress? := none
      phase := if state.phase == Phase.closed then Phase.closed else Phase.cancelled }
    -- Wake observers of the discarded progress, then let an empty live queue sleep
    -- on a new generation while execution cleanup or required diagnostics are pending.
    let ready ← if next.empty && next.phase != .closed then IO.Promise.new else pure next.ready
    set { next with ready }
    return state.ready
  ready.resolve ()

private def Queue.finish (queue : Queue) : IO Unit := do
  let ready ← queue.state.atomically do
    let state ← get
    set { state with phase := .closed }
    return state.ready
  ready.resolve ()

private inductive Read where
  | frame (value : StreamMessage)
  | waiting (ready : Task (Option Unit))
  | closed

private def Queue.poll (queue : Queue) : IO Read :=
  queue.state.atomically do
    let state ← get
    if let some error := state.failure? then throw error
    let (frame?, next) :=
      if let some frame := state.diagnostics[0]? then
        (some frame, { state with
          diagnostics := state.diagnostics.extract 1 state.diagnostics.size
          bytes := state.bytes - frame.bytes })
      else
        (state.progress?, { state with progress? := none })
    if let some frame := frame? then
      let ready ← if next.empty && next.phase != .closed then IO.Promise.new else pure next.ready
      set { next with ready }
      return .frame frame.value
    return if state.phase == .closed then .closed else .waiting state.ready.result?

private partial def drain
    (queue : Queue)
    (request : Task (Except IO.Error α))
    (response? : α → Option Response)
    (requestReady : Task (Option Unit))
    (id? : Option String)
    (write : StreamMessage → IO Unit)
    (terminal? : Option α) : IO α := do
  let terminal? ← match terminal? with
    | some response => pure (some response)
    | none =>
        if ← IO.hasFinished request then
          let response ← IO.ofExcept (← IO.wait request)
          -- Execution, including helper and broker admission cleanup, is already complete.
          match response? response with
          | some (.errorResult failure) =>
              if failure.error.code == "requestCancelled" then queue.cancelOptional else queue.text.seal
          | _ => queue.text.seal
          queue.finish
          pure (some response)
        else pure none
  let mut waiting := []
  match ← queue.poll with
  | .frame frame =>
      write frame
      return ← drain queue request response? requestReady id? write terminal?
  | .waiting ready => waiting := ready :: waiting
  | .closed => pure ()
  match ← queue.text.poll with
  | .chunk chunk =>
      write (.workspaceOutput id? chunk)
      drain queue request response? requestReady id? write terminal?
  | .waiting ready =>
      if terminal?.isNone then waiting := requestReady :: waiting
      discard <| IO.waitAny (ready :: waiting)
      drain queue request response? requestReady id? write terminal?
  | .closed =>
      if let some response := terminal? then
        if let some response := response? response then write (.response id? response)
        return response
      discard <| IO.waitAny (requestReady :: waiting)
      drain queue request response? requestReady id? write terminal?

/-- Only this consumer writes frames. Producers and execution cleanup never wait for it. -/
def Queue.run
    (queue : Queue)
    (request : Task (Except IO.Error α))
    (response? : α → Option Response)
    (id? : Option String)
    (write : StreamMessage → IO Unit) : IO α :=
  drain queue request response? (request.map fun _ => some ()) id? write none

end Beam.Broker.Output
