/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol

namespace Beam.Cli

/-- A terminal CLI failure. Broker errors remain intact until presentation. -/
structure CliFailure where
  failure : Beam.Broker.ResponseFailure
  exitCode : UInt32 := 1
  clientRequestId? : Option String := none
  diagnostic? : Option String := none
  usage? : Option String := none
  remedyCommand? : Option String := none
  /-- Foreground serve already published readiness; a later fault cannot retract it. -/
  responsePublished : Bool := false

abbrev CliM := ExceptT CliFailure IO

def CliFailure.make (code message : String) (exitCode : UInt32 := 1) : CliFailure := {
  failure := { error := { code, message } }
  exitCode
}

private def hexDigit (n : Nat) : Char :=
  Char.ofNat <| if n < 10 then 48 + n else 87 + n

/-- Render terminal control characters visibly; ordinary text and shell quoting are preserved. -/
def escapeDiagnosticText (text : String) : String :=
  String.join <| text.toList.map fun c =>
    if c == '\n' then "\\n"
    else if c == '\r' then "\\r"
    else if c == '\t' then "\\t"
    else if c.toNat < 32 || (c.toNat >= 127 && c.toNat <= 159) then
      "\\u00" ++ String.singleton (hexDigit (c.toNat / 16)) ++ String.singleton (hexDigit (c.toNat % 16))
    else String.singleton c

structure ArgumentPreview where
  field : String
  preview : String
  omittedChars : Nat
  deriving Lean.ToJson

def argumentPreview (field value : String) (limit : Nat := 128) : ArgumentPreview :=
  let excerpt := String.ofList <| value.toList.take limit
  { field, preview := escapeDiagnosticText excerpt, omittedChars := value.length - excerpt.length }

private def previewText (preview : ArgumentPreview) : String :=
  preview.preview ++ if preview.omittedChars == 0 then ""
    else s!" ... ({preview.omittedChars} characters omitted)"

def CliFailure.usage (message : String) (usage? : Option String := none) : CliFailure :=
  let preview := argumentPreview "arguments" message 512
  let message := preview.preview ++ if preview.omittedChars == 0 then ""
    else s!" ... ({preview.omittedChars} diagnostic characters omitted)"
  { CliFailure.make "invalidParams" message 2 with
    usage?
    failure.error.data? := if preview.omittedChars == 0 then none
      else some <| Lean.Json.mkObj [("argument", Lean.toJson preview)] }

/-- Bound local input echoes on both output channels while retaining field and omitted length. -/
def CliFailure.argument (field value : String) (message : String → String)
    (usage? : Option String := none) (data : List (String × Lean.Json) := []) : CliFailure :=
  let preview := argumentPreview field value
  let failure := CliFailure.usage (message preview.preview) usage?
  let omitted := if preview.omittedChars == 0 then ""
    else s!" ... ({preview.omittedChars} characters omitted from {field})"
  { failure with
    failure.error.message := failure.failure.error.message ++ omitted
    failure.error.data? := some <| Lean.Json.mkObj (("argument", Lean.toJson preview) :: data) }

def CliFailure.setup (message : String) : CliFailure :=
  CliFailure.make "setupError" message

def CliFailure.internal (error : IO.Error) : CliFailure :=
  CliFailure.make "internalError" error.toString

def CliFailure.cancelled : CliFailure :=
  CliFailure.make "requestCancelled"
    "Beam request interrupted; cancellation does not establish that the producer has stopped" 130

def CliFailure.broker (failure : Beam.Broker.ResponseFailure)
    (clientRequestId? : Option String := none) : CliFailure := {
  failure, clientRequestId?
  exitCode := if failure.error.code == "requestCancelled" then 130 else 1
}

/-- Attach a copyable local remedy and its machine-readable prerequisites. -/
def CliFailure.withRemedy (failure : CliFailure) (command : String)
    (data : List (String × Lean.Json) := []) : CliFailure :=
  let suffix := "\n" ++ command
  let message := failure.failure.error.message
  let message := if message.endsWith suffix then (message.dropEnd suffix.length).toString else message
  { failure with
    remedyCommand? := some command
    failure.error.message := message
    failure.error.data? := some <| Lean.Json.mkObj (("remedyCommand", Lean.toJson command) :: data) }

/-- Expected input access failures are usage errors; unexpected IO faults retain their class. -/
def CliFailure.inputFile (option path : String) (error : IO.Error) : CliFailure :=
  let detail := previewText <| argumentPreview "IO detail" error.toString
  let failure := CliFailure.argument option path fun preview => s!"cannot read {option} '{preview}': {detail}"
  match error with
  | .noFileOrDirectory .. | .permissionDenied .. | .inappropriateType .. => failure
  | _ => { failure with failure.error.code := "internalError", exitCode := 1 }

def readCliFile (option path : String) : CliM String := do
  let file := System.FilePath.mk path
  -- Admission-time observation: the path can still be replaced before the later path-based open.
  match ← file.metadata.toBaseIO with
  | .ok metadata =>
      unless metadata.type == .file do
        throw <| .argument option path fun preview => s!"{option} requires a regular file: {preview}"
  | .error error =>
      match error with
      | .invalidArgument .. =>
          throw <| .argument option path fun preview => s!"cannot resolve {option} path: {preview}"
      | _ => throw <| .inputFile option path error
  match ← (IO.FS.readFile file).toBaseIO with
  | .ok text => pure text
  | .error error => throw <| .inputFile option path error

end Beam.Cli
