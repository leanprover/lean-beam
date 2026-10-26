/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.BackendProcess
import Beam.StderrCapture
import Beam.Broker.Protocol
import Beam.Daemon.Protocol
import BeamTest.Broker.ClientUtil
import BeamTest.Broker.TestUtil
import BeamTest.Fixtures.TodoFixture
import Lean

open Lean

namespace BeamTest.Broker.StreamContractTest

open BeamTest.Broker.TestUtil

private abbrev capturedBrokerStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .piped
  stderr := .piped

/-- Preserve a bounded byte tail, including output that is not valid UTF-8. -/
private def startCapturedStream (source : IO.FS.Handle) :
    IO (Beam.StderrCapture × Std.Mutex ByteArray) := do
  let tail ← Std.Mutex.new ByteArray.empty
  let capture ← Beam.StderrCapture.start source 8192 (some fun bytes => do
    tail.atomically <| modify fun previous =>
      let bytes := previous ++ bytes
      bytes.extract (bytes.size - min bytes.size 8192) bytes.size
    pure true)
  pure (capture, tail)

/-- A local resource bracket for this fixture only. Observe failure before cleanup;
keep operation, stream-capture, and evidence-write errors independent. -/
private def withBrokerFailureEvidence
    (spawn : IO (IO.Process.Child capturedBrokerStdio))
    (act : Beam.Broker.BackendProcess → IO α)
    (logs? : Option System.FilePath := none)
    (cleanupTimeoutMs : Nat := 5000)
    (adopt : IO.Process.Child capturedBrokerStdio → BaseIO Beam.Broker.BackendProcess :=
      fun child => Beam.Broker.BackendProcess.create child.pid child.tryWait child.kill) : IO α := do
  let child ← spawn
  let owner ← adopt child
  let (stdout, stdoutBytes) ← startCapturedStream child.stdout
  let (stderr, stderrBytes) ← startCapturedStream child.stderr
  let result : Except IO.Error α ← try pure (.ok (← act owner)) catch error => pure (.error error)
  let observation ← owner.observe
  -- Retain exit/wait failures in the existing owner; never signal a reaped child again.
  let termination ← owner.terminate cleanupTimeoutMs
  let stdoutOutcome ← stdout.awaitCompletion
  let stderrOutcome ← stderr.awaitCompletion
  let operationError? := match result with
    | .ok _ => none
    | .error error => some error
  let cleanupError? := match termination with
    | .exited _ => none
    | .unconfirmed .. => some <| IO.userError "stream fixture cleanup did not confirm child exit"
  let captureErrors := [stdoutOutcome, stderrOutcome].filterMap fun outcome => match outcome with
    | .drained => none
    | .sourceFailed error => some error
    | .pipeStillOpen => some <| IO.userError "stream fixture child output pipe remained open"
  match operationError? <|> cleanupError? <|> captureErrors.head? with
  | none => IO.ofExcept result
  | some error =>
      let logs ← match logs? with
        | some path => pure path
        | none => pure <| System.FilePath.mk ".beam/test-failures" / s!"stream-contract-{← IO.monoNanosNow}"
      let observation := match observation with
        | none => "still running"
        | some (.exited code) => s!"exited with code {code}"
        | some (.waitFailed failure) => s!"exit observation failed: {failure}"
      let mut details := s!"\nchild {owner.pid} before cleanup: {observation}"
      match termination with
      | .exited code => details := details ++ s!"\ncleanup confirmed exit code {code}"
      | .unconfirmed waitError? signalError? =>
          details := details ++ "\ncleanup exit unconfirmed"
          if let some failure := waitError? then details := details ++ s!"\ncleanup wait: {failure}"
          if let some failure := signalError? then details := details ++ s!"\ncleanup signal: {failure}"
      try IO.FS.createDirAll logs catch failure =>
        details := details ++ s!"\nevidence directory {logs}: {failure}"
      for (name, outcome, bytes) in [
          ("stdout", stdoutOutcome, ← stdoutBytes.atomically get),
          ("stderr", stderrOutcome, ← stderrBytes.atomically get)] do
        match outcome with
        | .drained => pure ()
        | .sourceFailed failure => details := details ++ s!"\n{name} capture failed: {failure}"
        | .pipeStillOpen => details := details ++ s!"\n{name} capture incomplete: pipe still open"
        let path := logs / s!"daemon.{name}.log"
        try IO.FS.writeBinFile path bytes catch failure =>
          details := details ++ s!"\nevidence write {path}: {failure}"
        let text := (String.fromUTF8? bytes).getD "<non-UTF-8 tail; see retained log>"
        details := details ++ s!"\n{name} tail, at most 8192 bytes ({path}):\n{text}"
      throw <| IO.userError s!"{error}{details}"

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

private def syncVersion
    (endpoint : Beam.Broker.Endpoint)
    (path : String) : IO Nat := do
  let resp ← runClient endpoint {
    payload := .syncFile { path }
  }
  let result ← requireSyncFileResult s!"sync version for {path}" (← expectOk resp)
  pure result.version

private partial def waitForBrokerExit
    (broker : Beam.Broker.BackendProcess)
    (tries : Nat := 200) : IO Unit := do
  match ← broker.observe with
  | some (.exited _) => pure ()
  | some (.waitFailed error) => throw error
  | none =>
    if tries == 0 then
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
  withBrokerFailureEvidence
      (spawnLeanBroker endpoint root (stdio := capturedBrokerStdio)) fun broker => do
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.shutdown)
    waitForBrokerExit broker

private def checkInitialRequestErrors (endpoint : Beam.Broker.Endpoint) : IO Unit := do
  for (header?, expected) in #[(some "16777217\n", "exceeds 16777216 bytes"),
      (none, "initial request timed out")] do
    let connection ← Beam.Broker.Transport.connect endpoint
    try
      if let some header := header? then
        let .tcp socket _ := connection
        let sent ← Std.Internal.UV.TCP.Socket.send socket #[header.toUTF8]
        let some result ← IO.wait sent.result?
          | throw <| IO.userError "initial request probe lost its send result"
        IO.ofExcept result
      let deadline := (← IO.monoNanosNow) + 15000 * 1000000
      let some message ← Beam.Broker.Transport.recvMsgUntil connection deadline
        | throw <| IO.userError s!"initial request probe received no error for {expected}"
      let message : Beam.Broker.StreamMessage ← IO.ofExcept <| fromJson? (← IO.ofExcept <| Json.parse message)
      let .response none response := message
        | throw <| IO.userError "initial request failure was not an uncorrelated terminal response"
      expectErrorCode "initial request" "internalError" response
      let some error := response.error?
        | throw <| IO.userError "initial request probe received no error payload"
      unless error.message.contains expected do
        throw <| IO.userError s!"expected initial request error '{expected}', got '{error.message}'"
    finally
      Beam.Broker.Transport.closeConnection connection

private def checkStartupFailureEvidence : IO Unit := do
  let root ← mkTempProjectRoot "beam-stream-startup-evidence"
  IO.FS.createDirAll root
  try
    for writeFailure in [false, true] do
      let marker := root / s!"ready-{writeFailure}"
      let logs := root / s!"logs-{writeFailure}"
      if writeFailure then IO.FS.writeFile logs "preserve this non-directory"
      let script := String.intercalate "\n" [
        "import os,pathlib,sys,time",
        "os.write(1,b'child stdout without newline')",
        "os.write(2,b'child stderr without newline')",
        "pathlib.Path(sys.argv[1]).write_text('ready')",
        "time.sleep(60)"
      ]
      let ownerRef ← IO.mkRef (none : Option Beam.Broker.BackendProcess)
      let spawn := do
        let child ← IO.Process.spawn {
          toStdioConfig := capturedBrokerStdio
          cmd := "python3"
          args := #["-c", script, marker.toString]
          setsid := true
        }
        pure child
      let error? ← try
        withBrokerFailureEvidence spawn (logs? := some logs) fun owner => do
          ownerRef.set (some owner)
          let mut attempts := 500
          while !(← marker.pathExists) && attempts > 0 do
            IO.sleep 10
            attempts := attempts - 1
          unless ← marker.pathExists do
            throw <| IO.userError "startup evidence fake child was not ready"
          waitForBrokerReadyForRoot (← freshTcpEndpoint) root (tries := 0)
        pure none
      catch error => pure (some error)
      let some error := error?
        | throw <| IO.userError "expected fake child readiness to fail"
      for expected in ["timed out waiting for Beam daemon", "still running",
          "child stdout without newline", "child stderr without newline", logs.toString] do
        unless error.toString.contains expected do
          throw <| IO.userError s!"startup failure omitted '{expected}': {error}"
      if writeFailure then
        unless error.toString.contains "evidence write" &&
            (← IO.FS.readFile logs) == "preserve this non-directory" do
          throw <| IO.userError "evidence failure replaced the primary error or changed its blocker"
      else
        unless (← IO.FS.readFile (logs / "daemon.stdout.log")) == "child stdout without newline" &&
            (← IO.FS.readFile (logs / "daemon.stderr.log")) == "child stderr without newline" do
          throw <| IO.userError "startup failure did not retain the original child output"
      let some owner ← ownerRef.get
        | throw <| IO.userError "startup evidence fake child was not spawned"
      match ← owner.observe with
      | some (.exited _) => pure ()
      | _ => throw <| IO.userError "startup failure did not collect its child"
  finally
    IO.FS.removeDirAll root

private def checkUnconfirmedCleanupEvidence : IO Unit := do
  let root ← mkTempProjectRoot "beam-stream-unconfirmed-evidence"
  IO.FS.createDirAll root
  let marker := root / "ready"
  let release := root / "release"
  let logs := root / "logs"
  let ownerRef ← IO.mkRef (none : Option Beam.Broker.BackendProcess)
  let script := String.intercalate "\n" [
    "import os,pathlib,sys,time",
    "os.write(1,b'quiet live child stdout')",
    "os.write(2,b'quiet live child stderr')",
    "os.close(1); os.close(2)",
    "pathlib.Path(sys.argv[1]).write_text('ready')",
    "while not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.005)"
  ]
  try
    let spawn := IO.Process.spawn {
      toStdioConfig := capturedBrokerStdio
      cmd := "python3"
      args := #["-c", script, marker.toString, release.toString]
      setsid := true
    }
    let error? ← try
      -- A no-op termination operation keeps this real child alive until release.
      -- The assertion cannot race an OS signal; EOF still does not prove child exit.
      withBrokerFailureEvidence spawn (logs? := some logs) (cleanupTimeoutMs := 0)
          (adopt := fun child => Beam.Broker.BackendProcess.create
            child.pid child.tryWait (pure ())) fun owner => do
        ownerRef.set (some owner)
        let mut attempts := 500
        while !(← marker.pathExists) && attempts > 0 do
          IO.sleep 10
          attempts := attempts - 1
        unless ← marker.pathExists do
          throw <| IO.userError "unconfirmed-cleanup fake child was not ready"
      pure none
    catch error => pure (some error)
    let some error := error?
      | throw <| IO.userError "fixture accepted drained output as proof of child exit"
    for expected in ["cleanup did not confirm child exit", "cleanup exit unconfirmed",
        "still running", "quiet live child stdout", "quiet live child stderr", logs.toString] do
      unless error.toString.contains expected do
        throw <| IO.userError s!"unconfirmed cleanup omitted '{expected}': {error}"
    unless ← (logs / "daemon.stdout.log").pathExists do
      throw <| IO.userError "cleanup-only failure did not retain its evidence"
  finally
    IO.FS.writeFile release "release"
    if let some owner ← ownerRef.get then
      match ← owner.terminate 5000 with
      | .exited _ => pure ()
      | .unconfirmed .. => throw <| IO.userError "unconfirmed-cleanup fake child was not collected"
    IO.FS.removeDirAll root

def main : IO Unit := do
  checkStartupFailureEvidence
  checkUnconfirmedCleanupEvidence
  let port ← freshTcpPort
  let endpoint : Beam.Broker.Endpoint := .tcp port
  let root ← mkTempProjectRoot "beam-daemon-stream-contract"
  copySaveProjectFixture root
  let identity : Beam.Broker.DaemonIdentity := {
    daemonId := "stream-contract-generation"
    configHash := "stream-contract-config"
  }
  let action := fun (broker : Beam.Broker.BackendProcess) => do
    waitForBrokerReadyForRoot endpoint root
    checkInitialRequestErrors endpoint
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

    let todoVersion ← syncVersion endpoint BeamTest.Fixtures.TodoFixture.brokerPath
    let todoMessages ← requireSuccessStream "todo" <| ← runBrokerStream endpoint {
      payload := .todo {
        path := BeamTest.Fixtures.TodoFixture.brokerPath
        version := todoVersion
        range? := some {
          start := { line := BeamTest.Fixtures.TodoFixture.startLine, character := BeamTest.Fixtures.TodoFixture.startCharacter }
          «end» := { line := BeamTest.Fixtures.TodoFixture.endLine, character := BeamTest.Fixtures.TodoFixture.endCharacter }
        }
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
    if syncResult.version != 1 then
      throw <| IO.userError s!"expected sync_file version 1, got {syncResult.version}"
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
    let saveVersion ← IO.ofExcept <| savePayload.getObjValAs? Nat "version"
    if saveVersion != 2 then
      throw <| IO.userError s!"expected save_olean version 2, got {saveVersion}"
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
    let closeVersion ← IO.ofExcept <| savedPayload.getObjValAs? Nat "version"
    if closeVersion != 3 then
      throw <| IO.userError s!"expected close-save saved version 3, got {closeVersion}"
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
    | .probeFailed { cause := .transport .connect _, .. } => pure ()
    | status =>
        throw <| IO.userError s!"stopped daemon was classified as {repr status}"
    checkShutdownResponseBeforeExit root
  try
    withBrokerFailureEvidence
      (spawnLeanBroker endpoint root (identity? := some identity)
        (stdio := capturedBrokerStdio)) action
  finally
    try IO.FS.removeDirAll root catch _ => pure ()

end BeamTest.Broker.StreamContractTest
