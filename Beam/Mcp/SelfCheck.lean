/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Protocol
import Beam.Mcp.Stdio
import Beam.Path
import Beam.StderrCapture
import Beam.System

open Lean

namespace Beam.Mcp.SelfCheck

structure Options where
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none

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

private def childArgs (opts : Options) : List String :=
  [("--beam-cli", opts.beamCli?), ("--lean-cmd", opts.leanCmd?),
    ("--lean-plugin", opts.leanPlugin?)].flatMap fun (flag, value?) =>
      value?.toList.flatMap fun value => [flag, value]

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

private def terminateChild {cfg : IO.Process.StdioConfig} (child : IO.Process.Child cfg) : IO Unit := do
  try
    if (← child.tryWait).isNone then
      child.kill
  catch _ =>
    pure ()
  -- The probe may already have reaped the child; cleanup must preserve its original error.
  try
    discard <| child.wait
  catch _ =>
    pure ()

def run (opts : Options) (pathText : String) : IO Unit := do
  let root ← Beam.resolveExistingPath (← IO.currentDir)
  let resolvedPath ← Beam.resolvePathAgainstRoot root (System.FilePath.mk pathText)
  let appPath ← IO.appPath
  let timeout ← timeoutMs
  let (stdin, child) ← (← IO.Process.spawn {
    toStdioConfig := stdio
    cmd := appPath.toString
    args := (childArgs opts).toArray
    cwd := root.toString
  }).takeStdin
  let started ← IO.monoMsNow
  let remaining : IO Nat := do
    pure <| timeout - ((← IO.monoMsNow) - started)
  let timedOut := IO.userError
    s!"timed out after {timeout} ms waiting for lean-beam-mcp self-check"
  let await {α} (task : Task (Except IO.Error α)) : IO α := do
    let some result ← Beam.waitTaskWithTimeout task (← remaining)
      | throw timedOut
    IO.ofExcept result
  -- Drain while the child serves requests, retaining only a bounded diagnostic tail.
  let stderr ← Beam.StderrCapture.start child.stderr (64 * 1024)
  -- This task owns stdin and releases it before we wait for the child's EOF shutdown.
  let protocolTask ← IO.asTask (checkProtocol stdin child.stdout root pathText) Task.Priority.dedicated
  try
    await protocolTask
    let exitTask ← IO.asTask child.wait Task.Priority.dedicated
    let exitCode ← await exitTask
    if exitCode != 0 then
      throw <| IO.userError s!"lean-beam-mcp self-check child exited with code {exitCode}"
    match ← stderr.finishAfterWriterExit (← remaining) with
    | .drained => pure ()
    | .sourceFailed err => throw err
    | .pipeStillOpen => throw timedOut
  catch e =>
    terminateChild child
    -- Cleanup has a separate bounded drain wait. Blocking I/O still needs CI's watchdog.
    discard <| stderr.finishAfterWriterExit
    let tail ← stderr.snapshot
    if !tail.trimAscii.isEmpty then
      throw <| IO.userError s!"{e}\n{tail}"
    throw e
  IO.println "Lean Beam MCP self-check passed"
  IO.println s!"  root: {root}"
  IO.println s!"  file: {resolvedPath}"
  IO.println s!"  workspace: explicit root descriptor"
  IO.println s!"  protocol: {protocolVersion}"
  IO.println "  lean_sync: ok"

end Beam.Mcp.SelfCheck
