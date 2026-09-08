/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Broker.SmokeUtil
import BeamTest.Broker.JsonAssert
import BeamTest.Fixtures.TodoFixture

set_option maxRecDepth 4096

open Lean

namespace BeamTest.Broker.SmokeTest

open BeamTest.Broker.TestUtil
open BeamTest.Broker.JsonAssert

private def syncSnapshot
    (endpoint : Beam.Broker.Endpoint)
    (path : String) : IO Beam.SnapshotRef := do
  let resp ← runClient endpoint {
    payload := .syncFile { path }
  }
  let result ← requireSyncFileResult s!"sync snapshot for {path}" (← expectOk resp)
  pure result.snapshot

private def updateSnapshot
    (endpoint : Beam.Broker.Endpoint)
    (path : String) : IO Beam.SnapshotRef := do
  let resp ← runClient endpoint {
    payload := .updateFile { path }
  }
  let result ← requireUpdateFileResult s!"update snapshot for {path}" (← expectOk resp)
  pure result.snapshot

private def expectSnapshotMismatchData
    (label : String)
    (resp : Beam.Broker.Response)
    (expectedSnapshot acceptedSnapshot : Beam.SnapshotRef) : IO Unit := do
  let some err := resp.error?
    | throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"
  let some data := err.data?
    | throw <| IO.userError s!"{label}: expected error.data, got {(toJson resp).compress}"
  let reason ← IO.ofExcept <| data.getObjValAs? String "reason"
  if reason != "snapshotMismatch" then
    throw <| IO.userError s!"{label}: expected snapshotMismatch data, got {data.compress}"
  let expected ← IO.ofExcept <| data.getObjValAs? Beam.SnapshotRef "expectedSnapshot"
  if expected != expectedSnapshot then
    throw <| IO.userError s!"{label}: expected expectedSnapshot={expectedSnapshot}, got {data.compress}"
  let current ← IO.ofExcept <| data.getObjValAs? Beam.SnapshotRef "currentSnapshot"
  if current != acceptedSnapshot then
    throw <| IO.userError s!"{label}: expected currentSnapshot={acceptedSnapshot}, got {data.compress}"

private def runUpdateSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let dir := root / ".tmp" / s!"beam-update-smoke-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "UpdateSmoke.lean"
  IO.FS.writeFile path "def updateSmokeVal : Nat := 1\n"
  let relPath := Beam.pathRelativeToRootOrSelf root path
  let firstResp ← runClient endpoint {
    payload := .updateFile { path := relPath }
  }
  let first ← requireUpdateFileResult "initial update_file" (← expectOk firstResp)
  if first.snapshot.revision == 0 || !first.changed then
    throw <| IO.userError s!"expected initial update_file a nonempty snapshot and changed=true, got {(toJson first).compress}"
  let unchangedResp ← runClient endpoint {
    payload := .updateFile { path := relPath }
  }
  let unchanged ← requireUpdateFileResult "unchanged update_file" (← expectOk unchangedResp)
  if unchanged.snapshot != first.snapshot || unchanged.changed then
    throw <| IO.userError s!"expected unchanged update_file to preserve snapshot and report changed=false, got {(toJson unchanged).compress}"
  let syncResp ← runClient endpoint {
    payload := .syncFile { path := relPath }
  }
  let syncRes ← requireSyncFileResult "sync after update_file" (← expectOk syncResp)
  if syncRes.snapshot != first.snapshot then
    throw <| IO.userError s!"expected sync_file after update_file to reuse snapshot {first.snapshot}, got {syncRes.snapshot}"
  let runAtResp ← runClient endpoint {
    payload := .runAt {
      path := relPath
      snapshot := first.snapshot
      line := 0
      character := 0
      text := "#check Nat"
    }
  }
  let runAtRes ← expectOk runAtResp
  let .ok true := runAtRes.getObjValAs? Bool "success"
    | throw <| IO.userError s!"expected run_at with update_file snapshot to succeed, got {runAtRes.compress}"

  IO.FS.writeFile path "def updateSmokeVal : Nat := 2\n"
  let changedResp ← runClient endpoint {
    payload := .updateFile { path := relPath }
  }
  let changed ← requireUpdateFileResult "changed update_file" (← expectOk changedResp)
  if changed.snapshot == first.snapshot || !changed.changed then
    throw <| IO.userError s!"expected changed update_file to bump snapshot and report changed=true, got {(toJson changed).compress}"
  let syncChangedResp ← runClient endpoint {
    payload := .syncFile { path := relPath }
  }
  let syncChanged ← requireSyncFileResult "sync after changed update_file" (← expectOk syncChangedResp)
  if syncChanged.snapshot != changed.snapshot then
    throw <| IO.userError s!"expected sync_file after changed update_file to reuse snapshot {changed.snapshot}, got {syncChanged.snapshot}"
  let staleRunAtResp ← runClient endpoint {
    payload := .runAt {
      path := relPath
      snapshot := first.snapshot
      line := 0
      character := 0
      text := "#check Nat"
    }
  }
  expectErrCode staleRunAtResp "contentModified"
  expectSnapshotMismatchData "stale run_at" staleRunAtResp first.snapshot changed.snapshot

private def runReopenedSnapshotSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let dir := root / ".tmp" / s!"beam-snapshot-reopen-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "Snapshot.lean"
  let relPath := Beam.pathRelativeToRootOrSelf root path
  IO.FS.writeFile path "example : 1 = 1 := by\n  rfl\n"
  let before ← updateSnapshot endpoint relPath
  let probe := fun snapshot => runClient endpoint {
    payload := .runAt {
      path := relPath
      snapshot
      line := 1
      character := 2
      text := "rfl"
    }
  }
  let initial ← expectOk (← probe before)
  requireJsonBool "initial snapshot probe" "success" true initial
  -- Inserting another valid proof leaves the old coordinate valid but moves the intended target.
  IO.FS.writeFile path "example : 2 = 2 := by\n  rfl\n\nexample : 1 = 1 := by\n  rfl\n"
  let refreshed ← requireSyncFileResult "refresh replacement snapshot" <| ← expectOk <| ← runClient endpoint {
    payload := .refreshFile { path := relPath }
  }
  let current ← expectOk (← probe refreshed.snapshot)
  requireJsonBool "replacement snapshot probe" "success" true current
  let relocated ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := relPath, snapshot := refreshed.snapshot, line := 4, character := 2, text := "rfl"
    }
  }
  requireJsonBool "resolved target after insertion" "success" true relocated
  let stale ← probe before
  expectErrCode stale "contentModified"
  expectSnapshotMismatchData "refresh rejects old snapshot" stale before refreshed.snapshot
  require "refresh replaces snapshot" (before != refreshed.snapshot)
  discard <| expectOk <| ← runClient endpoint { payload := .close { path := relPath } }
  let reopened ← updateSnapshot endpoint relPath
  require "close/reopen replaces snapshot" (reopened != refreshed.snapshot)
  expectErrCode (← probe refreshed.snapshot) "contentModified"
  requireJsonBool "reopened snapshot works" "success" true (← expectOk <| ← probe reopened)
  let other := dir / "Other.lean"
  IO.FS.writeFile other (← IO.FS.readFile path)
  let otherSnapshot ← updateSnapshot endpoint (Beam.pathRelativeToRootOrSelf root other)
  require "identical files have distinct snapshots" (otherSnapshot != reopened)
  expectErrCode (← probe otherSnapshot) "contentModified"
  require "unchanged update preserves snapshot" ((← updateSnapshot endpoint relPath) == reopened)

private def runSyncSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let syncRequestId := some "smoke-sync"
  let (syncResp, syncEvents) ← runClientWithProgress endpoint {
    payload := .syncFile {
      path := "tests/scenario/docs/CommandA.lean"
    }
    clientRequestId? := syncRequestId
  }
  let syncRes ← requireSyncFileResult "sync_file" (← expectOk syncResp)
  if syncRes.snapshot.revision == 0 then
    throw <| IO.userError s!"expected sync_file a nonempty snapshot, got {syncRes.snapshot}"
  if !syncRes.readiness.saveReady then
    throw <| IO.userError
      s!"expected sync_file saveReady = true for clean module, got {(toJson syncRes).compress}"
  if syncRes.readiness.blockingErrorCount != 0 then
    throw <| IO.userError
      s!"expected sync_file blocking error count to be zero for clean module, got {(toJson syncRes).compress}"
  let syncTop := ← requireFileProgress "sync_file" syncResp
  if !syncTop.done then
    throw <| IO.userError s!"expected top-level sync_file fileProgress.done = true, got {(toJson syncTop).compress}"
  let some syncLast := syncEvents.back?
    | throw <| IO.userError "expected sync_file to stream fileProgress events"
  expectClientRequestId "sync_file progress" syncLast.clientRequestId? syncRequestId
  if !syncLast.progress.done then
    throw <| IO.userError s!"expected final streamed sync_file progress to be done, got {(toJson syncLast.progress).compress}"
  let syncRespAgain ← runClient endpoint {
    payload := .syncFile { path := "tests/scenario/docs/CommandA.lean" }
  }
  let syncResAgain ← requireSyncFileResult "unchanged sync_file" (← expectOk syncRespAgain)
  if syncResAgain.snapshot != syncRes.snapshot then
    throw <| IO.userError s!"expected unchanged sync_file to preserve its snapshot, got {syncResAgain.snapshot}"
  let syncTopAgain := ← requireFileProgress "unchanged sync_file" syncRespAgain
  if !syncTopAgain.done then
    throw <| IO.userError s!"expected unchanged sync_file fileProgress.done = true, got {(toJson syncTopAgain).compress}"
  let refreshRequestId := some "smoke-refresh"
  let (refreshResp, refreshEvents) ← runClientWithProgress endpoint {
    payload := .refreshFile {
      path := "tests/scenario/docs/CommandA.lean"
    }
    clientRequestId? := refreshRequestId
  }
  let refreshRes ← requireSyncFileResult "refresh_file" (← expectOk refreshResp)
  if refreshRes.snapshot == syncRes.snapshot then
    throw <| IO.userError s!"expected refresh_file to return a fresh snapshot, got {refreshRes.snapshot}"
  let refreshTop := ← requireFileProgress "refresh_file" refreshResp
  if !refreshTop.done then
    throw <| IO.userError s!"expected top-level refresh_file fileProgress.done = true, got {(toJson refreshTop).compress}"
  let some refreshLast := refreshEvents.back?
    | throw <| IO.userError "expected refresh_file to stream fileProgress events"
  expectClientRequestId "refresh_file progress" refreshLast.clientRequestId? refreshRequestId
  if !refreshLast.progress.done then
    throw <| IO.userError s!"expected final streamed refresh_file progress to be done, got {(toJson refreshLast.progress).compress}"

private def runErrorOnlySyncSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let errorPath ← writeStandaloneErrorFile root
  let errorRel := Beam.pathRelativeToRootOrSelf root errorPath
  let (errorResp, errorProgress, errorDiagnostics) ← runClientWithStream endpoint {
    payload := .syncFile { path := errorPath.toString }
  }
  let errorRes ← requireSyncFileResult "error-only sync_file" (← expectOk errorResp)
  if errorRes.snapshot.revision == 0 then
    throw <| IO.userError s!"expected error-only sync_file a nonempty snapshot, got {errorRes.snapshot}"
  if errorRes.readiness.saveReady then
    throw <| IO.userError
      s!"expected error-only sync_file saveReady = false, got {(toJson errorRes).compress}"
  if errorRes.readiness.blockingErrorCount == 0 then
    throw <| IO.userError
      s!"expected error-only sync_file blockingErrorCount > 0, got {(toJson errorRes).compress}"
  if errorRes.readiness.blockingDiagnostics.isEmpty &&
      errorRes.readiness.blockingMessages.isEmpty then
    throw <| IO.userError
      s!"expected error-only sync_file to include save-blocking evidence, got {(toJson errorRes).compress}"
  unless errorRes.readiness.blockingDiagnostics.all (·.saveBlocking) &&
      errorRes.readiness.blockingMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"expected error-only sync_file blocking evidence to be flagged saveBlocking, got {(toJson errorRes).compress}"
  if errorRes.readiness.reason != "documentErrors" then
    throw <| IO.userError
      s!"expected error-only sync_file readiness reason = documentErrors, got {(toJson errorRes).compress}"
  let some errorLast := errorProgress.back?
    | throw <| IO.userError "expected error-only sync_file to stream fileProgress events"
  if !errorLast.done then
    throw <| IO.userError s!"expected error-only sync_file progress to finish, got {(toJson errorLast).compress}"
  if errorDiagnostics.isEmpty then
    throw <| IO.userError "expected error-only sync_file to stream error diagnostics"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.severity? == some .error) do
    throw <| IO.userError s!"expected error-only sync_file to stream only errors by default, got {(toJson errorDiagnostics).compress}"
  unless errorDiagnostics.all (fun diagnostic => diagnostic.path == errorRel) do
    throw <| IO.userError s!"expected error-only sync_file paths to match {errorRel}, got {(toJson errorDiagnostics).compress}"

private def runInteractiveOnlyDiagnosticSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let path := "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  let (resp, progress, diagnostics) ← runClientWithStream endpoint {
    payload := .syncFile { path }
  }
  let res ← requireSyncFileResult "interactive-only diagnostic sync_file" (← expectOk resp)
  if res.readiness.saveReady then
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file saveReady = false, got {(toJson res).compress}"
  if res.readiness.blockingErrorCount == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic counts to report Lean errors only, got {(toJson res).compress}"
  if res.readiness.reason != "documentErrors" then
    throw <| IO.userError
      s!"expected interactive-only diagnostic readiness reason = documentErrors, got {(toJson res).compress}"
  if res.diagnostics.counts.error == 0 || res.diagnostics.counts.total == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic result to count the error-severity diagnostic, got {(toJson res).compress}"
  -- Regression for #99: current diagnostic errors must not coexist with saveReady=true.
  if res.diagnostics.counts.error > 0 && res.readiness.saveReady then
    throw <| IO.userError
      s!"expected interactive-only diagnostic errors to make saveReady=false, got {(toJson res).compress}"
  if res.readiness.blockingErrorCount == 0 then
    throw <| IO.userError
      s!"expected interactive-only diagnostic readiness to be blocked, got {(toJson res).compress}"
  if res.readiness.blockingDiagnostics.isEmpty ||
      res.readiness.blockingMessages.isEmpty then
    throw <| IO.userError
      s!"expected interactive-only diagnostic result to include Lean-side blocking evidence, got {(toJson res).compress}"
  let some lastProgress := progress.back?
    | throw <| IO.userError "expected interactive-only diagnostic sync_file to stream fileProgress"
  if !lastProgress.done then
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file progress to finish, got {(toJson lastProgress).compress}"
  unless diagnostics.any (fun diagnostic =>
      diagnostic.path == path && diagnostic.severity? == some .error &&
        diagnostic.message.contains "interactive-only diagnostic") do
    throw <| IO.userError
      s!"expected interactive-only diagnostic sync_file to stream the fixture error, got {(toJson diagnostics).compress}"

private def runTodoThenSyncDiagnosticSummarySmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let path := "tests/scenario/docs/InteractiveOnlyDiagnostic.lean"
  let snapshot ← syncSnapshot endpoint path
  let todoResp ← runClient endpoint {
    payload := .todo {
      path
      snapshot
      line := 0
      character := 0
      endLine := 22
      endCharacter := 0
      kinds? := some #[.diagnostic]
      suggest? := some .none
    }
  }
  let todoResult : Beam.LSP.Todo.TodoResult ← IO.ofExcept <| fromJson? (← expectOk todoResp)
  unless todoResult.items.any (fun item =>
      item.kind == .diagnostic &&
        item.severity? == some .error &&
        item.message?.map (·.contains "interactive-only diagnostic") == some true) do
    throw <| IO.userError
      s!"expected todo to observe interactive-only error diagnostic, got {(toJson todoResult).compress}"

  let syncResp ← runClient endpoint {
    payload := .syncFile { path }
  }
  let syncRes ← requireSyncFileResult "todo-warmed diagnostic sync_file" (← expectOk syncResp)
  if syncRes.readiness.saveReady then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic sync_file saveReady = false, got {(toJson syncRes).compress}"
  if syncRes.diagnostics.counts.error == 0 || syncRes.diagnostics.counts.total == 0 then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic result to retain current error counts, got {(toJson syncRes).compress}"
  if syncRes.readiness.blockingErrorCount == 0 then
    throw <| IO.userError
      s!"expected todo-warmed diagnostic readiness to stay blocked, got {(toJson syncRes).compress}"
  discard <| expectOk <| ← runClient endpoint {
    payload := .close { path }
  }

private def runTodoCodeActionResolveSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let path := BeamTest.Fixtures.TodoFixture.codeActionRepoPath.toString
  let snapshot ← updateSnapshot endpoint path
  let todoResp ← runClient endpoint {
    payload := .todo {
      path
      snapshot
      line := BeamTest.Fixtures.TodoFixture.codeActionLine
      character := BeamTest.Fixtures.TodoFixture.codeActionStartCharacter
      endLine := BeamTest.Fixtures.TodoFixture.codeActionLine
      endCharacter := BeamTest.Fixtures.TodoFixture.codeActionEndCharacter
      kinds? := some #[.codeAction]
    }
  }
  let todoResult : Beam.LSP.Todo.TodoResult ← IO.ofExcept <| fromJson? (← expectOk todoResp)
  let actionItems := todoResult.items.filter (fun item => item.kind == .codeAction)
  if actionItems.size != 1 then
    throw <| IO.userError
      s!"todo/code_action_resolve composition: expected one code action, got {(toJson todoResult).compress}"
  let some actionItem := actionItems[0]?
    | throw <| IO.userError "todo/code_action_resolve composition: missing code action item"
  let some action := actionItem.codeAction?
    | throw <| IO.userError <|
      s!"todo/code_action_resolve composition: expected embedded codeAction, got {(toJson actionItem).compress}"
  let resolveResp ← runClient endpoint {
    payload := .codeActionResolve { path, snapshot, codeAction := action }
  }
  let resolved : Beam.Broker.CodeActionResolveResult ← IO.ofExcept <| fromJson? (← expectOk resolveResp)
  if resolved.snapshot != snapshot then
    throw <| IO.userError
      s!"todo/code_action_resolve composition: expected resolved snapshot {snapshot}, got {resolved.snapshot}"
  if resolved.codeAction.title != action.title then
    throw <| IO.userError
      s!"todo/code_action_resolve composition: expected resolved action title {action.title}, got {resolved.codeAction.title}"
  if resolved.codeAction.edit?.isNone then
    throw <| IO.userError
      s!"todo/code_action_resolve composition: expected resolved action edit, got {(toJson resolved).compress}"
  discard <| requireFileProgress "code_action_resolve" resolveResp

  let staleResp ← runClient endpoint {
    payload := .codeActionResolve { path, snapshot := { session := "stale", revision := 1 }, codeAction := action }
  }
  expectErrCode staleResp "contentModified"
  expectSnapshotMismatchData "stale code_action_resolve" staleResp { session := "stale", revision := 1 } snapshot

  let otherPath := "tests/scenario/docs/CommandA.lean"
  let otherSnapshot ← updateSnapshot endpoint otherPath
  let mismatchedSourceResp ← runClient endpoint {
    payload := .codeActionResolve {
      path := otherPath
      snapshot := otherSnapshot
      codeAction := action
    }
  }
  expectErrCode mismatchedSourceResp "invalidParams"
  let mismatchMessage ←
    requireErrorMessage "code_action_resolve source mismatch" mismatchedSourceResp
  expectStringContains
    "code_action_resolve source mismatch"
    mismatchMessage
    "not requested document"

private def runReportedOnlyDiagnosticSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let path := "tests/scenario/docs/ReportedOnlyError.lean"
  let (resp, progress, diagnostics) ← runClientWithStream endpoint {
    payload := .syncFile { path }
  }
  let res ← requireSyncFileResult "reported-only diagnostic sync_file" (← expectOk resp)
  if !res.readiness.saveReady then
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file saveReady = true, got {(toJson res).compress}"
  if res.readiness.blockingErrorCount != 0 then
    throw <| IO.userError
      s!"expected reported-only diagnostic blocking count to be zero, got {(toJson res).compress}"
  if res.readiness.reason != "ok" then
    throw <| IO.userError
      s!"expected reported-only diagnostic readiness reason = ok, got {(toJson res).compress}"
  if res.readiness.blockingErrorCount != 0 || !res.readiness.saveReady then
    throw <| IO.userError
      s!"expected reported-only diagnostic readiness to stay clean, got {(toJson res).compress}"
  unless res.readiness.blockingDiagnostics.isEmpty &&
      res.readiness.blockingMessages.isEmpty do
    throw <| IO.userError
      s!"expected reported-only diagnostic result to omit blocking evidence, got {(toJson res).compress}"
  let some lastProgress := progress.back?
    | throw <| IO.userError "expected reported-only diagnostic sync_file to stream fileProgress"
  if !lastProgress.done then
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file progress to finish, got {(toJson lastProgress).compress}"
  unless diagnostics.isEmpty do
    throw <| IO.userError
      s!"expected reported-only diagnostic sync_file to stream no diagnostics, got {(toJson diagnostics).compress}"

private def runPartialProgressSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let partialRequestId := some "smoke-partial"
  let path := "tests/scenario/docs/PartialProgress.lean"
  let snapshot ← syncSnapshot endpoint path
  let (partialResp, partialEvents) ← runClientWithProgress endpoint {
    payload := .runAt {
      path
      snapshot
      line := 7
      character := 2
      text := "#check partialProgressAnchor"
    }
    clientRequestId? := partialRequestId
  }
  let partialRes ← expectOk partialResp
  let .ok true := partialRes.getObjValAs? Bool "success" | throw <| IO.userError "partial run_at did not succeed"
  let partialProgress := ← requireFileProgress "partial run_at" partialResp
  if !partialProgress.done then
    throw <| IO.userError s!"expected snapshoted run_at fileProgress.done = true after sync, got {(toJson partialProgress).compress}"
  if let some partialLast := partialEvents.back? then
    expectClientRequestId "partial run_at progress" partialLast.clientRequestId? partialRequestId
    if !partialLast.progress.done then
      throw <| IO.userError s!"expected final streamed snapshoted run_at progress to be complete, got {(toJson partialLast.progress).compress}"

private def runConcurrentSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let concurrentSyncId := some "concurrent-sync"
  let concurrentHoverId := some "concurrent-hover"
  let slowSyncPath ← writeSlowSyncFile root
  let hoverPath := "tests/scenario/docs/CommandA.lean"
  let hoverSnapshot ← updateSnapshot endpoint hoverPath
  let syncTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    payload := .syncFile {
      path := slowSyncPath.toString
    }
    clientRequestId? := concurrentSyncId
  }
  IO.sleep 200
  let hoverStartedAt ← IO.monoNanosNow
  let (hoverResp, hoverEvents) ← runClientWithProgress endpoint {
    payload := .hover {
      path := hoverPath
      snapshot := hoverSnapshot
      line := 0
      character := 4
    }
    clientRequestId? := concurrentHoverId
  }
  let _hoverLatencyMs := ((← IO.monoNanosNow) - hoverStartedAt) / 1000000
  let hoverPayload ← expectOk hoverResp
  expectProgressIds "concurrent hover progress" hoverEvents concurrentHoverId
  let hoverContents ← IO.ofExcept <| hoverPayload.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "concurrent hover markdown" hoverValue "answerA : Nat"
  let (concurrentSyncResp, concurrentSyncEvents) ← awaitTask "concurrent sync_file" syncTask
  let concurrentSyncTop := ← requireFileProgress "concurrent sync_file" concurrentSyncResp
  expectProgressIds "concurrent sync_file progress" concurrentSyncEvents concurrentSyncId
  if !concurrentSyncTop.done then
    throw <| IO.userError
      s!"expected concurrent sync_file fileProgress.done = true, got {(toJson concurrentSyncTop).compress}"

private def runRequestAndGoalsSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandSnapshot ← updateSnapshot endpoint commandPath
  let proofPath := "tests/scenario/docs/SimpleProof.lean"
  let proofSnapshot ← updateSnapshot endpoint proofPath
  let cmdResp ← runClient endpoint {
    payload := .runAt {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 2
      text := "#check answerA"
    }
  }
  let cmdRes ← expectOk cmdResp
  let .ok true := cmdRes.getObjValAs? Bool "success" | throw <| IO.userError "run_at did not succeed"

  let hoverResp ← runClient endpoint {
    payload := .hover {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 4
    }
  }
  let hover ← expectOk hoverResp
  discard <| requireFileProgress "hover" hoverResp
  let hoverContents ← IO.ofExcept <| hover.getObjVal? "contents"
  let hoverValue ← IO.ofExcept <| hoverContents.getObjValAs? String "value"
  expectStringContains "hover markdown" hoverValue "answerA : Nat"

  let signaturePath := "tests/scenario/docs/SignatureHelp.lean"
  let signatureSnapshot ← updateSnapshot endpoint signaturePath
  let signatureHelpResp ← runClient endpoint {
    payload := .signatureHelp {
      path := signaturePath
      snapshot := signatureSnapshot
      line := 4
      character := 12
    }
  }
  let signatureHelp ← expectOk signatureHelpResp
  discard <| requireFileProgress "signature help" signatureHelpResp
  expectStringContains "signature help result" signatureHelp.compress "x y : Nat"

  let definitionResp ← runClient endpoint {
    payload := .definition {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 4
    }
  }
  let definition ← expectOk definitionResp
  discard <| requireFileProgress "definition" definitionResp
  expectStringContains "definition result" definition.compress "CommandA.lean"

  let referencesResp ← runClient endpoint {
    payload := .references {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 4
      includeDeclaration? := some true
    }
  }
  let references ← expectOk referencesResp
  discard <| requireFileProgress "references" referencesResp
  expectStringContains "references result" references.compress "CommandA.lean"

  let documentSymbolsResp ← runClient endpoint {
    payload := .documentSymbols { path := commandPath, snapshot := commandSnapshot }
  }
  let documentSymbols ← expectOk documentSymbolsResp
  discard <| requireFileProgress "document symbols" documentSymbolsResp
  let .arr documentSymbols := documentSymbols
    | throw <| IO.userError s!"expected document_symbols result array, got {documentSymbols.compress}"
  unless documentSymbols.any (fun sym =>
      (sym.getObjValAs? String "name").toOption == some "answerA") do
    throw <| IO.userError
      s!"expected document_symbols to include answerA, got {(Json.arr documentSymbols).compress}"

  let workspaceSymbolsResp ← runClient endpoint {
    payload := .workspaceSymbols { query := "runAtMethod" }
  }
  let workspaceSymbols ← expectOk workspaceSymbolsResp
  match workspaceSymbols with
  | .arr _ => pure ()
  | _ => throw <| IO.userError s!"expected workspace_symbols result array, got {workspaceSymbols.compress}"

  let goalsPrevResp ← runClient endpoint {
    payload := .goals {
      path := proofPath
      snapshot := proofSnapshot
      line := 1
      character := 2
      mode? := some .before
    }
  }
  let goalsPrev ← expectOk goalsPrevResp
  discard <| requireFileProgress "goals prev" goalsPrevResp
  let prevGoals ← IO.ofExcept <| goalsPrev.getObjVal? "goals"
  let .arr prevGoals := prevGoals
    | throw <| IO.userError s!"expected goals prev result to be an array, got {prevGoals.compress}"
  if prevGoals.size != 1 then
    throw <| IO.userError s!"expected one previous goal, got {(Json.arr prevGoals).compress}"
  let prevTarget ← IO.ofExcept <| prevGoals[0]!.getObjValAs? String "target"
  expectStringContains "goals prev target" prevTarget "True"

  let goalsAfterResp ← runClient endpoint {
    payload := .goals {
      path := proofPath
      snapshot := proofSnapshot
      line := 1
      character := 2
      mode? := some .after
    }
  }
  let goalsAfter ← expectOk goalsAfterResp
  discard <| requireFileProgress "goals after" goalsAfterResp
  let afterGoals := ← IO.ofExcept <| goalsAfter.getObjVal? "goals"
  if afterGoals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals after trivial, got {afterGoals.compress}"

  let speculativeGoalsResp ← runClient endpoint {
    payload := .goals {
      path := proofPath
      snapshot := proofSnapshot
      line := 1
      character := 2
      text? := some "exact trivial"
      mode? := some .before
    }
  }
  expectErrCode speculativeGoalsResp "invalidParams"
  let speculativeGoalsMessage ←
    requireErrorMessage "lean goals speculative text" speculativeGoalsResp
  expectStringContains
    "lean goals speculative text"
    speculativeGoalsMessage
    "does not accept speculative text"

private def runCancelSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let slowRequestId := some "cancel-slow"
  let slowPath := "tests/scenario/docs/SlowPoll.lean"
  let slowSnapshot ← updateSnapshot endpoint slowPath
  let slowTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    payload := .runAt {
      path := slowPath
      snapshot := slowSnapshot
      line := 25
      character := 2
      text := "poll_sleep_cmd"
    }
    clientRequestId? := slowRequestId
  }
  IO.sleep 200
  let cancelResp ← runClient endpoint <| Beam.Broker.Request.cancel slowRequestId.get!
  let cancelPayload ← expectOk cancelResp
  let .ok true := cancelPayload.getObjValAs? Bool "cancelled"
    | throw <| IO.userError s!"expected cancel response to report cancelled=true, got {cancelPayload.compress}"
  let (slowResp, slowEvents) ← awaitTask "cancel slow run_at" slowTask
  expectErrCode slowResp "requestCancelled"
  expectProgressIds "cancelled run_at progress" slowEvents slowRequestId

  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandSnapshot ← updateSnapshot endpoint commandPath
  let postCancelHoverResp ← runClient endpoint {
    payload := .hover {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 4
    }
  }
  let postCancelHover ← expectOk postCancelHoverResp
  let postCancelHoverContents ← IO.ofExcept <| postCancelHover.getObjVal? "contents"
  let postCancelHoverValue ← IO.ofExcept <| postCancelHoverContents.getObjValAs? String "value"
  expectStringContains "post-cancel hover markdown" postCancelHoverValue "answerA : Nat"

private def runWorkerExitSmoke
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let branchPath := "tests/scenario/docs/BranchProof.lean"
  let branchSnapshot ← updateSnapshot endpoint branchPath
  let handleSeed ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := branchPath
      snapshot := branchSnapshot
      line := 0
      character := 27
      text := "constructor"
      storeHandle? := some true
    }
  }
  let handleJson ← IO.ofExcept <| handleSeed.getObjVal? "handle"
  let staleHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson

  let workerExitRequestId := some "worker-exit-slow"
  let slowPath := "tests/scenario/docs/SlowPoll.lean"
  let slowSnapshot ← updateSnapshot endpoint slowPath
  let slowTask ← IO.asTask (prio := Task.Priority.dedicated) <| runClientWithProgress endpoint {
    payload := .runAt {
      path := slowPath
      snapshot := slowSnapshot
      line := 25
      character := 2
      text := "poll_sleep_cmd"
    }
    clientRequestId? := workerExitRequestId
  }
  IO.sleep 200
  killLeanServerForEndpoint endpoint root
  let (slowResp, slowEvents) ← awaitTask "worker-exit slow run_at" slowTask
  expectErrCode slowResp "workerExited"
  let some workerExitError := slowResp.error?
    | throw <| IO.userError s!"expected worker-exit error, got {(toJson slowResp).compress}"
  unless workerExitError.message.contains "Lean backend failed after startup" do
    throw <| IO.userError s!"expected worker-exit phase diagnostic, got {(toJson slowResp).compress}"
  unless workerExitError.message.contains "backend stderr tail (last 16384 bytes):" do
    throw <| IO.userError s!"expected worker-exit stderr diagnostic, got {(toJson slowResp).compress}"
  expectProgressIds "worker-exit run_at progress" slowEvents workerExitRequestId

  let restartedSnapshot ← updateSnapshot endpoint branchPath
  require "backend restart replaces snapshot" (restartedSnapshot != branchSnapshot)
  expectErrCode (← runClient endpoint {
    payload := .runAt {
      path := branchPath, snapshot := branchSnapshot, line := 0, character := 27, text := "constructor"
    }
  }) "contentModified"
  requireJsonBool "restarted snapshot works" "success" true <| ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := branchPath, snapshot := restartedSnapshot, line := 0, character := 27, text := "constructor"
    }
  }
  let commandPath := "tests/scenario/docs/CommandA.lean"
  let commandSnapshot ← updateSnapshot endpoint commandPath
  let restartHoverResp ← runClient endpoint {
    payload := .hover {
      path := commandPath
      snapshot := commandSnapshot
      line := 0
      character := 4
    }
  }
  let restartHover ← expectOk restartHoverResp
  let restartHoverContents ← IO.ofExcept <| restartHover.getObjVal? "contents"
  let restartHoverValue ← IO.ofExcept <| restartHoverContents.getObjValAs? String "value"
  expectStringContains "post-restart hover markdown" restartHoverValue "answerA : Nat"

  let staleAfterRestart ← runClient endpoint {
    payload := .runWith {
      path := "tests/scenario/docs/BranchProof.lean"
      handle := staleHandle
      text := "exact trivial"
    }
  }
  expectErrCode staleAfterRestart "contentModified"

private def runHandleSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let branchPath := "tests/scenario/docs/BranchProof.lean"
  let branchSnapshot ← updateSnapshot endpoint branchPath
  let proofRes ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := branchPath
      snapshot := branchSnapshot
      line := 0
      character := 27
      text := "constructor"
      storeHandle? := some true
    }
  }
  let handleJson ← IO.ofExcept <| proofRes.getObjVal? "handle"
  let handle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? handleJson
  let proofNext ← expectOk <| ← runClient endpoint {
    payload := .runWith {
      path := "tests/scenario/docs/BranchProof.lean"
      handle
      text := "exact trivial"
      storeHandle? := some true
    }
  }
  let nextHandleJson ← IO.ofExcept <| proofNext.getObjVal? "handle"
  let nextHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? nextHandleJson
  discard <| expectOk <| ← runClient endpoint {
    payload := .runWith {
      path := "tests/scenario/docs/BranchProof.lean"
      handle
      text := "exact trivial"
    }
  }
  let proofDone ← expectOk <| ← runClient endpoint {
    payload := .runWith {
      path := "tests/scenario/docs/BranchProof.lean"
      handle := nextHandle
      text := "exact trivial"
    }
  }
  let goals ← IO.ofExcept <| proofDone.getObjVal? "proofState"
  let goals := (← IO.ofExcept <| goals.getObjVal? "goals")
  if goals != Json.arr #[] then
    throw <| IO.userError s!"expected no goals, got {goals.compress}"

  discard <| expectOk <| ← runClient endpoint {
    payload := .release { path := "tests/scenario/docs/BranchProof.lean", handle }
  }
  let stale ← runClient endpoint {
    payload := .runWith {
      path := "tests/scenario/docs/BranchProof.lean"
      handle
      text := "exact trivial"
    }
  }
  expectErrCode stale "invalidParams"
private def runSaveAndStatsSmoke
    (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let saveResp ← runClient endpoint {
    payload := .saveOlean { path := "tests/lean/BeamTest/Fixtures/Deps/DepA.lean" }
  }
  let savePayload ← expectOk saveResp
  let saveSnapshot ← IO.ofExcept <| savePayload.getObjValAs? Beam.SnapshotRef "snapshot"
  if saveSnapshot.revision == 0 then
    throw <| IO.userError s!"expected save_olean a nonempty snapshot, got {saveSnapshot}"
  let saveHash ← IO.ofExcept <| savePayload.getObjValAs? String "sourceHash"
  if saveHash.isEmpty then
    throw <| IO.userError "expected save_olean sourceHash to be present"
  let saveProgress := ← requireFileProgress "save_olean" saveResp
  if !saveProgress.done then
    throw <| IO.userError s!"expected save_olean fileProgress.done = true, got {(toJson saveProgress).compress}"

  let stats ← expectOk <| ← runClient endpoint {
    Beam.Broker.Request.stats with
    workspaceId? := some testWorkspaceId
  }
  expectOpCountAtLeast stats "lean" "sync_file" 1
  expectOpCountAtLeast stats "lean" "refresh_file" 1
  expectOpCountAtLeast stats "lean" "update_file" 1
  expectOpCountAtLeast stats "lean" "run_at" 3

  expectOpCountAtLeast stats "lean" "hover" 4
  expectOpCountAtLeast stats "lean" "goals" 2
  expectOpCountAtLeast stats "lean" "code_action_resolve" 1
  expectOpCountAtLeast stats "lean" "run_with" 3
  expectOpCountAtLeast stats "lean" "release" 1
  expectOpCountAtLeast stats "lean" "save_olean" 1
  expectBackendMetricAtLeast stats "lean" "cancelledCount" 1
  expectBackendMetricAtLeast stats "lean" "workerExitedCount" 1
  expectBackendMetricAtLeast stats "lean" "sessionRestarts" 1
  expectOpMetricAtLeast stats "lean" "run_at" "cancelledCount" 1
  expectOpMetricAtLeast stats "lean" "run_at" "workerExitedCount" 1

private def requireWorkspaceListed (payload : Json) (workspaceId : String) : IO Unit := do
  let workspaces ← IO.ofExcept <| payload.getObjVal? "workspaces"
  match workspaces with
  | Json.obj _ =>
      match workspaces.getObjVal? workspaceId with
      | .ok _ => pure ()
      | .error _ =>
        throw <| IO.userError s!"expected workspace '{workspaceId}' in payload: {payload.compress}"
  | _ =>
      throw <| IO.userError s!"expected workspaces object in payload: {payload.compress}"

private def requireWorkspaceArrayListed (payload : Json) (workspaceId : String) : IO Unit := do
  let workspaces ← IO.ofExcept <| payload.getObjVal? "workspaces"
  match workspaces with
  | Json.arr entries =>
      let found := entries.any fun entry =>
        match entry.getObjVal? "workspace_id" with
        | .ok (.str id) => id == workspaceId
        | _ => false
      unless found do
        throw <| IO.userError s!"expected workspace '{workspaceId}' in list payload: {payload.compress}"
  | _ =>
      throw <| IO.userError s!"expected workspaces array in payload: {payload.compress}"

private def runWorkspaceLifecycleSmoke
    (endpoint : Beam.Broker.Endpoint)
    (otherRoot plugin : System.FilePath)
    (leanCmd : String) : IO Unit := do
  let workspaceId := "fixture"
  let initResp ← runClient endpoint {
    payload := .initWorkspace {
      root := otherRoot.toString
      lean? := some { command := leanCmd, plugin := plugin.toString }
    }
    workspaceId? := some workspaceId
  }
  let init ← expectOk initResp
  requireJsonString "named workspace init" "workspace_id" workspaceId init
  requireJsonString "named workspace init mode" "mode" "set" init
  requireJsonBool "named workspace init reused" "runtime_reused" false init
  let duplicateRoot ← runClient endpoint {
    payload := .initWorkspace {
      root := otherRoot.toString
      lean? := some { command := leanCmd, plugin := plugin.toString }
    }
    workspaceId? := some "duplicate"
  }
  expectErrCode duplicateRoot "invalidParams"

  discard <| expectOk (← runClient endpoint {
    Beam.Broker.Request.ensure with
    workspaceId? := some workspaceId
  })
  let updatePayload ← expectOk (← runClient endpoint {
    payload := .updateFile {
      path := "PositionEmptyLine.lean"
    }
    workspaceId? := some workspaceId
  })
  let update ← requireUpdateFileResult "named workspace update" updatePayload
  if update.snapshot.revision == 0 then
    throw <| IO.userError s!"expected named workspace update a nonempty snapshot, got {update.snapshot}"
  let wrongFile ← runClient endpoint {
    payload := .runAt {
      path := "GoalSmoke.lean", snapshot := update.snapshot, line := 1, character := 2, text := "trivial"
    }
    workspaceId? := some workspaceId
  }
  expectErrCode wrongFile "contentModified"
  let proofUpdate ← requireUpdateFileResult "proof snapshot" <| ← expectOk <| ← runClient endpoint {
    payload := .updateFile { path := "GoalSmoke.lean" }
    workspaceId? := some workspaceId
  }
  let proofHandleSeed ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := "GoalSmoke.lean"
      snapshot := proofUpdate.snapshot
      line := 1
      character := 2
      text := "trivial"
      storeHandle? := some true
    }
    workspaceId? := some workspaceId
  }
  let proofHandleJson ← IO.ofExcept <| proofHandleSeed.getObjVal? "handle"
  let proofHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? proofHandleJson

  let resetResp ← runClient endpoint {
    payload := .initWorkspace {
      root := otherRoot.toString
      workspaceMode? := some .reset
      lean? := some { command := leanCmd, plugin := plugin.toString }
    }
    workspaceId? := some workspaceId
  }
  let reset ← expectOk resetResp
  requireJsonString "named workspace reset" "workspace_id" workspaceId reset
  requireJsonString "named workspace reset mode" "mode" "reset" reset
  requireJsonBool "named workspace reset invalidated handles" "invalidated_handles" true reset
  requireJsonString "named workspace reset previous root" "previous_root" otherRoot.toString reset
  let staleAfterReset ← runClient endpoint {
    payload := .runWith {
      path := "GoalSmoke.lean"
      handle := proofHandle
      text := "trivial"
    }
    workspaceId? := some workspaceId
  }
  expectErrCode staleAfterReset "contentModified"

  let updateAfterResetPayload ← expectOk (← runClient endpoint {
    payload := .updateFile {
      path := "GoalSmoke.lean"
    }
    workspaceId? := some workspaceId
  })
  let updateAfterReset ← requireUpdateFileResult "named workspace update after reset" updateAfterResetPayload
  require "workspace reset replaces snapshot" (updateAfterReset.snapshot != proofUpdate.snapshot)
  expectErrCode (← runClient endpoint {
    payload := .runAt {
      path := "GoalSmoke.lean", snapshot := proofUpdate.snapshot, line := 1, character := 2, text := "trivial"
    }
    workspaceId? := some workspaceId
  }) "contentModified"
  let postResetHandleSeed ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := "GoalSmoke.lean"
      snapshot := updateAfterReset.snapshot
      line := 1
      character := 2
      text := "trivial"
      storeHandle? := some true
    }
    workspaceId? := some workspaceId
  }
  let postResetHandleJson ← IO.ofExcept <| postResetHandleSeed.getObjVal? "handle"
  let postResetHandle : Beam.Broker.Handle ← IO.ofExcept <| fromJson? postResetHandleJson

  let wrongWorkspaceHandle ← runClient endpoint {
    payload := .runWith {
      path := "GoalSmoke.lean"
      handle := postResetHandle
      text := "trivial"
    }
    workspaceId? := some testWorkspaceId
  }
  expectErrCode wrongWorkspaceHandle "invalidParams"

  let scopedStats ← expectOk (← runClient endpoint {
    Beam.Broker.Request.stats with
    workspaceId? := some workspaceId
  })
  requireJsonString "scoped named workspace stats" "id" workspaceId scopedStats
  requireJsonString "scoped named workspace stats" "root" otherRoot.toString scopedStats
  requireFieldAbsent "scoped named workspace stats" "workspaces" scopedStats

  let scopedOpenDocs ← expectOk (← runClient endpoint {
    Beam.Broker.Request.openDocs with
    workspaceId? := some workspaceId
  })
  requireJsonString "scoped named workspace open_docs" "workspace_id" workspaceId scopedOpenDocs
  requireJsonString "scoped named workspace open_docs" "root" otherRoot.toString scopedOpenDocs
  requireFieldAbsent "scoped named workspace open_docs" "workspaces" scopedOpenDocs

  let openDocs ← expectOk (← runClient endpoint Beam.Broker.Request.openDocs)
  requireWorkspaceListed openDocs workspaceId
  let workspaces ← expectOk (← runClient endpoint Beam.Broker.Request.listWorkspaces)
  requireWorkspaceArrayListed workspaces workspaceId

  let drop ← expectOk (← runClient endpoint {
    Beam.Broker.Request.dropWorkspace with
    workspaceId? := some workspaceId
  })
  requireJsonBool "drop named workspace" "dropped" true drop
  let staleAfterDrop ← runClient endpoint {
    payload := .runWith {
      path := "GoalSmoke.lean"
      handle := postResetHandle
      text := "trivial"
    }
    workspaceId? := some workspaceId
  }
  expectErrCode staleAfterDrop "invalidParams"
  let droppedEnsure ← runClient endpoint {
    Beam.Broker.Request.ensure with
    workspaceId? := some workspaceId
  }
  expectErrCode droppedEnsure "invalidParams"
  discard <| expectOk <| ← runClient endpoint {
    payload := .initWorkspace {
      root := otherRoot.toString
      lean? := some { command := leanCmd, plugin := plugin.toString }
    }
    workspaceId? := some workspaceId
  }
  let recreated ← requireUpdateFileResult "recreated workspace snapshot" <| ← expectOk <| ← runClient endpoint {
    payload := .updateFile { path := "GoalSmoke.lean" }
    workspaceId? := some workspaceId
  }
  require "workspace recreation reuses the native revision in this regression"
    (recreated.snapshot.revision == updateAfterReset.snapshot.revision)
  require "workspace recreation replaces snapshot" (recreated.snapshot != updateAfterReset.snapshot)
  for snapshot in [proofUpdate.snapshot, updateAfterReset.snapshot] do
    expectErrCode (← runClient endpoint {
      payload := .runAt {
        path := "GoalSmoke.lean", snapshot, line := 1, character := 2, text := "trivial"
      }
      workspaceId? := some workspaceId
    }) "contentModified"
  requireJsonBool "recreated workspace snapshot works" "success" true <| ← expectOk <| ← runClient endpoint {
    payload := .runAt {
      path := "GoalSmoke.lean", snapshot := recreated.snapshot, line := 1, character := 2, text := "trivial"
    }
    workspaceId? := some workspaceId
  }
  discard <| expectOk <| ← runClient endpoint {
    Beam.Broker.Request.dropWorkspace with workspaceId? := some workspaceId
  }

private def runInitialWorkspaceDropDebugPayloadSmoke (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  let drop ← expectOk (← runClient endpoint {
    Beam.Broker.Request.dropWorkspace with
    workspaceId? := some testWorkspaceId
  })
  requireJsonBool "drop initial workspace" "dropped" true drop
  let stats ← expectOk (← runClient endpoint Beam.Broker.Request.stats)
  for field in ["root", "sessions", "byBackend"] do
    requireFieldAbsent "stats after initial workspace drop" field stats
  discard <| requireObjVal "stats after initial workspace drop" "workspaces" stats
  let openDocs ← expectOk (← runClient endpoint Beam.Broker.Request.openDocs)
  for field in ["root", "sessions"] do
    requireFieldAbsent "open_docs after initial workspace drop" field openDocs
  discard <| requireObjVal "open_docs after initial workspace drop" "workspaces" openDocs

def smokeMain : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let root ← repoRoot
  let otherRoot ← IO.FS.realPath <| root / "tests" / "save_olean_project"
  let plugin ← pluginPath
  let leanCmd ← leanCmd
  let broker ← spawnLeanBrokerWithPlugin endpoint root plugin leanCmd
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.ensure)
    runReopenedSnapshotSmoke endpoint root
    runWorkspaceLifecycleSmoke endpoint otherRoot plugin leanCmd
    runUpdateSmoke endpoint root
    runSyncSmoke endpoint
    runErrorOnlySyncSmoke endpoint root
    runTodoThenSyncDiagnosticSummarySmoke endpoint
    runTodoCodeActionResolveSmoke endpoint
    runInteractiveOnlyDiagnosticSmoke endpoint
    runReportedOnlyDiagnosticSmoke endpoint
    runPartialProgressSmoke endpoint
    runConcurrentSmoke endpoint root
    runRequestAndGoalsSmoke endpoint
    runCancelSmoke endpoint
    runWorkerExitSmoke endpoint root
    runHandleSmoke endpoint
    runSaveAndStatsSmoke endpoint
    runInitialWorkspaceDropDebugPayloadSmoke endpoint

    let shutdownResp ← runClient endpoint Beam.Broker.Request.shutdown
    discard <| expectOk shutdownResp
  finally
    try
      broker.kill
    catch _ =>
      pure ()

end BeamTest.Broker.SmokeTest
