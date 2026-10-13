/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.Broker.Server
import Lean

open Lean

namespace BeamTest.Broker.StreamDedupTest

private def fixtureWorkspaceId : Beam.Broker.WorkspaceId :=
  "stream-dedup-fixture"

private def jsonPos (line character : Nat) : Json :=
  Json.mkObj [
    ("line", toJson line),
    ("character", toJson character)
  ]

private def jsonRangeFull (line character endLine endCharacter : Nat) : Json :=
  Json.mkObj [
    ("start", jsonPos line character),
    ("end", jsonPos endLine endCharacter)
  ]

private def jsonRange (line character endCharacter : Nat) : Json :=
  jsonRangeFull line character line endCharacter

private def jsonDiagnosticWithRange (range : Json) (severity : Nat) (message : String) : Json :=
  Json.mkObj [
    ("range", range),
    ("severity", toJson severity),
    ("message", toJson message)
  ]

private def jsonDiagnostic (line character endCharacter severity : Nat) (message : String) : Json :=
  jsonDiagnosticWithRange (jsonRange line character endCharacter) severity message

private def jsonPublishDiagnostics
    (uri : String)
    (version : Nat)
    (diagnostics : Array Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson ("2.0" : String)),
    ("method", toJson ("textDocument/publishDiagnostics" : String)),
    ("params", Json.mkObj [
      ("uri", toJson uri),
      ("version", toJson version),
      ("diagnostics", Json.arr diagnostics)
    ])
  ]

private def jsonResponse (id : Nat) (result : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson ("2.0" : String)),
    ("id", toJson id),
    ("result", result)
  ]

private def lspFrame (json : Json) : String :=
  let body := json.compress
  s!"Content-Length: {body.toUTF8.size}\r\n\r\n{body}"

private def oneRequestTranscriptPython : String :=
  String.intercalate "\n" [
    "import re, sys, time",
    "header = b''",
    "while not header.endswith(b'\\r\\n\\r\\n'):",
    "    chunk = sys.stdin.buffer.read(1)",
    "    if not chunk:",
    "        break",
    "    header += chunk",
    "match = re.search(br'Content-Length:\\s*(\\d+)', header, re.IGNORECASE)",
    "if match:",
    "    sys.stdin.buffer.read(int(match.group(1)))",
    "with open(sys.argv[1], 'rb') as transcript:",
    "    sys.stdout.buffer.write(transcript.read())",
    "sys.stdout.buffer.flush()",
    "time.sleep(1)",
    ""
  ]

private def writeTranscript (messages : Array Json) : IO System.FilePath := do
  let path := System.FilePath.mk s!"/tmp/beam-daemon-transcript-{← IO.monoNanosNow}.txt"
  IO.FS.writeFile path <| String.intercalate "" <| messages.toList.map lspFrame
  pure path

private def fakeTrackedSession (root transcript : System.FilePath) : IO Beam.Broker.Session := do
  let proc ← IO.Process.spawn {
    toStdioConfig := Beam.Broker.brokerStdio
    cmd := "bash"
    args := #["-lc", s!"cat {transcript}; sleep 1"]
    cwd := root.toString
  }
  let pending ← Std.Mutex.new ({} : Std.TreeMap Lean.JsonRpc.RequestID Beam.Broker.PendingRequest)
  let stderrCapture ← Beam.Broker.startBackendStderrCapture proc.stderr
  let session : Beam.Broker.Session := {
    workspaceId := fixtureWorkspaceId
    workspaceGeneration := 1
    backend := .lean
    root
    epoch := 1
    sessionToken := "fake-tracked-session"
    proc
    stdin := IO.FS.Stream.ofHandle proc.stdin
    stdout := IO.FS.Stream.ofHandle proc.stdout
    stderrCapture
    pending
  }
  let _ ← IO.asTask (prio := Task.Priority.dedicated) <| Beam.Broker.sessionReaderLoop session
  pure session

private def fakeOneRequestProcess (root transcript : System.FilePath) :
    IO (IO.Process.Child Beam.Broker.brokerStdio) := do
  IO.Process.spawn {
    toStdioConfig := Beam.Broker.brokerStdio
    cmd := "python3"
    args := #["-c", oneRequestTranscriptPython, transcript.toString]
    cwd := root.toString
  }

private def fakeSessionWithSyncedDoc
    (root path transcript : System.FilePath)
    (version : Nat := 1) : IO Beam.Broker.Session := do
  let proc ← fakeOneRequestProcess root transcript
  let pending ← Std.Mutex.new ({} : Std.TreeMap Lean.JsonRpc.RequestID Beam.Broker.PendingRequest)
  let stderrCapture ← Beam.Broker.startBackendStderrCapture proc.stderr
  let text ← IO.FS.readFile path
  let textMTime ← Lake.getFileMTime path
  let uri := Beam.Broker.sessionUri path
  let docs := ({} : Std.TreeMap String Beam.Broker.DocState).insert uri {
    version
    textHash := hash text
    textTraceHash := Lake.Hash.ofText text
    textMTime
    syncSnapshotSeq := 1
  }
  let session : Beam.Broker.Session := {
    workspaceId := fixtureWorkspaceId
    workspaceGeneration := 1
    backend := .lean
    root
    epoch := 1
    sessionToken := "fake-run-at-session"
    nextDocumentVersion := version + 1
    proc
    stdin := IO.FS.Stream.ofHandle proc.stdin
    stdout := IO.FS.Stream.ofHandle proc.stdout
    stderrCapture
    pending
    docs
  }
  let _ ← IO.asTask (prio := Task.Priority.dedicated) <| Beam.Broker.sessionReaderLoop session
  pure session

private def fakeServerWithLeanSession
    (root : System.FilePath)
    (session : Beam.Broker.Session) : IO Beam.Broker.ServerRuntime := do
  let config : Beam.Broker.BrokerConfig := { root }
  let workspace : Beam.Broker.WorkspaceState := {
    generation := 1
    config
    lean := { nextEpoch := 1, session? := some session }
  }
  let server ← Beam.Broker.ServerRuntime.create config fixtureWorkspaceId
  server.state.atomically do
    set ({
      bootstrapConfig := config
      workspaces := Std.TreeMap.empty.insert fixtureWorkspaceId workspace
    } : Beam.Broker.State)
  pure server

def checkRunAtStreamsSetupDiagnostics : IO Unit := do
  let rootBase := System.FilePath.mk s!"/tmp/beam-daemon-run-at-stream-{← IO.monoNanosNow}"
  IO.FS.createDirAll rootBase
  let root ← IO.FS.realPath rootBase
  let path := root / "Tracked.lean"
  IO.FS.writeFile path "def tracked : Nat := 1\n"
  let uri := Beam.Broker.sessionUri path
  let setupProgress := jsonDiagnosticWithRange (jsonRangeFull 0 0 1 0) 3
    "✔ [1/2] Built Tracked (1s)\n"
  let ordinaryError := jsonDiagnostic 2 0 6 1 "regular file error"
  let transcript ← writeTranscript #[
    jsonPublishDiagnostics uri 1 #[setupProgress, ordinaryError],
    jsonResponse 1 (Json.mkObj [("success", toJson true)])
  ]
  let session ← fakeSessionWithSyncedDoc root path transcript
  let server ← fakeServerWithLeanSession root session
  let streamedRef ← IO.mkRef #[]
  try
    let resp ← server.dispatchRequest {
      payload := .runAt {
        path := "Tracked.lean"
        snapshot := ⟨session.sessionToken, 1⟩
        line := 0
        character := 2
        text := "#check tracked"
      }
      workspaceId? := some fixtureWorkspaceId
    } (emitDiagnostic? := some fun diagnostic =>
      streamedRef.modify fun seen => seen.push diagnostic)
    if !resp.ok then
      throw <| IO.userError s!"expected run_at success, got {(toJson resp).compress}"
    let streamed ← streamedRef.get
    unless streamed.map (·.message) == #["✔ [1/2] Built Tracked (1s)\n"] do
      throw <| IO.userError
        s!"expected run_at to stream default setup-file progress only, got {(toJson streamed).compress}"
    unless streamed.all (fun diagnostic =>
        diagnostic.path == "Tracked.lean" && diagnostic.severity? == some .information) do
      throw <| IO.userError
        s!"expected run_at setup diagnostics to stay informational and relative, got {(toJson streamed).compress}"
  finally
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      discard <| session.proc.tryWait
    catch _ =>
      pure ()
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()
    try
      IO.FS.removeFile transcript
    catch _ =>
      pure ()

def check : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-dedup-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  let path := root / "Tracked.lean"
  IO.FS.writeFile path "-- fake tracked file\n"
  let uri := Beam.Broker.sessionUri path
  let first := jsonDiagnostic 0 0 4 2 "first warning"
  let second := jsonDiagnostic 1 2 6 2 "second warning"
  let transcript ← writeTranscript #[
    jsonPublishDiagnostics uri 1 #[first],
    jsonPublishDiagnostics uri 1 #[first],
    jsonPublishDiagnostics uri 1 #[first, second],
    jsonPublishDiagnostics uri 1 #[first, second],
    jsonResponse 1
  ]
  let session ← fakeTrackedSession root transcript
  let streamedRef ← IO.mkRef #[]
  try
    let trackedResult ←
      Beam.Broker.sendRequestJsonTrackedDetailed session "textDocument/waitForDiagnostics"
        (toJson <| Lean.Lsp.WaitForDiagnosticsParams.mk uri 1)
        (tracked := some (uri, 1))
        (diagnosticScope := .all)
        (emitDiagnostic? := some fun diagnostic =>
          streamedRef.modify fun seen => seen.push diagnostic)
    let (_session, _result, _progress?, diagnostics) ←
      match trackedResult with
      | .ok result => pure result
      | .error failure =>
          throw <| IO.userError
            s!"expected tracked request success, got {(toJson failure.toResponse).compress}"
    let streamed ← streamedRef.get
    if streamed.size != 2 then
      throw <| IO.userError s!"expected two deduped streamed diagnostics, got {(toJson streamed).compress}"
    unless streamed.all (fun diagnostic => diagnostic.path == "Tracked.lean") do
      throw <| IO.userError s!"expected deduped diagnostic paths to stay relative, got {(toJson streamed).compress}"
    unless streamed.map (·.message) == #["first warning", "second warning"] do
      throw <| IO.userError s!"expected deduped diagnostics in first-seen order, got {(toJson streamed).compress}"
    unless diagnostics.map (·.message) == #["first warning", "second warning"] do
      throw <| IO.userError s!"expected final tracked diagnostics snapshot to keep both warnings, got {(toJson diagnostics).compress}"
  finally
    try
      session.proc.kill
    catch _ =>
      pure ()
    try
      discard <| session.proc.tryWait
    catch _ =>
      pure ()

#eval check
#eval checkRunAtStreamsSetupDiagnostics

end BeamTest.Broker.StreamDedupTest
