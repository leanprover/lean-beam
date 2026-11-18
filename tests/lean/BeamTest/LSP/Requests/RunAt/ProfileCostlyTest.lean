/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/
import BeamTest.LSP.Requests.Support
import BeamTest.LSP.Requests.RunAt.ProfileInvariants

open Lean BeamTest.LSP.Scenario

namespace BeamTest.LSP.Requests.RunAt.ProfileCostlyTest

private def maxProfileBytes := 20000

def anchorLine := 13
def declaration := "set_option trace.Kernel true in\ntheorem costly : True := by profile_costly; trivial"

def checkProfile (json : Json) : IO Unit := do
  IO.ofExcept (ProfileInvariants.check json)
  unless (← IO.ofExcept (json.getObjValAs? Bool "truncated")) do
    throw <| IO.userError "expected costly profile to be truncated"
  let summary ← IO.ofExcept (json.getObjVal? "summary")
  let phases ← IO.ofExcept (summary.getObjValAs? (Array Json) "phase_spans")
  for category in ["Kernel", "Elab.definition.value"] do
    unless phases.any (fun e => e.getObjValD "category" == toJson category) do
      throw <| IO.userError s!"costly profile lost {category}"
  let top ← IO.ofExcept (summary.getObjValAs? (Array Json) "top_spans")
  let isHot := fun (e : Json) => e.getObjValD "tag" == toJson "late-step"
  unless (top.extract 0 5).any (fun e => isHot e || isHot (e.getObjValD "inner_span")) do
    throw <| IO.userError s!"late-step missing from first five spans: {top}"
  unless json.compress.utf8ByteSize <= maxProfileBytes do
    throw <| IO.userError s!"costly profile is {json.compress.utf8ByteSize} bytes"

def run : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ProfileCostly.lean"
  syncDoc doc
  let req ← sendRunAt doc {line := anchorLine, character := 0, profile := true, text := declaration}
  let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
  unless result.success do throw <| IO.userError s!"costly declaration failed: {toJson result.messages}"
  let some profile := result.profile? | throw <| IO.userError "missing costly profile"
  checkProfile (← ProfileInvariants.project profile)
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.ProfileCostlyTest
