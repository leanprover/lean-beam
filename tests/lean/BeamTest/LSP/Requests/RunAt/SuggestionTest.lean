/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support
import BeamTest.LSP.Requests.RunAt.SuggestionSupport

open Lean BeamTest.LSP.Scenario BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.SuggestionTest

private def markerLine (source marker : String) : ScenarioM Nat := do
  let [(_, line)] := source.splitOn "\n" |>.zipIdx |>.filter (fun (s, _) => s.endsWith s!" -- {marker}")
    | throw <| IO.userError s!"missing suggestion marker {marker}"
  pure line

private def requireSuggestion (label : String) (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
  unless result.success &&
      result.messages.any (·.text.contains "Try this:") &&
      !result.messages.any (·.text.contains "PANIC") do
    throw <| IO.userError s!"{label}: invalid suggestion result: {(toJson result).compress}"

private def requireProofSuggestion (label : String) (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
  requireSuggestion label result
  unless result.proofState?.map (·.goals.isEmpty) == some true do
    throw <| IO.userError s!"{label}: suggestion did not close the proof"

def run : ScenarioM Unit := do
  for name in ["RunAtSuggestions", "RunAtSuggestionsUnicode"] do
    let path : System.FilePath := s!"tests/scenario/docs/{name}.lean"
    let source ← IO.FS.readFile path
    let line ← markerLine source "probe"
    let doc ← openDoc path
    let initial ← collectDiagnostics doc
    unless initial.diagnostics.all (fun d => d.severity? != some .error) do
      throw <| IO.userError "invalid ordinary suggestion fixture"
    for text in [
        "check_probe_suggestion \"check_probe\" in exact?",
        "first | check_probe_suggestion \"first | \" in exact?",
        "-- éα😀\ncheck_probe_suggestion \"-- éα😀\" in exact?"] do
      let result ← requireRunAtSuccess s!"{name}: tactic suggestion" doc { line, character := 2 } text
      requireProofSuggestion name result
    let req ← sendRunAt doc { line, character := 2, text := "skip", storeHandle := true }
    let stored ← requireRunAtResponseSuccess "store suggestion basis" req
    let some handle := stored.handle? | throw <| IO.userError "missing suggestion handle"
    let failedReq ← runWithHandle doc handle { text := "fail \"expected suggestion rollback\"", storeHandle := true }
    let failed : Beam.LSP.RunAt.Result ← awaitResponseAs failedReq
    unless !failed.success && failed.handle?.isNone &&
        failed.proofState?.map (·.goals.map (·.target)) == some #["True"] do
      throw <| IO.userError "failed suggestion branch changed its root or produced a successor"
    for text in [
        "-- longer ASCII handle input\ncheck_probe_suggestion \"-- longer ASCII\" in exact?",
        "-- α😀\ncheck_probe_suggestion \"-- α😀\" in exact?"] do
      let req ← runWithHandle doc handle { text }
      requireProofSuggestion "handle suggestion" (← requireRunAtResponseSuccess "handle suggestion" req)
    releaseHandle doc handle
    let commandLine ← markerLine source "command"
    let commandText := "-- command éα😀\nexample : True := by\n  check_probe_suggestion \"-- command éα😀\" in exact?"
    let commandReq ← sendRunAt doc { line := commandLine, character := 0, text := commandText, storeHandle := true }
    let commandResult ← requireRunAtResponseSuccess "command suggestion" commandReq
    requireSuggestion "command suggestion" commandResult
    unless commandResult.proofState?.isNone do
      throw <| IO.userError "expected a command suggestion basis"
    let some commandHandle := commandResult.handle? | throw <| IO.userError "missing command suggestion handle"
    let rejected ← runWithHandle doc commandHandle {
      text := "#check missingSuggestionConstant"
      storeHandle := true
    }
    let rejectedResult : Beam.LSP.RunAt.Result ← awaitResponseAs rejected
    unless !rejectedResult.success && rejectedResult.handle?.isNone &&
        rejectedResult.messages.any (·.severity == .error) do
      throw <| IO.userError "command continuation discarded its new error diagnostics"
    let continuation ← runWithHandle doc commandHandle {
      text := "-- different command input\nexample : True := by\n  check_probe_suggestion \"-- different command\" in exact?"
    }
    requireSuggestion "command handle suggestion"
      (← requireRunAtResponseSuccess "command handle suggestion" continuation)
    releaseHandle doc commandHandle
    let goalsReq ← sendGoals doc { line, character := 2, useAfter := false }
    let goals : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsReq
    unless goals.goals.map (·.target) == #["True"] do
      throw <| IO.userError "suggestion probe changed the real proof state"
    if let some after ← collectDiagnostics? doc then
      unless after.diagnostics == initial.diagnostics do
        throw <| IO.userError "suggestion probe changed the real document diagnostics"
    closeDoc doc
    unless (← IO.FS.readFile path) == source do
      throw <| IO.userError "suggestion probe changed the real document source"

end BeamTest.LSP.Requests.RunAt.SuggestionTest
