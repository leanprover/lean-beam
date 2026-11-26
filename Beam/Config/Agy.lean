/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean

namespace Beam.Config.Agy

def maxConfigBytes : Nat := 1024 * 1024

private def field? (value : Lean.Json) (key : String) : Option Lean.Json :=
  (value.getObjVal? key).toOption

private def stringArray (value : Lean.Json) : Option (Array String) := do
  (← value.getArr?.toOption).mapM (·.getStr?.toOption)

/-- Validate root and `mcpServers` container types using `Lean.Json`. -/
def servers (value : Lean.Json) : Except String Lean.Json := do
  unless value.getObj?.isOk do throw "root JSON value must be an object"
  match field? value "mcpServers" with
  | none => return Lean.Json.mkObj []
  | some servers =>
      unless servers.getObj?.isOk do throw "'mcpServers' must be a JSON object"
      return servers

structure Launch where
  command? : Option String
  args : Array String

inductive EntryError where
  | disabled
  | invalid (message : String)

def EntryError.message : EntryError → String
  | .disabled => "'disabled' must be false or absent"
  | .invalid message => message

def isSupportedToolsetArgs (args : Array String) : Bool :=
  args.isEmpty ||
    args == #["--toolset", "full"] ||
    args == #["--toolset", "core"]

/-- The installer refuses unrelated launch arguments so it cannot silently redirect an invoker,
    while permitting Beam's own `--toolset full|core` arguments. Doctor can inspect a command
    with arguments and separately report that unknown arguments are unverified. -/
def validateEntry (value : Lean.Json) (install := false) : Except EntryError Launch := do
  unless value.getObj?.isOk do throw (.invalid "must be a JSON object")
  match field? value "disabled" with
  | some (.bool true) => throw .disabled
  | none | some (.bool false) => pure ()
  | _ => throw (.invalid "'disabled' must be a boolean")
  if ["url", "serverUrl", "httpUrl"].any (fun key => (field? value key).isSome) then
    throw (.invalid "remove the remote transport (url, serverUrl, or httpUrl)")
  for key in ["type", "transport"] do
    if (field? value key).any (· != .str "stdio") then
      throw (.invalid s!"'{key}' must specify stdio if present")
  let command? ← match field? value "command" with
    | some (.str command) => pure (some command)
    | none =>
        if install then pure none else throw (.invalid "'command' is required")
    | _ => throw (.invalid "'command' must be a string")
  let args ← match field? value "args" with
    | none => pure #[]
    | some raw =>
        let some args := stringArray raw | throw (.invalid "'args' must be an array of strings")
        if install && !isSupportedToolsetArgs args then
          throw (.invalid "'args' must be an empty array, Beam's --toolset flag, or absent")
        pure args
  if (field? value "cwd").any (! ·.getStr?.isOk) then
    throw (.invalid "'cwd' must be a string or absent")
  if let some env := field? value "env" then
    match env.getObj? with
    | .ok fields =>
        unless fields.toArray.all (·.2.getStr?.isOk) do
          throw (.invalid "'env' must be a JSON object mapping strings to strings")
    | .error _ => throw (.invalid "'env' must be a JSON object mapping strings to strings")
  for key in ["enabledTools", "disabledTools"] do
    if (field? value key).any (fun setting => (stringArray setting).isNone) then
      throw (.invalid s!"'{key}' must be an array of strings")
  if let some timeout := field? value "timeoutSeconds" then
    match timeout with
    | .num n =>
        unless n.exponent == 0 do
          throw (.invalid "'timeoutSeconds' must be an integer")
    | _ => throw (.invalid "'timeoutSeconds' must be an integer")
  return { command?, args }

end Beam.Config.Agy
