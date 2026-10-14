/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import BeamTest.Broker.TestUtil
import Lean

open Lean

namespace BeamTest.Broker.SaveStreamTest

open BeamTest.Broker.TestUtil

private def expectNoTrackedLeanDoc (payload : Json) (path : String) : IO Unit := do
  let sessions ← IO.ofExcept <| payload.getObjVal? "sessions"
  let leanSession ← IO.ofExcept <| sessions.getObjVal? "lean"
  let files ← IO.ofExcept <| leanSession.getObjVal? "files"
  let .arr files := files
    | throw <| IO.userError s!"expected open_docs lean.files array, got {files.compress}"
  for file in files do
    let trackedPath ← IO.ofExcept <| file.getObjValAs? String "path"
    if trackedPath == path then
      throw <| IO.userError s!"expected {path} to be closed, but it is still tracked in {(toJson files).compress}"

private def expectSyncVerdict
    (label : String)
    (payload : Json)
    (expectedVersion : Nat)
    (expectedSaveReady : Bool) : IO Beam.Broker.SyncFileResult := do
  let syncJson ← IO.ofExcept <| payload.getObjVal? "sync"
  let sync ← requireSyncFileResult label syncJson
  if sync.version != expectedVersion then
    throw <| IO.userError
      s!"expected {label} sync.version = {expectedVersion}, got {(toJson sync).compress}"
  if sync.readiness.saveReady != expectedSaveReady then
    throw <| IO.userError
      s!"expected {label} sync.readiness.saveReady = {expectedSaveReady}, got {(toJson sync).compress}"
  pure sync

private def expectErrorSyncVerdict
    (label : String)
    (error : Beam.Broker.Error)
    (expectedSaveReady : Bool) : IO Beam.Broker.SyncFileResult := do
  let some data := error.data?
    | throw <| IO.userError s!"expected {label} error.data.sync"
  let syncJson ← IO.ofExcept <| data.getObjVal? "sync"
  let sync ← requireSyncFileResult label syncJson
  if sync.readiness.saveReady != expectedSaveReady then
    throw <| IO.userError
      s!"expected {label} sync.readiness.saveReady = {expectedSaveReady}, got {(toJson sync).compress}"
  pure sync

private def checkCrlfSyncSaveReplay : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let root ← mkTempProjectRoot "beam-crlf-save-replay"
  copySaveProjectFixture root
  let source := root / "SaveSmoke" / "B.lean"
  let crlf := "def bVal : Nat := 42\r\n"
  IO.FS.writeFile source crlf
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.ensure)
    let synced ← runClient endpoint { payload := .syncFile { path := "SaveSmoke/B.lean" } }
    let result ← requireSyncFileResult "CRLF sync" (← expectOk synced)
    unless result.readiness.saveReady && (← requireFileProgress "CRLF sync" synced).done do
      throw <| IO.userError s!"expected CRLF sync to complete and permit save: {(toJson result).compress}"
    discard <| expectOk (← runClient endpoint { payload := .saveOlean { path := "SaveSmoke/B.lean" } })
    unless (← IO.FS.readBinFile source) == crlf.toUTF8 do
      throw <| IO.userError "CRLF sync/save rewrote source bytes"
    let selected ← IO.Process.output {
      cmd := "lean"
      args := #["--print-prefix"]
      cwd := (← repoRoot).toString
    }
    unless selected.exitCode == 0 do
      throw <| IO.userError s!"failed to locate the test compiler: {selected.stderr}"
    let leanPrefix := System.FilePath.mk selected.stdout.trimAscii.toString
    let replay ← IO.Process.output {
      -- The copied fixture may declare an older release; replay must use the broker's compiler.
      cmd := (leanPrefix / "bin" / "lake").toString
      args := #["--no-cache", "-v", "build", "SaveSmoke.B"]
      cwd := root.toString
    }
    let output := replay.stdout ++ replay.stderr
    unless replay.exitCode == 0 && output.contains "Replayed SaveSmoke.B" &&
        !output.contains "Built SaveSmoke.B" do
      throw <| IO.userError s!"Lake did not replay the CRLF checkpoint:\n{output}"
    unless (← IO.FS.readBinFile source) == crlf.toUTF8 do
      throw <| IO.userError "Lake replay rewrote CRLF source bytes"
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.shutdown)
  finally
    try broker.kill catch _ => pure ()
    discard <| broker.tryWait
    IO.FS.removeDirAll root

def main : IO Unit := do
  checkCrlfSyncSaveReplay
  let endpoint ← freshTcpEndpoint
  let root ← mkTempProjectRoot "beam-daemon-save-stream"
  copySaveProjectFixture root
  let broker ← spawnLeanBroker endpoint root
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.ensure)

    writeSaveWarningFile root "-- default warning-only save"
    let (defaultResp, defaultProgress, defaultDiagnostics) ← runClientWithStream endpoint {
      payload := .saveOlean { path := "SaveSmoke/B.lean" }
    }
    let defaultPayload ← expectOk defaultResp
    expectNoReplayDiagnosticsField "default save_olean" defaultPayload
    let defaultVersion ← IO.ofExcept <| defaultPayload.getObjValAs? Nat "version"
    if defaultVersion != 1 then
      throw <| IO.userError s!"expected default save_olean version 1, got {defaultVersion}"
    let defaultSyncVerdict ← expectSyncVerdict "default save_olean" defaultPayload defaultVersion true
    if defaultSyncVerdict.readiness.blockingErrorCount != 0 then
      throw <| IO.userError
        s!"expected default save_olean sync verdict to be clean, got {(toJson defaultSyncVerdict).compress}"
    let defaultTop := ← requireFileProgress "default save_olean" defaultResp
    if !defaultTop.done then
      throw <| IO.userError s!"expected default save_olean top-level fileProgress.done = true, got {(toJson defaultTop).compress}"
    let some defaultLast := defaultProgress.back?
      | throw <| IO.userError "expected default save_olean to stream fileProgress events"
    if !defaultLast.done then
      throw <| IO.userError s!"expected default save_olean streamed progress to finish, got {(toJson defaultLast).compress}"
    unless defaultDiagnostics.isEmpty do
      throw <| IO.userError s!"expected default save_olean to suppress warning diagnostics, got {(toJson defaultDiagnostics).compress}"

    writeSaveWarningFile root "-- full warning-only save"
    let (fullResp, fullProgress, streamedDiagnostics) ← runClientWithStream endpoint {
      payload := .saveOlean {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
      }
    }
    let fullPayload ← expectOk fullResp
    expectNoReplayDiagnosticsField "full save_olean" fullPayload
    let fullVersion ← IO.ofExcept <| fullPayload.getObjValAs? Nat "version"
    if fullVersion != 2 then
      throw <| IO.userError s!"expected full save_olean version 2 after a fresh edit, got {fullVersion}"
    let fullSyncVerdict ← expectSyncVerdict "full save_olean" fullPayload fullVersion true
    if fullSyncVerdict.readiness.blockingErrorCount != 0 ||
        fullSyncVerdict.diagnostics.counts.warning == 0 then
      throw <| IO.userError
        s!"expected full save_olean sync verdict to preserve warning-only verdict, got {(toJson fullSyncVerdict).compress}"
    let fullTop := ← requireFileProgress "full save_olean" fullResp
    if !fullTop.done then
      throw <| IO.userError s!"expected full save_olean top-level fileProgress.done = true, got {(toJson fullTop).compress}"
    let some fullLast := fullProgress.back?
      | throw <| IO.userError "expected full save_olean to stream fileProgress events"
    if !fullLast.done then
      throw <| IO.userError s!"expected full save_olean streamed progress to finish, got {(toJson fullLast).compress}"
    if streamedDiagnostics.isEmpty then
      throw <| IO.userError "expected full save_olean to stream diagnostics"
    expectNonErrorDiagnosticsForPath "full save_olean" "SaveSmoke/B.lean" streamedDiagnostics
    expectWarningDiagnosticPresent "full save_olean" streamedDiagnostics

    let (repeatResp, repeatProgress, repeatDiagnostics) ← runClientWithStream endpoint {
      payload := .saveOlean {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
      }
    }
    let repeatPayload ← expectOk repeatResp
    expectNoReplayDiagnosticsField "unchanged full save_olean" repeatPayload
    let repeatVersion ← IO.ofExcept <| repeatPayload.getObjValAs? Nat "version"
    if repeatVersion != 2 then
      throw <| IO.userError s!"expected unchanged full save_olean version 2, got {repeatVersion}"
    discard <| expectSyncVerdict "unchanged full save_olean" repeatPayload repeatVersion true
    let repeatTop := ← requireFileProgress "unchanged full save_olean" repeatResp
    if !repeatTop.done then
      throw <| IO.userError
        s!"expected unchanged full save_olean top-level fileProgress.done = true, got {(toJson repeatTop).compress}"
    if let some repeatLast := repeatProgress.back? then
      if !repeatLast.done then
        throw <| IO.userError
          s!"expected unchanged full save_olean streamed progress to finish, got {(toJson repeatLast).compress}"
    unless repeatDiagnostics.isEmpty do
      throw <| IO.userError
        s!"expected unchanged full save_olean to avoid replaying stale diagnostics, got {(toJson repeatDiagnostics).compress}"

    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") <| String.intercalate "\n" [
      "def bVal : Nat := 1",
      "",
      "def brokenSave : Nat := \"oops\""
    ] ++ "\n"
    let (errorResp, _errorProgress, errorDiagnostics) ← runClientWithStream endpoint {
      payload := .saveOlean {
        path := "SaveSmoke/B.lean"
        diagnosticScope? := some .all
      }
    }
    expectErrCode errorResp "invalidParams"
    let some error := errorResp.error?
      | throw <| IO.userError s!"expected save_olean error payload, got {(toJson errorResp).compress}"
    if !error.message.contains "cannot save artifacts for a document with errors;" then
      throw <| IO.userError
        s!"expected save_olean error to explain artifact rejection, got {error.message}"
    if !error.message.contains "commandMessages:" then
      throw <| IO.userError
        s!"expected save_olean error to include command-message details, got {error.message}"
    let errorSyncVerdict ← expectErrorSyncVerdict "save_olean document error" error false
    if errorSyncVerdict.readiness.blockingErrorCount == 0 then
      throw <| IO.userError
        s!"expected save_olean error sync verdict to describe document errors, got {(toJson errorSyncVerdict).compress}"
    if errorSyncVerdict.readiness.blockingDiagnostics.isEmpty &&
        errorSyncVerdict.readiness.blockingMessages.isEmpty then
      throw <| IO.userError
        s!"expected save_olean error sync verdict to include save-blocking evidence, got {(toJson errorSyncVerdict).compress}"
    unless errorSyncVerdict.readiness.blockingDiagnostics.all (·.saveBlocking) &&
        errorSyncVerdict.readiness.blockingMessages.all (·.saveBlocking) do
      throw <| IO.userError
        s!"expected save_olean error sync verdict blocking evidence to be flagged saveBlocking, got {(toJson errorSyncVerdict).compress}"
    unless errorDiagnostics.any (fun diagnostic =>
      diagnostic.path == "SaveSmoke/B.lean" && diagnostic.severity? == some .error) do
      throw <| IO.userError
        s!"expected save_olean error stream to include an error diagnostic for SaveSmoke/B.lean, got {(toJson errorDiagnostics).compress}"

    writeSaveWarningFile root "-- full close-save"
    let (closeResp, closeProgress, closeDiagnostics) ← runClientWithStream endpoint {
      payload := .close {
        path := "SaveSmoke/B.lean"
        saveArtifacts? := some true
        diagnosticScope? := some .all
      }
    }
    let closePayload ← expectOk closeResp
    expectNoReplayDiagnosticsField "full close-save" closePayload
    let closeClosed ← IO.ofExcept <| closePayload.getObjValAs? Bool "closed"
    if !closeClosed then
      throw <| IO.userError s!"expected close-save payload to report closed = true, got {closePayload.compress}"
    let savedPayload ← IO.ofExcept <| closePayload.getObjVal? "saved"
    let closeVersion ← IO.ofExcept <| savedPayload.getObjValAs? Nat "version"
    if closeVersion != 4 then
      throw <| IO.userError s!"expected close-save saved version 4 after a fresh edit, got {closeVersion}"
    let closeSyncVerdict ← expectSyncVerdict "full close-save" savedPayload closeVersion true
    if closeSyncVerdict.readiness.blockingErrorCount != 0 ||
        closeSyncVerdict.diagnostics.counts.warning == 0 then
      throw <| IO.userError
        s!"expected full close-save sync verdict to preserve warning-only verdict, got {(toJson closeSyncVerdict).compress}"
    let closeTop := ← requireFileProgress "full close-save" closeResp
    if !closeTop.done then
      throw <| IO.userError s!"expected full close-save top-level fileProgress.done = true, got {(toJson closeTop).compress}"
    let some closeLast := closeProgress.back?
      | throw <| IO.userError "expected full close-save to stream fileProgress events"
    if !closeLast.done then
      throw <| IO.userError
        s!"expected full close-save streamed progress to finish, got {(toJson closeLast).compress}"
    if closeDiagnostics.isEmpty then
      throw <| IO.userError "expected full close-save to stream diagnostics"
    expectNonErrorDiagnosticsForPath "full close-save" "SaveSmoke/B.lean" closeDiagnostics
    expectWarningDiagnosticPresent "full close-save" closeDiagnostics

    let openDocsPayload ← expectOk <| ← runClient endpoint {
      Beam.Broker.Request.openDocs with
      workspaceId? := some testWorkspaceId
    }
    expectNoTrackedLeanDoc openDocsPayload "SaveSmoke/B.lean"

    discard <| expectOk (← runClient endpoint Beam.Broker.Request.shutdown)
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| broker.tryWait
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end BeamTest.Broker.SaveStreamTest
