/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.BasicTest

private def invalidParamsJson : Json :=
  Json.mkObj [("code", toJson "invalidParams")]

private def requestCancelledJson : Json :=
  Json.mkObj [("code", toJson "requestCancelled")]

def checkRunAtTacticPositions : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TacticPositionProof.lean"
  syncDoc doc

  -- At the start of simp, its replacement must handle the unsimplified goal.
  requireRunAtFailureMessage "runAt at simp start" doc { line := 1, character := 2 }
    "exact h" "0 + a = b"
  let simplified ← requireRunAtSuccess "rerun simp at its start" doc
    { line := 1, character := 2 } "simp"
  unless simplified.proofState?.map (·.goals.map (·.target)) == some #["a = b"] do
    throw <| IO.userError s!"simp should leave a = b, got {(toJson simplified).compress}"

  -- Moving inside simp or to its end selects the state after it.
  for character in [3, 6] do
    requireRunAtSolvesProof "runAt inside/at end of simp" doc { line := 1, character }
      "exact h"

  -- Zero-based line 2 is exact h; its before-state already includes simp's effect.
  requireRunAtSolvesProof "runAt at exact start" doc { line := 2, character := 2 } "exact h"
  requireRunAtFailureMessage "simp at exact start" doc { line := 2, character := 2 }
    "simp" "made no progress"
  requireRunAtFailureMessage "runAt inside exact" doc { line := 2, character := 3 }
    "exact h" "No goals to be solved"

  -- Explicit goal queries expose both states without changing later probes.
  for (useAfter, target) in [(false, "0 + a = b"), (true, "a = b")] do
    let req ← sendGoals doc { line := 1, character := 2, useAfter }
    let state : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    unless state.goals.map (·.target) == #[target] do
      throw <| IO.userError s!"goals useAfter={useAfter}: expected {target}, got {(toJson state).compress}"
  requireRunAtFailureMessage "runAt still uses simp's before-state" doc
    { line := 1, character := 2 } "exact h" "0 + a = b"

  -- A real LSP replacement agrees with the probe at the tactic's start.
  changeDoc doc { line := 1, character := 2, delete := "simp", insert := "exact h" }
  let diagnostics ← collectDiagnostics doc
  unless diagnostics.diagnostics.any (fun diagnostic =>
      diagnostic.severity? == some .error && diagnostic.range.start.line == 1 &&
      diagnostic.message.contains "0 + a = b") do
    throw <| IO.userError s!"expected replacement type mismatch, got {(toJson diagnostics).compress}"
  closeDoc doc

def checkRunAtTacticSequences : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TacticPositionProof.lean"
  syncDoc doc
  let simpStart : Lean.Lsp.Position := { line := 1, character := 2 }

  requireRunAtSolvesProof "newline-separated tactics" doc simpStart "simp\nexact h"
  requireRunAtSolvesProof "semicolon-separated tactics" doc simpStart "simp; exact h"
  requireRunAtSolvesProof "uniformly indented tactics" doc simpStart "  simp\n  exact h"
  requireRunAtSolvesProof "comments, blank lines, and nested bullets" doc simpStart
    "-- note\nhave h2 : 1 = 1 ∧ 2 = 2 := by\n  constructor\n  · rfl\n  · rfl\n\nsimp\nexact h"
  requireRunAtFailureMessage "comment-only text" doc simpStart "-- note" "expected tactic"
  -- A more indented line still continues the previous tactic's arguments, as in a `by` block.
  requireRunAtSolvesProof "indented argument continuation" doc simpStart
    "revert a b\n  h\nintro a b\nsimp"
  -- Retry only a failed parse whose later lines retain the source column.
  requireRunAtSolvesProof "copied indentation" doc simpStart "simp\n  exact h"
  requireRunAtSolvesProof "copied nested indentation" doc simpStart
    "have h2 : 1 = 1 ∧ 2 = 2 := by\n    constructor\n    · rfl\n    · rfl\n  simp\n  exact h"
  requireRunAtFailureMessage "line left of source column" doc simpStart "simp\n exact h"
    "<runAt>:2:"
  requireRunAtSolvesProof "CRLF sequence" doc simpStart "simp\r\nexact h"
  requireRunAtSolvesProof "CRLF copied indentation" doc simpStart "simp\r\n  exact h"
  for (text, diagnostic) in [("skip\nmade_up_tactic", "unknown tactic"),
      ("skip\nswap", "unknown tactic"), ("skip\n\texact h", "tabs are not allowed")] do
    let rejected : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← sendRunAt doc {
      line := 1, character := 2, text, storeHandle := true
    }
    unless !rejected.success && rejected.handle?.isNone &&
        rejected.messages.any (·.text.contains diagnostic) &&
        !rejected.messages.any (fun m => m.text.contains "Align sibling" ||
          m.text.contains "cursor-column retry" || m.text.contains "pasted at") do
      throw <| IO.userError "a non-layout parser failure acquired layout advice"
  for text in ["by\n  @@@@", "by\n  on_goal 1 => skip", "(by\n  @@@@)",
      "((by/- éα😀 -/\n  exact))"] do
    requireRunAtFailureMessage "outer by keeps its body parse error" doc simpStart text "<runAt>:2:"
  for text in ["simp\nexact h\n@@@@", "(by simp; exact h) @@@@", "by simp; exact h\n#check Nat"] do
    let rejected : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← sendRunAt doc {
      line := 1, character := 2, text, storeHandle := true
    }
    unless !rejected.success && rejected.handle?.isNone do
      throw <| IO.userError "tactic input silently discarded trailing syntax"
  for text in [
      "by simp; exact h", "by\n  simp\n  exact h",
      "by/- comment -/ simp; exact h", "-- note\n/- outer /- inner -/ -/ by\n  simp\n  exact h",
      "(by simp; exact h)", "((by\n  simp\n  exact h))",
      "by\n  have h2 : True ∧ True := by\n    constructor\n    · trivial\n    · trivial\n  simp\n  exact h",
      "by_cases hab : a = b\nall_goals simp\nall_goals exact h"] do
    requireRunAtSolvesProof "Lean-grammar tactic input" doc simpStart text
  for text in ["by", "by -- note", "(by)", "((by\n  -- note))"] do
    let empty : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← sendRunAt doc {
      line := 1, character := 2, text, storeHandle := true
    }
    unless !empty.success && empty.handle?.isNone do
      throw <| IO.userError s!"empty by must not create a no-op continuation: {(toJson empty).compress}"
  -- A successfully parsed input keeps its reading, even if the indentation was unintended.
  let ambiguous ← requireRunAtSuccess "standalone parse takes precedence" doc
    { line := 4, character := 2 } "intro a\n  omega"
  unless ambiguous.proofState?.map (·.goals.isEmpty) == some false do
    throw <| IO.userError "cursor retry replaced a successful standalone interpretation"
  let semanticFailure : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← sendRunAt doc {
    line := 1, character := 2, text := "simp\nexact missingLayoutConstant"
  }
  unless !semanticFailure.success &&
      !semanticFailure.messages.any (·.text.contains "Align sibling tactics") do
    throw <| IO.userError "layout advice must not be appended to elaboration errors"
  -- An outer by does not make unfinished nested elaboration resumable.
  requireRunAtFailureMessage "unfinished nested by remains a failure" doc simpStart
    "by\n  have h2 : True := by" "unsolved goals"
  -- Parsed as one tactic, `intro a⏎omega` would introduce `b` under the name `omega` and succeed
  -- without running `omega`, leaving the goal open.
  requireRunAtSolvesProof "line break ends tactic arguments" doc { line := 4, character := 2 }
    "intro a\nomega"
  -- Handle continuations parse their text the same way.
  let minted ← requireRunAtResponseSuccess "mint sequence handle" <|
    ← sendRunAt doc { line := 4, character := 2, text := "skip", storeHandle := true }
  let some handle := minted.handle?
    | throw <| IO.userError s!"expected a handle, got {(toJson minted).compress}"
  let targets (result : Beam.LSP.RunAt.Result) := result.proofState?.map (·.goals.map (·.target))
  -- A by-wrapped partial proof retains the same explicit handle semantics.
  let partialResult ← requireRunAtResponseSuccess "partial outer by" <| ← sendRunAt doc {
    line := 4, character := 2, text := "by\n  intro a", storeHandle := true
  }
  let some partialHandle := partialResult.handle?
    | throw <| IO.userError "partial by did not retain its proof state"
  for text in ["by intro b; omega", "((by\n  intro b\n  omega))"] do
    let solved ← requireRunAtResponseSuccess "by handle continuation" <|
      ← runWithHandle doc partialHandle { text }
    unless targets solved == some #[] do
      throw <| IO.userError "by continuation did not solve the retained goals"
  releaseHandle doc partialHandle
  let malformed : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← runWithHandle doc handle {
    text := "intro a\n @@@@", storeHandle := true
  }
  unless !malformed.success && malformed.handle?.isNone &&
      !malformed.messages.any (fun m => m.text.contains "pasted at" ||
        m.text.contains "run position's column" || m.text.contains "cursor-column retry") do
    throw <| IO.userError "handle parse error incorrectly describes a cursor retry"
  let copiedContinuation : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← runWithHandle doc handle {
    text := "skip\n  intro a", storeHandle := true
  }
  unless !copiedContinuation.success && copiedContinuation.handle?.isNone do
    throw <| IO.userError "handle continuation applied a source-column fallback"
  -- A failure after an advancing tactic rolls back the whole sequence and mints no successor.
  let requireRolledBack (label : String) (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
    unless !result.success && result.handle?.isNone && targets result == targets minted do
      throw <| IO.userError
        s!"{label}: expected rollback to the parent state, got {(toJson result).compress}"
  for linear in [false, true] do
    let failed : Beam.LSP.RunAt.Result ← awaitResponseAs
      (← runWithHandle doc handle { text := "intro a\nexact rfl", storeHandle := true, linear })
    requireRolledBack s!"failed sequence continuation (linear := {linear})" failed
    let reuseReq ← runWithHandle doc handle { text := "intro a\nomega" }
    if linear then
      -- A linear continuation consumes its parent even when it fails.
      expectErrorContains reuseReq invalidParamsJson
    else
      let continued : Beam.LSP.RunAt.Result ← awaitResponseAs reuseReq
      unless continued.success && targets continued == some #[] do
        throw <| IO.userError
          s!"runWith tactic sequence should solve the goal, got {(toJson continued).compress}"
  closeDoc doc

def checkRunAtUnicodeSourceColumn : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/RunAtUnicodeColumn.lean"
  syncDoc doc
  -- The astral character before sorry makes its UTF-16 position 27 but Lean column 26.
  -- The fallback must compare the next line's spaces with 26, not with the LSP character.
  requireRunAtSolvesProof "copied indentation after an astral source character" doc
    { line := 0, character := 27 } ("skip\n" ++ "".pushn ' ' 26 ++ "exact True.intro")
  closeDoc doc

def checkRunAtOneCommandOnly : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt command sequence" doc { line := 8, character := 0 }
    "def runAtOneCommandA : Nat := 1\n\n#check runAtOneCommandA"
    "runAtSupportsOneCommandOnly"
  closeDoc doc

def checkRunAtElaborationAborts : ScenarioM Unit := do
  let path := "tests/scenario/docs/RunAtElaborationAbort.lean"
  let source ← IO.FS.readFile path
  let some (_, line) := source.splitOn "\n" |>.zipIdx |>.find? (fun (text, _) =>
      text.endsWith " -- probe")
    | throw <| IO.userError "missing elaboration-abort probe position"
  let position : Lean.Lsp.Position := { line, character := 2 }
  let doc ← openDoc path
  let initial ← collectDiagnostics doc
  if initial.diagnostics.any (·.severity? == some .error) then
    throw <| IO.userError "invalid elaboration-abort fixture"
  let minted ← requireRunAtResponseSuccess "store elaboration-abort basis" <|
    ← sendRunAt doc { line, character := 2, text := "skip", storeHandle := true }
  let some handle := minted.handle?
    | throw <| IO.userError "missing elaboration-abort basis handle"
  let targets (result : Beam.LSP.RunAt.Result) := result.proofState?.map (·.goals.map (·.target))
  let requireFailure (label : String) (needles : List String)
      (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
    unless !result.success && result.handle?.isNone && targets result == targets minted do
      throw <| IO.userError s!"{label}: expected failure with original goals and no handle: {(toJson result).compress}"
    for needle in needles do
      unless result.messages.any (fun msg => msg.severity == .error && msg.text.contains needle) do
        throw <| IO.userError s!"{label}: missing error '{needle}': {(toJson result).compress}"
  let synthesisErrors := ["don't know how to synthesize implicit argument",
    "don't know how to synthesize placeholder"]
  -- Term.evalTerm logs the actual errors before throwing abortTermElab. A normal Result must
  -- retain those errors, including when a preceding tactic has already advanced the proof.
  for text in ["run_tac pure _", "constructor\nrun_tac pure _"] do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs <|
      ← sendRunAt doc { line, character := 2, text, storeHandle := true }
    requireFailure text synthesisErrors result
  for text in ["abort_term_probe", "abort_tactic_probe", "abort_command_probe"] do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs <|
      ← sendRunAt doc { line, character := 2, text := s!"constructor\n{text}", storeHandle := true }
    requireFailure text ["logged elaboration abort"] result
  let bareAbort : Beam.LSP.RunAt.Result ← awaitResponseAs <|
    ← sendRunAt doc {
      line, character := 2, text := "abort_without_diagnostics_probe", storeHandle := true
    }
  requireFailure "abort without diagnostics" ["tactic aborted without visible diagnostics"] bareAbort
  -- Logged errors do not justify swallowing an unrelated internal exception.
  let internalReq ← sendRunAt doc {
    line, character := 2, text := "constructor\nunexpected_internal_probe"
  }
  expectErrorContains internalReq (Json.mkObj [("code", toJson "internalError")])
  requireRunAtSolvesProof "internal exception preserves the document" doc position "constructor <;> trivial"
  for linear in [false, true] do
    let failed : Beam.LSP.RunAt.Result ← awaitResponseAs <| ← runWithHandle doc handle {
      text := "constructor\nrun_tac pure _", storeHandle := true, linear
    }
    requireFailure s!"aborted continuation (linear := {linear})" synthesisErrors failed
    let reused ← runWithHandle doc handle { text := "constructor <;> trivial" }
    if linear then
      expectErrorContains reused invalidParamsJson
    else
      let solved ← requireRunAtResponseSuccess "reuse after aborted continuation" reused
      unless targets solved == some #[] do
        throw <| IO.userError "aborted continuation changed its parent handle"
  requireRunAtSolvesProof "abort probes preserve the document" doc position "constructor <;> trivial"
  -- Ordinary file elaboration must report the same diagnostic categories as the natural probe.
  changeDoc doc { line, character := 2, delete := "constructor <;> trivial", insert := "run_tac pure _" }
  let ordinary ← collectDiagnostics doc
  for needle in synthesisErrors do
    unless ordinary.diagnostics.any (fun diagnostic =>
        diagnostic.severity? == some .error && diagnostic.message.contains needle) do
      throw <| IO.userError s!"ordinary Lean is missing elaboration error '{needle}'"
  changeDoc doc { line, character := 2, delete := "run_tac pure _", insert := "constructor <;> trivial" }
  let restored ← collectDiagnostics doc
  if restored.diagnostics.any (·.severity? == some .error) then
    throw <| IO.userError "abort probes changed ordinary document elaboration"
  closeDoc doc

def checkRunAtResourceLimits : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/RunAtElaborationAbort.lean"
  syncDoc doc
  let source ← IO.FS.readFile "tests/scenario/docs/RunAtElaborationAbort.lean"
  let some (_, line) := source.splitOn "\n" |>.zipIdx |>.find? (fun (text, _) =>
      text.endsWith " -- probe")
    | throw <| IO.userError "missing resource-limit probe position"
  let position : Lean.Lsp.Position := { line, character := 2 }
  for (text, needle) in [
      ("constructor\nset_option maxRecDepth 32 in iterate 100000 skip", "maximum recursion depth"),
      ("constructor\nset_option maxHeartbeats 10 in repeat skip", "maximum number of heartbeats")] do
    for linear in [false, true] do
      let initial ← requireRunAtResponseSuccess "store resource-limit basis" <|
        ← sendRunAt doc { line, character := 2, text := "skip", storeHandle := true }
      let some handle := initial.handle?
        | throw <| IO.userError "missing resource-limit basis handle"
      let requireFailure (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
        unless !result.success && result.handle?.isNone &&
            result.proofState?.map (·.goals.map (·.target)) ==
              initial.proofState?.map (·.goals.map (·.target)) &&
            result.messages.any (fun msg => msg.severity == .error && msg.text.contains needle) do
          throw <| IO.userError s!"resource limit must preserve the original goals: {(toJson result).compress}"
      -- A tactic advances the state before the limit is reached; failure restores the whole probe.
      let direct : Beam.LSP.RunAt.Result ← awaitResponseAs <|
        ← sendRunAt doc { line, character := 2, text, storeHandle := true }
      requireFailure direct
      let continued : Beam.LSP.RunAt.Result ← awaitResponseAs <|
        ← runWithHandle doc handle { text, storeHandle := true, linear }
      requireFailure continued
      let retry ← runWithHandle doc handle { text := "constructor <;> trivial" }
      if linear then
        expectErrorContains retry invalidParamsJson
      else
        let solved ← requireRunAtResponseSuccess "reuse handle after resource limit" retry
        unless solved.proofState?.map (·.goals.size) == some 0 do
          throw <| IO.userError "resource limit changed the stored proof state"
        releaseHandle doc handle
    requireRunAtSolvesProof "resource limits preserve the document" doc position
      "constructor <;> trivial"
  closeDoc doc

def checkRunAtSilentDiagnostics : ScenarioM Unit := do
  let path := "tests/scenario/docs/RunAtElaborationAbort.lean"
  let source ← IO.FS.readFile path
  let doc ← openDoc path
  syncDoc doc
  let hiddenFailure := "elaboration failed without visible diagnostics"
  for (marker, initialText, failures, successTexts) in [
      ("command", "#silent_info_probe", [("#silent_error_probe", hiddenFailure),
        ("set_option warningAsError true in\n#silent_warning_probe", hiddenFailure)],
        ["#silent_info_probe", "#silent_warning_probe", "#guard_msgs in\n#silent_error_probe",
          "#guard_msgs (drop error) in\n#check beamMissingExpectedProbe"]),
      ("probe", "skip", [("silent_error_probe", hiddenFailure),
        ("set_option warningAsError true in\nsilent_warning_probe", hiddenFailure),
        ("silent_abort_probe", "tactic aborted without visible diagnostics"),
        ("silent_then_throw_probe", "visible exception diagnostic"),
        ("mixed_error_probe", "visible diagnostic")],
        ["silent_info_probe\nconstructor <;> trivial", "silent_warning_probe\nconstructor <;> trivial",
          "fail_if_success (exact (0 : Nat))\nconstructor <;> trivial"])] do
    let some (_, line) := source.splitOn "\n" |>.zipIdx |>.find? (fun (text, _) =>
        text.endsWith s!" -- {marker}")
      | throw <| IO.userError s!"missing silent-diagnostic position {marker}"
    let character := if marker == "command" then 0 else 2
    let initial ← requireRunAtResponseSuccess "store silent-diagnostic basis" <|
      ← sendRunAt doc { line, character, text := initialText, storeHandle := true }
    let some handle := initial.handle?
      | throw <| IO.userError "missing silent-diagnostic handle"
    let requireFailure (text needle : String) (result : Beam.LSP.RunAt.Result) : ScenarioM Unit := do
      unless !result.success && result.handle?.isNone && result.messages.size == 1 &&
          result.messages.any (fun msg => msg.severity == .error && msg.text.contains needle) do
        throw <| IO.userError s!"{text}: expected one visible error and no successor: {(toJson result).compress}"
      if result.messages.any (·.text.contains "hidden diagnostic") then
        throw <| IO.userError s!"{text}: exposed a silent diagnostic"
    for (text, needle) in failures do
      let direct : Beam.LSP.RunAt.Result ← awaitResponseAs <|
        ← sendRunAt doc { line, character, text, storeHandle := true }
      requireFailure text needle direct
      let continued : Beam.LSP.RunAt.Result ← awaitResponseAs <|
        ← runWithHandle doc handle { text, storeHandle := true }
      requireFailure text needle continued
    -- Silent information/warnings do not fail. Neither do errors handled by an enclosing
    -- command or tactic: only the final log counts. Failed continuations leave the parent reusable.
    for text in successTexts do
      for req in [← sendRunAt doc { line, character, text, storeHandle := true },
          ← runWithHandle doc handle { text, storeHandle := true }] do
        let result ← requireRunAtResponseSuccess "handled or silent diagnostics" req
        unless result.messages.isEmpty do
          throw <| IO.userError s!"{text}: unexpected diagnostics: {(toJson result).compress}"
        let some successor := result.handle?
          | throw <| IO.userError s!"{text}: successful request omitted its successor handle"
        releaseHandle doc successor
    releaseHandle doc handle
  closeDoc doc

def checkRunAtTheoremProofFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem proof failure" doc { line := 8, character := 0 }
    "theorem runAtImpossibleProbe : False := by\n  trivial"
    "False"
  closeDoc doc

def checkRunAtTheoremSuccessOmitsSilentMessages : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"
  syncDoc doc
  let req ← sendRunAt doc {
    line := 8
    character := 0
    text := "theorem runAtCompletedProbe : True := by\n  trivial"
  }
  let result ← requireRunAtResponseSuccess "runAt completed theorem" req
  if result.messages.any (fun message => message.text.contains "Goals accomplished") then
    throw <| IO.userError
      s!"runAt completed theorem leaked a silent lifecycle message: {(toJson result).compress}"
  closeDoc doc

def checkRunAtTheoremTacticFailure : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/TopLevelTheoremRunAtFailure.lean"
  syncDoc doc
  requireRunAtFailureMessage "runAt theorem tactic failure" doc { line := 7, character := 0 }
    "theorem runAtTacticFailureProbe : True := by\n  runat_fail_tac"
    "runAt custom tactic failure"
  closeDoc doc

def checkRunAtInvalidPositionLine : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 99, character := 0, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtInvalidPositionCharacter : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/CommandA.lean"

  let req ← sendRunAt doc { line := 0, character := 200, text := "#check Nat" }

  expectErrorContains req invalidParamsJson

  closeDoc doc

def checkRunAtStaleEdit : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"

  let staleReq ← sendRunAt doc { line := 1, character := 2, text := "exact trivial" }
  invalidateWithWhitespacePrefixEdit doc

  expectContentModified staleReq

  closeDoc doc

def checkRunAtStaleVersion : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  syncDoc doc

  let staleReq ← sendRunAt doc {
    version? := some 0
    line := 1
    character := 2
    text := "exact trivial"
  }
  expectContentModified staleReq

  closeDoc doc

def checkRunAtStaleEditConcurrentRequest : ScenarioM Unit := do
  let staleDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let survivorDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let staleReq ← sendRunAt staleDoc { line := 1, character := 2, text := "exact trivial" }
  let survivorReq ← sendRunAt survivorDoc { line := 1, character := 2, text := "exact trivial" }

  invalidateWithWhitespacePrefixEdit staleDoc

  expectContentModified staleReq
  discard <| requireRunAtResponseSuccess "runAt concurrent request after stale edit" survivorReq

  closeDoc staleDoc
  closeDoc survivorDoc

def checkRunAtCancellation : ScenarioM Unit := do
  let slowDoc ← openDoc "tests/scenario/docs/SlowClose.lean"
  let fastDoc ← openDoc "tests/scenario/docs/CommandB.lean"

  let slowReq ← sendRunAt slowDoc { line := 8, character := 2, text := "exact trivial" }
  let fastReq ← sendRunAt fastDoc { line := 0, character := 2, text := "#check Nat" }

  cancelReq slowReq

  let fastResult ← requireRunAtResponseSuccess "runAt cancellation survivor" fastReq
  unless fastResult.messages.any (fun msg =>
      msg.severity == MessageSeverity.information && msg.text.contains "Nat : Type") do
    throw <| IO.userError
      s!"runAt cancellation survivor: expected Nat information message, got {(toJson fastResult).compress}"

  expectErrorContains slowReq requestCancelledJson

  closeDoc slowDoc
  closeDoc fastDoc

private def requireRunAtGoals (label : String) (doc : DocHandle) (position : Lean.Lsp.Position)
    (goals : Array String) : ScenarioM Unit := do
  let result ← requireRunAtSuccess label doc position "skip"
  let actual := (result.proofState?.map (·.goals.map (·.target))).getD #[]
  unless actual == goals do
    throw <| IO.userError s!"{label}: expected goals {goals}, got {(toJson result).compress}"

def checkRunAtPlaceholders : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/RunAtPlaceholders.lean"
  syncDoc doc

  -- At an unfilled `sorry` term, from its first character through its end, the text is tactics
  -- run against the goal the `sorry` stands for.
  for character in [65, 70] do
    requireRunAtGoals "term sorry" doc { line := 0, character } #["q"]
  requireRunAtSolvesProof "exact at term sorry" doc { line := 0, character := 65 } "exact hq"
  requireRunAtSolvesProof "outer by at term sorry" doc { line := 0, character := 65 }
    "by\n    exact hq"

  -- An unsynthesized `_` or `?x` becomes a goal with its expected type and local context,
  -- including local instances.
  requireRunAtGoals "term hole" doc { line := 2, character := 50 } #["Nat"]
  requireRunAtSolvesProof "exact at term hole" doc { line := 2, character := 50 } "exact 0"
  requireRunAtSolvesProof "local instance at hole" doc { line := 9, character := 72 }
    "exact default"
  requireRunAtGoals "named hole" doc { line := 11, character := 53 } #["p"]
  requireRunAtSolvesProof "exact at named hole" doc { line := 11, character := 53 } "exact hp"

  -- Inside a tactic proof the placeholder is more specific than the tactic containing it.
  requireRunAtGoals "sorry inside exact" doc { line := 7, character := 31 } #["0 < n"]
  requireRunAtSolvesProof "proof of nested sorry" doc { line := 7, character := 31 } "exact h"
  requireRunAtGoals "tactic start before nested sorry" doc { line := 7, character := 2 }
    #["n ≠ 0"]

  -- A hole that elaboration filled is not a placeholder; the command basis applies.
  let filled ← requireRunAtSuccess "filled hole" doc { line := 4, character := 42 }
    "#check (3 : Nat)"
  if filled.proofState?.isSome then
    throw <| IO.userError s!"filled hole: expected the command basis, got {(toJson filled).compress}"

  -- A `?_` that a later tactic handled, by solving its goal or with a `sorry` tactic, is not an
  -- open placeholder: the tactic basis applies there, and its after-state at `refine` holds both
  -- goals. An unhandled `?_` selects its own goal.
  requireRunAtGoals "unhandled refine hole" doc { line := 14, character := 14 } #["q"]
  requireRunAtGoals "refine hole solved later" doc { line := 17, character := 14 } #["p", "q"]
  requireRunAtGoals "refine hole with a later sorry" doc { line := 22, character := 14 } #["p", "q"]

  -- Tactics may leave goals at a placeholder; a stored handle continues them.
  let partialResult : Beam.LSP.RunAt.Result ← awaitResponseAs <|
    ← sendRunAt doc { line := 2, character := 50, text := "refine ?_ + 1", storeHandle := true }
  let some handle := partialResult.handle?
    | throw <| IO.userError s!"partial hole proof: expected a handle, got {(toJson partialResult).compress}"
  unless partialResult.proofState?.map (·.goals.map (·.target)) == some #["Nat"] do
    throw <| IO.userError s!"partial hole proof: expected goal Nat, got {(toJson partialResult).compress}"
  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs
    (← runWithHandle doc handle { text := "exact 0" })
  unless continued.success && continued.proofState?.any (·.goals.isEmpty) do
    throw <| IO.userError s!"partial hole proof: expected the handle to finish, got {(toJson continued).compress}"

  closeDoc doc

private def placeholderContentModifiedJson : Json :=
  Json.mkObj [("code", toJson "contentModified")]

def checkRunAtPlaceholderContexts : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/RunAtPlaceholderContexts.lean"
  syncDoc doc

  -- The placeholder's goal keeps its local context: `let` values, local instances, the open
  -- namespace, local notation, and section or header universes.
  let contexts : List (String × Lean.Lsp.Position × String × Array String) := [
    ("let", ⟨10, 47⟩, "exact k", #["Nat"]),
    ("letI", ⟨11, 52⟩, "exact default", #["Nat"]),
    ("instance", ⟨12, 45⟩, "exact default", #["α"]),
    ("open", ⟨13, 22⟩, "exact val", #["Nat"]),
    ("notation", ⟨14, 26⟩, "exact MAGIC", #["Nat"]),
    ("universe", ⟨15, 45⟩, "exact a", #["α"]),
    ("unused universe", ⟨16, 33⟩, "have : ULift.{u} Nat := ⟨0⟩; trivial", #["True"]),
    ("header universe", ⟨17, 50⟩, "have : ULift.{v} Nat := ⟨0⟩; trivial", #["True"])]
  for (label, position, solution, goals) in contexts do
    requireRunAtGoals s!"{label} placeholder" doc position goals
    requireRunAtSolvesProof s!"{label} placeholder solution" doc position solution
    -- A rejected probe reports the placeholder's goal unchanged.
    let rejected : Beam.LSP.RunAt.Result ← awaitResponseAs <|
      ← sendRunAt doc {
        line := position.line
        character := position.character
        text := "exact \"invalid\""
      }
    unless !rejected.success &&
        rejected.proofState?.map (·.goals.map (·.target)) == some goals do
      throw <| IO.userError s!"{label} placeholder: expected a rejection with goals {goals}, got {(toJson rejected).compress}"

  -- Each probe starts from the placeholder's goal: a local from one probe is visible only through
  -- the handle that stored it, including among concurrent requests.
  let letHole : Lean.Lsp.Position := ⟨10, 47⟩
  let introduced : Beam.LSP.RunAt.Result ← awaitResponseAs <|
    ← sendRunAt doc {
      line := letHole.line
      character := letHole.character
      text := "have extra : Nat := 1"
      storeHandle := true
    }
  let some extraHandle := introduced.handle?
    | throw <| IO.userError s!"placeholder isolation: expected a handle, got {(toJson introduced).compress}"
  requireRunAtFailureMessage "independent probe after a stored local" doc letHole "exact extra"
    "extra"
  let continued : Beam.LSP.RunAt.Result ← awaitResponseAs
    (← runWithHandle doc extraHandle { text := "exact extra" })
  unless continued.success && continued.proofState?.any (·.goals.isEmpty) do
    throw <| IO.userError s!"placeholder isolation: expected the handle to see its local, got {(toJson continued).compress}"
  let mut pending := #[]
  for i in [:8] do
    let text := if i % 2 == 0 then "have independent : Nat := 42; exact independent"
      else "exact independent"
    pending := pending.push (i, ← sendRunAt doc {
      line := letHole.line
      character := letHole.character
      text
    })
  for (i, req) in pending do
    let result : Beam.LSP.RunAt.Result ← awaitResponseAs req
    unless result.success == (i % 2 == 0) do
      throw <| IO.userError s!"concurrent placeholder probe {i}: {(toJson result).compress}"
  requireRunAtGoals "placeholder after concurrent probes" doc letHole #["Nat"]

  -- Known limitation, documented with runAt: probes do not run Lean's termination checking, so
  -- text that uses the declaration being proved succeeds although the same edit fails. Update
  -- these expectations when probes reject self-use. Later declarations stay unknown.
  requireRunAtSolvesProof "self-reference at a term sorry" doc ⟨20, 28⟩ "exact termSelf"
  requireRunAtSolvesProof "self-reference at a tactic sorry" doc ⟨21, 33⟩ "exact tacticSelf"
  requireRunAtFailureMessage "later declaration at a term sorry" doc ⟨20, 28⟩
    "exact tacticSelf" "tacticSelf"

  -- An edit invalidates handles stored at a placeholder.
  let minted : Beam.LSP.RunAt.Result ← awaitResponseAs <|
    ← sendRunAt doc { line := 12, character := 45, text := "skip", storeHandle := true }
  let some staleHandle := minted.handle?
    | throw <| IO.userError s!"placeholder invalidation: expected a handle, got {(toJson minted).compress}"
  changeDoc doc { line := 0, character := 10, insert := " " }
  syncDoc doc
  expectErrorContains (← runWithHandle doc staleHandle { text := "exact default" })
    placeholderContentModifiedJson
  expectErrorContains (← runWithHandle doc extraHandle { text := "exact extra" })
    placeholderContentModifiedJson

  closeDoc doc

def checkRunAtWithStandardLspInterference : ScenarioM Unit := do
  let runAtDoc ← openDoc "tests/scenario/docs/SimpleProof.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let runAtReq ← sendRunAt runAtDoc { line := 1, character := 2, text := "exact trivial" }
  syncWhitespacePrefixEdit editDoc

  discard <| requireRunAtResponseSuccess "runAt with LSP interference" runAtReq

  closeDoc runAtDoc
  closeDoc editDoc

def run : ScenarioM Unit := do
  checkRunAtTacticPositions
  checkRunAtTacticSequences
  checkRunAtUnicodeSourceColumn
  checkRunAtPlaceholders
  checkRunAtPlaceholderContexts
  checkRunAtElaborationAborts
  checkRunAtResourceLimits
  checkRunAtSilentDiagnostics
  checkRunAtOneCommandOnly
  checkRunAtTheoremSuccessOmitsSilentMessages
  checkRunAtTheoremProofFailure
  checkRunAtTheoremTacticFailure
  checkRunAtInvalidPositionLine
  checkRunAtInvalidPositionCharacter
  checkRunAtStaleEdit
  checkRunAtStaleVersion
  checkRunAtStaleEditConcurrentRequest
  checkRunAtCancellation
  checkRunAtWithStandardLspInterference

end BeamTest.LSP.Requests.RunAt.BasicTest
