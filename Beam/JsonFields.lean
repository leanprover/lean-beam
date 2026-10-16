/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam

/-- Require an object whose keys all belong to the declared JSON boundary. -/
def requireOnlyJsonFields
    (label : String)
    (allowed : Array String) : Json → Except String Unit
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{label} accepts no undeclared fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"{label} must be an object, got {other.compress}"

/-- Decode a required field while retaining its name in missing-value and type errors. -/
def requiredField [FromJson α] (json : Json) (field : String) : Except String α := do
  let value ←
    match json.getObjVal? field with
    | .ok value => pure value
    | .error _ => throw s!"missing '{field}'"
  match fromJson? value with
  | .ok decoded => pure decoded
  | .error err => throw s!"invalid '{field}': {err}"

end Beam
