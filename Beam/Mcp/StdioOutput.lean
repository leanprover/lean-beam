/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Std.Sync.Mutex

namespace Beam.Mcp.StdioOutput

open Lean

/-- Internal limits, reserved per request before broker admission. -/
structure Limits where
  requests : Nat := 32
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

private def stringBytes (text : String) (limit : Nat) : Nat := Id.run do
  let mut bytes := 2
  for char in text do
    bytes := bytes +
      if char == '"' || char == '\\' || char == '\n' || char == '\r' then 2
      else if char.toNat < 32 then 6
      else if char.toNat < 128 then 1
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

private def encode (json : Json) (label : String) (limit : Nat) : IO Frame := do
  -- Labels are diagnostic only. Bound them independently before retaining them.
  let label := (label.take 256).toString
  if label.utf8ByteSize + 1 > limit ||
      jsonBytes json (limit - label.utf8ByteSize - 1) > limit - label.utf8ByteSize - 1 then
    throw <| IO.userError "MCP output exceeds its frame limit"
  let frame := { text := json.compress ++ "\n", label : Frame }
  if frame.bytes > limit then
    throw <| IO.userError "MCP output exceeds its frame limit"
  pure frame

private structure Pending where
  cancelled : Bool := false
  diagnostics : Array Frame := #[]
  diagnosticBytes : Nat := 0
  progress? : Option Frame := none
  response? : Option Frame := none
  done : IO.Promise (Except IO.Error Unit)

private inductive Phase where
  | accepting
  | draining
  | failed (error : IO.Error)

private structure State where
  phase : Phase := .accepting
  nextId : Nat := 0
  pending : Std.TreeMap Nat Pending := {}

/-- One writer owns stdout. Pending slots contain only text and delivery promises. -/
structure Writer where
  private limits : Limits
  private state : Std.Mutex State
  private available : Std.Condvar
  private failure : IO.Promise IO.Error
  private finished : IO.Promise (Except IO.Error Unit)

/-- An exact private admission, independent of reusable JSON-RPC IDs. -/
structure Slot where
  private writer : Writer
  private id : Nat
  private done : IO.Promise (Except IO.Error Unit)

def Writer.failureTask (writer : Writer) : Task (Option IO.Error) := writer.failure.result?
def Writer.finishedTask (writer : Writer) : Task (Option (Except IO.Error Unit)) := writer.finished.result?
def Slot.deliveryTask (slot : Slot) : Task (Option (Except IO.Error Unit)) := slot.done.result?

private def failState (error : IO.Error) : Std.AtomicT State IO (Option (Array Pending)) := do
  let current ← get
  match current.phase with
  | .failed _ => pure none
  | _ =>
      set { current with phase := .failed error, pending := {} }
      pure <| some <| current.pending.toArray.map Prod.snd

private def Writer.publishFailure (writer : Writer) (error : IO.Error) (pending : Array Pending) : IO Unit := do
  for slot in pending do slot.done.resolve (.error error)
  writer.failure.resolve error
  writer.available.notifyAll

/-- Logical failure never joins a blocked physical write. -/
def Writer.fail (writer : Writer) (error : IO.Error) : IO Unit := do
  let some pending ← writer.state.atomically (failState error) | return
  writer.publishFailure error pending

/-- Reserve terminal capacity without waiting for the client. Exhaustion fails the session. -/
def Writer.reserve (writer : Writer) : IO Slot := do
  let done ← IO.Promise.new
  let result : Except (IO.Error × Array Pending) Nat ← writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | .draining => throw <| IO.userError "MCP output is draining"
    | .accepting =>
        if current.pending.size >= writer.limits.requests then
          let error := IO.userError "MCP output capacity exhausted"
          let pending ← failState error
          pure (.error (error, pending.getD #[]))
        else
          let id := current.nextId
          set { current with nextId := id + 1, pending := current.pending.insert id { done } }
          pure (.ok id)
  match result with
  | .error (error, pending) =>
      writer.publishFailure error pending
      throw error
  | .ok id => pure { writer, id, done }

private def Slot.isOpen (slot : Slot) : IO Bool :=
  slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ => pure <| (current.pending.get? slot.id).any (fun pending => !pending.cancelled && pending.response?.isNone)

/-- A stale producer cannot fail another admission between its identity check and failure. -/
private def Slot.failIfOpen (slot : Slot) (error : IO.Error) : IO Bool := do
  let pending? ← slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed retained => throw retained
    | _ =>
        let some pending := current.pending.get? slot.id | return none
        if pending.cancelled || pending.response?.isSome then return none
        failState error
  let some pending := pending? | return false
  slot.writer.publishFailure error pending
  pure true

private def Slot.encode? (slot : Slot) (json : Json) (label : String) (limit : Nat) : IO (Option Frame) := do
  if !(← slot.isOpen) then return none
  try return some (← encode json label limit)
  catch error =>
    if ← slot.failIfOpen error then throw error
    return none

private def Slot.offer (slot : Slot) (frame : Frame) (progress : Bool) : IO Unit := do
  let failure? ← slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ =>
        let some pending := current.pending.get? slot.id | return none
        if pending.cancelled || pending.response?.isSome then return none
        if progress then
          set { current with pending := current.pending.insert slot.id { pending with progress? := some frame } }
        else if pending.diagnostics.size >= slot.writer.limits.diagnosticRecords ||
            pending.diagnosticBytes + frame.bytes > slot.writer.limits.diagnosticBytes then
          let error := IO.userError "MCP required diagnostic capacity exhausted"
          let pending ← failState error
          return some (error, pending.getD #[])
        else
          set { current with pending := current.pending.insert slot.id { pending with
            diagnostics := pending.diagnostics.push frame
            diagnosticBytes := pending.diagnosticBytes + frame.bytes } }
        return none
  if let some (error, pending) := failure? then
    slot.writer.publishFailure error pending
    throw error
  slot.writer.available.notifyOne

/-- Required diagnostics retain their order; they cannot be replaced by progress. -/
def Slot.diagnostic (slot : Slot) (json : Json) (label : String := "") : IO Unit := do
  let some frame ← slot.encode? json label slot.writer.limits.diagnosticBytes | return
  slot.offer frame false

/-- Only the latest unsent progress update is useful. -/
def Slot.progress (slot : Slot) (json : Json) (label : String := "") : IO Unit := do
  let some frame ← slot.encode? json label slot.writer.limits.progressBytes | return
  slot.offer frame true

/-- Accept one terminal response, preserving required diagnostics and removing obsolete progress. -/
def Slot.respond (slot : Slot) (json : Json) (label : String := "") : IO Unit := do
  let some frame ← slot.encode? json label slot.writer.limits.responseBytes | return
  slot.writer.state.atomically do
    let current ← get
    match current.phase with
    | .failed error => throw error
    | _ =>
        let some pending := current.pending.get? slot.id | return
        if pending.cancelled || pending.response?.isSome then return
        set { current with pending := current.pending.insert slot.id { pending with
          response? := some frame, progress? := none } }
  slot.writer.available.notifyOne

/-- Stop publishers but retain the execution's reservation until cleanup finishes. -/
def Slot.cancel (slot : Slot) : IO Unit := do
  slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return
    if pending.response?.isSome then return
    set { current with pending := current.pending.insert slot.id { pending with
      cancelled := true, diagnostics := #[], diagnosticBytes := 0, progress? := none } }

/-- Release after execution cleanup. An accepted terminal response keeps its reservation. -/
def Slot.release (slot : Slot) : IO Unit := do
  let removed ← slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return false
    if pending.response?.isSome then return false
    set { current with pending := current.pending.erase slot.id }
    return true
  if removed then slot.done.resolve (.ok ())
  slot.writer.available.notifyAll

private structure Delivery where
  id : Nat
  frame : Frame
  terminal : Bool

private def select (current : State) : Option Delivery := Id.run do
  -- Ready responses, including their required diagnostics, take priority over live progress.
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
      | .draining => pure (current.pending.isEmpty || (select current).isSome)
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
            set { current with pending := current.pending.insert delivery.id pending }
          pure (some delivery))

private partial def Writer.run (writer : Writer) (write : Frame → IO Unit) : IO Unit := do
  let some delivery ← writer.take | return
  -- This is the only physical output call. No transport or coordinator lock is held.
  write delivery.frame
  if delivery.terminal then
    let done? ← writer.state.atomically do
      let current ← get
      let some pending := current.pending.get? delivery.id | return none
      set { current with pending := current.pending.erase delivery.id }
      pure (some pending.done)
    if let some done := done? then done.resolve (.ok ())
  writer.run write

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

/-- Close new-slot admission without waiting. Existing slots may still respond or release after cleanup. -/
def Writer.finish (writer : Writer) : IO Unit := do
  writer.state.atomically do
    let current ← get
    match current.phase with
    | .accepting => set { current with phase := .draining }
    | _ => pure ()
  writer.available.notifyAll

end Beam.Mcp.StdioOutput
