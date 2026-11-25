/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean
import Lake.Toml.Load
import Beam.Config.StrictJson

namespace Beam.Cli.ClientDoctor

open Lean Beam.Config.StrictJson

inductive Format where
  | json | jsonc | toml
  deriving BEq

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

/-- Antigravity accepts JSONC, with the same bounded value parser as the installer. -/
def parseAgyConfig (text : String) : Except Unit Value :=
  (parse text (jsonc := true)).mapError (fun _ => ())

end Beam.Cli.ClientDoctor
