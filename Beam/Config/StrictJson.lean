/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Std.Data.HashSet

namespace Beam.Config.StrictJson

/-- Preserve object order and number spellings independently of Lean's JSON representation. -/
inductive Value where
  | null
  | bool (value : Bool)
  | str (value : String)
  | num (lexeme : String)
  | arr (items : Array Value)
  | obj (fields : Array (String × Value))
  deriving Inhabited

def maxBytes : Nat := 1024 * 1024

abbrev Fields := Array (String × Value)

def Fields.get? (fields : Fields) (key : String) : Option Value :=
  (fields.find? (·.1 == key)).map (·.2)

def Fields.set (fields : Fields) (key : String) (value : Value) : Fields :=
  match fields.findIdx? (·.1 == key) with
  | some i => fields.set! i (key, value)
  | none => fields.push (key, value)

def isWhitespace (ch : Char) : Bool :=
  ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'

def withoutBOM (text : String) : String :=
  if text.startsWith "\uFEFF" then (text.drop 1).toString else text

def isBlank (text : String) : Bool :=
  (withoutBOM text).all isWhitespace

/-- Preserve strings and line breaks while removing JSONC comments. No source text escapes errors. -/
def withoutComments (text : String) : Except Unit String := do
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
      result := result.push (if ch == '\n' || ch == '\r' then ch else ' ')
      if ch == '\n' || ch == '\r' then lineComment := false
    else if blockComment then
      if ch == '*' && chars.head? == some '/' then
        chars := chars.tail!
        result := result ++ "  "
        blockComment := false
      else
        result := result.push (if ch == '\n' || ch == '\r' then ch else ' ')
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

def withoutTrailingCommas (text : String) : String := Id.run do
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
        let next := (chars.dropWhile isWhitespace).head?
        -- Do not turn invalid missing-value constructs such as [,] into JSON.
        (next == some ']' || next == some '}') &&
          !(['[', '{', ':', ','].contains previous)
      result := result.push (if trailing then ' ' else ch)
    if !isWhitespace ch then previous := ch
  return result

private def skipSpace (bytes : ByteArray) (start : Nat) : Nat := Id.run do
  let mut pos := start
  while isWhitespace (Char.ofNat (bytes[pos]?.getD 0).toNat) do
    pos := pos + 1
  return pos

private def hexDigit (byte : UInt8) : Option Nat :=
  if 48 ≤ byte && byte ≤ 57 then some (byte.toNat - 48)
  else if 65 ≤ byte && byte ≤ 70 then some (byte.toNat - 55)
  else if 97 ≤ byte && byte ≤ 102 then some (byte.toNat - 87)
  else none

private def hexQuad (bytes : ByteArray) (start : Nat) : Except String Nat := do
  let mut code := 0
  for pos in [start:start + 4] do
    let some digit := hexDigit (bytes[pos]?.getD 0) | throw "invalid Unicode escape"
    code := 16 * code + digit
  return code

private def parseString (bytes : ByteArray) (start : Nat) : Except String (String × Nat) := do
  let mut pos := start + 1
  let mut output := ByteArray.empty
  while pos < bytes.size do
    let byte := bytes[pos]!
    pos := pos + 1
    if byte == 34 then
      let some value := String.fromUTF8? output | throw "invalid UTF-8 string"
      return (value, pos)
    if byte < 32 then throw "unescaped control character"
    if byte != 92 then
      output := output.push byte
      continue
    let escape := bytes[pos]?.getD 0
    pos := pos + 1
    match escape.toNat with
    | 34 | 47 | 92 => output := output.push escape
    | 98 => output := output.push 8
    | 102 => output := output.push 12
    | 110 => output := output.push 10
    | 114 => output := output.push 13
    | 116 => output := output.push 9
    | 117 =>
        let mut code ← hexQuad bytes pos
        pos := pos + 4
        if 0xD800 ≤ code && code ≤ 0xDBFF then
          unless bytes[pos]? == some 92 && bytes[pos + 1]? == some 117 do
            throw "unpaired Unicode surrogate"
          let low ← hexQuad bytes (pos + 2)
          unless 0xDC00 ≤ low && low ≤ 0xDFFF do throw "unpaired Unicode surrogate"
          pos := pos + 6
          code := 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
        else if 0xDC00 ≤ code && code ≤ 0xDFFF then
          throw "unpaired Unicode surrogate"
        output := output ++ (String.singleton (Char.ofNat code)).toUTF8
    | _ => throw "invalid string escape"
  throw "unterminated JSON string"

private def isDigit (byte : UInt8) : Bool :=
  48 ≤ byte && byte ≤ 57

private def digitsEnd (bytes : ByteArray) (start : Nat) : Nat := Id.run do
  let mut pos := start
  while isDigit (bytes[pos]?.getD 0) do
    pos := pos + 1
  return pos

private def parseNumber (bytes : ByteArray) (start : Nat) : Except String (Value × Nat) := do
  let mut pos := if bytes[start]? == some 45 then start + 1 else start
  let first := bytes[pos]?.getD 0
  unless isDigit first do throw "invalid JSON number"
  pos := if first == 48 then pos + 1 else digitsEnd bytes pos
  if bytes[pos]? == some 46 then
    let endPos := digitsEnd bytes (pos + 1)
    if endPos == pos + 1 then throw "invalid JSON fraction"
    pos := endPos
  if bytes[pos]? == some 101 || bytes[pos]? == some 69 then
    pos := pos + 1
    if bytes[pos]? == some 43 || bytes[pos]? == some 45 then pos := pos + 1
    let endPos := digitsEnd bytes pos
    if endPos == pos then throw "invalid JSON exponent"
    pos := endPos
  return (.num (String.fromUTF8! (bytes.extract start pos)), pos)

private def parseLiteral (bytes : ByteArray) (pos : Nat) (literal : String)
    (value : Value) : Except String (Value × Nat) := do
  let endPos := pos + literal.utf8ByteSize
  unless bytes.extract pos endPos == literal.toUTF8 do throw "invalid JSON literal"
  return (value, endPos)

private partial def parseValue (bytes : ByteArray) (start depth : Nat) :
    Except String (Value × Nat) := do
  if depth > 128 then throw "JSON nesting exceeds 128 levels"
  let pos := skipSpace bytes start
  match (bytes[pos]?.getD 0).toNat with
  | 123 => -- {
      let mut pos := skipSpace bytes (pos + 1)
      let mut fields : Fields := #[]
      let mut seen : Std.HashSet String := {}
      if bytes[pos]? == some 125 then return (.obj fields, pos + 1)
      repeat
        unless bytes[pos]? == some 34 do throw "expected a JSON object key"
        let (key, keyEnd) ← parseString bytes pos
        if seen.contains key then throw "duplicate JSON object key"
        seen := seen.insert key
        pos := skipSpace bytes keyEnd
        unless bytes[pos]? == some 58 do throw "expected a colon after a JSON object key"
        let (value, valueEnd) ← parseValue bytes (pos + 1) (depth + 1)
        fields := fields.push (key, value)
        pos := skipSpace bytes valueEnd
        if bytes[pos]? == some 125 then return (.obj fields, pos + 1)
        unless bytes[pos]? == some 44 do throw "expected a JSON object comma or closing brace"
        pos := skipSpace bytes (pos + 1)
      unreachable!
  | 91 => -- [
      let mut pos := skipSpace bytes (pos + 1)
      let mut items := #[]
      if bytes[pos]? == some 93 then return (.arr items, pos + 1)
      repeat
        let (value, valueEnd) ← parseValue bytes pos (depth + 1)
        items := items.push value
        pos := skipSpace bytes valueEnd
        if bytes[pos]? == some 93 then return (.arr items, pos + 1)
        unless bytes[pos]? == some 44 do throw "expected a JSON array comma or closing bracket"
        pos := pos + 1
      unreachable!
  | 34 =>
      let (value, endPos) ← parseString bytes pos
      return (.str value, endPos)
  | 102 => parseLiteral bytes pos "false" (.bool false)
  | 110 => parseLiteral bytes pos "null" .null
  | 116 => parseLiteral bytes pos "true" (.bool true)
  | _ =>
      if bytes[pos]? == some 45 || isDigit (bytes[pos]?.getD 0) then parseNumber bytes pos
      else throw "expected a JSON value"

def parse (text : String) (jsonc := false) : Except String Value := do
  if text.utf8ByteSize > maxBytes then throw "JSON exceeds the 1 MiB size limit"
  let text := withoutBOM text
  let text ← if jsonc then
      (withoutComments text).map withoutTrailingCommas |>.mapError (fun _ => "unterminated block comment")
    else pure text
  let bytes := text.toUTF8
  let start := skipSpace bytes 0
  if start == bytes.size then return .obj #[]
  let (value, endPos) ← parseValue bytes start 0
  unless skipSpace bytes endPos == bytes.size do throw "unexpected text after the JSON value"
  return value

/-- Doctor checks numeric fields by type only. Avoid materializing arbitrary decimal exponents. -/
partial def Value.forInspection : Value → Lean.Json
  | .null => .null
  | .bool b => .bool b
  | .str s => .str s
  | .num _ => .num 0
  | .arr items => .arr (items.map Value.forInspection)
  | .obj fields => Lean.Json.mkObj (fields.toList.map fun (key, value) => (key, value.forInspection))

private partial def render (value : Value) (out : String) : String := Id.run do
  match value with
  | .null => return out ++ "null"
  | .bool b => return out ++ (if b then "true" else "false")
  | .str s => return out ++ (Lean.Json.str s).compress
  | .num lexeme => return out ++ lexeme
  | .arr items =>
      let mut out := out.push '['
      for i in [:items.size] do
        if i > 0 then out := out.push ','
        out := render items[i]! out
      return out.push ']'
  | .obj fields =>
      let mut out := out.push '{'
      for i in [:fields.size] do
        if i > 0 then out := out.push ','
        let (key, value) := fields[i]!
        out := (out ++ (Lean.Json.str key).compress).push ':'
        out := render value out
      return out.push '}'

def Value.compress (value : Value) : String := render value ""

end Beam.Config.StrictJson
