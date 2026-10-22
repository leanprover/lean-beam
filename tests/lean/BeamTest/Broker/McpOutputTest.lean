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

private def checkBlockedWriter : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let first ← writer.reserve
    first.respond (.str "first")
    await entered
    let second ← writer.reserve
    writer.finish
    -- Execution may finish after EOF closed new admission. Its reserved response still drains.
    second.respond (.str "second")
    requireFailure "late admission cannot invalidate accepted responses" (← attempt writer.reserve)
    require "blocked output leaves delivery pending"
      (!(← IO.hasFinished first.deliveryTask) && !(← IO.hasFinished second.deliveryTask))
    require "finishing never joins a blocked writer" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireSuccess (← awaitTask first.deliveryTask)
    requireSuccess (← awaitTask second.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    require "one writer preserves complete response frames"
      ((← frames.get) == #["\"first\"\n", "\"second\"\n"])
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkRetiredWriterOutcome : IO Unit := do
  let outcome ← do
    let writer ← start fun _ => pure ()
    let slot ← writer.reserve
    slot.respond (.str "response")
    let outcome := writer.outcomeTask
    writer.finish
    pure outcome
  -- Drop the owner's writer/slot references before observing completion, as the EOF supervisor
  -- does after cleanup. Normal retirement must produce success, not an orphaned promise.
  requireSuccess (← awaitTask outcome)

private def checkReservationCapacity : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start (limits := { requests := 2 }) fun _ => do
    entered.resolve ()
    await release
  try
    let executing ← writer.reserve
    let writing ← writer.reserve
    writing.respond (.str "response")
    await entered
    requireFailure "running and physically writing requests both reserve capacity" (← attempt writer.reserve)
    discard <| awaitTask writer.outcomeTask
    requireFailure "execution slot learns failure before stdout resumes" (← awaitTask executing.deliveryTask)
    requireFailure "writing slot learns failure before stdout resumes" (← awaitTask writing.deliveryTask)
    require "logical failure does not claim physical completion" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireFailure "writer retains failure after the pipe resumes" (← awaitTask writer.finishedTask)
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkFirstFailure : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start fun _ => do
    entered.resolve ()
    await release
  try
    let slot ← writer.reserve
    slot.respond (.str "blocked")
    await entered
    let original := IO.userError "first failure"
    let state := (outputPrivate% Beam.Mcp.StdioOutput.Writer.state) writer
    let some pending ← state.atomically ((outputPrivate% Beam.Mcp.StdioOutput.failState) original)
      | throw <| IO.userError "fixture did not own the first failure transition"
    -- Pause the first failure between its locked transition and unlocked publication. A competing
    -- closer must not publish a different cause while the original owner is paused.
    writer.fail (IO.userError "later failure")
    require "only the first failure owner may publish" (!(← IO.hasFinished writer.outcomeTask))
    (outputPrivate% Beam.Mcp.StdioOutput.Writer.publishFailure) writer original pending
    match ← awaitTask writer.outcomeTask with
    | .ok () => throw <| IO.userError "failed session reported success"
    | .error error => require "session observes the first failure" (error.toString.contains "first failure")
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
    let blocker ← writer.reserve
    blocker.respond (.str "blocker")
    await entered
    let complete ← writer.reserve
    complete.diagnostic (.str "log1")
    complete.progress (.str "old")
    complete.diagnostic (.str "log2")
    complete.progress (.str "new")
    -- Required diagnostics and progress cannot consume reserved terminal capacity.
    complete.respond (.str "result")
    let live ← writer.reserve
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
    let frames ← frames.get
    require "required diagnostics precede response and completion removes obsolete progress"
      (frames.extract 0 4 == #["\"blocker\"\n", "\"log1\"\n", "\"log2\"\n", "\"result\"\n"])
    require "replaced progress is never delivered" (!frames.contains "\"old live\"\n")
  finally
    release.resolve ()
    writer.fail (IO.userError "fixture cleanup")
    discard <| awaitTask writer.finishedTask

private def checkDiagnosticOverflow (limits : Limits) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let writer ← start (limits := limits) fun _ => do
    entered.resolve ()
    await release
  try
    let blocker ← writer.reserve
    blocker.respond (.str "blocker")
    await entered
    let slot ← writer.reserve
    slot.diagnostic (.str "required")
    slot.progress (.str "replaceable")
    requireFailure "diagnostics fail explicitly instead of being silently replaced"
      (← attempt <| slot.diagnostic (.str "overflow"))
    discard <| awaitTask writer.outcomeTask
    requireFailure "diagnostic overflow settles every reserved slot" (← awaitTask slot.deliveryTask)
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkEncodedSize : IO Unit := do
  -- Exercise UTF-8, control escapes, quotes, metadata, and container delimiters at exact limits.
  for json in #[Json.str "αβ", .str "\x01\n\"\\", .arr #[], .arr #[.null, .bool true],
      Json.mkObj [("α", .str "\r"), ("empty", Json.mkObj [])]] do
    let expected := json.compress ++ "\n"
    let writer ← start (limits := { responseBytes := expected.utf8ByteSize }) fun frame =>
      require "preflight uses the existing JSON serializer" (frame.text == expected)
    let slot ← writer.reserve
    slot.respond json
    writer.finish
    requireSuccess (← awaitTask slot.deliveryTask)
    requireSuccess (← awaitTask writer.finishedTask)
    let oversized ← start (limits := { responseBytes := expected.utf8ByteSize - 1 }) fun _ =>
      throw <| IO.userError "oversized frame reached physical output"
    let slot ← oversized.reserve
    requireFailure "encoded byte budget rejects before physical output" (← attempt <| slot.respond json)
    requireFailure "oversized response fails the transport" (← awaitTask oversized.finishedTask)

private def checkCancelledReservation : IO Unit := do
  let writer ← start (limits := { requests := 1 }) fun _ => pure ()
  let running ← writer.reserve
  running.cancel
  requireFailure "cancellation retains capacity until execution cleanup" (← attempt writer.reserve)
  requireFailure "cancelled execution retains session failure" (← awaitTask running.deliveryTask)
  requireFailure "capacity failure settles the writer" (← awaitTask writer.finishedTask)

private def checkCancellationAndReuse : IO Unit := do
  let writer ← start (limits := { requests := 1, progressBytes := 1, responseBytes := 32 }) fun _ => pure ()
  let retired ← writer.reserve
  retired.cancel
  retired.release
  let current ← writer.reserve
  -- Model encoding begun before retirement and completed after replacement admission.
  require "retired encoder cannot fail replacement work"
    (!(← (outputPrivate% Beam.Mcp.StdioOutput.Slot.failIfOpen) retired (IO.userError "late encoding failure")))
  retired.progress (.str "late oversized progress")
  retired.respond (.str "late")
  require "late exact-generation publisher cannot complete a replacement" (!(← IO.hasFinished current.deliveryTask))
  current.respond (.str "current")
  writer.finish
  requireSuccess (← awaitTask current.deliveryTask)
  requireSuccess (← awaitTask writer.finishedTask)

private def checkWriteFailure : IO Unit := do
  let writer ← start fun _ => throw <| IO.userError "MCP output fixture write failure"
  let response ← writer.reserve
  response.respond (.str "response")
  discard <| awaitTask writer.outcomeTask
  requireFailure "write failure settles delivery" (← awaitTask response.deliveryTask)
  requireFailure "physical writer reports failure" (← awaitTask writer.finishedTask)
  requireFailure "write failure closes admission" (← attempt writer.reserve)

def run : IO Unit := do
  checkBlockedWriter
  checkRetiredWriterOutcome
  checkReservationCapacity
  checkFirstFailure
  checkNotificationBudgets
  checkDiagnosticOverflow { diagnosticRecords := 1 }
  checkDiagnosticOverflow { diagnosticBytes := 20 }
  checkEncodedSize
  checkCancelledReservation
  checkCancellationAndReuse
  checkWriteFailure

end BeamTest.Broker.McpOutputTest
