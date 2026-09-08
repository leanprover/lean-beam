/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.Daemon.Protocol
import BeamTest.Broker.ClientUtil
import BeamTest.Broker.TestUtil
import BeamTest.Fixtures.TodoFixture
import Lean

open Lean

namespace BeamTest.Broker.StreamContractTest

open BeamTest.Broker.TestUtil

private def buildLakeTarget (root : System.FilePath) (target : String) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "env"
    args := #["LAKE_ARTIFACT_CACHE=false", "lake", "--no-cache", "build", target]
    cwd := root.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to build {target} in {root}\n{out.stderr}"

private def expectErrorCode (label code : String) (resp : Beam.Broker.Response) : IO Unit := do
  match resp with
  | .successResult .. =>
      throw <| IO.userError s!"expected {label} error {code}, got success {(toJson resp).compress}"
  | .errorResult failure =>
      if failure.error.code != code then
        throw <| IO.userError s!"expected {label} error {code}, got {(toJson resp).compress}"

private def expectTodoKindOnly
    (label : String)
    (kind : Beam.LSP.Todo.TodoKind)
    (result : Beam.LSP.Todo.TodoResult) : IO Beam.LSP.Todo.TodoItem := do
  let some item := result.items.find? (fun item => item.kind == kind)
    | throw <| IO.userError s!"expected {label} to contain todo kind {kind.key}, got {(toJson result).compress}"
  if result.items.any (fun item => item.kind != kind) then
    throw <| IO.userError s!"expected {label} to contain only todo kind {kind.key}, got {(toJson result).compress}"
  pure item

private def syncSnapshot
    (endpoint : Beam.Broker.Endpoint)
    (path : String) : IO Beam.SnapshotRef := do
  let resp ← runClient endpoint {
    payload := .syncFile { path }
  }
  let result ← requireSyncFileResult s!"sync snapshot for {path}" (← expectOk resp)
  pure result.snapshot

private partial def waitForBrokerExit
    (broker : IO.Process.Child nullBrokerStdio)
    (tries : Nat := 200) : IO Unit := do
  if (← broker.tryWait).isSome then
    pure ()
  else if tries == 0 then
    throw <| IO.userError "daemon remained alive after shutdown"
  else
    IO.sleep 25
    waitForBrokerExit broker (tries - 1)

private def sendShutdownAndResetConnection (port : UInt16) : IO Unit := do
  let payload := (toJson Beam.Broker.Request.shutdown).compress
  let script := String.intercalate ";" [
    "import socket,struct,sys",
    "s=socket.create_connection(('127.0.0.1',int(sys.argv[1])))",
    "s.setsockopt(socket.SOL_SOCKET,socket.SO_LINGER,struct.pack('ii',1,0))",
    "p=sys.argv[2].encode('utf-8')",
    "s.sendall(str(len(p)).encode('ascii')+b'\\n'+p)",
    "s.close()"
  ]
  let out ← IO.Process.output {
    cmd := "python3"
    args := #["-c", script, toString port.toNat, payload]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to reset shutdown connection\n{out.stderr}"

private def checkShutdownResponseBeforeExit (root : System.FilePath) : IO Unit := do
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.shutdown)
    waitForBrokerExit broker
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    try
      discard <| broker.tryWait
    catch _ =>
      pure ()

def main : IO Unit := do
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-stream-contract"
  copySaveProjectFixture root
  let identity : Beam.Broker.DaemonIdentity := {
    daemonId := "stream-contract-generation"
    configHash := "stream-contract-config"
  }
  let broker ← spawnLeanBroker endpoint root (identity? := some identity)
  try
    waitForBrokerReadyForRoot endpoint root
    match ← Beam.Daemon.standaloneDaemonGenerationStatus endpoint testWorkspaceId root identity with
    | .exact => pure ()
    | status =>
        throw <| IO.userError
          s!"daemon did not report its expected generation identity: {repr status}"
    for mismatched in #[
        { identity with daemonId := identity.daemonId ++ "-other" },
        { identity with configHash := identity.configHash ++ "-other" }
      ] do
      match ← Beam.Daemon.standaloneDaemonGenerationStatus endpoint testWorkspaceId root mismatched with
      | .wrongGeneration _ => pure ()
      | status =>
          throw <| IO.userError s!"daemon generation mismatch was classified as {repr status}"
    let otherRoot := root / "other-root"
    IO.FS.createDirAll otherRoot
    match ← Beam.Daemon.standaloneDaemonGenerationStatus endpoint testWorkspaceId otherRoot identity with
    | .wrongRoot _ => pure ()
    | status =>
        throw <| IO.userError s!"daemon root mismatch was classified as {repr status}"
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.ensure)

    let todoSnapshot ← syncSnapshot endpoint BeamTest.Fixtures.TodoFixture.brokerPath
    let todoMessages ← requireSuccessStream "todo" <| ← runBrokerStream endpoint {
      payload := .todo {
        path := BeamTest.Fixtures.TodoFixture.brokerPath
        snapshot := todoSnapshot
        line := BeamTest.Fixtures.TodoFixture.startLine
        character := BeamTest.Fixtures.TodoFixture.startCharacter
        endLine := BeamTest.Fixtures.TodoFixture.endLine
        endCharacter := BeamTest.Fixtures.TodoFixture.endCharacter
        kinds? := some #[.sorry]
        suggest? := some .none
      }
    }
    let todoResp ← requireFinalStreamResponse "todo" todoMessages
    let todoPayload ← expectOk todoResp
    let todoResult : Beam.LSP.Todo.TodoResult ← IO.ofExcept <| fromJson? todoPayload
    let todoSorry ← expectTodoKindOnly "todo" .sorry todoResult
    if todoSorry.runAtPosition != BeamTest.Fixtures.TodoFixture.sorryPosition then
      throw <| IO.userError
        s!"expected todo runAtPosition at {BeamTest.Fixtures.TodoFixture.sorryPosition}, got {(toJson todoSorry).compress}"

    writeSaveWarningFile root "-- broker stream sync"
    let syncRequestId := some "broker-stream-sync"
    let syncMessages ← requireSuccessStream "sync_file" <| ← runBrokerStream endpoint {
      payload := .syncFile {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
      }
      clientRequestId? := syncRequestId
    }
    expectStreamClientRequestId "sync_file" syncMessages syncRequestId
    let syncResp ← requireFinalStreamResponse "sync_file" syncMessages
    discard <| requireFileProgress "sync_file terminal response" syncResp
    let syncPayload ← expectOk syncResp
    expectNoReplayDiagnosticsField "sync_file" syncPayload
    let syncResult ← requireSyncFileResult "sync_file" syncPayload
    if syncResult.snapshot.session.isEmpty then
      throw <| IO.userError s!"expected sync_file a nonempty snapshot, got {syncResult.snapshot}"
    if !syncResult.readiness.saveReady then
      throw <| IO.userError s!"expected sync_file saveReady = true, got {(toJson syncResult).compress}"
    if syncResult.readiness.blockingErrorCount != 0 then
      throw <| IO.userError
        s!"expected sync_file blocking error count = 0, got {(toJson syncResult).compress}"
    let syncProgress := ← requireAnyStreamFileProgress "sync_file" syncMessages
    let some syncLast := syncProgress.back?
      | throw <| IO.userError "expected sync_file fileProgress tail"
    if !syncLast.done then
      throw <| IO.userError s!"expected sync_file final fileProgress to be done, got {(toJson syncLast).compress}"
    let syncDiagnostics ← requireAnyStreamDiagnostics "sync_file" syncMessages
    expectDiagnosticsForPath "sync_file" "SaveSmoke/B.lean" syncDiagnostics

    let syncReplyMessages ← requireSuccessStream "sync_file include diagnostics" <| ← runBrokerStream endpoint {
      payload := .syncFile {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
        diagnosticsInResult? := some true
      }
    }
    let syncReplyResp ← requireFinalStreamResponse "sync_file include diagnostics" syncReplyMessages
    let syncReplyPayload ← expectOk syncReplyResp
    let syncReplyResult ← requireSyncFileResult "sync_file include diagnostics" syncReplyPayload
    let some replyDiagnostics := syncReplyResult.diagnostics.items?
      | throw <| IO.userError "expected sync_file final diagnostic items"
    if replyDiagnostics.isEmpty then
      throw <| IO.userError
        s!"expected sync_file include diagnostics to replay diagnostics, got {syncReplyPayload.compress}"
    expectDiagnosticsForPath "sync_file include diagnostics" "SaveSmoke/B.lean" replyDiagnostics
    expectWarningDiagnosticPresent "sync_file include diagnostics" replyDiagnostics

    writeSaveWarningFile root "-- broker stream save"
    let saveMessages ← requireSuccessStream "save_olean" <| ← runBrokerStream endpoint {
      payload := .saveOlean {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
      }
    }
    let saveResp ← requireFinalStreamResponse "save_olean" saveMessages
    let savePayload ← expectOk saveResp
    expectNoReplayDiagnosticsField "save_olean" savePayload
    let saveSnapshot ← IO.ofExcept <| savePayload.getObjValAs? Beam.SnapshotRef "snapshot"
    if saveSnapshot == syncResult.snapshot then
      throw <| IO.userError s!"expected save_olean a fresh snapshot, got {saveSnapshot}"
    let saveDiagnostics ← requireAnyStreamDiagnostics "save_olean" saveMessages
    expectNonErrorDiagnosticsForPath "save_olean" "SaveSmoke/B.lean" saveDiagnostics

    writeSaveWarningFile root "-- broker stream close-save"
    let closeMessages ← requireSuccessStream "close-save" <| ← runBrokerStream endpoint {
      payload := .close {
        path := "SaveSmoke/B.lean"
        saveArtifacts? := some true
        diagnosticScope? := some .all
      }
    }
    let closeResp ← requireFinalStreamResponse "close-save" closeMessages
    let closePayload ← expectOk closeResp
    expectNoReplayDiagnosticsField "close-save" closePayload
    let closed ← IO.ofExcept <| closePayload.getObjValAs? Bool "closed"
    if !closed then
      throw <| IO.userError s!"expected close-save payload to report closed = true, got {closePayload.compress}"
    let savedPayload ← IO.ofExcept <| closePayload.getObjVal? "saved"
    let closeSnapshot ← IO.ofExcept <| savedPayload.getObjValAs? Beam.SnapshotRef "snapshot"
    if closeSnapshot == saveSnapshot then
      throw <| IO.userError s!"expected close-save saved a fresh snapshot, got {closeSnapshot}"
    let closeDiagnostics ← requireAnyStreamDiagnostics "close-save" closeMessages
    expectNonErrorDiagnosticsForPath "close-save" "SaveSmoke/B.lean" closeDiagnostics

    let standalonePath := root / "StandaloneSaveSmoke.lean"
    IO.FS.writeFile standalonePath "import SaveSmoke.B\n\n#check bVal\n"
    let standaloneSyncMessages ← requireSuccessStream "standalone sync_file" <| ← runBrokerStream endpoint {
      payload := .syncFile { path := "StandaloneSaveSmoke.lean" }
    }
    let standaloneSyncResp ← requireFinalStreamResponse "standalone sync_file" standaloneSyncMessages
    discard <| expectOk standaloneSyncResp

    let standaloneSaveMessages ← requireFailedStream "standalone save_olean" <| ← runBrokerStream endpoint {
      payload := .saveOlean { path := "StandaloneSaveSmoke.lean" }
    }
    let standaloneSaveResp ← requireFinalStreamResponse "standalone save_olean" standaloneSaveMessages
    expectErrorCode "standalone save_olean" Beam.Broker.saveTargetNotModuleCode standaloneSaveResp

    buildLakeTarget root "SaveSmoke/A.lean"
    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"

    let staleSyncMessages ← requireFailedStream "stale sync_file" <| ← runBrokerStream endpoint {
      payload := .syncFile { path := "SaveSmoke/A.lean" }
    }
    let staleSyncResp ← requireFinalStreamResponse "stale sync_file" staleSyncMessages
    expectErrorCode "stale sync_file" Beam.Broker.syncBarrierIncompleteCode staleSyncResp
    discard <| requireFileProgress "stale sync_file terminal response" staleSyncResp

    let staleSaveMessages ← requireFailedStream "stale save_olean" <| ← runBrokerStream endpoint {
      payload := .saveOlean { path := "SaveSmoke/A.lean" }
    }
    let staleSaveResp ← requireFinalStreamResponse "stale save_olean" staleSaveMessages
    expectErrorCode "stale save_olean" Beam.Broker.syncBarrierIncompleteCode staleSaveResp
    discard <| requireFileProgress "stale save_olean terminal response" staleSaveResp

    let staleCloseMessages ← requireFailedStream "stale close-save" <| ← runBrokerStream endpoint {
      payload := .close { path := "SaveSmoke/A.lean", saveArtifacts? := some true }
    }
    let staleCloseResp ← requireFinalStreamResponse "stale close-save" staleCloseMessages
    expectErrorCode "stale close-save" Beam.Broker.syncBarrierIncompleteCode staleCloseResp
    discard <| requireFileProgress "stale close-save terminal response" staleCloseResp

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := 1\n"
    buildLakeTarget root "SaveSmoke/A.lean"
    discard <| expectOk <| ← runClient endpoint {
      payload := .close { path := "SaveSmoke/A.lean" }
    }
    let staleTraceSyncResp ← runClient endpoint {
      payload := .syncFile { path := "SaveSmoke/A.lean" }
    }
    discard <| expectOk staleTraceSyncResp
    writeSaveWarningFile root "-- broker stream stale trace"

    let staleTraceSaveMessages ← requireFailedStream "stale trace save_olean" <| ← runBrokerStream endpoint {
      payload := .saveOlean { path := "SaveSmoke/A.lean" }
    }
    let staleTraceSaveResp ← requireFinalStreamResponse "stale trace save_olean" staleTraceSaveMessages
    expectErrorCode "stale trace save_olean" Beam.Broker.saveTraceStaleCode staleTraceSaveResp
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.stats)

    sendShutdownAndResetConnection port
    waitForBrokerExit broker
    match ← Beam.Daemon.standaloneDaemonGenerationStatus endpoint testWorkspaceId root identity with
    | .probeFailed (.transport .connect _) => pure ()
    | status =>
        throw <| IO.userError s!"stopped daemon was classified as {repr status}"
    checkShutdownResponseBeforeExit root
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    try
      discard <| broker.tryWait
    catch _ =>
      pure ()
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end BeamTest.Broker.StreamContractTest
