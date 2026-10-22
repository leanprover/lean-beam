/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Std.Sync.Mutex

namespace Beam.Mcp.StdioOutput

open Lean

/-- Internal storage limits. Each admission reserves a small terminal reply before work begins. -/
structure Limits where
  pendingBytes : Nat := 64 * 1024 * 1024
  rejectionBytes : Nat := 256 * 1024
  reservedResponseBytes : Nat := 4 * 1024
  responseBytes : Nat := 8 * 1024 * 1024
  diagnosticBytes : Nat := 256 * 1024
  diagnosticRecords : Nat := 64
  progressBytes : Nat := 64 * 1024

/-- Serialized protocol data; it carries no execution authority. -/
structure Frame where
  text : String
  label : String := ""

private def Frame.bytes (frame : Frame) : Nat :=
  frame.text.utf8ByteSize + frame.label.utf8ByteSize

-- Derive ASCII escaping from the selected Lean serializer, including DEL, rather than copying
-- its escape table. The closed table is shared by all preflight traversals.
private def asciiStringBytes : Array Nat :=
  (Array.range 128).map fun code =>
    (Json.str (String.singleton (Char.ofNat code))).compress.utf8ByteSize - 2

private def stringBytes (text : String) (limit : Nat) : Nat := Id.run do
  let mut bytes := 2
  for char in text do
    bytes := bytes +
      if char.toNat < 128 then asciiStringBytes[char.toNat]!
      else if char.toNat < 2048 then 2
      else if char.toNat < 65536 then 3
      else 4
    if bytes > limit then return limit + 1
  return bytes

/-- Count the existing serializer's output, stopping at the budget before allocating its string. -/
private partial def jsonBytes (json : Json) (limit : Nat) : Nat := Id.run do
  match json with
  | .null => return 4
  | .bool value => return if value then 4 else 5
  | .num value => return (toString value).utf8ByteSize
  | .str text => return stringBytes text limit
  | .arr values =>
      let mut bytes := 2
      let mut first := true
      for value in values do
        bytes := bytes + (if first then 0 else 1)
        if bytes > limit then return limit + 1
        bytes := bytes + jsonBytes value (limit - bytes)
        if bytes > limit then return limit + 1
        first := false
      return bytes
  | .obj fields =>
      let mut bytes := 2
      let mut first := true
      for (key, value) in fields do
        bytes := bytes + (if first then 0 else 1) + stringBytes key (limit - bytes) + 1
        if bytes > limit then return limit + 1
        bytes := bytes + jsonBytes value (limit - bytes)
        if bytes > limit then return limit + 1
        first := false
      return bytes

inductive OutputLimit where
  | tooLarge (limit : Nat)
  | capacity
  deriving BEq

private def encode (json : Json) (label : String) (limit : Nat) : Except OutputLimit Frame := do
  -- Labels are diagnostic only. Bound them independently before retaining them.
  let label := (label.take 256).toString
  if label.utf8ByteSize + 1 > limit ||
      jsonBytes json (limit - label.utf8ByteSize - 1) > limit - label.utf8ByteSize - 1 then
    throw (.tooLarge limit)
  let frame := { text := json.compress ++ "\n", label : Frame }
  if frame.bytes > limit then
    throw (.tooLarge limit)
  pure frame

private inductive SlotKind where
  | request
  | rejection

private structure Pending where
  kind : SlotKind := .request
  cancelled : Bool := false
  diagnostics : Array Frame := #[]
  diagnosticBytes : Nat := 0
  omittedDiagnostics : Nat := 0
  progress? : Option Frame := none
  response? : Option Frame := none
  done : IO.Promise (Except IO.Error Unit)

private def Pending.bytes (pending : Pending) (limits : Limits) : Nat :=
  limits.reservedResponseBytes + pending.diagnosticBytes +
    (pending.progress?.map Frame.bytes).getD 0 +
    ((pending.response?.map Frame.bytes).getD 0 - limits.reservedResponseBytes)

private inductive Phase where
  | accepting
  | draining
  | finished
  | failed (error : IO.Error)

private structure State where
  phase : Phase := .accepting
  nextId : Nat := 0
  pending : Std.TreeMap Nat Pending := {}
  pendingBytes : Nat := 0
  rejectionBytes : Nat := 0

/-- Keep accounting in one pure transition for insertion, replacement, and retirement. -/
private def State.replace (current : State) (limits : Limits) (id : Nat)
    (next? : Option Pending) : State := Id.run do
  let previous? := current.pending.get? id
  let some reference := previous?.or next? | return current
  let oldBytes := (previous?.map (·.bytes limits)).getD 0
  let newBytes := (next?.map (·.bytes limits)).getD 0
  let pending := match next? with
    | some next => current.pending.insert id next
    | none => current.pending.erase id
  match reference.kind with
  | .request => return { current with
      pending := pending
      pendingBytes := current.pendingBytes - oldBytes + newBytes }
  | .rejection => return { current with
      pending := pending
      rejectionBytes := current.rejectionBytes - oldBytes + newBytes }

private def State.fits (current : State) (limits : Limits) : Bool :=
  current.pendingBytes <= limits.pendingBytes && current.rejectionBytes <= limits.rejectionBytes

/-- One writer owns stdout. Pending slots contain only text and delivery promises. -/
structure Writer where
  private limits : Limits
  private state : Std.Mutex State
  private available : Std.Condvar
  private outcome : IO.Promise (Except IO.Error Unit)
  private finished : IO.Promise (Except IO.Error Unit)

/-- An exact private admission, independent of reusable JSON-RPC IDs. -/
structure Slot where
  private writer : Writer
  private id : Nat
  private done : IO.Promise (Except IO.Error Unit)

/-- Logical outcome: failures settle immediately, including while physical output is blocked. -/
def Writer.outcomeTask (writer : Writer) : Task (Option (Except IO.Error Unit)) := writer.outcome.result?
def Writer.finishedTask (writer : Writer) : Task (Option (Except IO.Error Unit)) := writer.finished.result?
def Slot.deliveryTask (slot : Slot) : Task (Option (Except IO.Error Unit)) := slot.done.result?

private def failState (error : IO.Error) : Std.AtomicT State IO (Option (Array Pending)) := do
  let current ← get
  match current.phase with
  | .failed _ | .finished => pure none
  | _ =>
      set { current with phase := .failed error, pending := {}, pendingBytes := 0, rejectionBytes := 0 }
      pure <| some <| current.pending.toArray.map Prod.snd

private def Writer.publishFailure (writer : Writer) (error : IO.Error) (pending : Array Pending) : IO Unit := do
  for slot in pending do slot.done.resolve (.error error)
  writer.outcome.resolve (.error error)
  writer.available.notifyAll

/-- Logical failure never joins a blocked physical write. -/
def Writer.fail (writer : Writer) (error : IO.Error) : IO Unit := do
  let some pending ← writer.state.atomically (failState error) | return
  writer.publishFailure error pending

/-- Try to reserve a small terminal reply. Normal overload never fails the session. -/
def Writer.tryReserve (writer : Writer) : IO (Option Slot) := do
  let done ← IO.Promise.new
  let id? ← writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | .draining | .finished => throw <| IO.userError "MCP output is draining"
    | .accepting =>
        let id := current.nextId
        let next := current.replace writer.limits id (some { done })
        if !next.fits writer.limits then return none
        set { next with nextId := id + 1 }
        pure (some id)
  pure <| id?.map fun id => { writer, id, done }

/-- Reject bursts from a separate budget. Only the input reader waits when it too is full. -/
def Writer.reserveRejection (writer : Writer) : IO Slot := do
  let done ← IO.Promise.new
  let id ← writer.state.atomicallyOnce writer.available
    (do
      let current ← get
      match current.phase with
      | .accepting => pure <|
          current.rejectionBytes + writer.limits.reservedResponseBytes <= writer.limits.rejectionBytes
      | _ => pure true)
    (do
      let current ← get
      match current.phase with
      | .failed error => throw error
      | .draining | .finished => throw <| IO.userError "MCP output is draining"
      | .accepting =>
          let id := current.nextId
          let next := current.replace writer.limits id (some { kind := .rejection, done })
          set { next with nextId := id + 1 }
          pure id)
  pure { writer, id, done }

private def Slot.isOpen (slot : Slot) : IO Bool :=
  slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ => pure <| (current.pending.get? slot.id).any (fun pending => !pending.cancelled && pending.response?.isNone)

private def Slot.encode? (slot : Slot) (json : Json) (label : String) (limit : Nat) : IO (Option Frame) := do
  if !(← slot.isOpen) then return none
  pure (encode json label limit).toOption

private def Slot.offer (slot : Slot) (frame : Frame) (progress : Bool) : IO Unit := do
  slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ =>
        let some pending := current.pending.get? slot.id | return
        if pending.cancelled || pending.response?.isSome then return
        if progress then
          let next := current.replace slot.writer.limits slot.id (some { pending with progress? := some frame })
          if next.fits slot.writer.limits then set next
          else set <| current.replace slot.writer.limits slot.id (some { pending with progress? := none })
        else
          let next := current.replace slot.writer.limits slot.id (some { pending with
            diagnostics := pending.diagnostics.push frame
            diagnosticBytes := pending.diagnosticBytes + frame.bytes })
          if pending.omittedDiagnostics > 0 ||
              pending.diagnostics.size >= slot.writer.limits.diagnosticRecords ||
              pending.diagnosticBytes + frame.bytes > slot.writer.limits.diagnosticBytes ||
              !next.fits slot.writer.limits then
            set <| current.replace slot.writer.limits slot.id (some { pending with
              omittedDiagnostics := pending.omittedDiagnostics + 1 })
          else set next
  slot.writer.available.notifyOne

/-- Retain a bounded diagnostic prefix and count omissions without stalling execution. -/
def Slot.diagnostic (slot : Slot) (json : Json) (label : String := "") : IO Unit := do
  if !(← slot.isOpen) then return
  match encode json label slot.writer.limits.diagnosticBytes with
  | .ok frame => slot.offer frame false
  | .error _ =>
      slot.writer.state.atomically do
        let current ← get
        let some pending := current.pending.get? slot.id | return
        if pending.cancelled || pending.response?.isSome then return
        set <| current.replace slot.writer.limits slot.id (some { pending with
          omittedDiagnostics := pending.omittedDiagnostics + 1 })

/-- Only the latest unsent progress update is useful. -/
def Slot.progress (slot : Slot) (json : Json) (label : String := "") : IO Unit := do
  let some frame ← slot.encode? json label slot.writer.limits.progressBytes | return
  slot.offer frame true

/-- Accept a terminal response with an exact omission count. The pure projection is not retained.
An oversized response leaves the reservation open so its caller can send a small error instead. -/
private def Slot.accept (slot : Slot) (response : Nat → Json) (label : String)
    (reserved : Bool) : IO (Except OutputLimit Unit) := do
  let result ← slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ =>
        let some pending := current.pending.get? slot.id | return .ok ()
        if pending.cancelled || pending.response?.isSome then return .ok ()
        let limit := match pending.kind with
          | .request => if reserved then slot.writer.limits.reservedResponseBytes else slot.writer.limits.responseBytes
          | .rejection => slot.writer.limits.reservedResponseBytes
        let frame ← match encode (response pending.omittedDiagnostics) label limit with
          | .ok frame => pure frame
          | .error error => return .error error
        let next := current.replace slot.writer.limits slot.id (some { pending with
          response? := some frame, progress? := none })
        if !next.fits slot.writer.limits then return .error .capacity
        set next
        return .ok ()
  slot.writer.available.notifyOne
  pure result

/-- Successful results may claim extra shared storage without waiting for stdout. -/
def Slot.respond (slot : Slot) (response : Nat → Json) (label : String := "") :
    IO (Except OutputLimit Unit) :=
  slot.accept response label false

/-- A small terminal error uses only storage already reserved before execution. -/
def Slot.respondReserved (slot : Slot) (response : Nat → Json) (label : String := "") :
    IO (Except OutputLimit Unit) :=
  slot.accept response label true

/-- Stop publishers but retain the execution's reservation until cleanup finishes. -/
def Slot.cancel (slot : Slot) : IO Unit := do
  slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return
    if pending.response?.isSome then return
    set <| current.replace slot.writer.limits slot.id (some { pending with
      cancelled := true, diagnostics := #[], diagnosticBytes := 0, progress? := none })

/-- Release after execution cleanup. An accepted terminal response keeps its reservation. -/
def Slot.release (slot : Slot) : IO Unit := do
  let removed ← slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return false
    if pending.response?.isSome then return false
    set <| current.replace slot.writer.limits slot.id none
    return true
  if removed then slot.done.resolve (.ok ())
  slot.writer.available.notifyAll

private structure Delivery where
  id : Nat
  frame : Frame
  terminal : Bool

private def select (current : State) : Option Delivery := Id.run do
  -- Ready responses, including their retained diagnostics, take priority over live progress.
  for (id, pending) in current.pending do
    if pending.response?.isSome then
      if let some frame := pending.diagnostics[0]? then return some { id, frame, terminal := false }
      if let some frame := pending.response? then return some { id, frame, terminal := true }
  for (id, pending) in current.pending do
    if let some frame := pending.diagnostics[0]? then return some { id, frame, terminal := false }
    if let some frame := pending.progress? then return some { id, frame, terminal := false }
  return none

private def Writer.take (writer : Writer) : IO (Option Delivery) :=
  writer.state.atomicallyOnce writer.available
    (do
      let current ← get
      match current.phase with
      | .failed _ => pure true
      | .draining | .finished => pure (current.pending.isEmpty || (select current).isSome)
      | .accepting => pure (select current).isSome)
    (do
      let current ← get
      match current.phase with
      | .failed error => throw error
      | _ =>
          let some delivery := select current | return none
          if !delivery.terminal then
            let some pending := current.pending.get? delivery.id | return none
            let pending := if pending.diagnostics.isEmpty then { pending with progress? := none }
              else { pending with
                diagnostics := pending.diagnostics.extract 1 pending.diagnostics.size
                diagnosticBytes := pending.diagnosticBytes - delivery.frame.bytes }
            set <| current.replace writer.limits delivery.id (some pending)
          pure (some delivery))

private partial def Writer.run (writer : Writer) (write : Frame → IO Unit) : IO Unit := do
  let some delivery ← writer.take | return
  -- This is the only physical output call. No transport or coordinator lock is held.
  write delivery.frame
  if delivery.terminal then
    let done? ← writer.state.atomically do
      let current ← get
      let some pending := current.pending.get? delivery.id | return none
      set <| current.replace writer.limits delivery.id none
      pure (some pending.done)
    if let some done := done? then done.resolve (.ok ())
    writer.available.notifyAll
  writer.run write

/-- Commit normal completion against concurrent failure and retain the first failed-state cause. -/
private def Writer.settle (writer : Writer) : IO (Except IO.Error Unit) :=
  writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => pure (.error error)
    | _ =>
        set { current with phase := .finished }
        pure (.ok ())

def start (write : Frame → IO Unit) (limits : Limits := {}) : IO Writer := do
  if limits.reservedResponseBytes == 0 || limits.pendingBytes < limits.reservedResponseBytes ||
      limits.rejectionBytes < limits.reservedResponseBytes then
    throw <| IO.userError "MCP output budgets must each hold a nonempty reserved response"
  let writer : Writer := {
    limits, state := ← Std.Mutex.new {}, available := ← Std.Condvar.new
    outcome := ← IO.Promise.new, finished := ← IO.Promise.new
  }
  try
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      try writer.run write
      catch error => writer.fail error
      let result ← writer.settle
      -- Every observer has a producer on normal completion too; a failure-only promise would be
      -- orphaned when the writer retires and could race successful completion with `none`.
      writer.outcome.resolve result
      writer.finished.resolve result
    pure writer
  catch error =>
    writer.fail error
    throw error

/-- Close new-slot admission without waiting. Existing slots may still respond or release after cleanup. -/
def Writer.finish (writer : Writer) : IO Unit := do
  writer.state.atomically do
    let current ← get
    match current.phase with
    | .accepting => set { current with phase := .draining }
    | _ => pure ()
  writer.available.notifyAll

end Beam.Mcp.StdioOutput
