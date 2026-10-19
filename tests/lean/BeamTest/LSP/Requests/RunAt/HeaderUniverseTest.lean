/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean BeamTest.LSP.Scenario BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.HeaderUniverseTest

private def probe (source marker : String) : ScenarioM (Nat × String) := do
  let rows := source.splitOn "\n" |>.zipIdx |>.filter fun (line, _) =>
    line.endsWith s!" -- probe:{marker}"
  let [(line, lineNo)] := rows | throw <| IO.userError s!"missing header-universe marker {marker}"
  pure (lineNo, ((line.splitOn " -- probe:").head!).trimAscii.toString)

def run : ScenarioM Unit := do
  let path : System.FilePath := "tests/scenario/docs/RunAtHeaderUniverses.lean"
  let source ← IO.FS.readFile path
  let doc ← openDoc path
  let initial ← collectDiagnostics doc
  unless initial.diagnostics.all (fun d => d.severity? != some .error) do
    throw <| IO.userError s!"invalid ordinary header-universe fixture: {(toJson initial).compress}"
  let mut edits := #[]
  for marker in ["top", "private", "nested", "mutual-first", "mutual-second"] do
    let (line, original) ← probe source marker
    let rawLine := (source.splitOn "\n")[line]!
    let character := (rawLine.toList.takeWhile (· == ' ')).length
    let text := s!"first | guard_universe_absent leaked; {original}"
    requireRunAtSolvesProof s!"{marker}: proof-value-only universes" doc { line, character } text
    let req ← sendRunAt doc { line, character, text := "skip", storeHandle := true }
    let stored ← requireRunAtResponseSuccess s!"store {marker} header universe" req
    let some handle := stored.handle? | throw <| IO.userError "missing header-universe handle"
    for _ in [:2] do
      let continuation ← runWithHandle doc handle { text }
      let result ← requireRunAtResponseSuccess s!"resume {marker} header universe" continuation
      unless result.proofState?.map (·.goals.isEmpty) == some true do
        throw <| IO.userError s!"{marker}: resumed proof did not close"
    releaseHandle doc handle
    edits := edits.push { line, character, delete := original, insert := text : ChangeSpec }
  changeDocBatch doc edits
  let ordinary ← collectDiagnostics doc
  unless ordinary.diagnostics.all (fun d => d.severity? != some .error) do
    throw <| IO.userError s!"ordinary replacement disagrees with header-universe probes: {(toJson ordinary).compress}"

  -- Unlike synchronous proofs, Lean's asynchronous header check rejects this body-only binder.
  let options := source.splitOn "\n" |>.zipIdx |>.filter fun (line, _) =>
    line.endsWith " -- option:async"
  let [(_, optionLine)] := options | throw <| IO.userError "missing async option marker"
  changeDoc doc {
    line := optionLine
    character := 0
    delete := "set_option Elab.async false"
    insert := "set_option Elab.async true"
  }
  let rejected ← collectDiagnostics doc
  unless rejected.diagnostics.any (fun d => d.severity? == some .error &&
      d.message.contains "unused universe parameter") do
    throw <| IO.userError s!"ordinary asynchronous Lean did not reject its unused binder: {(toJson rejected).compress}"
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.HeaderUniverseTest
