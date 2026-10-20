/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.BackendProcess
import Beam.Mcp.Protocol
import Beam.Mcp.Stdio
import Beam.Path
import Beam.StderrCapture
import Beam.System

open Lean

namespace Beam.Mcp.SelfCheck

private abbrev stdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .piped

private def defaultTimeoutMs : Nat :=
  120000

private def timeoutMs : IO Nat := do
  match ← IO.getEnv "LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS" with
  | none => pure defaultTimeoutMs
  | some raw =>
      let some timeout := raw.toNat?
        | throw <| IO.userError
            s!"invalid LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS value '{raw}': expected milliseconds"
      if timeout == 0 then
        throw <| IO.userError "invalid LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS value '0': expected a positive timeout"
      pure timeout

private def fieldError (label field : String) (json : Json) (err : String) : String :=
  s!"{label}: missing or invalid '{field}': {err}; response: {json.compress}"

private def requireObjVal (label field : String) (json : Json) : Except String Json :=
  (json.getObjVal? field).mapError (fieldError label field json)

private def requireObjValAs [FromJson α]
    (label field : String) (json : Json) : Except String α :=
  (json.getObjValAs? α field).mapError (fieldError label field json)

/-- Validate an envelope and return its result, skipping notifications. -/
private def validateResponse
    (expectedId : Json) (phase : String) (json : Json) : Except String (Option Json) := do
  let revision ← requireObjValAs (α := String) "self-check response" "jsonrpc" json
  unless revision == "2.0" do
    throw s!"self-check {phase}: expected jsonrpc 2.0, got {revision}"
  let method? ← (optionalField? (α := String) json "method").mapError
    (fun err => s!"self-check {phase}: {err}")
  match method? with
  | some method =>
      match json.getObjVal? "id" with
      | .ok _ =>
          throw s!"lean-beam-mcp self-check child sent unexpected request '{method}' during {phase}: {json.compress}"
      | .error _ => pure none
  | none =>
      let id ← requireObjVal "self-check response" "id" json
      unless id == expectedId do
        throw s!"expected self-check {phase} id {expectedId.compress}, got {json.compress}"
      match json.getObjVal? "error" with
      | .ok err => throw s!"{phase} failed: {err.compress}"
      | .error _ => return some (← requireObjVal phase "result" json)

private def validateComplete (label : String) (result : Json) : Except String Unit := do
  let resultType ← requireObjValAs (α := String) s!"{label} result" "resultType" result
  unless resultType == "complete" do
    throw s!"{label} returned resultType {resultType}, expected complete"

private def validateDiscovery (result : Json) : Except String Unit := do
  validateComplete "server/discover" result
  let supported ← requireObjValAs (α := Array String)
    "server/discover result" "supportedVersions" result
  unless supported.contains protocolVersion do
    throw s!"server/discover did not advertise MCP protocol {protocolVersion}: {result.compress}"

private def validateSync (result : Json) : Except String Unit := do
  validateComplete "lean_sync" result
  let isError? ← (optionalField? (α := Bool) result "isError").mapError
    (fun err => s!"lean_sync result: {err}")
  if isError?.getD false then
    throw s!"lean_sync returned an MCP tool error: {result.compress}"
  let structured ← requireObjVal "lean_sync result" "structuredContent" result
  let progress ← requireObjVal "lean_sync structuredContent" "document_progress" structured
  discard <| requireObjValAs (α := Nat) "lean_sync document_progress" "updates" progress
  -- Sync can succeed before elaboration finishes; this smoke test checks shape, not readiness.
  discard <| requireObjValAs (α := Bool) "lean_sync document_progress" "done" progress

private def fromValidation (result : Except String α) : IO α :=
  IO.ofExcept <| result.mapError IO.userError

private partial def readResult
    (stdout : IO.FS.Handle)
    (expectedId : Json)
    (phase : String) : IO Json := do
  let line := Beam.Mcp.Stdio.stripLineEnding (← stdout.getLine)
  if line.isEmpty then
    throw <| IO.userError s!"lean-beam-mcp self-check child closed stdout during {phase}"
  let json ←
    match Json.parse line with
    | .ok json => pure json
    | .error err => throw <| IO.userError s!"lean-beam-mcp self-check child wrote invalid JSON during {phase}: {err}: {line}"
  match ← fromValidation (validateResponse expectedId phase json) with
  | none => readResult stdout expectedId phase
  | some result => pure result

private def modernMeta : Json :=
  Json.mkObj [
    ("io.modelcontextprotocol/protocolVersion", toJson protocolVersion),
    ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
    ("io.modelcontextprotocol/clientInfo", Json.mkObj [
      ("name", toJson "lean-beam-mcp-self-check"),
      ("version", toJson serverVersion)
    ])
  ]

private def sendDiscover (stdin : IO.FS.Handle) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (1 : Nat)),
    ("method", toJson "server/discover"),
    ("params", Json.mkObj [
      ("_meta", modernMeta)
    ])
  ]

private def sendSync
    (stdin : IO.FS.Handle)
    (root : System.FilePath)
    (pathText : String) : IO Unit := do
  Beam.Mcp.Stdio.writeJsonLineToHandle stdin <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (2 : Nat)),
    ("method", toJson "tools/call"),
    ("params", Json.mkObj [
      ("name", toJson (ToolName.leanOperation .sync)),
      ("arguments", Json.mkObj [
        ("path", toJson pathText),
        ("workspace", toJson <| Beam.Workspace.Descriptor.ofRoot root)
      ]),
      ("_meta", modernMeta)
    ])
  ]

private def checkProtocol
    (stdin stdout : IO.FS.Handle)
    (root : System.FilePath)
    (pathText : String) : IO Unit := do
  sendDiscover stdin
  fromValidation <| validateDiscovery
    (← readResult stdout (toJson (1 : Nat)) "server/discover response")
  sendSync stdin root pathText
  fromValidation <| validateSync (← readResult stdout (toJson (2 : Nat)) "lean_sync response")
  -- Keep stdin alive through the final response; the protocol task then releases it.
  stdin.flush

private structure ChildScope where
  process : Beam.Broker.BackendProcess
  active : Std.Mutex Bool

private def ChildScope.observe (scope : ChildScope) :
    IO (Option Beam.Broker.BackendObservation) :=
  scope.active.atomically do
    unless ← get do throw <| IO.userError "self-check child scope is closed"
    scope.process.observe

/-- Poll through the same owner used by teardown; no consuming wait task survives a timeout. -/
private partial def ChildScope.waitForExit
    (scope : ChildScope) (timeoutMs : Nat) : IO (Option Beam.Broker.BackendObservation) := do
  let deadline := (← IO.monoMsNow) + timeoutMs
  let rec loop : IO (Option Beam.Broker.BackendObservation) := do
    if let some exit ← scope.observe then return some exit
    let remaining := deadline - (← IO.monoMsNow)
    if remaining == 0 then return none
    IO.sleep (min remaining 50).toUInt32
    loop
  loop

/-- Adopt one process owner for this scope and retain both failures for the CLI boundary. -/
private def withChildScope
    (process : Beam.Broker.BackendProcess) (cleanupTimeoutMs : Nat)
    (action : ChildScope → IO α) :
    IO (Except IO.Error α × Except IO.Error Beam.Broker.BackendTermination) := do
  let scope : ChildScope := { process, active := ← Std.Mutex.new true }
  let outcome ← (action scope).toBaseIO
  -- Fence escaped/in-flight observers before teardown. Polling sleeps never hold this lock.
  scope.active.atomically (set false)
  let termination ← (process.terminate cleanupTimeoutMs).toBaseIO
  pure (outcome, termination)

/-- Render independent operation/process/pipe outcomes only at this CLI diagnostic boundary. -/
private def finishCheck
    (outcome : Except IO.Error Unit)
    (termination : Except IO.Error Beam.Broker.BackendTermination)
    (protocolCompletion : Except IO.Error Bool)
    (capture : Except IO.Error (Option (Beam.StderrCaptureOutcome × String))) : IO Unit := do
  let processErrors := match termination with
    | .ok (.exited _) => []
    | .ok (.unconfirmed waitError? signalError?) =>
        ["self-check child exit was not confirmed during cleanup"] ++
          (waitError?.toList.map fun error => s!"child wait failed: {error}") ++
          (signalError?.toList.map fun error => s!"child termination failed: {error}")
    | .error error => [s!"self-check process cleanup failed: {error}"]
  let (captureErrors, tail) := match capture with
    | .error error => ([s!"self-check stderr cleanup failed: {error}"], "")
    | .ok none => ([], "")
    | .ok (some (.drained, tail)) => ([], tail)
    | .ok (some (.sourceFailed error, tail)) => ([s!"self-check stderr source failed: {error}"], tail)
    | .ok (some (.pipeStillOpen, tail)) => (["self-check stderr drain did not finish within its timeout"], tail)
  let protocolErrors := match protocolCompletion with
    | .ok true => []
    | .ok false => ["self-check protocol task did not finish after child cleanup"]
    | .error error => [s!"self-check protocol cleanup failed: {error}"]
  let cleanupErrors := processErrors ++ captureErrors ++ protocolErrors
  match outcome, cleanupErrors with
  | .ok (), [] => pure ()
  | .error error, [] =>
      if tail.trimAscii.isEmpty then throw error
      throw <| IO.userError s!"{error}\n{tail}"
  | _, _ =>
      let errors := (match outcome with | .ok () => [] | .error error => [error.toString]) ++ cleanupErrors
      let errors := if tail.trimAscii.isEmpty then errors else errors ++ [tail]
      throw <| IO.userError <| String.intercalate "\n" errors

def run (pathText : String) : IO Unit := do
  let root ← Beam.resolveExistingPath (← IO.currentDir)
  let resolvedPath ← Beam.resolvePathAgainstRoot root (System.FilePath.mk pathText)
  let appPath ← Beam.resolveExistingPath (← IO.appPath)
  let timeout ← timeoutMs
  let captureRef ← IO.mkRef (none : Option Beam.StderrCapture)
  let protocolRef ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
  let (stdin, child) ← (← IO.Process.spawn {
    toStdioConfig := stdio
    cmd := appPath.toString
    args := #[]
    cwd := root.toString
  }).takeStdin
  -- Adopt after taking stdin: callbacks must not retain another copy of its pipe writer.
  let process ← Beam.Broker.BackendProcess.create child.pid child.tryWait child.kill
  let started ← IO.monoMsNow
  let remaining : IO Nat := do
    pure <| timeout - ((← IO.monoMsNow) - started)
  let timedOut := IO.userError
    s!"timed out after {timeout} ms waiting for lean-beam-mcp self-check"
  let await {α} (task : Task (Except IO.Error α)) : IO α := do
    let some result ← Beam.waitTaskWithTimeout task (← remaining)
      | throw timedOut
    IO.ofExcept result
  let (outcome, termination) ← withChildScope process 1000 fun scope => do
    -- Both resources are acquired inside process ownership, including startup failure cleanup.
    let stderr ← Beam.StderrCapture.start child.stderr (64 * 1024)
    captureRef.set (some stderr)
    -- This task owns stdin and releases it before we wait for the child's EOF shutdown.
    let protocolTask ← IO.asTask (checkProtocol stdin child.stdout root pathText) Task.Priority.dedicated
    protocolRef.set (some protocolTask)
    await protocolTask
    let exitCode ← match ← scope.waitForExit (← remaining) with
      | some (.exited code) => pure code
      | some (.waitFailed error) => throw error
      | none => throw timedOut
    if exitCode != 0 then
      throw <| IO.userError s!"lean-beam-mcp self-check child exited with code {exitCode}"
  -- Process failures are data, so neither can skip independent task/pipe completion.
  let protocolCompletion ← (do
    match ← protocolRef.get with
    | none => pure true
    | some task => pure <| (← Beam.waitTaskWithTimeout task 1000).isSome).toBaseIO
  let capture ← (do
    match ← captureRef.get with
    | none => pure none
    | some stderr =>
        let drainTimeout ← if outcome.isOk then remaining else pure 1000
        let drain ← stderr.awaitCompletion drainTimeout
        pure <| some (drain, ← stderr.snapshot)).toBaseIO
  finishCheck outcome termination protocolCompletion capture
  IO.println "Lean Beam MCP self-check passed"
  IO.println s!"  root: {root}"
  IO.println s!"  file: {resolvedPath}"
  IO.println s!"  workspace: explicit root descriptor"
  IO.println s!"  protocol: {protocolVersion}"
  IO.println "  lean_sync: ok"

end Beam.Mcp.SelfCheck
