/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean BeamTest.LSP.Scenario BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.ProfileContractsTest

def expectProfileRequired (request : ReqHandle) : ScenarioM Unit := do
  let outcome ← awaitReq request
  unless outcome.errorCode? == some "invalidParams" &&
      outcome.errorMessage.contains "continuations require profile: true" &&
      outcome.errorMessage.contains "not been consumed" do
    throw <| IO.userError s!"expected profiling restriction, got {outcome.errorCode?}: {outcome.errorMessage}"

private def checkGuards (doc : DocHandle) : ScenarioM Unit := do
  let guard := "/-- trace: [debug] hello -/\n#guard_msgs in\nset_option trace.debug true in\nrun_cmd trace[debug] \"hello\""
  for text in [guard, s!"set_option pp.universes true in\n{guard}", "profile_guard_alias"] do
    let ordinary ← requireRunAtResponseSuccess "ordinary trace assertion" <| ← sendRunAt doc {
      line := 13, character := 0, text
    }
    unless ordinary.messages.isEmpty do
      throw <| IO.userError "ordinary trace assertion did not consume its messages"
    let profiled ← sendRunAt doc { line := 13, character := 0, text, profile := true, storeHandle := true }
    let outcome ← awaitReq profiled
    unless outcome.errorCode? == some "invalidParams" &&
        outcome.errorMessage.contains "Profiling #guard_msgs is unsupported" && outcome.result?.isNone do
      throw <| IO.userError "profiling reported an instrumentation-induced assertion as a Lean verdict"
  -- The check is about executed commands, not text matches or unexecuted syntax quotations.
  for text in ["run_cmd logInfo \"#guard_msgs\"",
      "run_cmd let _ ← `(command| #guard_msgs in #check Nat); pure ()"] do
    discard <| requireRunAtResponseSuccess "unexecuted guard syntax" <| ← sendRunAt doc {
      line := 13, character := 0, text, profile := true
    }

private def realizationText : String :=
  "run_cmd Lean.Elab.Command.liftTermElabM do\n  let outer ← Lean.getOptions\n  let enabled ← Lean.Meta.realizeValue `reviewFunction `reviewProfileProbe do\n    let opts ← Lean.getOptions\n    Lean.withTraceNode `review.realization (fun _ => pure \"later realization\") do\n      IO.sleep 15\n    pure (Lean.trace.profiler.get opts)\n  Lean.logInfo m!\"outer={Lean.trace.profiler.get outer} realization={enabled}\""

private def checkRealizations (doc : DocHandle) : ScenarioM Unit := do
  for profiled in [false, true] do
    let parent ← requireRunAtResponseSuccess "independent declaration handle" <| ← sendRunAt doc {
      line := 13, character := 0, text := "def reviewFunction (n : Nat) : Nat := n + 0"
      profile := profiled, storeHandle := true
    }
    let some handle := parent.handle? | throw <| IO.userError "missing declaration handle"
    if profiled then
      for linear in [false, true] do
        expectProfileRequired <| ← runWithHandle doc handle {
          text := realizationText, linear }
    -- A refused linear call must leave the handle usable. The deferred callback and the outer
    -- continuation must agree: both disabled for an ordinary handle, both enabled for a profile.
    let continued ← requireRunAtResponseSuccess "deferred realization" <| ← runWithHandle doc handle {
      text := realizationText, profile := profiled, linear := true, storeHandle := true
    }
    let expected := s!"outer={profiled} realization={profiled}"
    unless continued.messages.any (·.text == expected) && continued.profile?.isSome == profiled do
      throw <| IO.userError s!"deferred options disagreed with continuation: {(toJson continued).compress}"
    expectErrorContains (← runWithHandle doc handle { text := "#check Nat", profile := profiled }) <|
      Json.mkObj [("code", toJson "invalidParams")]
    let some successor := continued.handle? | throw <| IO.userError "missing successor handle"
    if profiled then
      expectProfileRequired <| ← runWithHandle doc successor { text := "#check reviewFunction" }
    discard <| requireRunAtResponseSuccess "successor declaration context" <| ← runWithHandle doc successor {
      text := "#check reviewFunction", profile := profiled }
    releaseHandle doc successor

  -- Profiling a continuation also marks its successor, without changing its reusable parent.
  let parent ← requireRunAtResponseSuccess "ordinary parent" <| ← sendRunAt doc {
    line := 13, character := 0, text := "#check Nat", storeHandle := true }
  let some handle := parent.handle? | throw <| IO.userError "missing ordinary handle"
  let profiled ← requireRunAtResponseSuccess "profiled child" <| ← runWithHandle doc handle {
    text := "#check Nat", profile := true, storeHandle := true }
  let some child := profiled.handle? | throw <| IO.userError "missing profiled child"
  expectProfileRequired <| ← runWithHandle doc child { text := "#check Nat", linear := true }
  discard <| requireRunAtResponseSuccess "unmodified ordinary parent" <| ← runWithHandle doc handle {
    text := "#check Nat" }
  releaseHandle doc child
  releaseHandle doc handle

def run : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ProfileContracts.lean"
  syncDoc doc
  checkGuards doc
  checkRealizations doc
  closeDoc doc

end BeamTest.LSP.Requests.RunAt.ProfileContractsTest
