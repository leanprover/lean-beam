/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Pending
import BeamTest.Broker.JsonAssert

open Lean
open Lean.JsonRpc
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.PendingTest

private def requireFailureCode
    (label expectedCode : String)
    (failure : ResponseFailure) : IO Error := do
  if failure.error.code != expectedCode then
    throw <| IO.userError
      s!"{label}: expected code={expectedCode}, got {(toJson failure.toResponse).compress}"
  pure failure.error

private def mkPending
    (cancelRef? : Option (IO.Ref Bool) := none)
    (progress? : Option SyncFileProgress := none)
    (tracked? : Option (DocumentUri × Nat) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO PendingRequest := do
  let promise ← IO.Promise.new
  let progressRef ← IO.mkRef progress?
  let diagnosticsRef ← IO.mkRef #[]
  let diagnosticsSeenRef ← IO.mkRef false
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  pure {
    cancelRef?
    promise
    tracked?
    progressRef
    diagnosticsRef
    diagnosticsSeenRef
    seenDiagnosticKeysRef
    emitProgress?
    diagnosticScope
    emitDiagnostic?
  }

private def expectRegistered
    (label : String)
    (result : Except BrokerFailure ActiveRequest) : IO ActiveRequest := do
  match result with
  | .ok active => pure active
  | .error failure =>
      throw <| IO.userError s!"{label}: {failure.message}"

private def checkActiveRegistry : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let noneResult ← ActiveRequestRegistry.register registry none none
  let anonymous ← expectRegistered "register without clientRequestId" noneResult
  require "anonymous admission participates in active request count"
    ((← ActiveRequestRegistry.count registry) == 1)
  require "anonymous admission can be cancelled by its exact handle"
    (Option.isSome (← ActiveRequestRegistry.markCancelledActive registry anonymous))
  match ← ensureRequestNotCancelled (some anonymous.cancelRef) with
  | .ok _ => throw <| IO.userError "anonymous admission did not observe cancellation"
  | .error failure =>
      discard <| requireFailureCode
        "anonymous admission reports broker cancellation"
        "requestCancelled"
        failure
  ActiveRequestRegistry.unregister registry (some anonymous)
  require "unregistered anonymous admission leaves no active request"
    ((← ActiveRequestRegistry.count registry) == 0)

  let firstResult ← ActiveRequestRegistry.register registry none (some "req-1")
  let first ← expectRegistered "register active request" firstResult
  match ← ActiveRequestRegistry.register registry none (some "req-1") with
  | .ok _ =>
      throw <| IO.userError "duplicate clientRequestId registered successfully"
  | .error failure =>
      require "duplicate active request error is typed" (failure.code == .invalidParams)
      require "duplicate active request error names id" (failure.message.contains "req-1")

  require "mark active request cancelled"
    (Option.isSome (← ActiveRequestRegistry.markCancelled registry none "req-1"))
  match ← ensureRequestNotCancelled (some (ActiveRequest.cancelRef first)) with
  | .ok _ =>
      throw <| IO.userError "ensureRequestNotCancelled reports broker cancellation: expected error"
  | .error failure =>
      discard <| requireFailureCode
        "ensureRequestNotCancelled reports broker cancellation"
        "requestCancelled"
        failure

  ActiveRequestRegistry.unregister registry (some first)
  require "unregistered active request is no longer cancellable"
    (Option.isNone (← ActiveRequestRegistry.markCancelled registry none "req-1"))

  let replacementResult ← ActiveRequestRegistry.register registry none (some "req-1")
  let replacement ← expectRegistered "register replacement active request" replacementResult
  ActiveRequestRegistry.unregister registry (some first)
  require "stale active handle cannot cancel replacement"
    (Option.isNone (← ActiveRequestRegistry.markCancelledActive registry first))
  match ← ensureRequestNotCancelled (some replacement.cancelRef) with
  | .ok _ => pure ()
  | .error failure =>
      throw <| IO.userError
        s!"stale active handle cancelled replacement: {(toJson failure.toResponse).compress}"
  require "stale unregister preserves replacement active request"
    (Option.isSome (← ActiveRequestRegistry.markCancelled registry none "req-1"))
  match ← ensureRequestNotCancelled (some replacement.cancelRef) with
  | .ok _ =>
      throw <| IO.userError "replacement active request did not observe cancellation"
  | .error failure =>
      discard <| requireFailureCode
        "replacement active request reports broker cancellation"
        "requestCancelled"
        failure
  ActiveRequestRegistry.unregister registry (some replacement)

  let workspaceA ← expectRegistered "register workspace A request" <|
    ← ActiveRequestRegistry.register registry (some "workspace-a") (some "shared-id")
  let workspaceB ← expectRegistered "register workspace B request" <|
    ← ActiveRequestRegistry.register registry (some "workspace-b") (some "shared-id")
  require "workspace-scoped cancellation finds the selected request"
    (Option.isSome (← ActiveRequestRegistry.markCancelled registry
      (some "workspace-a") "shared-id"))
  match ← ensureRequestNotCancelled (some workspaceA.cancelRef) with
  | .ok _ => throw <| IO.userError "workspace A request did not observe cancellation"
  | .error _ => pure ()
  match ← ensureRequestNotCancelled (some workspaceB.cancelRef) with
  | .ok _ => pure ()
  | .error _ => throw <| IO.userError "workspace A cancellation leaked into workspace B"
  require "unscoped cancellation does not alias a workspace-scoped request"
    (Option.isNone (← ActiveRequestRegistry.markCancelled registry none "shared-id"))
  ActiveRequestRegistry.unregister registry (some workspaceA)
  ActiveRequestRegistry.unregister registry (some workspaceB)

private def checkActiveRegistryCloseDrain : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let named ← expectRegistered "register named request before close" <|
    ← ActiveRequestRegistry.register registry none (some "closing-request")
  let anonymous ← expectRegistered "register anonymous request before close" <|
    ← ActiveRequestRegistry.register registry none none
  ActiveRequestRegistry.closeAdmission registry
  for active in #[named, anonymous] do
    match ← ensureRequestNotCancelled (some active.cancelRef) with
    | .ok _ => throw <| IO.userError "admission close did not cancel an active request"
    | .error failure =>
        discard <| requireFailureCode
          "admission close cancellation"
          "requestCancelled"
          failure
  match ← ActiveRequestRegistry.register registry none (some "after-close") with
  | .ok _ => throw <| IO.userError "closed admission accepted a new request"
  | .error failure =>
      require "closed admission rejection is typed" (failure.code == .requestCancelled)
  let drainTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    ActiveRequestRegistry.awaitDrained registry
  ActiveRequestRegistry.unregister registry (some named)
  IO.sleep 10
  require "drain should wait for every admitted request" (!(← IO.hasFinished drainTask))
  ActiveRequestRegistry.unregister registry (some anonymous)
  match ← IO.wait drainTask with
  | .ok () => pure ()
  | .error err => throw err
  ActiveRequestRegistry.closeAdmission registry
  require "repeated admission close should preserve the drained state"
    ((← ActiveRequestRegistry.count registry) == 0)

private def checkPendingCancellationIdentity : IO Unit := do
  let registry ← ActiveRequestRegistry.create
  let firstResult ← ActiveRequestRegistry.register registry none (some "reused-id")
  let first ← expectRegistered "register first cancellation identity" firstResult
  ActiveRequestRegistry.unregister registry (some first)
  let replacementResult ← ActiveRequestRegistry.register registry none (some "reused-id")
  let replacement ← expectRegistered "register replacement cancellation identity" replacementResult
  let firstPending ← mkPending (cancelRef? := some first.cancelRef)
  let replacementPending ← mkPending (cancelRef? := some replacement.cancelRef)
  require "first admission matches its pending request"
    (← PendingRequestStore.matchesCancellation firstPending first.cancelRef)
  require "first admission does not match replacement pending request"
    (!(← PendingRequestStore.matchesCancellation replacementPending first.cancelRef))
  require "replacement admission does not match first pending request"
    (!(← PendingRequestStore.matchesCancellation firstPending replacement.cancelRef))
  require "replacement admission matches its pending request"
    (← PendingRequestStore.matchesCancellation replacementPending replacement.cancelRef)
  ActiveRequestRegistry.unregister registry (some replacement)

private def checkPendingStoreResolve : IO Unit := do
  let store ← PendingRequestStore.create
  let pending ← mkPending
    (progress? := some { updates := 3, done := false })
  let id : RequestID := 7
  PendingRequestStore.insert store id pending
  let entries ← PendingRequestStore.snapshotEntries store
  require "pending store has inserted request" (entries.size == 1)
  let some pending ← PendingRequestStore.remove store id
    | throw <| IO.userError "pending store remove missed inserted request"
  PendingRequest.resolveResponse pending (Json.mkObj [("value", toJson true)])
  let result ←
    match ← pending.awaitOutcome with
    | .ok result => pure result
    | .error failure =>
        throw <| IO.userError
          s!"pending response result: expected success, got {(toJson failure.toResponse).compress}"
  requireJsonBool "pending response result" "value" true result.result
  require "pending response preserves progress"
    (result.progress? == some { updates := 3, done := false })
  require "pending response records no diagnostics publication"
    (!result.diagnosticsSeen)
  require "pending store is empty after remove"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def checkPendingStoreFailAll : IO Unit := do
  let store ← PendingRequestStore.create
  let firstProgress : SyncFileProgress := { updates := 5, done := false }
  let secondProgress : SyncFileProgress := { updates := 8, done := true }
  let cancelRef ← IO.mkRef true
  let firstPending ← mkPending
    (progress? := some firstProgress) (cancelRef? := some cancelRef)
  let secondPending ← mkPending (progress? := some secondProgress)
  PendingRequestStore.insert store 11 firstPending
  PendingRequestStore.insert store 12 secondPending
  PendingRequestStore.failAll store
    (responseFailureFor .workerExited "worker exited")
  for (label, pending, expectedCode, expectedProgress) in #[
      ("cancelled", firstPending, "requestCancelled", firstProgress),
      ("worker-exited", secondPending, "workerExited", secondProgress)
    ] do
    match ← pending.awaitOutcome with
    | .ok _ =>
        throw <| IO.userError
          s!"failAll resolves {label} pending request as an error: expected error"
    | .error failure =>
        discard <| requireFailureCode
          s!"failAll resolves {label} pending request as an error"
          expectedCode failure
        require s!"failAll preserves {label} pending request progress"
          (failure.fileProgress? == some expectedProgress)
  require "failAll clears pending store"
    ((← PendingRequestStore.snapshot store).isEmpty)

private def checkPendingOutcomeCancellationPrecedence : IO Unit := do
  let progress : SyncFileProgress := { updates := 13, done := true }
  let backendFailure :=
    (responseFailureFor .contentModified "backend worker terminated")
      |>.withOptionalFileProgress (some progress)
  let cancelRef ← IO.mkRef true
  let cancelledPending ← mkPending (cancelRef? := some cancelRef)
  cancelledPending.promise.resolve (.error backendFailure)
  match ← cancelledPending.awaitOutcome with
  | .ok _ =>
      throw <| IO.userError "cancelled pending backend failure resolved as a success"
  | .error failure =>
      discard <| requireFailureCode
        "marked cancellation takes precedence over a backend failure"
        "requestCancelled"
        failure
      require "cancellation precedence preserves backend failure progress"
        (failure.fileProgress? == some progress)

  cancelRef.set false
  let backendFailurePending ← mkPending (cancelRef? := some cancelRef)
  backendFailurePending.promise.resolve (.error backendFailure)
  match ← backendFailurePending.awaitOutcome with
  | .ok _ =>
      throw <| IO.userError "uncancelled pending backend failure resolved as a success"
  | .error failure =>
      discard <| requireFailureCode
        "backend failure remains authoritative without cancellation"
        "contentModified"
        failure

  cancelRef.set true
  let successPending ← mkPending (cancelRef? := some cancelRef)
  successPending.promise.resolve (.ok { result := Json.mkObj [("completed", toJson true)] })
  match ← successPending.awaitOutcome with
  | .error failure =>
      throw <| IO.userError
        s!"completed backend success lost to later cancellation: {(toJson failure.toResponse).compress}"
  | .ok result =>
      requireJsonBool "completed backend success remains authoritative" "completed" true result.result

private def checkPendingResolveError : IO Unit := do
  let expectedProgress : SyncFileProgress := { updates := 4, done := false }
  let pending ← mkPending (progress? := some expectedProgress)
  let data := Json.mkObj [
    ("expectedVersion", toJson (4 : Nat)),
    ("acceptedVersion", toJson (5 : Nat))
  ]
  PendingRequest.resolveError pending .contentModified "document changed" (some data)
  match ← pending.awaitOutcome with
  | .ok _ =>
      throw <| IO.userError "pending typed error resolved as a success"
  | .error failure =>
      let err ← requireFailureCode
        "pending typed error preserves its code" "contentModified" failure
      require "pending typed error preserves its message" (err.message == "document changed")
      match err.data? with
      | none =>
          throw <| IO.userError "pending typed error lost its data"
      | some actual =>
          require "pending typed error preserves its data" (actual.compress == data.compress)
      require "pending typed error preserves progress"
        (failure.fileProgress? == some expectedProgress)

private def mkRange (startLine startCharacter endLine endCharacter : Nat) : Range := {
  start := { line := startLine, character := startCharacter }
  «end» := { line := endLine, character := endCharacter }
}

private def mkFileProgress (ranges : Array Range) : LeanFileProgressParams := {
  textDocument := { uri := "file:///workspace/Foo.lean", version? := some 1 }
  processing := ranges.map fun range => { range }
}

private def mkDiagnostic (range : Range) (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some .error
  message
}

private def mkDiagnosticWithSeverity
    (range : Range)
    (severity : DiagnosticSeverity)
    (message : String) : Diagnostic := {
  range
  fullRange? := some range
  severity? := some severity
  message
}

private def mkPublishDiagnostics (diagnostics : Array Diagnostic) : PublishDiagnosticsParams := {
  uri := "file:///workspace/Foo.lean"
  version? := some 1
  diagnostics
}

private def observeFileProgress
    (progress : SyncFileProgress)
    (ranges : Array Range) : IO SyncFileProgress := do
  let pending ← mkPending
    (progress? := some progress)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeProgress pending (mkFileProgress ranges)
  let some next ← pending.progressRef.get
    | throw <| IO.userError "observeProgress cleared fileProgress"
  pure next

private def checkSyncFileProgressDisplay : IO Unit := do
  require "display includes range and done=false"
    (SyncFileProgress.displayDetails {
      updates := 4
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    } == "range=3..13 updates=4 done=false")
  require "display can omit done=true"
    (SyncFileProgress.displayDetails {
      updates := 5
      done := true
      rangeEndLine? := some 13
    } (includeDoneTrue := false) == "rangeEndLine=13 updates=5")

private def checkSyncFileProgressLines : IO Unit := do
  let trailingNewline ← observeFileProgress {} #[mkRange 0 0 1 0]
  require "progress trailing newline reports one-line range bound"
    (trailingNewline == {
      updates := 1
      done := false
      rangeStartLine? := some 1
      rangeEndLine? := some 1
    })

  let multipleRanges ← observeFileProgress {} #[
    mkRange 5 0 10 0,
    mkRange 2 0 12 3
  ]
  require "progress multiple ranges use earliest active line and max range end"
    (multipleRanges == {
      updates := 1
      done := false
      rangeStartLine? := some 3
      rangeEndLine? := some 13
    })

  let finished ← observeFileProgress multipleRanges #[]
  require "progress final empty processing preserves range end and clears active range start"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 13
    })
  let renderedProgress := toJson finished
  requireFieldAbsent "finished progress" "line" renderedProgress
  requireFieldAbsent "finished progress" "totalLines" renderedProgress
  requireJsonInt "finished progress" "rangeEndLine" 13 renderedProgress

private def checkDiagnosticLineCanExceedProgressRange : IO Unit := do
  let active ← observeFileProgress {} #[mkRange 0 0 1 0]
  let finished ← observeFileProgress active #[]
  require "progress fixture ends at one-line range bound"
    (finished == {
      updates := 2
      done := true
      rangeEndLine? := some 1
    })

  let farDiagnostic := mkDiagnostic (mkRange 20 2 20 8) "diagnostic beyond progress range"
  let pending ← mkPending
    (progress? := some finished)
    (tracked? := some ("file:///workspace/Foo.lean", 1))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk ".")
    "test-session"
    pending
    (mkPublishDiagnostics #[farDiagnostic])
  require "diagnostic publication does not rewrite fileProgress range"
    ((← pending.progressRef.get) == some finished)
  let diagnostics ← pending.diagnosticsRef.get
  let some diagnostic := diagnostics[0]?
    | throw <| IO.userError "expected diagnostic beyond progress range"
  require "diagnostic may start beyond progress rangeEndLine"
    (diagnostic.range.start.line + 1 > finished.rangeEndLine?.getD 0)

private def observeStreamedDiagnostics
    (diagnosticScope : DiagnosticScope)
    (diagnostics : Array Diagnostic) : IO (Array StreamDiagnostic) := do
  let streamedRef ← IO.mkRef #[]
  let pending ← mkPending
    (tracked? := some ("file:///workspace/Foo.lean", 1))
    (diagnosticScope := diagnosticScope)
    (emitDiagnostic? := some fun diagnostic =>
      streamedRef.modify (·.push diagnostic))
  PendingRequest.observeDiagnostics
    (System.FilePath.mk "/workspace")
    "test-session"
    pending
    (mkPublishDiagnostics diagnostics)
  streamedRef.get

private def checkDiagnosticEmitterFailureIsolation : IO Unit := do
  let diagnostic := mkDiagnostic (mkRange 1 0 1 4) "stream consumer disconnected"
  let pending ← mkPending
    (tracked? := some ("file:///workspace/Foo.lean", 1))
    (diagnosticScope := .all)
    (emitDiagnostic? := some fun _ =>
      throw <| IO.userError "diagnostic sink failed")
  PendingRequest.observeDiagnostics
    (System.FilePath.mk "/workspace")
    "test-session"
    pending
    (mkPublishDiagnostics #[diagnostic])
  require "diagnostic sink failure still records the publication"
    (← pending.diagnosticsSeenRef.get)
  require "diagnostic sink failure still records current diagnostics"
    ((← pending.diagnosticsRef.get).map (·.message) == #[diagnostic.message])

private def checkProgressEmitterFailureIsolation : IO Unit := do
  let pending ← mkPending
    (progress? := some {})
    (tracked? := some ("file:///workspace/Foo.lean", 1))
    (emitProgress? := some fun _ =>
      throw <| IO.userError "progress sink failed")
  PendingRequest.observeProgress pending (mkFileProgress #[mkRange 0 0 2 0])
  require "progress sink failure still records the latest progress"
    ((← pending.progressRef.get) == some {
      updates := 1
      done := false
      rangeStartLine? := some 1
      rangeEndLine? := some 2
    })

private def checkSetupFileProgressStreamsByScope : IO Unit := do
  let setupProgress :=
    mkDiagnosticWithSeverity
      (mkRange 0 0 1 0)
      .information
      "✔ [1/2] Built Liris.Iris.HeapLang.PrimitiveLaws (12s)\n"
  let warning :=
    mkDiagnosticWithSeverity
      (mkRange 3 0 3 6)
      .warning
      "unused variable"
  let goalsAccomplished := {
    mkDiagnosticWithSeverity
      (mkRange 5 0 5 8)
      .information
      "Goals accomplished!" with
    isSilent? := some true
    leanTags? := some #[.goalsAccomplished]
  }
  let defaultStreamed ← observeStreamedDiagnostics .errors #[setupProgress, warning, goalsAccomplished]
  require "default sync streams setup-file status"
    (defaultStreamed.map (·.message) == #[setupProgress.message])
  require "default setup-file status stays informational"
    (defaultStreamed.all (fun diagnostic => diagnostic.severity? == some .information))

  let allStreamed ← observeStreamedDiagnostics .all #[setupProgress, warning, goalsAccomplished]
  require "streamed diagnostics carry their backend snapshot"
    (allStreamed.all fun diagnostic => diagnostic.snapshot? == some ⟨"test-session", 1⟩)
  require "all diagnostic scope streams user-facing setup-file status and warning"
    (allStreamed.map (·.message) == #[setupProgress.message, warning.message])

def main : IO Unit := do
  checkActiveRegistry
  checkActiveRegistryCloseDrain
  checkPendingCancellationIdentity
  checkPendingStoreResolve
  checkPendingStoreFailAll
  checkPendingOutcomeCancellationPrecedence
  checkPendingResolveError
  checkSyncFileProgressDisplay
  checkSyncFileProgressLines
  checkDiagnosticLineCanExceedProgressRange
  checkDiagnosticEmitterFailureIsolation
  checkProgressEmitterFailureIsolation
  checkSetupFileProgressStreamsByScope

end BeamTest.Broker.PendingTest

def main := BeamTest.Broker.PendingTest.main
