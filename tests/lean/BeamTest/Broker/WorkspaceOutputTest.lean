/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.WorkspaceOutput
import Beam.ProcessJob

namespace BeamTest.Broker.WorkspaceOutputTest

open Beam.WorkspaceOutput

private def require (message : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError message

private def borrow (buffer : Buffer) : IO Publisher := do
  let some publisher ← buffer.borrow | throw <| IO.userError "expected a live request"
  return publisher

private def takeAll (buffer : Buffer) : IO (Array Chunk) := do
  let mut chunks := #[]
  while true do
    match ← buffer.poll with
    | .chunk chunk => chunks := chunks.push chunk
    | .waiting _ | .closed => break
  return chunks

private def text (chunks : Array Chunk) : String :=
  String.join (chunks.toList.map (·.text))

private def checkRetirement : IO Unit := do
  let buffer ← Buffer.create
  let first ← borrow buffer
  let second ← borrow buffer
  first.offer .stderr "warning from fast helper\n"
  first.retire
  first.offer .stderr "late output"
  second.offer .stdout "second helper\n"
  buffer.seal
  second.offer .stdout "after seal"
  require "sealed request admitted another helper" (← buffer.borrow).isNone
  let chunks ← takeAll buffer
  require "retiring/sealing lost accepted text or admitted late text"
    (text chunks == "warning from fast helper\nsecond helper\n")
  require "stdout/stderr identity was lost"
    (chunks.map (·.source) == #[.stderr, .stdout])
  require "loss was reported without overflow" (!chunks.any (·.omittedBefore))
  let cancelled ← Buffer.create
  let producer ← borrow cancelled
  producer.offer .stderr "discard me"
  cancelled.discard
  producer.offer .stderr "late"
  require "cancelled request retained output" (match ← cancelled.poll with | .closed => true | _ => false)

private def checkReadiness : IO Unit := do
  let buffer ← Buffer.create
  let publisher ← borrow buffer
  let initialActivity ← buffer.activity
  let .waiting first ← buffer.poll | throw <| IO.userError "empty request was not waiting"
  require "empty live buffer was already signalled" (!(← IO.hasFinished first))
  publisher.offer .stderr "ready"
  let offeredActivity ← buffer.activity
  require "accepted text did not report activity" (offeredActivity != initialActivity)
  require "publication missed its waiter" (← IO.hasFinished first)
  let .chunk chunk ← buffer.poll | throw <| IO.userError "signalled chunk was unavailable"
  require "readiness changed the payload" (chunk.text == "ready")
  require "draining text reported new producer activity" ((← buffer.activity) == offeredActivity)
  publisher.retire
  publisher.offer .stderr "late"
  require "retired publisher reported activity" ((← buffer.activity) == offeredActivity)
  let .waiting second ← buffer.poll | throw <| IO.userError "drained request was not waiting"
  require "drained buffer reused a stale readiness signal" (!(← IO.hasFinished second))
  buffer.seal
  require "seal missed its waiter" (← IO.hasFinished second)
  require "sealed empty request did not close" (match ← buffer.poll with | .closed => true | _ => false)
  let cancelled ← Buffer.create
  let .waiting waiter ← cancelled.poll | throw <| IO.userError "empty request was not waiting"
  cancelled.discard
  require "discard missed its waiter" (← IO.hasFinished waiter)

private def checkOverflow : IO Unit := do
  let buffer ← Buffer.create
  let publisher ← borrow buffer
  publisher.offer .stdout (String.ofList (List.replicate (byteLimit + chunkLimit) 'x'))
  publisher.offer .stdout "latest α🙂\n"
  buffer.seal
  let chunks ← takeAll buffer
  let retained := text chunks
  require "pending bytes exceeded the bound" (retained.utf8ByteSize ≤ byteLimit)
  require "pending records exceeded the bound" (chunks.size ≤ recordLimit)
  require "overflow lost the latest output" (retained.endsWith "latest α🙂\n")
  require "overflow was not attached to the retained tail"
    (chunks[0]?.any (·.omittedBefore))
  require "a presentation chunk exceeded the bound"
    (chunks.all fun chunk => chunk.text.utf8ByteSize ≤ chunkLimit)
  let records ← Buffer.create
  let producer ← borrow records
  for i in [:recordLimit + 10] do
    producer.offer (if i % 2 == 0 then .stdout else .stderr) "x"
  let chunks ← takeAll records
  require "alternating streams bypassed the record limit" (chunks.size == recordLimit)
  require "record overflow lost its omission indication"
    (chunks[0]?.any (·.omittedBefore))

private def checkForwardedOmission : IO Unit := do
  let buffer ← Buffer.create
  let publisher ← borrow buffer
  publisher.offer .stderr "before gap"
  publisher.offer .stderr "after gap" (omittedBefore := true)
  publisher.offer .stderr " and continuation"
  let chunks ← takeAll buffer
  require "forwarded omission merged across its gap" (chunks.size == 2)
  require "forwarded omission changed its position"
    (chunks[0]?.any (fun chunk => !chunk.omittedBefore && chunk.text == "before gap") &&
     chunks[1]?.any (fun chunk => chunk.omittedBefore && chunk.text == "after gap and continuation"))
  let oversized := String.ofList (List.replicate (2 * chunkLimit) 'α')
  publisher.offer .stdout oversized (omittedBefore := true)
  let chunks ← takeAll buffer
  require "splitting forwarded text lost its gap" (chunks[0]?.any (·.omittedBefore))
  require "splitting forwarded text duplicated its gap"
    ((chunks.filter (·.omittedBefore)).size == 1)
  require "splitting forwarded text changed its contents" (text chunks == oversized)

private def checkResponsiveConsumer : IO Unit := do
  let buffer ← Buffer.create
  let publisher ← borrow buffer
  let fragment := String.ofList (List.replicate chunkLimit 'α')
  let mut received := 0
  for _ in [:40] do
    publisher.offer .stderr fragment
    let chunks ← takeAll buffer
    require "responsive consumer lost output" (text chunks == fragment)
    require "total output was mistaken for pending output" (!chunks.any (·.omittedBefore))
    received := received + (text chunks).utf8ByteSize
  require "fixture did not exceed the pending budget" (received > byteLimit)

/-- Child mode in the existing portable process test executable. -/
def producer (flood : Bool) : IO Unit := do
  let stdout ← IO.getStdout
  let stderr ← IO.getStderr
  stdout.putStr "α"
  stdout.flush
  stderr.putStr "warning"
  stderr.flush
  unless (← (← IO.getStdin).getLine) == "release\n" do
    throw <| IO.userError "output producer was not released"
  let fragment := String.ofList (List.replicate chunkLimit 'x')
  while flood do
    stdout.putStr fragment
    stdout.flush
  -- The parent stops consuming while this exceeds both pipe capacity and its pending budget.
  stdout.putStr (String.ofList (List.replicate (2 * byteLimit) 'x'))
  -- Exercise malformed and incomplete UTF-8 independently of typed result transport.
  stdout.write (ByteArray.mk #[255, 226])
  stdout.flush

private def checkPromptCapture (cancel : Bool) : IO Unit := do
  let buffer ← Buffer.create
  let publisher ← borrow buffer
  let child ← IO.Process.spawn {
    cmd := (← IO.appPath).toString
    args := #[if cancel then "--workspace-output-flood" else "--workspace-output-producer"]
    stdin := .piped, stdout := .piped, stderr := .piped
    setsid := true
  }
  let captureRef ← IO.mkRef (none : Option Capture)
  let releasedAt ← IO.mkRef 0
  try
    Beam.ProcessJob.withChild child fun scope => do
      captureRef.set (some (← Capture.start child.stdout child.stderr publisher))
      let deadline := (← IO.monoMsNow) + 5000
      let mut stdout := ""
      let mut stderr := ""
      while stdout != "α" || stderr != "warning" do
        match ← buffer.poll with
        | .chunk chunk =>
          match chunk.source with
          | .stdout => stdout := stdout ++ chunk.text
          | .stderr => stderr := stderr ++ chunk.text
        | .waiting _ =>
          require "short flushed fragments waited for newline or EOF" ((← IO.monoMsNow) < deadline)
          IO.sleep 1
        | .closed => throw <| IO.userError "output request closed before producer release"
      require "producer exited before its release gate" ((← scope.poll) == .running)
      releasedAt.set (← IO.monoMsNow)
      child.stdin.putStr "release\n"
      child.stdin.flush
      if cancel then
        -- Observe an active flood, then revoke output without consuming its remainder.
        let mut emitting := false
        while !emitting do
          match ← buffer.poll with
          | .chunk chunk => emitting := chunk.source == .stdout && !chunk.text.isEmpty
          | .waiting _ =>
              require "output producer did not start its flood" ((← IO.monoMsNow) < deadline)
              IO.sleep 1
          | .closed => throw <| IO.userError "output request closed before cancellation"
        buffer.discard
        -- Returning lets the job scope terminate the still-running writer before draining EOF.
      else
        while (← scope.poll) == .running do
          require "output producer did not exit" ((← IO.monoMsNow) < deadline)
          IO.sleep 1
  finally
    if let some capture ← captureRef.get then
      let (stdout, stderr) ← capture.finish
      require "stdout drain did not complete" (match stdout with | .drained => true | _ => false)
      require "stderr drain did not complete" (match stderr with | .drained => true | _ => false)
  if cancel then
    require "cancelled capture admitted late output" (match ← buffer.poll with | .closed => true | _ => false)
    IO.println s!"workspace output: active flood cancelled and drained in {(← IO.monoMsNow) - (← releasedAt.get)} ms"
    return
  buffer.seal
  let chunks ← takeAll buffer
  let retained := text chunks
  require "invalid or incomplete UTF-8 was not replaced" (retained.endsWith "��")
  require "unconsumed helper output exceeded its budget" (retained.utf8ByteSize ≤ byteLimit)
  require "unconsumed helper output omitted its overflow indication"
    (chunks[0]?.any (·.omittedBefore))
  IO.println s!"workspace output: {2 * byteLimit}-byte burst drained in {(← IO.monoMsNow) - (← releasedAt.get)} ms"

def check : IO Unit := do
  checkRetirement
  checkReadiness
  checkOverflow
  checkForwardedOmission
  checkResponsiveConsumer
  checkPromptCapture false
  checkPromptCapture true

end BeamTest.Broker.WorkspaceOutputTest
