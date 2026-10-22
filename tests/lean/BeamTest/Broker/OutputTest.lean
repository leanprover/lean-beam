/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Output

open Lean Beam.Broker

namespace BeamTest.Broker.OutputTest

private def require (message : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError message

private def checkCodec : IO Unit := do
  let chunk : Beam.WorkspaceOutput.Chunk := { source := .stderr, text := "α", omittedBefore := true }
  let message := StreamMessage.workspaceOutput (some "output-request") chunk
  match ← IO.ofExcept (fromJson? (α := StreamMessage) (toJson message)) with
  | .workspaceOutput id? actual =>
      require "workspace output codec lost identity or gap" (id? == some "output-request" && actual == chunk)
  | _ => throw <| IO.userError "workspace output changed variant"
  let payload := toJson chunk
  for invalid in #[
      payload.setObjVal! "source" (toJson "unknown"),
      payload.setObjVal! "text" (toJson ""),
      payload.setObjVal! "text" (toJson (String.ofList (List.replicate Beam.WorkspaceOutput.chunkLimit 'α'))),
      payload.setObjVal! "unexpected" (toJson true),
      payload.setObjVal! "omittedBefore" Json.null
    ] do
    let envelope := Json.mkObj [("kind", toJson "workspaceOutput"), ("payload", invalid)]
    require "workspace output accepted an invalid payload"
      (match fromJson? (α := StreamMessage) envelope with | .error _ => true | .ok _ => false)

private def checkCompletedTail : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let some publisher ← text.borrow | throw <| IO.userError "new output buffer closed"
  let queue ← Output.Queue.create text
  let fragment := String.ofList (List.replicate (2 * Beam.WorkspaceOutput.chunkLimit) 'x')
  publisher.offer .stdout fragment
  publisher.retire
  queue.progress (some "tail") { updates := 1, done := false }
  queue.progress (some "tail") { updates := 2, done := true }
  queue.diagnostic (some "tail") {
    path := "Example.lean", uri := "file:///Example.lean", range := default, message := "required" }
  let execution ← IO.asTask (prio := Task.Priority.dedicated) <|
    pure (Response.success (toJson "finished"))
  let frames ← IO.mkRef (#[] : Array StreamMessage)
  discard <| queue.run execution some (some "tail") fun message => do
    frames.modify (·.push message)
  let messages ← frames.get
  require "output writer lost request identity" (messages.all (·.clientRequestId? == some "tail"))
  let texts := messages.filterMap fun message => match message with
    | .workspaceOutput _ chunk => some chunk.text
    | _ => none
  require "completion discarded accepted text" (String.join texts.toList == fragment)
  require "completion lost final file progress" (messages.any fun message => match message with
    | .fileProgress _ progress => progress.done && progress.updates == 2
    | _ => false)
  require "completion lost required diagnostic" (messages.any fun message => match message with
    | .diagnostic _ diagnostic => diagnostic.message == "required"
    | _ => false)
  require "output writer did not end in exactly one terminal response"
    (messages.back?.any (fun message => match message with | .response .. => true | _ => false) &&
     (messages.filter fun message => match message with | .response .. => true | _ => false).size == 1)

private def checkBlockedWriter : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let some publisher ← text.borrow | throw <| IO.userError "new output buffer closed"
  let queue ← Output.Queue.create text
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let cleaned ← IO.Promise.new
  let execution ← IO.asTask (prio := Task.Priority.dedicated) do
    publisher.offer .stderr "visible before completion"
    discard <| IO.wait entered.result?
    publisher.retire
    cleaned.resolve ()
    pure (Response.success Json.null)
  let writer ← IO.asTask (prio := Task.Priority.dedicated) <|
    queue.run execution some none fun message => do
      match message with
      | .workspaceOutput .. =>
          entered.resolve ()
          discard <| IO.wait release.result?
      | _ => pure ()
  try
    require "blocked presentation prevented execution cleanup"
      (← Beam.waitTaskWithTimeout cleaned.result? 2000).isSome
    require "writer unexpectedly finished before release" (!(← IO.hasFinished writer))
  finally
    release.resolve ()
    discard <| IO.ofExcept (← IO.wait writer)

private def checkCancelledOutput : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let some publisher ← text.borrow | throw <| IO.userError "new output buffer closed"
  let queue ← Output.Queue.create text
  let release ← IO.Promise.new
  let started ← IO.Promise.new
  let first ← IO.Promise.new
  let second ← IO.Promise.new
  let frames ← IO.mkRef (#[] : Array StreamMessage)
  publisher.offer .stderr "pending"
  queue.progress none { updates := 1, done := false }
  queue.cancelOptional
  publisher.offer .stderr "late"
  queue.progress none { updates := 2, done := true }
  let execution ← IO.asTask (prio := Task.Priority.dedicated) do
    discard <| IO.wait release.result?
    pure (Response.errorResult { error := { code := "requestCancelled", message := "cancelled" } })
  let writer ← IO.asTask (prio := Task.Priority.dedicated) do
    started.resolve ()
    queue.run execution some none fun message => do
      frames.modify (·.push message)
      match message with
      | .diagnostic _ diagnostic =>
          if diagnostic.message == "first" then first.resolve () else second.resolve ()
      | _ => pure ()
  try
    require "cancelled writer did not start"
      (← Beam.waitTaskWithTimeout started.result? 2000).isSome
    for (message, delivered) in #[("first", first), ("second", second)] do
      -- Repeated cancellation must neither close required delivery nor finish execution.
      queue.cancelOptional
      queue.diagnostic none {
        path := "Example.lean", uri := "file:///Example.lean", range := default, message }
      require "cancelled queue lost a required diagnostic during cleanup"
        (← Beam.waitTaskWithTimeout delivered.result? 2000).isSome
      require "delivery finished before cancellation cleanup" (!(← IO.hasFinished writer))
  finally
    release.resolve ()
    discard <| IO.ofExcept (← IO.wait writer)
  let messages ← frames.get
  require "cancelled cleanup produced optional or extra terminal frames"
    (messages.size == 3 && messages.all fun message => match message with
      | .diagnostic .. | .response .. => true
      | _ => false)
  require "cancelled cleanup did not end in its terminal response"
    (messages.back?.any fun message => match message with
      | .response _ (.errorResult failure) => failure.error.code == "requestCancelled"
      | _ => false)

private def checkExistingDiagnosticAllowance : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let queue ← Output.Queue.create text
  queue.diagnostic none {
    path := "Example.lean", uri := "file:///Example.lean", range := default
    message := String.ofList (List.replicate (1024 * 1024) 'x') }
  require "delivery narrowed the existing diagnostic frame allowance" (!(← queue.failed))

private def checkRequiredCapacity : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let queue ← Output.Queue.create text
  for _ in [:65] do
    queue.diagnostic none {
      path := "Example.lean", uri := "file:///Example.lean", range := default, message := "required" }
  require "required diagnostic exhaustion was silent" (← queue.failed)

def check : IO Unit := do
  checkCodec
  checkCompletedTail
  checkBlockedWriter
  checkCancelledOutput
  checkExistingDiagnosticAllowance
  checkRequiredCapacity

end BeamTest.Broker.OutputTest
