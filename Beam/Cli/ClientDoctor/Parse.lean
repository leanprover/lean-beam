/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Lake.Toml.Load

namespace Beam.Cli.ClientDoctor

open Lean

inductive Format where
  | json | jsonc | toml
  deriving BEq

/-- Preserve strings and line breaks while removing JSONC comments. No source text escapes errors. -/
private def withoutComments (text : String) : Except Unit String := do
  let mut result := ""
  let mut quoted := false
  let mut escaped := false
  let mut lineComment := false
  let mut blockComment := false
  let mut chars := text.toList
  while !chars.isEmpty do
    let ch := chars.head!
    chars := chars.tail!
    if lineComment then
      result := result.push (if ch == '\n' then '\n' else ' ')
      if ch == '\n' then lineComment := false
    else if blockComment then
      if ch == '*' && chars.head? == some '/' then
        chars := chars.tail!
        result := result ++ "  "
        blockComment := false
      else
        result := result.push (if ch == '\n' then '\n' else ' ')
    else if quoted then
      result := result.push ch
      if escaped then escaped := false
      else if ch == '\\' then escaped := true
      else if ch == '"' then quoted := false
    else if ch == '"' then
      result := result.push ch
      quoted := true
    else if ch == '/' && chars.head? == some '/' then
      chars := chars.tail!
      result := result ++ "  "
      lineComment := true
    else if ch == '/' && chars.head? == some '*' then
      chars := chars.tail!
      result := result ++ "  "
      blockComment := true
    else
      result := result.push ch
  if blockComment then throw ()
  return result

private def withoutTrailingCommas (text : String) : String := Id.run do
  let mut result := ""
  let mut quoted := false
  let mut escaped := false
  let mut previous := ' '
  let mut chars := text.toList
  while !chars.isEmpty do
    let ch := chars.head!
    chars := chars.tail!
    if quoted then
      result := result.push ch
      if escaped then escaped := false
      else if ch == '\\' then escaped := true
      else if ch == '"' then quoted := false
    else if ch == '"' then
      result := result.push ch
      quoted := true
    else
      -- Look ahead only at commas, keeping long whitespace runs linear.
      let trailing := if ch != ',' then false else
        let next := (chars.dropWhile Char.isWhitespace).head?
        -- Do not turn invalid missing-value constructs such as [,] into JSON.
        (next == some ']' || next == some '}') &&
          !(['[', '{', ':', ','].contains previous)
      result := result.push (if trailing then ' ' else ch)
    if !ch.isWhitespace then previous := ch
  return result

private partial def tomlJson : Lake.Toml.Value → Json
  | .string _ s => toJson s
  | .integer _ n => toJson n
  | .boolean _ b => toJson b
  | .array _ values => .arr (values.map tomlJson)
  | .table _ values => Json.mkObj <|
      values.items.toList.map fun (key, value) => (key.getString!, tomlJson value)
  -- These TOML types are not launch or skill fields. Retain a non-string value for type checks.
  | .float .. | .dateTime .. => .null

/-- Parse in-process. Errors deliberately contain neither input fragments nor parser messages. -/
def parseConfig (format : Format) (text : String) : IO (Except Unit Json) := do
  match format with
  | .json => return (Json.parse text).mapError (fun _ => ())
  | .jsonc =>
      return (withoutComments text).bind fun text =>
        (Json.parse (withoutTrailingCommas text)).mapError (fun _ => ())
  | .toml =>
      match ← (Lake.Toml.loadToml (Parser.mkInputContext text "client-config")).toBaseIO with
      | .ok table => return .ok <| tomlJson (.table .missing table)
      | .error _ => return .error ()

end Beam.Cli.ClientDoctor
