/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.JsonFields

namespace Beam

/-- An executable and its exact argument vector. Execute directly, without shell parsing. -/
structure CommandInvocation where
  executable : String
  arguments : Array String
  deriving BEq, Repr, Lean.ToJson

instance : Lean.FromJson CommandInvocation where
  fromJson? json := do
    requireOnlyJsonFields "command invocation" #["executable", "arguments"] json
    let executable ← requiredField (α := String) json "executable"
    let arguments ← requiredField (α := Array String) json "arguments"
    unless !executable.isEmpty do throw "command executable must not be empty"
    if (arguments.push executable).any (·.contains (Char.ofNat 0)) then
      throw "command invocation must not contain NUL"
    pure { executable, arguments }

/-- Human display only. The JSON argument vector remains authoritative for execution. -/
def CommandInvocation.display (command : CommandInvocation) : String :=
  let quote := fun text : String =>
    "'" ++ (if System.Platform.isWindows then text.replace "'" "''"
            else text.replace "'" "'\\''") ++ "'"
  (if System.Platform.isWindows then "& " else "") ++
    String.intercalate " " ((command.arguments.toList.cons command.executable).map quote)

instance : ToString CommandInvocation := ⟨CommandInvocation.display⟩

end Beam
