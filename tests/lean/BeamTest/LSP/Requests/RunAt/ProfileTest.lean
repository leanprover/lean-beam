/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.RunAt.ProfileTest

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def profileOf (result : Beam.LSP.RunAt.Result) : ScenarioM Beam.LSP.RunAt.Profile.Result := do
  let some profile := result.profile?
    | throw <| IO.userError s!"missing profile: {(toJson result).compress}"
  require (profile.elapsedMs > 0) "profile elapsed time must be positive"
  require (!profile.truncated) "small profile unexpectedly truncated"
  require (profile.thresholdMs == 1) "profile threshold changed"
  for i in [:profile.spans.size] do
    let span := profile.spans[i]!
    require (span.startMs >= 0 && span.durationMs >= 0) "negative span time"
    require (span.startMs + span.durationMs <= profile.elapsedMs + 0.01)
      "span exceeds execution interval"
    if let some parent := span.parent? then
      require (parent < i) "span parent must precede child"
      require (profile.spans[parent]!.thread == span.thread) "parent crosses execution threads"
  return profile

private def hasCategory (profile : Beam.LSP.RunAt.Profile.Result) (category : String) : Bool :=
  profile.spans.any (·.category == category)

private def awaitResult (request : ReqHandle) : ScenarioM Beam.LSP.RunAt.Result :=
  awaitResponseAs request

def checkProjection : IO Unit := do
  let forced ← IO.mkRef false
  let label := MessageData.ofLazy (fun _ => do
    forced.set true
    pure <| Dynamic.mk (m!"expensive label")) (fun _ => false)
  let child : MessageData := .trace {
    cls := `child, startTime := 1.2, stopTime := 1.4, tag := "child"
  } label #[]
  let root : MessageData := .trace {
    cls := `root, startTime := 1.1, stopTime := 1.9, tag := "root"
  } label #[child]
  let state : TraceState := { tid := 7, traces := ({} : PersistentArray TraceElem).push { ref := .missing, msg := root } }
  let profile := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000 #[state] ""
  require (profile.spans.size == 2 && profile.spans[1]!.parent? == some 0)
    "projection lost nested parent relation"
  require (profile.spans.all (·.thread == 7)) "projection lost thread identity"
  require (profile.spans.all (·.range?.isNone)) "projection invented a missing source location"
  require (!profile.truncated && profile.elapsedMs == 1000) "unexpected projection summary"
  require (!(← forced.get)) "projection evaluated a lazy trace label"

  let wide : MessageData := .trace { cls := `root, startTime := 1.1, stopTime := 1.9 }
    label (Array.replicate (Beam.LSP.RunAt.Profile.maxSpans + 1) child)
  let bounded := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000
    #[{ state with traces := ({} : PersistentArray TraceElem).push { ref := .missing, msg := wide } }] ""
  require (bounded.truncated && bounded.spans.size == Beam.LSP.RunAt.Profile.maxSpans)
    "wide profile exceeded response budget or omitted truncation"
  let deep := (List.range (Beam.LSP.RunAt.Profile.maxDepth + 1)).foldl (fun msg _ => .group msg) root
  let depthBounded := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000
    #[{ state with traces := ({} : PersistentArray TraceElem).push { ref := .missing, msg := deep } }] ""
  require depthBounded.truncated "deep profile did not report truncation"
  let old : MessageData := .trace { cls := `inherited, startTime := 0.1, stopTime := 0.2 } label #[]
  let filtered := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000
    #[{ state with traces := ({} : PersistentArray TraceElem).push { ref := .missing, msg := old } }] ""
  require filtered.spans.isEmpty "projection attributed pre-request work to the request"
  require (!(← forced.get)) "bounded projection evaluated lazy labels"

  -- Malformed and out-of-window intervals are dropped rather than leaking into a request's
  -- profile. A dropped node must not become a parent of its children.
  let badInterval : MessageData := .trace {
    cls := `reversed, startTime := 1.8, stopTime := 1.7
  } label #[child]
  let afterStop : MessageData := .trace {
    cls := `afterStop, startTime := 2.1, stopTime := 2.2
  } label #[]
  let mixed := ({} : PersistentArray TraceElem)
    |>.push { ref := .missing, msg := badInterval }
    |>.push { ref := .missing, msg := afterStop }
    |>.push { ref := .missing, msg := root }
  let intervalFiltered := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000
    #[{ state with traces := mixed }] ""
  require (intervalFiltered.spans.map (·.category) == #["child", "root", "child"])
    "projection retained an invalid interval or discarded its valid child"
  require (intervalFiltered.spans[0]!.parent?.isNone &&
      intervalFiltered.spans[2]!.parent? == some 1)
    "an excluded interval changed the surviving parent relationships"
  require (!(← forced.get)) "interval filtering evaluated a lazy trace label"

  let mut manyTraces : PersistentArray TraceElem := {}
  for _ in [:Beam.LSP.RunAt.Profile.maxVisited + 1] do
    manyTraces := manyTraces.push { ref := .missing, msg := label }
  let visitBounded := Beam.LSP.RunAt.Profile.collect 1000000000 2000000000
    #[{ state with traces := manyTraces }] ""
  require (visitBounded.truncated && visitBounded.spans.isEmpty)
    "projection exceeded its visited-node budget"
  require (!(← forced.get)) "visited-node bounding evaluated a lazy trace label"

  let original : Options := ({} : Options)
    |>.setBool `trace.profiler false
    |>.set `trace.profiler.threshold (7 : Nat)
    |>.setBool `trace.profiler.useHeartbeats true
    |>.set `trace.profiler.output ("original.profiler.output" : String)
    |>.setBool `trace.profiler.serve true
    |>.set `pp.width (41 : Nat)
  let changed := (Beam.LSP.RunAt.Profile.options original).set `pp.width (72 : Nat)
  let restored := Beam.LSP.RunAt.Profile.restoreOptions original changed
  require (!trace.profiler.get restored &&
      restored.get (α := Nat) `trace.profiler.threshold 0 == 7 &&
      restored.get (α := Bool) `trace.profiler.useHeartbeats false &&
      restored.get? (α := String) `trace.profiler.output == some "original.profiler.output" &&
      restored.get (α := Bool) `trace.profiler.serve false)
    "option restoration did not restore every profiler option"
  require (restored.get (α := Nat) `pp.width 0 == 72) "option restoration discarded command option changes"

def checkProofs : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ProfileProof.lean"
  syncDoc doc
  let complete ← sendRunAt doc {
    line := 25, character := 2, text := "profile_left; profile_right; trivial", profile := true
  }
  let result ← awaitResult complete
  require (result.success && result.proofState?.any (·.goals.isEmpty)) "whole proof did not solve"
  let profile ← profileOf result
  require (hasCategory profile "beam.profile.left" && hasCategory profile "beam.profile.right")
    "whole proof must include both tactic phases"
  require (result.traces.isEmpty) "profile should not pretty-print the trace tree"

  let multiline ← sendRunAt doc {
    line := 25, character := 2
    text := "-- a complete proof block\nprofile_left\nhave h : True ∧ True := by\n  constructor\n  · trivial\n  · trivial\nprofile_right\nexact h.1"
    profile := true
  }
  let multilineResult ← awaitResult multiline
  require (multilineResult.success && multilineResult.proofState?.any (·.goals.isEmpty))
    "multiline proof with nested goals failed"

  let failed ← sendRunAt doc {
    line := 25, character := 2, text := "profile_left; exact (0 : Nat)", profile := true,
    storeHandle := true
  }
  let failure ← awaitResult failed
  require (!failure.success && failure.handle?.isNone &&
      failure.messages.any (·.severity == .error)) "expected semantic proof failure with rollback"
  require (failure.proofState?.map (·.goals.map (·.target)) == some #["True"])
    "profiled failure did not restore the original goal"
  let failureProfile ← profileOf failure
  require (hasCategory failureProfile "beam.profile.left") "failure lost execution evidence on rollback"

  let left ← sendRunAt doc {
    line := 25, character := 2, text := "profile_left; trivial", profile := true
  }
  let right ← sendRunAt doc {
    line := 25, character := 2, text := "profile_right; trivial", profile := true
  }
  let ordinary ← sendRunAt doc {
    line := 25, character := 2, text := "profile_check_off; profile_left; trivial"
  }
  let leftProfile ← profileOf (← awaitResult left)
  let rightProfile ← profileOf (← awaitResult right)
  let ordinaryResult ← awaitResult ordinary
  require (hasCategory leftProfile "beam.profile.left" && !hasCategory leftProfile "beam.profile.right")
    "concurrent right probe leaked into left profile"
  require (hasCategory rightProfile "beam.profile.right" && !hasCategory rightProfile "beam.profile.left")
    "concurrent left probe leaked into right profile"
  require (ordinaryResult.success && ordinaryResult.profile?.isNone)
    "concurrent profiling attached profiler output to the ordinary request"

  -- Exercise real tactic elaboration in a multi-step proof, in addition to synthetic timed scopes.
  let realProof ← sendRunAt doc {
    line := 25, character := 2
    text := "have h : (1 : Nat) + 1 = 2 := by decide\nhave hp : True := trivial\nexact hp"
    profile := true
  }
  let realResult ← awaitResult realProof
  require (realResult.success && realResult.proofState?.any (·.goals.isEmpty))
    "profiled multi-tactic proof did not solve the goal"
  discard <| profileOf realResult

  -- The instrumentation option must not change behavior at a term placeholder.
  let placeholderUnprofiled ← sendRunAt doc {
    line := 35, character := 10, text := "exact 1"
  }
  let placeholderProfiled ← sendRunAt doc {
    line := 35, character := 10, text := "exact 1", profile := true
  }
  let plainHoleResult ← awaitResult placeholderUnprofiled
  let profiledHoleResult ← awaitResult placeholderProfiled
  require (plainHoleResult.success && profiledHoleResult.success &&
      plainHoleResult.proofState?.map (·.goals.map (·.target)) ==
        profiledHoleResult.proofState?.map (·.goals.map (·.target)))
    "profiling changed the proof state selected at a term placeholder"
  discard <| profileOf profiledHoleResult

  let mint ← sendRunAt doc {
    line := 25, character := 2, text := "profile_left", profile := true, storeHandle := true
  }
  let minted ← awaitResult mint
  let some handle := minted.handle? | throw <| IO.userError "missing profiled proof handle"
  let failedContinuation ← runWithHandle doc handle {
    text := "profile_right; exact (0 : Nat)", profile := true, storeHandle := true
  }
  let failedResult ← awaitResult failedContinuation
  require (!failedResult.success && failedResult.handle?.isNone &&
      failedResult.proofState?.map (·.goals.map (·.target)) == some #["True"])
    "failed profiled continuation did not roll back"
  require (hasCategory (← profileOf failedResult) "beam.profile.right")
    "failed profiled continuation lost timing evidence"
  let plain ← runWithHandle doc handle { text := "profile_check_off; trivial" }
  let plainResult ← awaitResult plain
  require (plainResult.success && plainResult.profile?.isNone && plainResult.traces.isEmpty)
    "profiling leaked into unprofiled continuation"
  let next ← runWithHandle doc handle { text := "profile_right; trivial", profile := true }
  let nextProfile ← profileOf (← awaitResult next)
  require (hasCategory nextProfile "beam.profile.right" && !hasCategory nextProfile "beam.profile.left")
    "profiled continuation reported parent work"

  let plainRoot ← sendRunAt doc {
    line := 25, character := 2, text := "profile_check_off; trivial"
  }
  let plainRootResult ← awaitResult plainRoot
  require (plainRootResult.success && plainRootResult.profile?.isNone) "real proof state was modified"
  let parseFailure ← sendRunAt doc { line := 25, character := 2, text := "(", profile := true }
  let parsed ← awaitResult parseFailure
  require (!parsed.success && parsed.profile?.isNone) "parse failure must not claim execution evidence"
  closeDoc doc

def checkCommands : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ProfileProof.lean"
  syncDoc doc
  -- Re-elaborate the declaration already present in the synced file at its start position.
  -- The preceding snapshot must not include that declaration or unrelated later work.
  let existing ← sendRunAt doc {
    line := 27, character := 0
    text := "theorem existingProfiledDeclaration : True ∧ True := by\n  constructor\n  · profile_left\n    trivial\n  · profile_right\n    trivial"
    profile := true
  }
  let existingResult ← awaitResult existing
  require existingResult.success "profiling an existing declaration used the wrong snapshot"
  let existingProfile ← profileOf existingResult
  require (hasCategory existingProfile "beam.profile.left" && hasCategory existingProfile "beam.profile.right")
    "existing declaration omitted part of its tactic breakdown"
  let theoremReq ← sendRunAt doc {
    line := 22, character := 0
    text := "theorem profiledWholeTheorem : True := by\n  profile_left\n  profile_right\n  trivial"
    profile := true, storeHandle := true
  }
  let result ← awaitResult theoremReq
  require result.success "whole theorem profiling failed"
  let profile ← profileOf result
  require (hasCategory profile "beam.profile.left" && hasCategory profile "beam.profile.right")
    "whole theorem omitted asynchronous proof body"
  let some handle := result.handle? | throw <| IO.userError "missing command handle"
  let check ← runWithHandle doc handle { text := "profile_check_command" }
  let checked ← awaitResult check
  require (checked.success && checked.profile?.isNone && checked.traces.isEmpty)
    "command handle retained profiling options or traces"
  let continued ← runWithHandle doc handle {
    text := "example : True := by profile_right; trivial", profile := true
  }
  let continuationProfile ← profileOf (← awaitResult continued)
  require (!hasCategory continuationProfile "beam.profile.left") "command handle retained old task traces"
  let failed ← sendRunAt doc {
    line := 22, character := 0
    text := "theorem profiledFailedTheorem : False := by\n  profile_left\n  trivial"
    profile := true, storeHandle := true
  }
  let failure ← awaitResult failed
  require (!failure.success && failure.handle?.isNone) "expected failed async theorem with rollback"
  require (hasCategory (← profileOf failure) "beam.profile.left") "failed theorem lost async profile"
  closeDoc doc

def checkCancellationAndStaleness : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/SlowPoll.lean"
  syncDoc doc
  let request ← sendRunAt doc { line := 28, character := 2, text := "poll_sleep_tac", profile := true }
  IO.sleep 100
  cancelReq request
  expectErrorContains request <| Json.mkObj [("code", toJson "requestCancelled")]
  let survivor ← sendRunAt doc { line := 28, character := 2, text := "custom_trivial", profile := true }
  require (← awaitResult survivor).success "cancelled profile affected the next probe"
  let theoremRequest ← sendRunAt doc {
    line := 25, character := 0
    text := "example : True := by poll_sleep_tac", profile := true
  }
  IO.sleep 100
  cancelReq theoremRequest
  expectErrorContains theoremRequest <| Json.mkObj [("code", toJson "requestCancelled")]
  let theoremSurvivor ← sendRunAt doc {
    line := 25, character := 0, text := "example : True := by trivial", profile := true
  }
  require (← awaitResult theoremSurvivor).success "cancelled async profile affected the next theorem"
  let stale ← sendRunAt doc { line := 28, character := 2, text := "poll_sleep_tac", profile := true }
  IO.sleep 100
  changeDoc doc { line := 0, character := 0, insert := "\n" }
  expectContentModified stale
  closeDoc doc

def run : ScenarioM Unit := do
  checkProjection
  checkProofs
  checkCommands
  checkCancellationAndStaleness

end BeamTest.LSP.Requests.RunAt.ProfileTest
