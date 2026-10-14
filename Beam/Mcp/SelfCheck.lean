/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Protocol
import Beam.Mcp.Stdio
import Beam.Path
import Beam.Mcp.SelfCheck.Pipe

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

private def timeoutMessage (phase : String) (timeoutMs : Nat) : String :=
  s!"timed out after {timeoutMs} ms waiting for lean-beam-mcp self-check {phase}"

private structure Deadline where
  phase : String
  timeoutMs : Nat
  expiresAt : Nat

private def Deadline.start (phase : String) (timeoutMs : Nat) : IO Deadline := do
  pure { phase, timeoutMs, expiresAt := (← IO.monoMsNow) + timeoutMs }

private def Deadline.remaining (deadline : Deadline) : IO Nat := do
  pure <| deadline.expiresAt - (← IO.monoMsNow)

private def Deadline.timeout (deadline : Deadline) : IO.Error :=
  IO.userError (timeoutMessage deadline.phase deadline.timeoutMs)

private def Deadline.check (deadline : Deadline) : IO Unit := do
  if (← deadline.remaining) == 0 then
    throw deadline.timeout

private def Deadline.pause (deadline : Deadline) : IO Unit := do
  deadline.check
  IO.sleep (min (← deadline.remaining) 10).toUInt32

private abbrev childStdio : IO.Process.StdioConfig := { stdio with stdin := .null }

private structure ChildState where
  exitCode? : Option UInt32 := none
  pending : ByteArray := .empty
  stderrTail : ByteArray := .empty
  stderrOpen : Bool := true
  pipesReady : Bool := false

/-- A single controller owns all pipe I/O and reaping. No blocking tasks survive cleanup. -/
private structure OwnedChild where
  child : IO.Process.Child childStdio
  state : IO.Ref ChildState

private def OwnedChild.start (child : IO.Process.Child childStdio) : IO OwnedChild := do
  pure { child, state := ← IO.mkRef {} }

private def OwnedChild.configure (owner : OwnedChild) (stdin : IO.FS.Handle) : IO Unit := do
  Pipe.nonblocking stdin
  Pipe.nonblocking owner.child.stdout
  Pipe.nonblocking owner.child.stderr
  owner.state.modify fun state => { state with pipesReady := true }

/-- Cache the first result: supported Lean runtimes need not allow a second wait after reaping. -/
private def OwnedChild.pollExit (owner : OwnedChild) : IO (Option UInt32) := do
  if let some code := (← owner.state.get).exitCode? then
    return some code
  let code? ← owner.child.tryWait
  owner.state.modify fun state => { state with exitCode? := code? }
  pure code?

/-- Diagnostics are best effort, bounded, and never part of protocol success. -/
private def OwnedChild.captureStderr (owner : OwnedChild) : IO Bool := do
  let state ← owner.state.get
  unless state.pipesReady && state.stderrOpen do return false
  try
    let some chunk ← Pipe.read owner.child.stderr | return false
    let tail := state.stderrTail ++ chunk
    owner.state.modify fun state => { state with
      stderrOpen := !chunk.isEmpty
      stderrTail := tail.extract (tail.size - 8192) tail.size }
    return !chunk.isEmpty
  catch _ =>
    owner.state.modify fun state => { state with stderrOpen := false }
    return false

private def OwnedChild.stderrText (owner : OwnedChild) : IO String := do
  let bytes := (← owner.state.get).stderrTail
  -- A bounded byte tail can start inside a UTF-8 character. Skip its continuation bytes.
  let mut start := 0
  while start < bytes.size && bytes[start]! >= 128 && bytes[start]! < 192 do
    start := start + 1
  pure <| (String.fromUTF8? (bytes.extract start bytes.size)).getD "<stderr tail is not valid UTF-8>"

private partial def OwnedChild.waitForExit (owner : OwnedChild) (deadline : Deadline) : IO UInt32 := do
  deadline.check
  let mut progress ← owner.captureStderr
  if (← owner.state.get).pipesReady then
    -- The server may still be writing notifications after the final response. Discard them
    -- during teardown so its stdout buffer cannot prevent it from processing stdin EOF.
    try
      if let some chunk ← Pipe.read owner.child.stdout then
        progress := progress || !chunk.isEmpty
    catch _ => pure ()
  if let some code ← owner.pollExit then
    -- Collect already available diagnostics, but never wait for EOF from descendants.
    -- Cap both work and time even if a descendant writes continuously.
    for _ in [:128] do
      if (← deadline.remaining) == 0 then break
      unless ← owner.captureStderr do break
    return code
  unless progress do deadline.pause
  owner.waitForExit deadline

private def OwnedChild.finish (owner : OwnedChild) (timeoutMs : Nat) : IO Unit := do
  let code ← owner.waitForExit (← Deadline.start "EOF teardown" timeoutMs)
  if code != 0 then
    throw <| IO.userError s!"lean-beam-mcp self-check child exited with code {code}"

private def OwnedChild.terminate (owner : OwnedChild) : IO Unit := do
  let deadline ← Deadline.start "cleanup" 1000
  if (← owner.pollExit).isNone then
    try
      owner.child.kill
    catch err =>
      if (← owner.pollExit).isNone then throw err
  discard <| owner.waitForExit deadline

private def decodeLine (bytes : ByteArray) : IO String := do
  let some line := String.fromUTF8? bytes
    | throw <| IO.userError "lean-beam-mcp self-check child wrote invalid UTF-8"
  pure <| Beam.Mcp.Stdio.stripLineEnding line

private partial def readLine (owner : OwnedChild) (deadline : Deadline) : IO String := do
  deadline.check
  let progress ← owner.captureStderr
  let pending := (← owner.state.get).pending
  let endPos? := pending.findIdx? (· == 10)
  -- Limit a frame, not the entire buffer: one read may include several lines.
  if endPos?.getD pending.size > 1024 * 1024 then
    throw <| IO.userError "lean-beam-mcp self-check response exceeds 1 MiB"
  if let some endPos := endPos? then
    let line := pending.extract 0 endPos
    owner.state.modify fun state =>
      { state with pending := pending.extract (endPos + 1) pending.size }
    return ← decodeLine line
  match ← Pipe.read owner.child.stdout with
  | none => unless progress do deadline.pause
  | some chunk =>
    if chunk.isEmpty then
      owner.state.modify fun state => { state with pending := .empty }
      return ← decodeLine pending
    owner.state.modify fun state => { state with pending := pending ++ chunk }
  readLine owner deadline

private def send (owner : OwnedChild) (stdin : IO.FS.Handle) (json : Json)
    (deadline : Deadline) : IO Unit := do
  let bytes := (json.compress ++ "\n").toUTF8
  let mut offset := 0
  while offset < bytes.size do
    deadline.check
    discard <| owner.captureStderr
    let written ← Pipe.write stdin bytes offset.toUSize
    offset := offset + written.toNat
    if written == 0 then deadline.pause

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
    (owner : OwnedChild)
    (expectedId : Json)
    (deadline : Deadline) : IO Json := do
  let phase := deadline.phase
  let line ← readLine owner deadline
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
          readResponse owner expectedId deadline
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

private def discoverRequest : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (1 : Nat)),
    ("method", toJson "server/discover"),
    ("params", Json.mkObj [
      ("_meta", modernMeta)
    ])
  ]

private def syncRequest (root : System.FilePath) (pathText : String) : Json :=
  Json.mkObj [
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
    (owner : OwnedChild) (stdin : IO.FS.Handle) (root : System.FilePath)
    (pathText : String) (timeout : Nat) : IO Unit := do
  let discoveryDeadline ← Deadline.start "server/discover response" timeout
  send owner stdin discoverRequest discoveryDeadline
  let discovery ← expectResult "server/discover" =<<
    readResponse owner (toJson (1 : Nat)) discoveryDeadline
  let resultType ← requireObjValAs (α := String) "server/discover result" "resultType" discovery
  if resultType != "complete" then
    throw <| IO.userError s!"server/discover returned resultType {resultType}, expected complete"
  let supported ← requireObjValAs (α := Array String)
    "server/discover result" "supportedVersions" discovery
  unless supported.contains protocolVersion do
    throw <| IO.userError
      s!"server/discover did not advertise MCP protocol {protocolVersion}: {discovery.compress}"
  let syncDeadline ← Deadline.start "lean_sync response" timeout
  send owner stdin (syncRequest root pathText) syncDeadline
  let sync ← expectResult "lean_sync" =<<
    readResponse owner (toJson (2 : Nat)) syncDeadline
  let syncResultType ← requireObjValAs (α := String) "lean_sync result" "resultType" sync
  if syncResultType != "complete" then
    throw <| IO.userError s!"lean_sync returned resultType {syncResultType}, expected complete"
  match sync.getObjVal? "isError" with
  | .ok (.bool true) =>
      throw <| IO.userError s!"lean_sync returned an MCP tool error: {sync.compress}"
  | _ => pure ()
  let structured ← requireObjVal "lean_sync result" "structuredContent" sync
  discard <| requireObjVal "lean_sync structuredContent" "document_progress" structured

def run (opts : Options) (pathText : String) : IO Unit := do
  let root ← root
  let resolvedPath ← resolveFile root pathText
  let timeout ← timeoutMs
  let (stdin, child) ← (← IO.Process.spawn {
    toStdioConfig := stdio
    cmd := (← IO.appPath).toString
    args := (childArgs opts).toArray
    cwd := root.toString
  }).takeStdin
  let owner ← OwnedChild.start child
  try
    owner.configure stdin
    -- Last use of the extracted input closes it before teardown, sending EOF to the server.
    checkProtocol owner stdin root pathText timeout
    owner.finish timeout
    IO.println "Lean Beam MCP self-check passed"
    IO.println s!"  root: {root}"
    IO.println s!"  file: {resolvedPath}"
    IO.println s!"  workspace: explicit root descriptor"
    IO.println s!"  protocol: {protocolVersion}"
    IO.println "  lean_sync: ok"
  catch e =>
    let cleanupError? ← try
      owner.terminate
      pure none
    catch cleanupError => pure (some cleanupError)
    let tail := (← owner.stderrText).trimAscii.toString
    let message := e.toString ++ (if tail.isEmpty then "" else s!"\nstderr tail:\n{tail}")
    let message := match cleanupError? with
      | none => message
      | some cleanupError => message ++ s!"\nself-check cleanup failed: {cleanupError}"
    throw <| IO.userError message

end Beam.Mcp.SelfCheck
