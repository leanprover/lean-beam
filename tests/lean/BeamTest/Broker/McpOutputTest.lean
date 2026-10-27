/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.StdioOutput
import BeamTest.Broker.JsonAssert

open Lean
open Beam.Mcp.StdioOutput
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpOutputTest

-- Access narrow transition boundaries without adding production fault-injection options.
local macro "outputPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Mcp.StdioOutput name.getId)

private def awaitTask (task : Task (Option α)) : IO α := do
  let some value ← IO.wait task
    | throw <| IO.userError "MCP output fixture dropped its promise"
  pure value

private def await (promise : IO.Promise α) : IO α := awaitTask promise.result?

private def requireSuccess (result : Except IO.Error Unit) : IO Unit := do
  match result with
  | .ok () => pure ()
  | .error error => throw error

private def requireFailure (label : String) (result : Except IO.Error α) : IO Unit := do
  match result with
  | .ok _ => throw <| IO.userError s!"{label}: expected failure"
  | .error _ => pure ()

private def attempt (action : IO α) : IO (Except IO.Error α) := do
  try pure (.ok (← action)) catch error => pure (.error error)

private def reserve (writer : Writer) : IO Slot := do
  let some slot ← writer.tryReserve
    | throw <| IO.userError "fixture unexpectedly exhausted output reservations"
  pure slot

private def respond (slot : Slot) (json : Json) : IO Unit := do
  match ← slot.respond (fun _ => json) with
  | .ok () => pure ()
  | .error _ => throw <| IO.userError "fixture response unexpectedly exceeded its budget"

private def requireEmptyBudget (writer : Writer) : IO Unit := do
  let current ← ((outputPrivate% Beam.Mcp.StdioOutput.Writer.state) writer).atomically get
  require "normal frame storage was fully released"
    ((outputPrivate% Beam.Mcp.StdioOutput.State.pendingBytes) current == 0)
  require "rejection storage was fully released"
    ((outputPrivate% Beam.Mcp.StdioOutput.State.rejectionBytes) current == 0)
  require "recovery storage was fully released"
    ((outputPrivate% Beam.Mcp.StdioOutput.State.recoveryBytes) current == 0)

private def checkBlockedWriter : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let first ← (reserve writer)
    respond first (.str "first")
    await entered
    let second ← (reserve writer)
    writer.finish
    -- Execution may finish after EOF closed new admission. Its reserved response still drains.
    respond second (.str "second")
    requireFailure "late admission cannot invalidate accepted responses" (← attempt (reserve writer))
    require "blocked output leaves delivery pending"
      (!(← IO.hasFinished first.deliveryTask) && !(← IO.hasFinished second.deliveryTask))
    require "finishing never joins a blocked writer" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireSuccess (← awaitTask first.deliveryTask)
    requireSuccess (← awaitTask second.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
    require "one writer preserves complete response frames"
      ((← frames.get) == #["\"first\"\n", "\"second\"\n"])
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkRetiredWriterOutcome : IO Unit := do
  let outcome ← do
    let writer ← start fun _ => pure ()
    let slot ← (reserve writer)
    respond slot (.str "response")
    let outcome := writer.outcomeTask
    writer.finish
    pure outcome
  -- Drop the owner's writer/slot references before observing completion, as the EOF supervisor
  -- does after cleanup. Normal retirement must produce success, not an orphaned promise.
  requireSuccess (← awaitTask outcome)
  let writer ← start fun _ => pure ()
  writer.finish
  requireSuccess (← awaitTask writer.outcomeTask)
  writer.fail (IO.userError "late failure after success")
  requireSuccess (← (outputPrivate% Beam.Mcp.StdioOutput.Writer.settle) writer)
  requireSuccess (← awaitTask writer.finishedTask)

private def checkReservationCapacity : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start (limits := { pendingBytes := 64, reservedResponseBytes := 32 }) fun _ => do
    entered.resolve ()
    await release
  try
    let executing ← reserve writer
    let writing ← reserve writer
    respond writing (.str "response")
    await entered
    require "running and physically writing requests both reserve capacity" (← writer.tryReserve).isNone
    require "reservation overload does not fail the session" (!(← IO.hasFinished writer.outcomeTask))
    executing.release
    let replacement ← reserve writer
    respond replacement (.str "next")
    writer.finish
    require "physical completion remains separate" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireSuccess (← awaitTask writing.deliveryTask)
    requireSuccess (← awaitTask replacement.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkRejectionBackpressure : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let waiterStarted ← IO.Promise.new
  let writer ← start (limits := {
      pendingBytes := 32, reservedResponseBytes := 32, rejectionBytes := 32 }) fun _ => do
    entered.resolve ()
    await release
  try
    let blocker ← reserve writer
    respond blocker (.str "blocked")
    await entered
    require "ordinary storage is full" (← writer.tryReserve).isNone
    let rejection ← writer.reserveRejection
    respond rejection (.str "busy")
    let waiter ← IO.asTask (prio := Task.Priority.dedicated) do
      waiterStarted.resolve ()
      writer.reserveRejection
    await waiterStarted
    require "only complete rejection saturation pauses the reader" (!(← IO.hasFinished waiter))
    require "saturation preserves the session" (!(← IO.hasFinished writer.outcomeTask))
    -- Both kinds of publisher and the writer remain independent of the paused reader.
    rejection.cancel
    release.resolve ()
    let replacement ← match ← IO.wait waiter with
      | .ok slot => pure slot
      | .error error => throw error
    respond replacement (.str "resumed")
    writer.finish
    requireSuccess (← awaitTask blocker.deliveryTask)
    requireSuccess (← awaitTask rejection.deliveryTask)
    requireSuccess (← awaitTask replacement.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

/-- Recovery admissions reserve from their own bounded budget while ordinary output is full. -/
private def checkRecoveryBudget : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start (limits := {
      pendingBytes := 32, reservedResponseBytes := 32, rejectionBytes := 32,
      recoveryBytes := 64 }) fun _ => do
    entered.resolve ()
    await release
  try
    let blocker ← reserve writer
    respond blocker (.str "blocked")
    await entered
    require "ordinary storage is full" (← writer.tryReserve).isNone
    let some first ← writer.tryReserve .recovery
      | throw <| IO.userError "recovery budget was denied by full ordinary storage"
    let some second ← writer.tryReserve .recovery
      | throw <| IO.userError "recovery budget denied its second reservation"
    require "recovery budget is bounded" (← writer.tryReserve .recovery).isNone
    require "recovery admissions do not enlarge ordinary storage" (← writer.tryReserve).isNone
    match ← first.respond (fun _ => .str (String.ofList (List.replicate 64 'x'))) with
    | .error _ => pure ()
    | .ok () => throw <| IO.userError "recovery response exceeded its budget"
    match ← first.respondReserved (fun _ => .str "limit") with
    | .ok () => pure ()
    | .error _ => throw <| IO.userError "recovery slot lost its reserved terminal reply"
    second.release
    let some reused ← writer.tryReserve .recovery
      | throw <| IO.userError "released recovery capacity was not reusable"
    respond reused (.str "reused")
    release.resolve ()
    writer.finish
    requireSuccess (← awaitTask blocker.deliveryTask)
    requireSuccess (← awaitTask first.deliveryTask)
    requireSuccess (← awaitTask reused.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkSharedResponseBudget : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start (limits := { pendingBytes := 64, reservedResponseBytes := 8 }) fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let large ← reserve writer
    let limited ← reserve writer
    let peer ← reserve writer
    respond large (.str "012345678901234567890123456789")
    await entered
    match ← limited.respond (fun _ => .str "012345678901234567890123456789") with
    | .error .capacity => pure ()
    | _ => throw <| IO.userError "shared storage did not refuse the second large result"
    let .ok () ← limited.respondReserved (fun _ => .str "error")
      | throw <| IO.userError "reserved terminal error lost its storage"
    respond peer (.num 42)
    writer.finish
    release.resolve ()
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
    require "only the affected result degrades" ((← frames.get).size == 3)
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkFirstFailure (physicalFailure : Bool) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start fun _ => do
    entered.resolve ()
    await release
    if physicalFailure then throw <| IO.userError "later physical write failure"
  try
    let slot ← (reserve writer)
    respond slot (.str "blocked")
    await entered
    let original := IO.userError "first failure"
    let state := (outputPrivate% Beam.Mcp.StdioOutput.Writer.state) writer
    let some pending ← state.atomically ((outputPrivate% Beam.Mcp.StdioOutput.failState) original)
      | throw <| IO.userError "fixture did not own the first failure transition"
    -- Pause the first failure between its locked transition and unlocked publication. A competing
    -- closer must not publish a different cause while the original owner is paused.
    writer.fail (IO.userError "later failure")
    require "a competing failure cannot publish another cause" (!(← IO.hasFinished writer.outcomeTask))
    -- Exercise successful settlement racing a committed-but-unpublished failure as well.
    requireFailure "normal settlement cannot override committed failure"
      (← (outputPrivate% Beam.Mcp.StdioOutput.Writer.settle) writer)
    release.resolve ()
    match ← awaitTask writer.finishedTask with
    | .ok () => throw <| IO.userError "physical completion lost committed failure"
    | .error error =>
        require "physical completion retains first cause" (error.toString.contains "first failure")
    match ← awaitTask writer.outcomeTask with
    | .ok () => throw <| IO.userError "failed session reported success"
    | .error error => require "session observes the first failure" (error.toString.contains "first failure")
    (outputPrivate% Beam.Mcp.StdioOutput.Writer.publishFailure) writer original pending
    match ← awaitTask slot.deliveryTask with
    | .ok () => throw <| IO.userError "failed slot reported success"
    | .error error => require "delivery retains the same failure" (error.toString.contains "first failure")
    release.resolve ()
    requireFailure "physical completion retains failure" (← awaitTask writer.finishedTask)
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkNotificationBudgets : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start (limits := { diagnosticBytes := 16, diagnosticRecords := 2, progressBytes := 16 }) fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let blocker ← (reserve writer)
    respond blocker (.str "blocker")
    await entered
    let complete ← (reserve writer)
    complete.diagnostic (.str "log1")
    complete.progress (.str "old")
    complete.diagnostic (.str "log2")
    complete.progress (.str "new")
    -- Diagnostics and progress cannot consume reserved terminal capacity.
    respond complete (.str "result")
    let live ← (reserve writer)
    live.progress (.str "old live")
    live.progress (.str "new live")
    -- Cancellation after acceptance cannot erase the result or its diagnostics.
    complete.cancel
    release.resolve ()
    requireSuccess (← awaitTask complete.deliveryTask)
    live.cancel
    live.release
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
    let frames ← frames.get
    require "retained diagnostics precede response and completion removes obsolete progress"
      (frames.extract 0 4 == #["\"blocker\"\n", "\"log1\"\n", "\"log2\"\n", "\"result\"\n"])
    require "replaced progress is never delivered" (!frames.contains "\"old live\"\n")
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkDiagnosticOverflow (limits : Limits) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start (limits := limits) fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let blocker ← (reserve writer)
    respond blocker (.str "blocker")
    await entered
    let slot ← (reserve writer)
    slot.diagnostic (.str "required")
    slot.progress (.str "replaceable")
    slot.diagnostic (.str "overflow")
    slot.diagnostic (.str "later")
    -- Once the prefix overflows, all subsequent diagnostics are counted, even if oversized.
    slot.diagnostic (.str (String.ofList (List.replicate 100 'x')))
    require "diagnostic overflow leaves the session healthy" (!(← IO.hasFinished writer.outcomeTask))
    let .ok () ← slot.respond (fun omitted => Json.mkObj [("omitted", toJson omitted)])
      | throw <| IO.userError "bounded omission report did not fit"
    let peer ← (reserve writer)
    respond peer (.str "peer")
    release.resolve ()
    writer.finish
    requireSuccess (← awaitTask slot.deliveryTask)
    requireSuccess (← awaitTask peer.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
    require "bounded diagnostics retain the prefix and explicitly count every omission"
      ((← frames.get) == #["\"blocker\"\n", "\"required\"\n", "{\"omitted\":3}\n", "\"peer\"\n"])
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkEncodedSize : IO Unit := do
  -- Exercise UTF-8, control escapes, quotes, metadata, and container delimiters at exact limits.
  for json in #[Json.str "αβ😀", .str "\x01\n\"\\",
      .str (String.ofList ((List.range 128).map Char.ofNat)),
      .num 0, .num (-12345), .arr #[], .arr #[.null, .bool true],
      Json.mkObj [("α", .str "\r"), ("empty", Json.mkObj [])]] do
    let expected := json.compress ++ "\n"
    let writer ← start (limits := { responseBytes := expected.utf8ByteSize }) fun frame =>
      require "preflight uses the existing JSON serializer" (frame.text == expected)
    let slot ← (reserve writer)
    respond slot json
    writer.finish
    requireSuccess (← awaitTask slot.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
    let oversized ← start (limits := { responseBytes := expected.utf8ByteSize - 1 }) fun _ =>
      throw <| IO.userError "oversized frame reached physical output"
    let slot ← (reserve oversized)
    match ← slot.respond (fun _ => json) with
    | .error (.tooLarge limit) =>
        require "oversized response reports its exact limit" (limit == expected.utf8ByteSize - 1)
    | .error .capacity => throw <| IO.userError "fixture unexpectedly exhausted shared storage"
    | .ok () => throw <| IO.userError "oversized response was accepted"
    require "oversized response leaves the session alive" (!(← IO.hasFinished oversized.outcomeTask))
    slot.release
    oversized.finish
    requireSuccess (← awaitTask oversized.finishedTask)

private def checkCancelledReservation : IO Unit := do
  let writer ← start (limits := { pendingBytes := 32, reservedResponseBytes := 32 }) fun _ => pure ()
  let running ← reserve writer
  running.cancel
  require "cancellation retains capacity until execution cleanup" (← writer.tryReserve).isNone
  require "cancellation does not fail unrelated work" (!(← IO.hasFinished writer.outcomeTask))
  running.release
  let next ← reserve writer
  respond next (.str "next")
  writer.finish
  requireSuccess (← awaitTask writer.finishedTask)

private def checkCancellationAndReuse : IO Unit := do
  let writer ← start (limits := { pendingBytes := 32, reservedResponseBytes := 32, progressBytes := 1, responseBytes := 32 }) fun _ => pure ()
  let retired ← (reserve writer)
  retired.cancel
  retired.release
  let current ← (reserve writer)
  -- A late oversized publisher cannot fail the session or affect replacement work.
  retired.progress (.str "late oversized progress")
  respond retired (.str "late")
  require "late exact-generation publisher cannot complete a replacement" (!(← IO.hasFinished current.deliveryTask))
  respond current (.str "current")
  writer.finish
  requireSuccess (← awaitTask current.deliveryTask)
  requireSuccess (← awaitTask writer.finishedTask)

private def checkWriteFailure : IO Unit := do
  let writer ← start fun _ => throw <| IO.userError "MCP output fixture write failure"
  let response ← (reserve writer)
  respond response (.str "response")
  discard <| awaitTask writer.outcomeTask
  requireFailure "write failure settles delivery" (← awaitTask response.deliveryTask)
  requireFailure "physical writer reports failure" (← awaitTask writer.finishedTask)
  requireFailure "write failure closes admission" (← attempt (reserve writer))

private def workspaceContext : Beam.Mcp.Server.WorkspaceTextContext := {
  requestId := .string "raw", tool := "lean_sync", policy := .request (some .info)
}

private def attachText (slot : Slot)
    (context : Beam.Mcp.Server.WorkspaceTextContext := workspaceContext) :
    IO Beam.WorkspaceOutput.Buffer := do
  let some buffer ← slot.attachWorkspaceOutput context
    | throw <| IO.userError "fixture unexpectedly exhausted workspace text storage"
  return buffer

private def awaitTextObserver (slot : Slot) : IO Unit := do
  let writer := (outputPrivate% Beam.Mcp.StdioOutput.Slot.writer) slot
  let id := (outputPrivate% Beam.Mcp.StdioOutput.Slot.id) slot
  let deadline := (← IO.monoMsNow) + 5000
  while true do
    let observing ← ((outputPrivate% Beam.Mcp.StdioOutput.Writer.state) writer).atomically do
      let pending := (outputPrivate% Beam.Mcp.StdioOutput.State.pending) (← get)
      let some pending := pending.get? id | return false
      return ((outputPrivate% Beam.Mcp.StdioOutput.Pending.text?) pending).any
        (outputPrivate% Beam.Mcp.StdioOutput.WorkspaceText.watching)
    if observing then return
    require "writer did not wait for an empty workspace buffer" ((← IO.monoMsNow) < deadline)
    IO.sleep 1

private def checkWorkspaceText : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start fun frame => do
    if (← frames.get).isEmpty then
      entered.resolve ()
      await release
    frames.modify (·.push frame.text)
  try
    let slot ← reserve writer
    let buffer ← attachText slot
    let some publisher ← buffer.borrow | throw <| IO.userError "new text buffer closed"
    -- Publish only after the physical writer is asleep on an otherwise empty outbox.
    awaitTextObserver slot
    publisher.offer .stderr "live"
    require "workspace text did not wake the writer before completion"
      (← Beam.waitTaskWithTimeout entered.result? 5000).isSome
    publisher.offer .stdout (String.ofList (List.replicate (2 * Beam.WorkspaceOutput.byteLimit) 'x'))
    let tail := String.singleton (Char.ofNat 1) ++ "🙂"
    publisher.offer .stdout tail
    publisher.retire
    respond slot (.str "done")
    require "completion reopened workspace publishing" (← buffer.borrow).isNone
    require "blocked presentation completed delivery" (!(← IO.hasFinished slot.deliveryTask))
    release.resolve ()
    requireSuccess (← awaitTask slot.deliveryTask)
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    let frames ← frames.get
    require "workspace tail did not precede the terminal response" (frames.back? == some "\"done\"\n")
    let mut received := ""
    let mut gaps := 0
    for frame in frames.pop do
      let json ← IO.ofExcept (Json.parse frame)
      let params ← requireObjVal "workspace notification" "params" json
      requireJsonString "workspace notification" "level" "info" params
      requireJsonString "workspace notification" "logger" "lake.output" params
      let data ← requireObjVal "workspace notification" "data" params
      requireJsonString "workspace association" "requestId" "raw" data
      requireJsonString "workspace association" "tool" "lean_sync" data
      received := received ++ (← IO.ofExcept (data.getObjValAs? String "text"))
      if ← IO.ofExcept (data.getObjValAs? Bool "omittedBefore") then gaps := gaps + 1
    require "workspace overflow lost its gap or retained tail"
      (received.startsWith "live" && received.endsWith tail && gaps == 1 &&
       received.utf8ByteSize <= Beam.WorkspaceOutput.byteLimit + 4)
    requireEmptyBudget writer
  finally
    release.resolve ()
    writer.fail (IO.userError "workspace text fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkWorkspaceBudget : IO Unit := do
  let writer ← start (limits := { pendingBytes := Beam.WorkspaceOutput.byteLimit + 80 * 1024 })
    fun _ => pure ()
  try
    let first ← reserve writer
    let second ← reserve writer
    discard <| attachText first
    require "workspace text escaped the shared storage budget"
      (← second.attachWorkspaceOutput workspaceContext).isNone
    first.release
    discard <| attachText second
    second.release
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    writer.fail (IO.userError "workspace budget fixture cleanup")
    discard <| awaitTask writer.finishedTask

  let writer ← start (limits := { responseBytes := 80 * 1024 }) fun _ => pure ()
  try
    let slot ← reserve writer
    let context := { workspaceContext with
      requestId := .string (String.ofList (List.replicate 6000 (Char.ofNat 1))) }
    require "text metadata omitted JSON escaping from its packet allowance"
      (← slot.attachWorkspaceOutput context).isNone
    require "disabled request logging reserved workspace text"
      (← slot.attachWorkspaceOutput { workspaceContext with policy := .request none }).isNone
    slot.release
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    writer.fail (IO.userError "workspace metadata fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkWorkspaceWakeups : IO Unit := do
  let delivered ← IO.mkRef 0
  let writer ← start fun _ => delivered.modify (· + 1)
  try
    let slot ← reserve writer
    let buffer ← attachText slot
    let some publisher ← buffer.borrow | throw <| IO.userError "new text buffer closed"
    for message in #["first wake", "second wake", "third wake"] do
      awaitTextObserver slot
      let previous ← delivered.get
      publisher.offer .stdout message
      let deadline := (← IO.monoMsNow) + 5000
      while (← delivered.get) == previous do
        require "workspace text reused a stale wakeup after draining" ((← IO.monoMsNow) < deadline)
        IO.sleep 1
    respond slot (.str "done")
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    requireEmptyBudget writer
  finally
    writer.fail (IO.userError "workspace wakeup fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkWorkspaceLogPolicy (enable : Bool) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start fun frame => do
    if (← frames.get).isEmpty then
      entered.resolve ()
      await release
    frames.modify (·.push frame.text)
  try
    let blocker ← reserve writer
    respond blocker (.str "blocker")
    await entered
    let protocol ← Std.Mutex.new <| Beam.Mcp.Server.ProtocolState.legacy {
      logLevel := if enable then .warning else .debug }
    let legacy ← reserve writer
    let buffer ← attachText legacy { workspaceContext with policy := .legacy protocol }
    let some publisher ← buffer.borrow | throw <| IO.userError "new text buffer closed"
    publisher.offer .stderr "legacy text"
    respond legacy (.str "legacy result")
    let modern ← reserve writer
    let buffer ← attachText modern
    let some publisher ← buffer.borrow | throw <| IO.userError "new text buffer closed"
    publisher.offer .stdout "modern text"
    respond modern (.str "modern result")
    protocol.atomically do
      set <| Beam.Mcp.Server.ProtocolState.legacy { logLevel := if enable then .debug else .warning }
    release.resolve ()
    requireSuccess (← awaitTask legacy.deliveryTask)
    requireSuccess (← awaitTask modern.deliveryTask)
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    let output := String.join (← frames.get).toList
    require "legacy text ignored delivery-time logging policy"
      (decide ((output.splitOn "legacy text").length > 1) == enable)
    require "legacy logging changes affected immutable modern policy"
      ((output.splitOn "modern text").length > 1)
  finally
    release.resolve ()
    writer.fail (IO.userError "workspace policy fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkWorkspaceCancellation : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start fun frame => do
    if (← frames.get).isEmpty then
      entered.resolve ()
      await release
    frames.modify (·.push frame.text)
  try
    let blocker ← reserve writer
    respond blocker (.str "blocker")
    await entered
    let cancelled ← reserve writer
    let buffer ← attachText cancelled
    let some publisher ← buffer.borrow | throw <| IO.userError "new text buffer closed"
    publisher.offer .stderr "cancelled text"
    cancelled.cancel
    publisher.offer .stderr "late text"
    require "cancelled MCP delivery retained workspace text"
      (match ← buffer.poll with | .closed => true | _ => false)
    cancelled.release
    let replacement ← reserve writer
    let buffer ← attachText replacement
    let some replacementPublisher ← buffer.borrow | throw <| IO.userError "replacement text buffer closed"
    replacementPublisher.offer .stdout "replacement text"
    respond replacement (.str "replacement result")
    release.resolve ()
    requireSuccess (← awaitTask replacement.deliveryTask)
    writer.finish
    requireSuccess (← awaitTask writer.finishedTask)
    let output := String.join (← frames.get).toList
    require "cancelled text leaked into replacement delivery"
      ((output.splitOn "cancelled text").length == 1 && (output.splitOn "late text").length == 1 &&
       (output.splitOn "replacement text").length > 1)
    requireEmptyBudget writer
  finally
    release.resolve ()
    writer.fail (IO.userError "workspace cancellation fixture cleanup")
    discard <| awaitTask writer.finishedTask

def run : IO Unit := do
  checkBlockedWriter
  checkRetiredWriterOutcome
  checkReservationCapacity
  checkRejectionBackpressure
  checkRecoveryBudget
  checkSharedResponseBudget
  checkFirstFailure false
  checkFirstFailure true
  checkNotificationBudgets
  checkDiagnosticOverflow { diagnosticRecords := 1 }
  checkDiagnosticOverflow { diagnosticBytes := 20 }
  checkDiagnosticOverflow { pendingBytes := 52, reservedResponseBytes := 8 }
  checkEncodedSize
  checkCancelledReservation
  checkCancellationAndReuse
  checkWriteFailure
  checkWorkspaceText
  checkWorkspaceBudget
  checkWorkspaceWakeups
  checkWorkspaceLogPolicy false
  checkWorkspaceLogPolicy true
  checkWorkspaceCancellation

end BeamTest.Broker.McpOutputTest
