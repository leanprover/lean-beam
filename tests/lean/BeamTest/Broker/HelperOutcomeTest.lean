/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.LakeHelper
import BeamTest.Broker.JsonAssert

open Lean Beam.Broker BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.HelperOutcomeTest

private def requireIOError (label : String) (result : Except IO.Error α)
    (message : String) : IO Unit := do
  match result with
  | .error (.userError actual) => require label (actual == message)
  | _ => throw <| IO.userError s!"{label}: missing original IO error"

private def failureOf (result : Except BrokerFailure α) : IO BrokerFailure :=
  match result with
  | .error failure => pure failure
  | .ok _ => throw <| IO.userError "expected helper failure"

private def checkScopeOutcomes : IO Unit := do
  for operationFails in [false, true] do
    for cleanupFails in [false, true] do
      let actions ← IO.mkRef (0 : Nat)
      let cleanups ← IO.mkRef (0 : Nat)
      let result ← Beam.ProcessJob.Internal.runScope
        (pure { observe := pure .running, finalize := fun retained => do
          require "cleanup receives retained ownership" retained
          cleanups.modify (· + 1)
          if cleanupFails then throw <| IO.userError "job cleanup"
        }) (pure ()) fun _ => do
          actions.modify (· + 1)
          if operationFails then throw <| IO.userError "operation"
          pure 7
      require "operation runs once" ((← actions.get) == 1)
      require "scope finalizes once" ((← cleanups.get) == 1)
      if operationFails then requireIOError "operation retained" result.operation "operation"
      else require "operation success retained" (match result.operation with | .ok 7 => true | _ => false)
      if cleanupFails then requireIOError "cleanup retained" result.cleanup "job cleanup"
      else discard <| IO.ofExcept result.cleanup
  let actions ← IO.mkRef (0 : Nat)
  let collections ← IO.mkRef (0 : Nat)
  let result ← Beam.ProcessJob.Internal.runScope
    (throw <| IO.userError "assignment")
    (do collections.modify (· + 1); throw <| IO.userError "unassigned cleanup")
    (fun _ => do actions.modify (· + 1); pure ())
  requireIOError "assignment is not replaced by cleanup" result.operation "assignment"
  requireIOError "failed-assignment cleanup retained" result.cleanup "unassigned cleanup"
  require "failed assignment never admits action" ((← actions.get) == 0)
  require "failed assignment collects once" ((← collections.get) == 1)

private def checkLostOwnership : IO Unit := do
  let observations ← IO.mkRef (0 : Nat)
  let retained? ← IO.mkRef (none : Option Bool)
  let result ← Beam.ProcessJob.Internal.runScope
    (pure {
      observe := do observations.modify (· + 1); pure .notChild
      finalize := fun retained => retained?.set (some retained)
    }) (throw <| IO.userError "unexpected unassigned cleanup") fun scope => do
      require "first poll records ownership loss" ((← scope.poll) == .notChild)
      require "subsequent polls retain ownership loss" ((← scope.poll) == .notChild)
      pure scope
  discard <| IO.ofExcept result.cleanup
  let scope ← IO.ofExcept result.operation
  require "lost ownership avoids another native observation" ((← observations.get) == 1)
  require "cleanup cannot claim lost ownership" ((← retained?.get) == some false)
  requireIOError "lost scope still closes" (← scope.poll.toBaseIO) "process-job scope is closed"

/-- The current policy serializes observation behind final collection. This test deliberately
holds cleanup; its short observation window is a fixture gate, not a production deadline. -/
private def checkClosingScope : IO Unit := do
  let ready ← IO.Promise.new (α := Option Beam.ProcessJob.Scope)
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  let attempted ← IO.Promise.new
  let released ← IO.mkRef false
  let releaseOnce : IO Unit := do
    unless ← released.get do
      released.set true
      release.resolve ()
  let observations ← IO.mkRef (0 : Nat)
  let collections ← IO.mkRef (0 : Nat)
  let observer? ← IO.mkRef (none : Option (Task (Except IO.Error Beam.ProcessJob.State)))
  let owner ← IO.asTask (prio := .dedicated) do
    let result ← Beam.ProcessJob.Internal.runScope
      (pure {
        observe := do observations.modify (· + 1); pure .running
        finalize := fun retained => do
          require "closing scope still owns collection" retained
          collections.modify (· + 1)
          entered.resolve ()
          discard <| IO.wait release.result?
          throw <| IO.userError "collection failure"
      }) (pure ()) fun scope => do
        ready.resolve (some scope)
        pure 7
    pure result
  try
    let some (some scope) ← IO.wait ready.result? | throw <| IO.userError "scope was not admitted"
    discard <| IO.wait entered.result?
    let observer ← IO.asTask (prio := .dedicated) do
      attempted.resolve ()
      scope.poll
    observer?.set (some observer)
    discard <| IO.wait attempted.result?
    require "poll waits while final collection holds the mutex"
      (← Beam.waitTaskWithTimeout observer 25).isNone
    require "closing poll never enters native observation" ((← observations.get) == 0)
    releaseOnce
    let result ← IO.ofExcept (← IO.wait owner)
    requireIOError "collection failure survives scope exit" result.cleanup "collection failure"
    require "operation survives failed collection" (match result.operation with | .ok 7 => true | _ => false)
    requireIOError "blocked poll observes closed scope" (← IO.wait observer) "process-job scope is closed"
    requireIOError "failed cleanup never reopens the scope" (← scope.poll.toBaseIO) "process-job scope is closed"
    require "final collection executes once" ((← collections.get) == 1)
    require "no observation after closure" ((← observations.get) == 0)
  finally
    releaseOnce
    discard <| IO.wait owner
    if let some observer ← observer?.get then discard <| IO.wait observer

private def checkHelperOutcomes : IO Unit := do
  let data := Json.mkObj [("marker", toJson "original data")]
  let outcomes : Array (Except BrokerFailure Response) := #[
    .ok (Response.success (Json.mkObj [("value", toJson 7)])),
    .error { code := .requestCancelled, message := "original cancellation", data? := some data },
    .error { code := .workerExited, message := "original worker exit", data? := some data },
    .error { code := .internalError, message := "original timeout", data? := some data },
    .ok (({ code := .invalidParams, message := "original helper error", data? := some data } :
      BrokerFailure).toResponse)
  ]
  for outcome in outcomes do
    for jobFails in [false, true] do
      for directoryFails in [false, true] do
        for outputFails in [false, true] do
          let removals ← IO.mkRef (0 : Nat)
          let job : Beam.ProcessJob.Completion (Except BrokerFailure Response) := {
            operation := .ok outcome
            cleanup := if jobFails then .error (IO.userError "job cleanup") else .ok ()
          }
          let completed ← LakeHelperJob.Internal.complete (pure job) do
            removals.modify (· + 1)
            if directoryFails then throw <| IO.userError "directory cleanup"
          let outputCleanup : Except IO.Error Unit :=
            if outputFails then .error (IO.userError "output cleanup") else .ok ()
          let completed := { completed with outputCleanup }
          require "directory removal runs once" ((← removals.get) == 1)
          let projected : Except BrokerFailure Json :=
            LakeHelperJob.Internal.projectCompletion .writeSaveTrace completed
          let clean : LakeHelperJob.Completion := {
            completed with jobCleanup := .ok (), directoryCleanup := .ok (), outputCleanup := .ok () }
          let original : Except BrokerFailure Json :=
            LakeHelperJob.Internal.projectCompletion .writeSaveTrace clean
          match outcome, original with
          | .ok (.successResult expected _), .ok actual =>
              require "helper success decodes unchanged" (actual.compress == expected.compress)
          | .error expected, .error actual =>
              require "local typed failure unchanged"
                ((toJson actual.toResponse).compress == (toJson expected.toResponse).compress)
          | .ok (.errorResult expected), .error actual =>
              require "remote typed failure unchanged"
                ((toJson actual.toResponseFailure.error).compress == (toJson expected.error).compress)
          | _, _ => throw <| IO.userError "clean helper projection changed the operation category"
          if jobFails || directoryFails || outputFails then
            let failure ← failureOf projected
            require "cleanup failure is not cancellation-only or unqualified success"
              (failure.code == .internalError)
            let info := failure.data?.getD Json.null
            requireJsonString "cleanup reason" "reason" "helperCleanupFailed" info
            let cleanup ← requireObjVal "cleanup context" "cleanup" info
            if jobFails then requireJsonString "job cleanup" "processJob" "job cleanup" cleanup
            else requireFieldAbsent "job cleanup" "processJob" cleanup
            if directoryFails then
              requireJsonString "directory cleanup" "temporaryDirectory" "directory cleanup" cleanup
            else requireFieldAbsent "directory cleanup" "temporaryDirectory" cleanup
            if outputFails then requireJsonString "output cleanup" "outputCapture" "output cleanup" cleanup
            else requireFieldAbsent "output cleanup" "outputCapture" cleanup
            let operation ← requireObjVal "operation outcome" "operationOutcome" info
            match original with
            | .ok _ => requireJsonString "successful operation" "status" "succeeded" operation
            | .error expected =>
              requireJsonString "failed operation" "status" "failed" operation
              let error ← requireObjVal "original error" "error" operation
              requireJsonString "original code" "code" expected.code.name error
              requireJsonString "original message" "message" expected.message error
              let retainedData ← requireObjVal "original data" "data" error
              requireJsonString "retained data" "marker" "original data" retainedData
            if let .ok response := outcome then
              let retained ← requireObjVal "operation receipt" "operationResponse" info
              require "raw response retained" (retained.compress == (toJson response).compress)
          else
            match original, projected with
            | .ok expected, .ok actual => require "clean success unchanged" (actual.compress == expected.compress)
            | .error expected, .error actual =>
              require "clean typed failure unchanged"
                ((toJson actual.toResponse).compress == (toJson expected.toResponse).compress)
            | _, _ => throw <| IO.userError "clean operation changed category"
  let completed ← LakeHelperJob.Internal.complete
    (throw <| IO.userError "setup IO failure") (throw <| IO.userError "directory cleanup")
  requireIOError "setup IO failure retained" completed.operation "setup IO failure"
  requireIOError "outer cleanup does not erase setup failure" completed.directoryCleanup "directory cleanup"
  let projected : Except BrokerFailure Json := LakeHelperJob.Internal.projectCompletion .serverEnv completed
  let failure ← failureOf projected
  require "setup and cleanup fail overall" (failure.code == .internalError)

private def checkInvalidResponse : IO Unit := do
  let data := Json.mkObj [("marker", toJson "unknown error data")]
  for response in #[Response.success (Json.str "invalid environment"),
      Response.errorResult { error := { code := "unknownFixtureError", message := "remote", data? := some data } }] do
    let completion : LakeHelperJob.Completion := {
      operation := .ok (.ok response)
      jobCleanup := .error (IO.userError "cleanup")
      directoryCleanup := .ok ()
    }
    let result : Except BrokerFailure LeanServerLakeEnv :=
      LakeHelperJob.Internal.projectCompletion .serverEnv completion
    let failure ← failureOf result
    let info := failure.data?.getD Json.null
    let receipt ← requireObjVal "invalid operation receipt" "operationResponse" info
    require "invalid/unknown response survives failed cleanup" (receipt.compress == (toJson response).compress)
    let operation ← requireObjVal "invalid operation outcome" "operationOutcome" info
    requireJsonString "invalid operation still fails" "status" "failed" operation
    let error ← requireObjVal "decoding error" "error" operation
    requireJsonString "decoding error code" "code" "internalError" error

private def checkEarlyOutputRetirement : IO Unit :=
  IO.FS.withTempDir fun temporary => do
    for cancelled in [false, true] do
      let output ← Beam.WorkspaceOutput.Buffer.create
      let some publisher ← output.borrow | throw <| IO.userError "fixture could not borrow publisher"
      let cancelRef ← IO.mkRef cancelled
      let result : Except BrokerFailure Json ← LakeHelperJob.runRequest
        (temporary / "missing-helper") .serverEnv Json.null .cancellable {
          cancelRef? := some cancelRef, output? := some publisher }
      let failure ← failureOf result
      -- Depending on spawn semantics, a missing executable either fails setup or exits
      -- as an admitted child. Both paths must retire its output capability.
      let expected := if cancelled then failure.code == .requestCancelled
        else failure.code == .internalError || failure.code == .workerExited
      require s!"early helper failure retains its category (cancelled={cancelled}): {(toJson failure.toResponse).compress}"
        expected
      let activity ← output.activity
      publisher.offer .stdout "late output from retired helper"
      require "cancellation/launch failure retires the borrowed publisher" ((← output.activity) == activity)

def run : IO Unit := do
  checkScopeOutcomes
  checkLostOwnership
  checkClosingScope
  checkHelperOutcomes
  checkInvalidResponse
  checkEarlyOutputRetirement
  IO.println "helper outcomes: operation, assignment, resource cleanup and closed ownership passed"

end BeamTest.Broker.HelperOutcomeTest
