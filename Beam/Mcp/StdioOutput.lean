/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Std.Sync.Mutex
import Beam.Mcp.Reporting
import Beam.WorkspaceOutput

namespace Beam.Mcp.StdioOutput

open _root_.Lean

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

private structure WorkspaceText where
  buffer : Beam.WorkspaceOutput.Buffer
  context : Beam.Mcp.Server.WorkspaceTextContext
  encodedLimit : Nat
  ready : Task (Option Unit)
  watching : Bool := false
  closed : Bool := false

private def WorkspaceText.bytes (text : WorkspaceText) : Nat :=
  Beam.WorkspaceOutput.byteLimit + Beam.WorkspaceOutput.chunkLimit + text.encodedLimit

private structure Pending where
  kind : SlotKind := .request
  cancelled : Bool := false
  diagnostics : Array Frame := #[]
  diagnosticBytes : Nat := 0
  omittedDiagnostics : Nat := 0
  progress? : Option Frame := none
  text? : Option WorkspaceText := none
  response? : Option Frame := none
  done : IO.Promise (Except IO.Error Unit)

private def Pending.bytes (pending : Pending) (limits : Limits) : Nat :=
  limits.reservedResponseBytes + pending.diagnosticBytes +
    (pending.progress?.map Frame.bytes).getD 0 +
    (pending.text?.map WorkspaceText.bytes).getD 0 +
    ((pending.response?.map Frame.bytes).getD 0 - limits.reservedResponseBytes)

private inductive Phase where
  | accepting
  | draining
  | finished
  | failed (error : IO.Error)

private structure State where
  phase : Phase := .accepting
  nextId : Nat := 0
  nextTextId : Nat := 0
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

/-- Check the exact terminal-error envelope before accepting any work for its request ID. -/
def Writer.validateReserved (writer : Writer) (json : Json) (label : String) : Except OutputLimit Unit := do
  let _ ← encode json label writer.limits.reservedResponseBytes
  pure ()

private def failState (error : IO.Error) : Std.AtomicT State IO (Option (Array Pending)) := do
  let current ← get
  match current.phase with
  | .failed _ | .finished => pure none
  | _ =>
      set { current with phase := .failed error, pending := {}, pendingBytes := 0, rejectionBytes := 0 }
      pure <| some <| current.pending.toArray.map Prod.snd

private def Writer.publishFailure (writer : Writer) (error : IO.Error) (pending : Array Pending) : IO Unit := do
  for slot in pending do
    if let some text := slot.text? then text.buffer.discard
    slot.done.resolve (.error error)
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

/-- Reserve raw storage and one worst-case encoded packet before execution. The writer claims
the buffer directly; raw text never enters the diagnostic or replaceable-progress queues. -/
def Slot.attachWorkspaceOutput (slot : Slot) (context : Beam.Mcp.Server.WorkspaceTextContext) :
    IO (Option Beam.WorkspaceOutput.Buffer) := do
  if !context.policy.mayAllow .info then return none
  let probe := context.notification { source := .stderr, text := "" }
  let some envelope := (encode probe "workspace output" slot.writer.limits.responseBytes).toOption
    | return none
  let encodedLimit := envelope.bytes + 6 * Beam.WorkspaceOutput.chunkLimit
  if encodedLimit > slot.writer.limits.responseBytes then return none
  let buffer ← Beam.WorkspaceOutput.Buffer.create
  let ready ← buffer.readiness
  let attached ← slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return false
    if let .rejection := pending.kind then return false
    if pending.cancelled || pending.response?.isSome || pending.text?.isSome then return false
    let next := current.replace slot.writer.limits slot.id (some { pending with
      text? := some { buffer, context, encodedLimit, ready } })
    if !next.fits slot.writer.limits then return false
    set next
    return true
  if !attached then return none
  slot.writer.available.notifyOne
  return some buffer

private def Slot.sealWorkspaceOutput (slot : Slot) : IO Unit := do
  let buffer? ← slot.writer.state.atomically do
    let pending? := (← get).pending.get? slot.id
    pure <| pending?.bind fun pending => pending.text?.map (·.buffer)
  if let some buffer := buffer? then buffer.seal

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
  slot.sealWorkspaceOutput
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
  let buffer? ← slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return none
    if pending.response?.isSome then return none
    set <| current.replace slot.writer.limits slot.id (some { pending with
      cancelled := true, diagnostics := #[], diagnosticBytes := 0, progress? := none, text? := none })
    return pending.text?.map (·.buffer)
  if let some buffer := buffer? then buffer.discard

/-- Release after execution cleanup. An accepted terminal response keeps its reservation. -/
def Slot.release (slot : Slot) : IO Unit := do
  let removed? ← slot.writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? slot.id | return none
    if pending.response?.isSome then return none
    set <| current.replace slot.writer.limits slot.id none
    return some pending
  if let some removed := removed? then
    if let some text := removed.text? then text.buffer.discard
    slot.done.resolve (.ok ())
  slot.writer.available.notifyAll

private inductive Payload where
  | frame (value : Frame)
  | text (value : WorkspaceText)

private structure Delivery where
  id : Nat
  payload : Payload
  terminal : Bool

private def Writer.takeFrame (writer : Writer) (id : Nat) (pending : Pending)
    (frame : Frame) (terminal : Bool) : Std.AtomicT State IO Delivery := do
  unless terminal do
    let pending := if pending.diagnostics.isEmpty then { pending with progress? := none }
      else { pending with
        diagnostics := pending.diagnostics.extract 1 pending.diagnostics.size
        diagnosticBytes := pending.diagnosticBytes - frame.bytes }
    modify fun current => current.replace writer.limits id (some pending)
  return { id, payload := .frame frame, terminal }

private def Writer.takeText (id : Nat)
    (text : WorkspaceText) : Std.AtomicT State IO (Option Delivery) := do
  modify fun current => { current with nextTextId := id + 1 }
  return some { id, payload := .text text, terminal := false }

private def Writer.select (writer : Writer) : Std.AtomicT State IO (Option Delivery) := do
  let current ← get
  -- A completed request keeps its accepted bounded text tail before its terminal response.
  for (id, pending) in current.pending do
    if pending.response?.isSome then
      if let some frame := pending.diagnostics[0]? then
        return some (← writer.takeFrame id pending frame false)
      if let some text := pending.text? then
        unless text.closed do return ← Writer.takeText id text
      if let some frame := pending.response? then
        return some (← writer.takeFrame id pending frame true)
  for (id, pending) in current.pending do
    if let some frame := pending.diagnostics[0]? then
      return some (← writer.takeFrame id pending frame false)
    if let some frame := pending.progress? then
      return some (← writer.takeFrame id pending frame false)
  -- Round-robin live text so an output flood does not monopolize other helpers' feedback.
  for wrapped in [false, true] do
    for (id, pending) in current.pending do
      if (id < current.nextTextId) == wrapped then
        if let some text := pending.text? then
          if !text.closed && (← IO.hasFinished text.ready) then
            return ← Writer.takeText id text
  return none

private def Writer.hasDelivery (writer : Writer) : Std.AtomicT State IO Bool := do
  let current ← get
  for (_, pending) in current.pending do
    if pending.response?.isSome || !pending.diagnostics.isEmpty || pending.progress?.isSome then
      return true
    if let some text := pending.text? then
      if !text.closed && (← IO.hasFinished text.ready) then return true
  -- Each empty buffer has at most one outstanding observer. Its continuation takes this
  -- mutex before notifying, so a publication cannot race the condition-variable wait.
  for (id, pending) in current.pending do
    if let some text := pending.text? then
      if !text.closed && !text.watching then
        modify fun current => current.replace writer.limits id
          (some { pending with text? := some { text with watching := true } })
        let _ ← IO.mapTask (fun _ => do
          writer.state.atomically do
            let current ← get
            if let some pending := current.pending.get? id then
              if let some text := pending.text? then
                set <| current.replace writer.limits id
                  (some { pending with text? := some { text with watching := false } })
          writer.available.notifyOne) text.ready (sync := false)
        pure ()
  return false

private partial def Writer.take (writer : Writer) : IO (Option Delivery) := do
  let delivery? ← writer.state.atomicallyOnce writer.available
    (do
      let current ← get
      match current.phase with
      | .failed _ => pure true
      | .draining | .finished =>
          if current.pending.isEmpty then pure true else writer.hasDelivery
      | .accepting => writer.hasDelivery)
    (do
      let current ← get
      match current.phase with
      | .failed error => throw error
      | _ => writer.select)
  if delivery?.isSome then return delivery?
  let finished ← writer.state.atomically do
    let current ← get
    return current.pending.isEmpty && (match current.phase with | .accepting => false | _ => true)
  if finished then return none
  writer.take

private def Writer.refreshText (writer : Writer) (id : Nat)
    (ready : Task (Option Unit)) (closed : Bool := false) : IO Unit :=
  writer.state.atomically do
    let current ← get
    let some pending := current.pending.get? id | return
    let some text := pending.text? | return
    -- Preserve the current observer flag: its continuation can run while we claim text.
    set <| current.replace writer.limits id
      (some { pending with text? := some { text with ready, closed } })

private partial def Writer.run (writer : Writer) (write : Frame → IO Unit) : IO Unit := do
  let some delivery ← writer.take | return
  -- This is the only physical output call. No transport or coordinator lock is held.
  match delivery.payload with
  | .frame frame => write frame
  | .text text =>
      -- Buffer claims, logging policy reads, encoding and writes all occur outside the outbox lock.
      match ← text.buffer.poll with
      | .chunk chunk =>
          writer.refreshText delivery.id (← text.buffer.readiness)
          if (← text.context.policy.minimumLogLevel?).any (·.allows .info) then
            let frame ← IO.ofExcept <|
              (encode (text.context.notification chunk) "workspace output" text.encodedLimit).mapError fun _ =>
                IO.userError "workspace output exceeded its reserved encoded packet allowance"
            write frame
      | .waiting ready => writer.refreshText delivery.id ready
      | .closed => writer.refreshText delivery.id text.ready true
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
