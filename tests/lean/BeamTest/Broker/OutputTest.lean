/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Output
import Beam.Broker.Errors

open Lean Beam.Broker

namespace BeamTest.Broker.OutputTest

private def require (message : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError message

private def withOutputPeer
    (act : Transport.Connection → Transport.Connection → IO Unit) : IO Unit := do
  let listener ← Transport.bindAndListen (.tcp 0)
  try
    let client ← Transport.connect (← Transport.listenerEndpoint listener)
    try
      let peer ← Transport.accept listener
      try act peer client
      finally Transport.abandonConnection peer
    finally Transport.abandonConnection client
  finally Transport.closeListener listener

private def receiveMessage (client : Transport.Connection) : IO StreamMessage := do
  let some bytes ← Transport.recvMsgUntil client ((← IO.monoNanosNow) + 2000000000)
    | throw <| IO.userError "output peer did not receive a frame"
  let json ← IO.ofExcept <| (Json.parse bytes).mapError IO.userError
  IO.ofExcept <| (fromJson? json).mapError IO.userError

private def requirePeerEof (client : Transport.Connection) : IO Unit := do
  let closed ←
    try
      discard <| Transport.recvMsgUntil client ((← IO.monoNanosNow) + 2000000000)
      pure false
    catch _ => pure true
  require "output peer received extra bytes or remained open instead of EOF" closed

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

private def requireCapacityError (error : IO.Error) : IO Unit :=
  match error with
  | .userError message =>
      require "required diagnostic failure changed its original cause"
        (message == "broker required diagnostic capacity exhausted")
  | _ => throw <| IO.userError "required diagnostic capacity did not retain its typed IO error"

private def checkAcceptedCapacity : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let queue ← Output.Queue.create text
  for _ in [:64] do
    queue.diagnostic none {
      path := "Example.lean", uri := "file:///Example.lean", range := default, message := "required" }
  require "exactly 64 required diagnostics exceeded capacity" (!(← queue.failed))
  let execution ← IO.asTask (prio := Task.Priority.dedicated) <|
    pure (Response.success Json.null)
  let frames ← IO.mkRef (#[] : Array StreamMessage)
  discard <| queue.run execution some none fun message => frames.modify (·.push message)
  let messages ← frames.get
  require "accepted diagnostic capacity did not drain completely"
    ((messages.filter fun message => match message with | .diagnostic .. => true | _ => false).size == 64)
  require "accepted diagnostic capacity did not end in exactly one terminal"
    (messages.size == 65 && messages.back?.any fun message => match message with
      | .response .. => true | _ => false)

private def checkRequiredCapacity : IO Unit := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let queue ← Output.Queue.create text
  for _ in [:65] do
    queue.diagnostic none {
      path := "Example.lean", uri := "file:///Example.lean", range := default, message := "required" }
  require "required diagnostic exhaustion was silent" (← queue.failed)
  let some original ← queue.failure?
    | throw <| IO.userError "required diagnostic exhaustion lost its original error"
  requireCapacityError original
  let settled ← IO.Promise.new
  let execution ← IO.asTask (prio := Task.Priority.dedicated) do
    settled.resolve ()
    pure (Response.success Json.null)
  let frames ← IO.mkRef (#[] : Array StreamMessage)
  let writer ← IO.asTask (prio := Task.Priority.dedicated) <|
    queue.run execution some none fun message => frames.modify (·.push message)
  match ← IO.wait writer with
  | .error error => requireCapacityError error
  | .ok _ => throw <| IO.userError "exhausted required diagnostics were reported as successful delivery"
  discard <| IO.ofExcept (← IO.wait execution)
  require "queue failure prevented producer settlement"
    (← Beam.waitTaskWithTimeout settled.result? 2000).isSome
  require "exhausted queue emitted an incomplete successful stream" (← frames.get).isEmpty

private def checkOverflowAfterDeliveredFrame : IO Unit :=
  withOutputPeer fun peer client => do
    let text ← Beam.WorkspaceOutput.Buffer.create
    let queue ← Output.Queue.create text
    let phase ← IO.mkRef Output.FramePhase.betweenFrames
    let delivered ← IO.Promise.new
    let overflow ← IO.Promise.new
    let releaseWriter ← IO.Promise.new
    let releaseExecution ← IO.Promise.new
    let settled ← IO.Promise.new
    queue.progress none { updates := 1, done := false }
    let execution ← IO.asTask (prio := Task.Priority.dedicated) do
      try
        discard <| IO.wait delivered.result?
        for _ in [:65] do
          queue.diagnostic none {
            path := "Example.lean", uri := "file:///Example.lean", range := default, message := "required" }
        overflow.resolve ()
        discard <| IO.wait releaseExecution.result?
        pure (Response.success Json.null)
      finally settled.resolve ()
    let frames ← IO.mkRef (#[] : Array StreamMessage)
    let writer ← IO.asTask (prio := Task.Priority.dedicated) <|
      queue.run execution some none fun message => do
        Output.writeMessage phase message <| Transport.sendMsg peer (toJson message).compress
        frames.modify (·.push message)
        match message with
        | .fileProgress .. =>
            -- Pause the callback after accepting one whole message; no socket scheduling guess.
            delivered.resolve ()
            discard <| IO.wait releaseWriter.result?
        | _ => pure ()
    try
      require "controlled required-diagnostic burst did not finish"
        (← Beam.waitTaskWithTimeout overflow.result? 2000).isSome
      require "controlled burst failed to exhaust pending capacity" (← queue.failed)
      releaseWriter.resolve ()
      let some result ← Beam.waitTaskWithTimeout writer 2000
        | throw <| IO.userError "overflow writer remained blocked after release"
      let failure ← match result with
        | .error error => pure error
        | .ok _ => throw <| IO.userError "overflow after a delivered frame became successful delivery"
      requireCapacityError failure
      require "delivery failure was mistaken for producer settlement" (!(← IO.hasFinished execution))
      releaseExecution.resolve ()
      discard <| IO.ofExcept (← IO.wait execution)
      let response := StreamMessage.response none (errorResponseFor .internalError failure.toString)
      let reported ← Output.tryReportFailure phase <| Transport.sendMsg peer (toJson response).compress
      require "completed-frame overflow could not report its terminal failure" reported
      match ← receiveMessage client with
      | .fileProgress .. => pure ()
      | _ => throw <| IO.userError "overflow peer lost its complete first frame"
      match ← receiveMessage client with
      | .response _ (.errorResult failure) =>
          require "overflow peer received the wrong terminal error" (failure.error.code == "internalError")
      | _ => throw <| IO.userError "overflow peer did not receive one typed terminal failure"
      Transport.abandonConnection peer
      requirePeerEof client
    finally
      delivered.resolve ()
      releaseWriter.resolve ()
      releaseExecution.resolve ()
      discard <| IO.wait writer
      discard <| IO.ofExcept (← IO.wait execution)
    require "controlled producer failed to settle after release"
      (← Beam.waitTaskWithTimeout settled.result? 2000).isSome
    let messages ← frames.get
    require "controlled overflow produced a terminal or extra accepted message"
      (messages.size == 1 && messages.all fun message => match message with
        | .fileProgress .. => true | _ => false)

private def checkPartialFrameFailure : IO Unit :=
  withOutputPeer fun peer client => do
    let phase ← IO.mkRef Output.FramePhase.betweenFrames
    let message := StreamMessage.fileProgress none { updates := 1, done := false }
    let partialSent ← IO.mkRef false
    let failed ←
      try
        Output.writeMessage phase message do
          let .tcp socket _ := peer
          -- Emit only half the declared body, then fail the send callback deterministically.
          let sent ← Std.Internal.UV.TCP.Socket.send socket #["8\n{\"ok".toUTF8]
          let some result ← IO.wait sent.result?
            | throw <| IO.userError "partial-frame fixture lost its send result"
          discard <| IO.ofExcept result
          partialSent.set true
          throw <| IO.userError "controlled partial frame failure"
        pure false
      catch _ => pure true
    require "partial-frame fixture did not fail" failed
    require "partial-frame fixture failed before emitting its bytes" (← partialSent.get)
    require "failed notification lost its uncertain phase" ((← phase.get) == .sendingNotification)
    let attempts ← IO.mkRef 0
    let reported ← Output.tryReportFailure phase do
      attempts.modify (· + 1)
      Transport.sendMsg peer (toJson (StreamMessage.response none (Response.success Json.null))).compress
    require "partial frame admitted a replacement terminal" (!reported && (← attempts.get) == 0)
    Transport.abandonConnection peer
    requirePeerEof client

private def checkPostTerminalCleanupFailure : IO Unit :=
  withOutputPeer fun peer client => do
    let phase ← IO.mkRef Output.FramePhase.betweenFrames
    let message := StreamMessage.response none (Response.success (toJson "finished"))
    Output.writeMessage phase message <| Transport.sendMsg peer (toJson message).compress
    let attempts ← IO.mkRef 0
    let reported : Bool ←
      try
        throw <| IO.userError "controlled post-terminal cleanup failure"
      catch error =>
        Output.tryReportFailure phase do
          attempts.modify (· + 1)
          let response := StreamMessage.response none (errorResponseFor .internalError error.toString)
          Transport.sendMsg peer (toJson response).compress
    require "post-terminal cleanup admitted a duplicate response" (!reported && (← attempts.get) == 0)
    require "complete terminal lost its phase" ((← phase.get) == .terminalComplete)
    Transport.abandonConnection peer
    match ← receiveMessage client with
    | .response _ (.successResult ..) => pure ()
    | _ => throw <| IO.userError "post-terminal cleanup lost the original successful response"
    requirePeerEof client

def check : IO Unit := do
  checkCodec
  checkCompletedTail
  checkBlockedWriter
  checkCancelledOutput
  checkExistingDiagnosticAllowance
  checkAcceptedCapacity
  checkRequiredCapacity
  checkOverflowAfterDeliveredFrame
  checkPartialFrameFailure
  checkPostTerminalCleanupFailure

end BeamTest.Broker.OutputTest
