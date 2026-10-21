/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.StdioOutput
import BeamTest.Broker.JsonAssert

open Beam.Mcp.StdioOutput
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpOutputTest

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
    let first ← writer.submit { text := "first\n" }
    await entered
    let second ← writer.submit { text := "second\n" }
    writer.finish
    requireFailure "late submission cannot invalidate accepted frames"
      (← attempt <| writer.submit { text := "late\n" })
    require "blocked output leaves delivery pending" (!(← IO.hasFinished first) && !(← IO.hasFinished second))
    require "finishing never joins a blocked writer" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireSuccess (← awaitTask first)
    requireSuccess (← awaitTask second)
    requireSuccess (← awaitTask writer.finishedTask)
    require "one writer preserves complete frame order" ((← frames.get) == #["first\n", "second\n"])
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkCapacity (limits : Limits) (firstFrame secondFrame : String) : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start (limits := limits) fun frame => do
    entered.resolve ()
    await release
    frames.modify (·.push frame.text)
  try
    let first ← writer.submit { text := firstFrame }
    await entered
    requireFailure "capacity includes in-flight output" (← attempt <| writer.submit { text := secondFrame })
    discard <| awaitTask writer.failureTask
    -- These complete before releasing the physical write: the session owner need not join it.
    requireFailure "failed delivery is independently observable" (← awaitTask first)
    requireFailure "failed queue cannot accept replacement work" (← attempt <| writer.submit { text := "late" })
    require "logical failure does not claim physical completion" (!(← IO.hasFinished writer.finishedTask))
    release.resolve ()
    requireFailure "writer retains failure after the pipe resumes" (← awaitTask writer.finishedTask)
    require "unsent frames are discarded on failure" ((← frames.get) == #[firstFrame])
  finally
    release.resolve ()
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkOversizedFrame : IO Unit := do
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← start (limits := { frameBytes := 3 }) fun frame => frames.modify (·.push frame.text)
  try
    requireFailure "frame size counts encoded UTF-8 bytes" (← attempt <| writer.submit { text := "αβ" })
    discard <| awaitTask writer.failureTask
    requireFailure "oversized output fails the transport" (← awaitTask writer.finishedTask)
    require "oversized output is never partially submitted" (← frames.get).isEmpty
  finally
    writer.finish
    discard <| awaitTask writer.finishedTask

private def checkWriteFailure : IO Unit := do
  let writer ← start fun _ => throw <| IO.userError "MCP output fixture write failure"
  try
    let response ← writer.submit { text := "response\n" }
    discard <| awaitTask writer.failureTask
    requireFailure "write failure settles its delivery" (← awaitTask response)
    requireFailure "physical writer reports failure" (← awaitTask writer.finishedTask)
    requireFailure "write failure closes admission" (← attempt <| writer.submit { text := "late\n" })
  finally
    writer.finish
    discard <| awaitTask writer.finishedTask

def run : IO Unit := do
  checkBlockedWriter
  checkCapacity { messages := 1 } "first\n" "second\n"
  checkCapacity { bytes := 10 } "1234567" "8901"
  checkOversizedFrame
  checkWriteFailure

end BeamTest.Broker.McpOutputTest
