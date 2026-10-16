/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Protocol
import Beam.Mcp.Stdio
import Beam.Path
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
  let args := []
  let args :=
    match opts.beamCli? with
    | some beamCli => args ++ ["--beam-cli", beamCli]
    | none => args
  let args :=
    match opts.leanCmd? with
    | some leanCmd => args ++ ["--lean-cmd", leanCmd]
    | none => args
  let args :=
    match opts.leanPlugin? with
    | some leanPlugin => args ++ ["--lean-plugin", leanPlugin]
    | none => args
  args

private def root : IO System.FilePath := do
  Beam.resolveExistingPath (← IO.currentDir)

private def resolveFile (root : System.FilePath) (pathText : String) : IO System.FilePath := do
  let path := System.FilePath.mk pathText
  Beam.resolvePathAgainstRoot root path

private def throwJsonFieldError (label field : String) (json : Json) (err : String) : IO α :=
  throw <| IO.userError s!"{label}: missing or invalid '{field}': {err}; response: {json.compress}"

private def requireObjVal (label field : String) (json : Json) : IO Json := do
  match json.getObjVal? field with
  | .ok value => pure value
  | .error err => throwJsonFieldError label field json err

private def requireObjValAs [FromJson α] (label field : String) (json : Json) : IO α := do
  match json.getObjValAs? α field with
  | .ok value => pure value
  | .error err => throwJsonFieldError label field json err

private def expectResult (label : String) (json : Json) : IO Json := do
  match json.getObjVal? "error" with
  | .ok err =>
      throw <| IO.userError s!"{label} failed: {err.compress}"
  | .error _ =>
      requireObjVal label "result" json

private partial def readResponse
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
  match json.getObjValAs? String "method" with
  | .ok method =>
      match json.getObjVal? "id" with
      | .ok _ =>
          throw <| IO.userError s!"lean-beam-mcp self-check child sent unexpected request '{method}' during {phase}: {json.compress}"
      | .error _ =>
          readResponse stdout expectedId phase
  | .error _ =>
      let id ← requireObjVal "self-check response" "id" json
      if id == expectedId then
        pure json
      else
        throw <| IO.userError s!"expected self-check {phase} id {expectedId.compress}, got {json.compress}"

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
  let discovery ← expectResult "server/discover" =<<
    readResponse stdout (toJson (1 : Nat)) "server/discover response"
  let resultType ← requireObjValAs (α := String) "server/discover result" "resultType" discovery
  if resultType != "complete" then
    throw <| IO.userError s!"server/discover returned resultType {resultType}, expected complete"
  let supported ← requireObjValAs (α := Array String)
    "server/discover result" "supportedVersions" discovery
  unless supported.contains protocolVersion do
    throw <| IO.userError
      s!"server/discover did not advertise MCP protocol {protocolVersion}: {discovery.compress}"
  sendSync stdin root pathText
  let sync ← expectResult "lean_sync" =<<
    readResponse stdout (toJson (2 : Nat)) "lean_sync response"
  let syncResultType ← requireObjValAs (α := String) "lean_sync result" "resultType" sync
  if syncResultType != "complete" then
    throw <| IO.userError s!"lean_sync returned resultType {syncResultType}, expected complete"
  match sync.getObjVal? "isError" with
  | .ok (.bool true) =>
      throw <| IO.userError s!"lean_sync returned an MCP tool error: {sync.compress}"
  | _ => pure ()
  let structured ← requireObjVal "lean_sync result" "structuredContent" sync
  discard <| requireObjVal "lean_sync structuredContent" "document_progress" structured
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
  let root ← root
  let resolvedPath ← resolveFile root pathText
  let appPath ← IO.appPath
  let timeout ← timeoutMs
  let (stdin, child) ← (← IO.Process.spawn {
    toStdioConfig := stdio
    cmd := appPath.toString
    args := (childArgs opts).toArray
    cwd := root.toString
  }).takeStdin
  let started ← IO.monoMsNow
  let await {α} (task : Task (Except IO.Error α)) : IO α := do
    let elapsed := (← IO.monoMsNow) - started
    let some result ← Beam.waitTaskWithTimeout task (timeout - elapsed)
      | throw <| IO.userError
          s!"timed out after {timeout} ms waiting for lean-beam-mcp self-check"
    IO.ofExcept result
  -- Drain while the child serves requests: Windows pipes can fill with diagnostic traces
  -- before a response is sent. Keep the captured result typed until the diagnostic edge.
  let stderrTask ← IO.asTask child.stderr.readToEnd Task.Priority.dedicated
  -- This task owns stdin and releases it before we wait for the child's EOF shutdown.
  let protocolTask ← IO.asTask (checkProtocol stdin child.stdout root pathText) Task.Priority.dedicated
  try
    await protocolTask
    let exitTask ← IO.asTask child.wait Task.Priority.dedicated
    let exitCode ← await exitTask
    if exitCode != 0 then
      throw <| IO.userError s!"lean-beam-mcp self-check child exited with code {exitCode}"
    discard <| await stderrTask
  catch e =>
    terminateChild child
    -- Failure cleanup is best-effort too; CI's external watchdog bounds stuck pipes.
    match ← IO.wait stderrTask with
    | .ok stderr =>
        if !stderr.trimAscii.isEmpty then
          throw <| IO.userError s!"{e}\n{stderr}"
    | .error _ => pure ()
    throw e
  IO.println "Lean Beam MCP self-check passed"
  IO.println s!"  root: {root}"
  IO.println s!"  file: {resolvedPath}"
  IO.println s!"  workspace: explicit root descriptor"
  IO.println s!"  protocol: {protocolVersion}"
  IO.println "  lean_sync: ok"

end Beam.Mcp.SelfCheck
