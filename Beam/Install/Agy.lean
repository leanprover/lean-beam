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

private def hex4? : List Char → Option (Nat × List Char)
  | a :: b :: c :: d :: rest => do
      let digit (c : Char) : Option Nat :=
        if '0' ≤ c && c ≤ '9' then some (c.toNat - '0'.toNat)
        else if 'a' ≤ c && c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
        else if 'A' ≤ c && c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
        else none
      return ((((← digit a) * 16 + (← digit b)) * 16 + (← digit c)) * 16 + (← digit d), rest)
  | _ => none

/-- Detect lone UTF-16 surrogate escapes that `Lean.Json.parse` would silently replace with U+FFFD. -/
private def hasLoneSurrogate (text : String) : Bool := Id.run do
  if !text.contains "\\u" then return false
  let mut quoted := false
  let mut chars := text.toList
  while !chars.isEmpty do
    let ch := chars.head!
    chars := chars.tail!
    if !quoted then
      if ch == '"' then quoted := true
    else if ch == '"' then
      quoted := false
    else if ch == '\\' then
      match chars with
      | 'u' :: tail =>
          if let some (code, after) := hex4? tail then
            if 0xD800 ≤ code && code ≤ 0xDBFF then
              match after with
              | '\\' :: 'u' :: tail2 =>
                  if let some (low, after2) := hex4? tail2 then
                    if 0xDC00 ≤ low && low ≤ 0xDFFF then chars := after2 else return true
                  else return true
              | _ => return true
            else if 0xDC00 ≤ code && code ≤ 0xDFFF then return true
            else chars := after
          else chars := tail
      | _ :: tail => chars := tail
      | [] => break
  return false

private def readConfig? (path : String) : IO (Option (String × String)) := do
  let fp := System.FilePath.mk path
  unless ← fp.pathExists do return none
  let limit := Agy.maxConfigBytes
  let metadata ← fp.metadata
  if metadata.type != .file then
    throw <| IO.userError s!"refusing to edit non-regular Antigravity MCP config at {path}"
  if metadata.byteSize.toNat > limit then
    throw <| IO.userError s!"Antigravity MCP config at {path} exceeds the 1 MiB size limit"
  let handle ← IO.FS.Handle.mk fp .read
  let mut bytes := ByteArray.empty
  while bytes.size ≤ limit do
    let next ← handle.read (limit + 1 - bytes.size).toUSize
    if next.isEmpty then break
    bytes := bytes ++ next
  if bytes.size > limit then
    throw <| IO.userError s!"Antigravity MCP config at {path} exceeds the 1 MiB size limit"
  let some text := String.fromUTF8? bytes
    | throw <| IO.userError s!"refusing to edit invalid Antigravity MCP config at {path}: expected UTF-8"
  return some (text, s!"{bytes.size}:{hash bytes}")

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
      | .ok value =>
          if hasLoneSurrogate text then
            throw <| invalid "unsupported lone UTF-16 surrogate escape; edit the file manually or use agy mcp add"
          pure value
      | .error _ =>
          if (parseAgyConfig text).isOk then
            throw <| invalid "the file contains comments or trailing commas the installer cannot preserve; remove them or use agy mcp add"
          throw <| invalid "not valid JSON"
  let .ok rootMap := root.getObj? | throw <| invalid "root JSON value must be an object"
  let servers := (field? root "mcpServers").getD (Json.mkObj [])
  let .ok serversMap := servers.getObj? | throw <| invalid "'mcpServers' must be a JSON object"
  let prior := (field? servers "lean-beam").getD (Json.mkObj [])
  let conflict (reason : String) := IO.userError
    s!"refusing to edit conflicting 'mcpServers.lean-beam' in Antigravity MCP config at {path}: {reason}; adjust or rename the entry and rerun the installer"
  let .ok beforeMap := prior.getObj? | throw <| conflict "must be a JSON object"
  let launch ← IO.ofExcept ((Agy.validateEntry prior (install := true)).mapError
    (fun error => conflict error.message))
  let desiredArgs? :=
    if toolset == "core" then some coreToolsetArgs
    else if !launch.args.isEmpty then none
    else field? prior "args"
  let changes := [
    ("command", field? prior "command", some (Json.str command)),
    ("disabled", field? prior "disabled", some (Json.bool false)),
    ("args", field? prior "args", desiredArgs?)
  ].filter fun (_, before, after) => before != after
  if changes.isEmpty then return none
  let afterMap := changes.foldl (fun acc (key, _, after) =>
    match after with
    | some value => acc.insert key value
    | none => acc.erase key) beforeMap
  let updated := Json.obj (rootMap.insert "mcpServers" (.obj (serversMap.insert "lean-beam" (.obj afterMap))))
  let output := updated.pretty ++ "\n"
  if output.utf8ByteSize > Agy.maxConfigBytes then
    throw <| invalid "the updated file would exceed the 1 MiB size limit"
  if !(Json.parse output).isOk then
    throw <| invalid "cannot safely serialize this file without altering JSON syntax; edit the file manually or use agy mcp add"
  let preview := if !showPreview then "" else if blank then output else
    String.join (changes.map fun (key, before, after) => fieldDiff key before after)
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
  IO.println (if edit.isSome then fingerprint else "noop")

private def render (path command toolset expectedFingerprint : String) : IO Unit := do
  let (text, fingerprint) := (← readConfig? path).getD ("", "absent")
  if fingerprint != expectedFingerprint then
    throw <| IO.userError s!"Antigravity MCP config changed before writing {path}; rerun the installer"
  let some edit ← edit? path command toolset text false
    | throw <| IO.userError s!"Antigravity MCP config no longer requires editing at {path}; rerun the installer"
  let stdout ← IO.getStdout
  stdout.putStr edit.output
  stdout.flush

def run (args : List String) : IO Unit := do
  match args with
  | ["plan", path, command, "--toolset", toolset] => plan path command toolset false
  | ["plan", path, command, "--toolset", toolset, "--preview"] => plan path command toolset true
  | ["render", path, command, "--toolset", toolset, fingerprint] =>
      render path command toolset fingerprint
  | _ => throw <| IO.userError (
      "usage: beam-install-runtime agy-mcp plan PATH COMMAND --toolset full|core [--preview] | agy-mcp render PATH COMMAND --toolset full|core FINGERPRINT")

end Beam.Install.Agy
