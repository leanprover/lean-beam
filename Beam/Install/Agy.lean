/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Cli.ClientDoctor.Parse
import Beam.Config.Agy

namespace Beam.Install.Agy

open Beam.Config Lean
open Beam.Cli.ClientDoctor (isBlankJson parseAgyConfig withoutBOM)

private def coreToolsetArgs : Json :=
  .arr #[.str "--toolset", .str "core"]

private def fnv64 (bytes : ByteArray) : UInt64 := Id.run do
  let mut h : UInt64 := 14695981039346656037
  for b in bytes.data do
    h := (h ^^^ b.toUInt64) * 1099511628211
  return h

private def readConfig? (path : String) : IO (Option (String × String)) := do
  let fp := System.FilePath.mk path
  unless ← fp.pathExists do return none
  let bytes ← IO.FS.readBinFile fp
  if bytes.size > Agy.maxConfigBytes then
    throw <| IO.userError s!"Antigravity MCP config at {path} exceeds the 1 MiB size limit"
  let some text := String.fromUTF8? bytes
    | throw <| IO.userError s!"refusing to edit invalid Antigravity MCP config at {path}: expected UTF-8"
  return some (text, s!"{bytes.size}:{fnv64 bytes}")

private structure Edit where
  output : String
  preview : String

private def fieldDiff (key : String) (before after : Option Json) : String :=
  let render (marker : String) (value : Json) :=
    s!"{marker}  {(Json.str key).compress}: {value.compress}\n"
  (before.map (render "-")).getD "" ++ (after.map (render "+")).getD ""

private def field? (obj : Json) (key : String) : Option Json :=
  (obj.getObjVal? key).toOption

private def edit? (path command toolset text : String) (showPreview : Bool) : IO (Option Edit) := do
  unless toolset == "full" || toolset == "core" do
    throw <| IO.userError s!"invalid Antigravity MCP toolset: {toolset} (expected full or core)"
  let invalid (reason : String) := IO.userError
    s!"refusing to edit invalid Antigravity MCP config at {path}: {reason}"
  let blank := isBlankJson text
  let root ← if blank then pure (Json.mkObj [])
    else match Json.parse (withoutBOM text) with
      | .ok value => pure value
      | .error error =>
          if (parseAgyConfig text).isOk then
            throw <| invalid "the file contains comments or trailing commas the installer cannot preserve; remove them or use agy mcp add"
          throw <| invalid error
  let servers ← IO.ofExcept ((Agy.servers root).mapError invalid)
  let prior := (field? servers "lean-beam").getD (Json.mkObj [])
  let conflict (reason : String) := IO.userError
    s!"refusing to edit conflicting 'mcpServers.lean-beam' in Antigravity MCP config at {path}: {reason}; adjust or rename the entry and rerun the installer"
  let .ok beforeMap := prior.getObj? | throw <| conflict "must be a JSON object"
  let launch ← IO.ofExcept ((Agy.validateEntry prior (install := true)).mapError
    (fun error => conflict error.message))
  let oldDisabled := field? prior "disabled"
  let oldArgs := field? prior "args"
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
  let newCommand := Json.str command
  let newDisabled := Json.bool false
  let afterMap := (beforeMap.insert "command" newCommand).insert "disabled" newDisabled
  let afterMap := match newArgs? with
    | some argsVal => if argsChanged then afterMap.insert "args" argsVal else afterMap
    | none => if argsChanged then afterMap.erase "args" else afterMap
  let .ok rootMap := root.getObj? | throw <| invalid "root JSON value must be an object"
  let .ok serversMap := servers.getObj? | throw <| invalid "'mcpServers' must be a JSON object"
  let updated := Json.obj (rootMap.insert "mcpServers" (.obj (serversMap.insert "lean-beam" (.obj afterMap))))
  let output := updated.pretty ++ "\n"
  if output.utf8ByteSize > Agy.maxConfigBytes then
    throw <| invalid "the updated file would exceed the 1 MiB size limit"
  let preview := if !showPreview then "" else if blank then output else
    (if commandChanged then fieldDiff "command" (field? prior "command") (some newCommand) else "") ++
    (if disabledChanged then fieldDiff "disabled" oldDisabled (some newDisabled) else "") ++
    (if argsChanged then fieldDiff "args" oldArgs newArgs? else "")
  return some { output, preview }

private def plan (path command toolset : String) (preview : Bool) : IO Unit := do
  let (text, fingerprint) := (← readConfig? path).getD ("", "absent")
  let edit ← edit? path command toolset text preview
  if let some edit := edit then
    if preview then
      let stderr ← IO.getStderr
      stderr.putStrLn s!"\nInstaller wants to register lean-beam MCP server in the Antigravity config at {(Json.str path).compress}"
      stderr.putStr edit.preview
      stderr.flush
  IO.println s!"{if edit.isSome then "edit" else "noop"}\n{fingerprint}"

private def render (path command toolset expectedFingerprint : String) : IO Unit := do
  let (text, fingerprint) := (← readConfig? path).getD ("", "absent")
  if fingerprint != expectedFingerprint then
    throw <| IO.userError s!"Antigravity MCP config changed before writing {path}; rerun the installer"
  if let some edit ← edit? path command toolset text false then
    IO.print edit.output

def run (args : List String) : IO Unit := do
  match args with
  | ["plan", path, command, "--toolset", toolset] => plan path command toolset false
  | ["plan", path, command, "--toolset", toolset, "--preview"] => plan path command toolset true
  | ["render", path, command, "--toolset", toolset, fingerprint] =>
      render path command toolset fingerprint
  | _ => throw <| IO.userError (
      "usage: beam-install-runtime agy-mcp plan PATH COMMAND --toolset full|core [--preview] | agy-mcp render PATH COMMAND --toolset full|core FINGERPRINT")

end Beam.Install.Agy
