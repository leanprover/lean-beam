/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean BeamTest.LSP.Scenario BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.AvailabilityTest

private def markerLine (source marker : String) : ScenarioM Nat := do
  let rows := source.splitOn "\n" |>.zipIdx |>.filter fun (line, _) =>
    line.endsWith s!" -- {marker}"
  let [(_, line)] := rows
    | throw <| IO.userError s!"expected one availability marker {marker}"
  pure line

def run : ScenarioM Unit := do
  let path : System.FilePath := "tests/scenario/docs/RunAtAvailability.lean"
  let source ← IO.FS.readFile path
  let doc ← openDoc path
  syncDoc doc
  for label in ["sync", "async"] do
    let root ← mkTmpDir s!"beam-run-at-availability-{label}"
    let entered := root / "entered"
    let release := root / "release"
    let gateLine ← markerLine source s!"gate:{label}"
    let probeLine ← markerLine source s!"probe:{label}"
    let gate := s!"await_test_gate {(toJson entered.toString).compress} {(toJson release.toString).compress}"
    changeDoc doc { line := gateLine, character := 2, delete := "trivial", insert := gate }
    try
      let started ← IO.monoMsNow
      while !(← entered.pathExists) do
        if (← IO.monoMsNow) - started > 10000 then
          throw <| IO.userError s!"{label}: later tactic did not enter its gate"
        IO.sleep 5
      let goalsReq ← sendGoals doc { line := probeLine, character := 2, useAfter := false }
      let goals : Beam.LSP.Lib.ProofState ← awaitResponseAs goalsReq
      unless goals.goals.map (·.target) == #["True"] do
        throw <| IO.userError s!"{label}: expected an available proof goal, got {(toJson goals).compress}"

      -- Release only after the response. The watchdog prevents a regressed server from hanging
      -- the suite; it is not the synchronization condition for a successful test.
      let finished ← IO.mkRef false
      let watchdog ← IO.asTask (prio := .dedicated) do
        let started ← IO.monoMsNow
        while !(← finished.get) do
          if (← IO.monoMsNow) - started > 5000 then
            IO.FS.writeFile release "watchdog"
            return
          IO.sleep 5
      try
        requireRunAtSolvesProof s!"{label}: probe an available goal before the later tactic finishes"
          doc { line := probeLine, character := 2 } "first | guard_command_universe; trivial"
        if ← release.pathExists then
          throw <| IO.userError s!"{label}: runAt waited for the enclosing command to finish"
      finally
        finished.set true
        IO.FS.writeFile release "released"
        IO.ofExcept watchdog.get
    finally
      IO.FS.writeFile release "released"
    if let some diagnostics ← collectDiagnostics? doc then
      if diagnostics.diagnostics.any (fun d => d.severity? == some .error) then
        throw <| IO.userError s!"{label}: ordinary elaboration failed: {(toJson diagnostics).compress}"
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.AvailabilityTest
