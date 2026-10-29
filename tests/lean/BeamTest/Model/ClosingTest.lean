/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import BeamTest.Model.RequestSettlementTest
import BeamTest.Model.LspRequestsTest
import BeamModel
import BeamTest.Model.AdmissionTest
import BeamTest.Model.PublicationTest

open BeamModel.Closing

namespace BeamTest.Model.ClosingTest

private def doc : Document := ⟨1, 10⟩
private def first : Lease := ⟨⟨1, 1⟩, doc⟩
private def second : Lease := ⟨⟨1, 2⟩, doc⟩
private def replacement : Lease := ⟨⟨2, 1⟩, doc⟩

private def check (message : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError message

private def trace (label : String) (actions : List (Action × Outcome)) : IO State := do
  let mut state : State := {}
  for ((action, expected), index) in actions.zipIdx do
    let (next, actual) := step state action
    check s!"{label}, step {index}: {repr action}; expected {repr expected}, got {repr actual}"
      (actual == expected)
    state := next
  pure state

def runTests : IO Unit := do
  BeamTest.Model.PublicationTest.runTests
  let state ← trace "exclusive close with committed checkpoint" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.accept ⟨1, 0⟩ 20, .rejected .closing),
    (.reserve ⟨1, 0⟩ 10, .rejected .closing),
    (.close, .rejected .closing),
    (.committed first, .done),
    (.finish first, .done),
    (.release first, .done)]
  check "successful close retains checkpoint" (saved state first && state.lifecycle == .open none)
  discard <| trace "delayed read cannot reopen; a new read can" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.committed first, .done),
    (.finish first, .done),
    (.accept ⟨1, 0⟩ 20, .rejected .staleRead),
    (.accept ⟨1, 1⟩ 20, .accepted ⟨2, 20⟩)]
  discard <| trace "failure releases reservation, not the read fence" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.finish first, .rejected .notCommitted),
    (.release first, .done),
    (.accept ⟨1, 0⟩ 20, .rejected .staleRead),
    (.accept ⟨1, 1⟩ 20, .accepted ⟨2, 20⟩)]
  discard <| trace "cleanup from first attempt cannot release retry on identical basis" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.release first, .done),
    (.reserve ⟨1, 1⟩ 10, .reserved second),
    (.release first, .done),
    (.accept ⟨1, 2⟩ 20, .rejected .closing),
    (.committed second, .done),
    (.finish first, .rejected .staleLease),
    (.finish second, .done)]
  let state ← trace "commit before replacement, same text and local counters" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.committed first, .done),
    (.replace, .done),
    (.reserve ⟨2, 0⟩ 10, .reserved replacement),
    (.release first, .done),
    (.finish first, .rejected .staleLease),
    (.accept ⟨2, 1⟩ 20, .rejected .closing)]
  check "replacement preserves historical commit" (saved state first)
  let state ← trace "commit observation after teardown" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.replace, .done),
    (.committed first, .done),
    (.finish first, .rejected .staleLease),
    (.release first, .done),
    (.accept ⟨2, 0⟩ 20, .accepted ⟨1, 20⟩)]
  check "late commit is still reported" (saved state first)
  let state ← trace "postcommit cleanup preserves evidence without certifying a retry" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.committed first, .done),
    (.release first, .done),
    (.reserve ⟨1, 1⟩ 10, .reserved second),
    (.finish second, .rejected .notCommitted),
    (.release second, .done)]
  check "cleanup retains committed evidence and the accepted document"
    (saved state first && !saved state second && state.lifecycle == .open (some doc))
  discard <| trace "replacement invalidates old reads even with reused fence" [
    (.replace, .done),
    (.accept ⟨1, 0⟩ 10, .rejected .staleRead),
    (.accept ⟨2, 0⟩ 10, .accepted doc)]
  discard <| trace "ordinary close fences delayed reads" [
    (.accept ⟨1, 0⟩ 10, .accepted doc),
    (.close, .done),
    (.accept ⟨1, 0⟩ 20, .rejected .staleRead),
    (.accept ⟨1, 1⟩ 10, .accepted ⟨2, 10⟩)]
  discard <| trace "reservation accepts source with a distinct basis" [
    (.accept ⟨1, 0⟩ 20, .accepted ⟨1, 20⟩),
    (.reserve ⟨1, 0⟩ 10, .reserved ⟨⟨1, 1⟩, ⟨2, 10⟩⟩)]
  discard <| trace "duplicate finish and cleanup are harmless" [
    (.reserve ⟨1, 0⟩ 10, .reserved first),
    (.committed first, .done),
    (.finish first, .done),
    (.finish first, .rejected .staleLease),
    (.release first, .done),
    (.release first, .done)]
  check "closing refuses read initiation"
    (match beginRead { lifecycle := .closing first } with
      | .error .closing => true
      | _ => false)
  check "open slot issues current owner and fence"
    (match beginRead { owner := 3, fence := 7 } with
      | .ok permit => permit == ⟨3, 7⟩
      | _ => false)
  IO.println "closing model: 11 transition traces and read-admission checks passed"

end BeamTest.Model.ClosingTest

def main : IO Unit := do
  BeamTest.Model.ClosingTest.runTests
  BeamTest.Model.AdmissionTest.runTests
  BeamTest.Model.LspRequestsTest.runTests
  BeamTest.Model.RequestSettlementTest.runTests
