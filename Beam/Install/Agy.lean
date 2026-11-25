/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Config.Agy
import Beam.Install.Checksum

namespace Beam.Install.Agy

open Beam.Config StrictJson

private structure Snapshot where
  physical : String
  stamp : String
  bytes : ByteArray

@[extern "beam_agy_config_read"]
private opaque readSnapshot (requested : @& String) : IO Snapshot

@[extern "beam_agy_config_replace"]
private opaque replaceConfig (requested physical stamp : @& String)
    (before after : @& ByteArray) : IO Unit

private def readRequested (requested : String) : IO Snapshot := do
  try readSnapshot requested
  catch error => throw <| IO.userError s!"{requested}: {error}"

private def Snapshot.text (snapshot : Snapshot) : IO String := do
  let some text := String.fromUTF8? snapshot.bytes
    | throw <| IO.userError s!"invalid Antigravity MCP config at {snapshot.physical}: expected UTF-8"
  return text

private def Snapshot.fingerprint (snapshot : Snapshot) (text : String) : IO String := do
  let checksum ← Checksum.select
  return snapshot.stamp ++ ":" ++ (← checksum.textHash text)

private structure Edit where
  output : String
  preview : String

private def fieldDiff (key : String) (before after : Option Value) : String :=
  let render (marker : String) (value : Value) :=
    s!"{marker}  {(Lean.Json.str key).compress}: {value.compress}\n"
  (before.map (render "-")).getD "" ++ (after.map (render "+")).getD ""

private def coreToolsetArgs : Value :=
  .arr #[.str "--toolset", .str "core"]

private def edit? (path command toolset text : String) (showPreview : Bool) : IO (Option Edit) := do
  unless toolset == "full" || toolset == "core" do
    throw <| IO.userError s!"invalid Antigravity MCP toolset: {toolset} (expected full or core)"
  let invalid (reason : String) := IO.userError
    s!"refusing to edit invalid Antigravity MCP config at {path}: {reason}"
  let root ← match StrictJson.parse text with
    | .ok value => pure value
    | .error error =>
        if (StrictJson.parse text (jsonc := true)).isOk then
          throw <| invalid "the file contains comments or trailing commas the installer cannot preserve; remove them or use agy mcp add"
        throw <| invalid error
  let (root, servers) ← IO.ofExcept ((Agy.servers root).mapError invalid)
  let prior := (Fields.get? servers "lean-beam").getD (.obj #[])
  let conflict (reason : String) := IO.userError
    s!"refusing to edit conflicting 'mcpServers.lean-beam' in Antigravity MCP config at {path}: {reason}; adjust or rename the entry and rerun the installer"
  let .obj before := prior | throw <| conflict "must be a JSON object"
  let launch ← IO.ofExcept ((Agy.validateEntry prior.forInspection (install := true)).mapError
    (fun error => conflict error.message))
  let oldDisabled := Fields.get? before "disabled"
  let oldArgs := Fields.get? before "args"
  let commandChanged := launch.command? != some command
  let disabledChanged := oldDisabled.isNone
  let (argsChanged, newArgs?) :=
    if toolset == "core" then
      (launch.args != #["--toolset", "core"], some coreToolsetArgs)
    else if !launch.args.isEmpty then
      (true, none)
    else
      (false, oldArgs)
  if !commandChanged && !disabledChanged && !argsChanged then return none
  let newCommand := Value.str command
  let newDisabled := Value.bool false
  let after := Fields.set (Fields.set before "command" newCommand) "disabled" newDisabled
  let after := match newArgs? with
    | some argsVal => if argsChanged then Fields.set after "args" argsVal else after
    | none => if argsChanged then Fields.erase after "args" else after
  let servers := Fields.set servers "lean-beam" (.obj after)
  let updated := Value.obj (Fields.set root "mcpServers" (.obj servers))
  let blank := StrictJson.isBlank text
  let output := (if blank then updated.forInspection.pretty else updated.compress) ++ "\n"
  if output.utf8ByteSize > StrictJson.maxBytes then
    throw <| invalid "the updated file would exceed the 1 MiB size limit"
  let preview := if !showPreview then "" else if blank then output else
    (if commandChanged then fieldDiff "command" (Fields.get? before "command") (some newCommand) else "") ++
    (if disabledChanged then fieldDiff "disabled" oldDisabled (some newDisabled) else "") ++
    (if argsChanged then fieldDiff "args" oldArgs newArgs? else "")
  return some { output, preview }

private def plan (requested command toolset : String) (expectedPath : Option String)
    (preview : Bool) : IO Unit := do
  let snapshot ← readRequested requested
  if expectedPath.any (· != snapshot.physical) then
    throw <| IO.userError "Antigravity MCP config location changed before planning; rerun the installer"
  let text ← snapshot.text
  let edit ← edit? snapshot.physical command toolset text preview
  let fingerprint ← snapshot.fingerprint text
  if let some edit := edit then
    if preview then
      let stderr ← IO.getStderr
      stderr.putStrLn s!"\nInstaller wants to register lean-beam MCP server in the Antigravity config at {(Lean.Json.str snapshot.physical).compress}"
      stderr.putStr edit.preview
      stderr.flush
  -- The shell reads two fixed-format lines, then the entire physical path.
  IO.println s!"{if edit.isSome then "edit" else "noop"}\n{fingerprint}\n{snapshot.physical}"

private def apply (requested command toolset physical fingerprint : String) : IO Unit := do
  let snapshot ← readRequested requested
  if snapshot.physical != physical then
    throw <| IO.userError "Antigravity MCP config location changed before writing; rerun the installer"
  let text ← snapshot.text
  if (← snapshot.fingerprint text) != fingerprint then
    throw <| IO.userError "Antigravity MCP config changed before writing; rerun the installer"
  if let some edit ← edit? physical command toolset text false then
    try replaceConfig requested physical snapshot.stamp snapshot.bytes edit.output.toUTF8
    catch error => throw <| IO.userError s!"{physical}: {error}"

def run (args : List String) : IO Unit := do
  match args with
  | ["plan", requested, command] => plan requested command "full" none false
  | ["plan", requested, command, physical] => plan requested command "full" (some physical) false
  | ["plan", requested, command, physical, "--preview"] =>
      plan requested command "full" (some physical) true
  | ["plan", requested, command, physical, "--toolset", toolset] =>
      plan requested command toolset (some physical) false
  | ["plan", requested, command, physical, "--toolset", toolset, "--preview"] =>
      plan requested command toolset (some physical) true
  | ["apply", requested, command, physical, fingerprint] =>
      apply requested command "full" physical fingerprint
  | ["apply", requested, command, physical, fingerprint, "--toolset", toolset] =>
      apply requested command toolset physical fingerprint
  | _ => throw <| IO.userError (
      "usage: beam-install-runtime agy-mcp plan PATH COMMAND [PHYSICAL [--toolset full|core] [--preview]] | agy-mcp apply PATH COMMAND PHYSICAL FINGERPRINT [--toolset full|core]")

end Beam.Install.Agy
