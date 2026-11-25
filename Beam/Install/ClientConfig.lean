/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake.Toml.Load
import Lean.Data.Json
import Lean.Util.Diff

namespace Beam.Install.ClientConfig

open Lean Lake.Toml

private def readToml (path text : String) : IO Table := do
  match ← (loadToml (Parser.mkInputContext text path (normalizeLineEndings := false))).toBaseIO with
  | .ok table => return table
  | .error _ => throw <| IO.userError s!"refusing to edit invalid TOML at {path}"

private def sourceRange (ref : Syntax) : IO Syntax.Range := do
  let some range := ref.getRange? |
    throw <| IO.userError "missing TOML source range"
  return range

private def lineStart (text : String) (pos : String.Pos.Raw) : String.Pos.Raw := Id.run do
  let mut pos := pos
  while pos.byteIdx > 0 do
    let prev := pos.prev text
    if prev.get text == '\n' then
      break
    pos := prev
  return pos

private def nextLine (text : String) (pos : String.Pos.Raw) : String.Pos.Raw := Id.run do
  let mut pos := pos
  while !pos.atEnd text do
    let c := pos.get text
    pos := pos.next text
    if c == '\n' then
      break
  return pos

private def replaceRange (text : String) (range : Syntax.Range) (replacement : String) : String :=
  String.Pos.Raw.extract text 0 range.start ++ replacement ++
    String.Pos.Raw.extract text range.stop text.rawEndPos

private def lineEnding (text : String) : String :=
  if (text.splitOn "\r\n").length > 1 then "\r\n" else "\n"

private def writeStdout (text : String) : IO Unit := do
  let stdout ← IO.getStdout
  stdout.putStr text
  stdout.flush

def codexParallelTools (path snapshot : String) : IO Unit := do
  if snapshot == "-" then
    throw <| IO.userError s!"Codex MCP config disappeared during registration at {path}"
  let text ← IO.FS.readFile snapshot
  let config ← readToml path text
  let some (.table _ servers) := config.find? `mcp_servers |
    throw <| IO.userError s!"Codex MCP config lacks the lean-beam server table at {path}"
  let some (.table header server) := servers.find? (Name.mkSimple "lean-beam") |
    throw <| IO.userError s!"Codex MCP config lacks the lean-beam server table at {path}"
  unless header.isOfKind `Lake.Toml.stdTable do
    throw <| IO.userError s!"Codex MCP config must use a standard table for lean-beam at {path}"
  let updated ← match server.find? `supports_parallel_tool_calls with
    | some (.boolean ref _) => pure <| replaceRange text (← sourceRange ref) "true"
    | some _ =>
      throw <| IO.userError s!"Codex lean-beam supports_parallel_tool_calls must be a boolean at {path}"
    | none =>
      let endOfHeader := (← sourceRange header).stop
      let pos := nextLine text endOfHeader
      let eol := lineEnding text
      let separator := if (pos.prev text).get text == '\n' then "" else eol
      pure <| replaceRange text ⟨pos, pos⟩ (separator ++ "supports_parallel_tool_calls = true" ++ eol)
  writeStdout updated

/-- A target Vibe table can be removed as a contiguous block if it has no explicit subtables. -/
private partial def vibeFieldEnd (value : Value) : IO String.Pos.Raw := do
  let ref := value.ref
  if ref.isOfKind `Lake.Toml.stdTable || ref.isOfKind `Lake.Toml.arrayTable then
    throw <| IO.userError "Vibe lean-beam subtable is unsupported; use inline fields in the server block"
  let stop := (← sourceRange ref).stop
  match value with
  | .table _ fields =>
    fields.items.foldlM (init := stop) fun last (_, field) => return max last (← vibeFieldEnd field)
  | .array _ values =>
    values.foldlM (init := stop) fun last field => return max last (← vibeFieldEnd field)
  | _ => return stop

private def vibeBlockLines (command toolset : String) : Array String :=
  let argsLine := if toolset == "core" then "args = [\"--toolset\", \"core\"]" else "args = []"
  #["[[mcp_servers]]", "name = \"lean-beam\"", "transport = \"stdio\"",
    s!"command = [{ppString command}]", argsLine, "tool_timeout_sec = 600"]

private def redactVibeBlock (server : Table) : Array String := Id.run do
  -- Print only known keys and fixed placeholders for arbitrary prior values.
  let mut lines := #["[[mcp_servers]]", "name = \"lean-beam\""]
  for key in [`transport, `command, `args, `tool_timeout_sec] do
    if (server.find? key).isSome then
      lines := lines.push s!"{key} = <redacted>"
  if server.items.any (fun (key, _) =>
    !([`name, `transport, `command, `args, `tool_timeout_sec].contains key)) then
    lines := lines.push "# Other settings redacted"
  return lines

def vibeRegistration (path snapshot command toolset : String) (preview : Bool) : IO Unit := do
  unless toolset == "full" || toolset == "core" do
    throw <| IO.userError s!"invalid Mistral Vibe MCP toolset: {toolset} (expected full or core)"
  let text ← if snapshot == "-" then pure "" else IO.FS.readFile snapshot
  let config ← readToml path text
  let eol := lineEnding text
  let lines := vibeBlockLines command toolset
  let block := String.intercalate eol lines.toList ++ eol
  let mut ranges := #[]
  let mut before := #[]
  let mut remaining := text
  if let some entry := config.find? `mcp_servers then
    match entry with
    | .array header entries =>
      if entries.isEmpty then
        let range ← sourceRange header
        remaining := replaceRange text ⟨lineStart text range.start, nextLine text range.stop⟩ ""
      else
        unless header.isOfKind `Lake.Toml.arrayTable do
          throw <| IO.userError s!"refusing to edit Mistral Vibe config with inline mcp_servers entries at {path}; move them to [[mcp_servers]] tables first"
        for entry in entries do
          let .table header server := entry |
            throw <| IO.userError "invalid Mistral Vibe [[mcp_servers]] entry"
          let some (.string ref name) := server.find? `name |
            throw <| IO.userError "Mistral Vibe [[mcp_servers]] entries must have a string name"
          unless header.isOfKind `Lake.Toml.arrayTable &&
              (ref[0].isOfKind `Lake.Toml.basicString || ref[0].isOfKind `Lake.Toml.literalString) do
            throw <| IO.userError "Mistral Vibe [[mcp_servers]] entries must have a single-line name"
          if name == "lean-beam" then
            let range ← sourceRange header
            let stop ← server.items.foldlM (init := range.stop) fun last (_, field) =>
              return max last (← vibeFieldEnd field)
            ranges := ranges.push (⟨lineStart text range.start, nextLine text stop⟩ : Syntax.Range)
            if preview then
              before := before ++ redactVibeBlock server
    | _ => throw <| IO.userError "Mistral Vibe mcp_servers must be an array of server tables"
  if ranges.isEmpty then
    let separator := if remaining.isEmpty then "" else
      if remaining.endsWith eol then eol else eol ++ eol
    remaining := remaining ++ separator ++ block
  else
    for i in (List.range ranges.size).reverse do
      remaining := replaceRange remaining ranges[i]! (if i == 0 then block else "")
  discard <| readToml path remaining
  if preview then
    IO.eprintln "--- Current Mistral Vibe lean-beam block (redacted)"
    IO.eprintln "+++ Proposed Mistral Vibe lean-beam block"
    for (action, line) in Diff.diff before lines do
      IO.eprintln (action.linePrefix ++ line)
  writeStdout remaining

def claudeUserRegistration (path : String) : IO Unit := do
  let text ← IO.FS.readFile path
  let registration : Except String Bool := do
    let config ← (← Json.parse text).getObj?
    match config.get? "mcpServers" with
    | none => return false
    | some servers => return (← servers.getObj?).contains "lean-beam"
  match registration with
  | .ok present => IO.println (if present then "present" else "absent")
  | .error _ => throw <| IO.userError s!"refusing to edit invalid Claude Code MCP config at {path}"

end Beam.Install.ClientConfig
