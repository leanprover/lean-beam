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

def CliFailure.usage (message : String) (usage? : Option String := none) : CliFailure :=
  { CliFailure.make "invalidParams" message 2 with usage? }

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
  { failure with
    remedyCommand? := some command
    diagnostic? := some <| ((failure.diagnostic?.getD failure.failure.error.message).splitOn "\n").headD ""
    failure.error.data? := some <| Lean.Json.mkObj (("remedyCommand", Lean.toJson command) :: data) }

/-- Expected input access failures are usage errors; unexpected IO faults retain their class. -/
def CliFailure.inputFile (option path : String) (error : IO.Error) : CliFailure :=
  let message := s!"cannot read {option} '{path}': {error}"
  match error with
  | .noFileOrDirectory .. | .permissionDenied .. => .usage message
  | _ => .make "internalError" message

def readCliFile (option path : String) : CliM String := do
  match ← (IO.FS.readFile (System.FilePath.mk path)).toBaseIO with
  | .ok text => pure text
  | .error error => throw <| .inputFile option path error

end Beam.Cli
