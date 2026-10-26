/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Lean
import Beam.Broker.Protocol
import Beam.Broker.Readiness
import Beam.Broker.Server
import Beam.Cli.LeanOperation
import Beam.Daemon.Startup
import Beam.JsonPretty
import BeamTest.Broker.ClientUtil
import BeamTest.Broker.DocumentFixture
import BeamTest.Broker.JsonAssert
import BeamTest.Broker.PublicationClaimTest
import Lean

open Lean
open Lean.Lsp
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.ProtocolTest

private def checkExactErrorAssertions : IO Unit := do
  let wrong : Response := .errorResult {
    error := { code := "-32602", message := "unrelated invalid-parameter failure" }
  }
  for expected in #[BrokerFailureCode.contentModified, .requestCancelled, .workerExited, .invalidParams] do
    BeamTest.Broker.TestUtil.expectErrCode (errorResponseFor expected) expected.name
    let accepted ←
      try
        BeamTest.Broker.TestUtil.expectErrCode wrong expected.name
        pure true
      catch _ => pure false
    require s!"error assertion must reject -32602 when expecting {expected.name}" (!accepted)

private def checkDaemonReadinessProtocol : IO Unit := do
  let identity : DaemonIdentity := {
    daemonId := "ready-generation"
    configHash := "ready-config"
  }
  let endpoint : Transport.Endpoint := .tcp 43123
  let ready := Beam.Daemon.StartupReady.ofEndpoint endpoint identity
  match Beam.Daemon.StartupReady.decodeLine identity ready.encodeLine with
  | .ok decoded =>
      unless decoded == endpoint do
        throw <| IO.userError s!"daemon readiness endpoint mismatch: {reprStr decoded}"
  | .error err =>
      throw <| IO.userError s!"valid daemon readiness failed to decode: {err}"

  let wrongIdentity : DaemonIdentity := {
    daemonId := "other-generation"
    configHash := identity.configHash
  }
  match Beam.Daemon.StartupReady.decodeLine wrongIdentity ready.encodeLine with
  | .ok _ => throw <| IO.userError "daemon readiness accepted the wrong generation identity"
  | .error err =>
      unless err.contains "identity does not match" do
        throw <| IO.userError s!"unexpected daemon readiness identity error: {err}"

  let unsupported := { ready with schemaVersion := Beam.Daemon.startupReadySchemaVersion + 1 }
  match Beam.Daemon.StartupReady.decodeLine identity unsupported.encodeLine with
  | .ok _ => throw <| IO.userError "daemon readiness accepted an unsupported schema"
  | .error err =>
      unless err.contains "unsupported Beam daemon readiness schema" do
        throw <| IO.userError s!"unexpected daemon readiness schema error: {err}"

  let invalidPort := { ready with port := 0 }
  match Beam.Daemon.StartupReady.decodeLine identity invalidPort.encodeLine with
  | .ok _ => throw <| IO.userError "daemon readiness accepted port zero"
  | .error err =>
      unless err.contains "outside 1-65535" do
        throw <| IO.userError s!"unexpected daemon readiness port error: {err}"

  let missingVersion := Json.mkObj [
    ("port", toJson 43123),
    ("identity", toJson identity)
  ]
  match fromJson? (α := Beam.Daemon.StartupReady) missingVersion with
  | .ok _ => throw <| IO.userError "daemon readiness accepted a missing schema version"
  | .error _ => pure ()

private def checkServerHelloProtocol : IO Unit := do
  let identity : DaemonIdentity := {
    daemonId := "hello-generation"
    configHash := "hello-config"
  }
  let hello := ServerHello.current identity
  match ServerHello.decode identity (toJson hello).compress with
  | .ok () => pure ()
  | .error err => throw <| IO.userError s!"valid daemon greeting failed to decode: {err}"
  let wrongIdentity : DaemonIdentity := {
    daemonId := "other-generation"
    configHash := identity.configHash
  }
  match ServerHello.decode wrongIdentity (toJson hello).compress with
  | .ok () => throw <| IO.userError "daemon greeting accepted the wrong generation identity"
  | .error err =>
      unless err.contains "identity does not match" do
        throw <| IO.userError s!"unexpected daemon greeting identity error: {err}"

private def decodeResponse (label : String) (json : Json) : IO Response := do
  match fromJson? json with
  | .ok resp => pure resp
  | .error err => throw <| IO.userError s!"{label}: failed to decode response: {err}"

private def expectDecodeFailure (α : Type) [FromJson α] [ToJson α]
    (label : String) (json : Json) : IO Unit := do
  match fromJson? (α := α) json with
  | .ok value =>
      throw <| IO.userError s!"{label}: expected decode failure, got {(toJson value).compress}"
  | .error _ =>
      pure ()

private def requireError
    (label : String)
    (expectedCode : String)
    (expectedMessage : String)
    (resp : Response) : IO Error := do
  match resp with
  | .successResult .. =>
      throw <| IO.userError s!"{label}: expected error response, got {(toJson resp).compress}"
  | .errorResult failure =>
      let err := failure.error
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected code={expectedCode}, got {(toJson resp).compress}"
      if err.message != expectedMessage then
        throw <| IO.userError s!"{label}: expected message={expectedMessage}, got {(toJson resp).compress}"
      pure err

private def requireResponseResult (label : String) (resp : Response) : IO Json := do
  match resp with
  | .successResult result .. => pure result
  | .errorResult .. =>
      throw <| IO.userError s!"{label}: expected result payload, got {(toJson resp).compress}"

private def requireErrorData (label : String) (err : Error) : IO Json := do
  match err.data? with
  | some data => pure data
  | none => throw <| IO.userError s!"{label}: expected error data, got {(toJson err).compress}"

private def sampleHandle : Handle := {
  workspaceId := "handle-workspace"
  epoch := 1
  session := "session"
  raw := Json.mkObj [("value", toJson ("raw" : String))]
}

private def sampleRequest : Op → Request
  | .ensure => Request.ensure
  | .openDocs => Request.openDocs
  | .cancel => Request.cancel "request"
  | .updateFile => { payload := .updateFile { path := "Demo.lean" } }
  | .syncFile => { payload := .syncFile { path := "Demo.lean" } }
  | .refreshFile => { payload := .refreshFile { path := "Demo.lean" } }
  | .close => { payload := .close { path := "Demo.lean" } }
  | .runAt => { payload := .runAt {
      path := "Demo.lean", version := 7, line := 1, character := 2, text := "exact trivial"
    } }
  | .hover => { payload := .hover {
      path := "Demo.lean", version := 7, line := 1, character := 2
    } }
  | .signatureHelp => { payload := .signatureHelp {
      path := "Demo.lean", version := 7, line := 1, character := 2
    } }
  | .definition => { payload := .definition {
      path := "Demo.lean", version := 7, line := 1, character := 2
    } }
  | .references => { payload := .references {
      path := "Demo.lean", version := 7, line := 1, character := 2
    } }
  | .documentSymbols => { payload := .documentSymbols { path := "Demo.lean", version := 7 } }
  | .workspaceSymbols => { payload := .workspaceSymbols { query := "Demo" } }
  | .codeActionResolve => { payload := .codeActionResolve {
      path := "Demo.lean", version := 7, codeAction := { title := "Resolve" }
    } }
  | .saveOlean => { payload := .saveOlean { path := "Demo.lean" } }
  | .goals => { payload := .goals {
      path := "Demo.lean", version := 7, line := 1, character := 2
    } }
  | .todo => { payload := .todo {
      path := "Demo.lean", version := 7,
      range? := some { start := { line := 1, character := 2 }, «end» := { line := 3, character := 4 } }
    } }
  | .runWith => { payload := .runWith {
      path := "Demo.lean", text := "exact trivial", handle := sampleHandle
    } }
  | .release => { payload := .release { path := "Demo.lean", handle := sampleHandle } }
  | .initWorkspace => { payload := .initWorkspace { root := "/workspace" } }
  | .listWorkspaces => Request.listWorkspaces
  | .dropWorkspace => Request.dropWorkspace
  | .stats => Request.stats
  | .shutdown => Request.shutdown

private def lspPos (line character : Nat) : Lsp.Position :=
  { line, character }

private def lspRange (line character endCharacter : Nat) : Lsp.Range :=
  { start := lspPos line character, «end» := lspPos line endCharacter }

private def diagnostic (severity : DiagnosticSeverity) (message : String) : Diagnostic :=
  let range := lspRange 0 0 1
  {
    range
    fullRange? := some range
    severity? := some severity
    message
  }

private def syncResultFor
    (version : Nat)
    (saveReady : Bool := true)
    (reason : String := "ok")
    (blockingErrorCount : Nat := 0)
    (warningCount : Nat := 0) : SyncFileResult := {
  path := "Demo.lean"
  version
  diagnostics := { counts := { warning := warningCount } }
  readiness := {
    saveReady
    reason
    blockingErrorCount
  }
}

private def syncDiagnosticCountsJson : Json :=
  Json.mkObj [
    ("error", toJson (0 : Nat)),
    ("warning", toJson (0 : Nat)),
    ("information", toJson (0 : Nat)),
    ("hint", toJson (0 : Nat)),
    ("unknown", toJson (0 : Nat)),
    ("total", toJson (0 : Nat))
  ]

private def syncReadinessJson (saveReady : Bool := true) : Json :=
  Json.mkObj [
    ("saveReady", toJson saveReady),
    ("reason", toJson "ok"),
    ("blockingErrorCount", toJson (0 : Nat)),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]

private def syncFileResultJson (version : Nat) (readiness : Json) : Json :=
  Json.mkObj [
    ("path", toJson "Demo.lean"),
    ("version", toJson version),
    ("diagnostics", Json.mkObj [("counts", syncDiagnosticCountsJson)]),
    ("readiness", readiness)
  ]

private def checkResponseJsonShape : IO Unit := do
  let successJson := toJson <| Response.success (Json.mkObj [("value", toJson (1 : Nat))])
  requireJsonBool "success response" "ok" true successJson
  requireFieldPresent "success response" "result" successJson
  requireFieldAbsent "success response" "error" successJson

  let errorJson := toJson <| (responseFailureFor .invalidParams "bad request").toResponse
  requireJsonBool "error response" "ok" false errorJson
  requireFieldPresent "error response" "error" errorJson
  requireFieldAbsent "error response" "result" errorJson

  requireFieldAbsent "semantic success response" "clientRequestId" successJson

private def checkStreamMessageDecode : IO Unit := do
  let response := Response.success (Json.mkObj [("value", toJson (1 : Nat))])
  let validResponse ← expectOk "valid response stream" <|
    fromJson? (α := StreamMessage) (toJson <| StreamMessage.response none response)
  match validResponse with
  | .response none _ => pure ()
  | other => throw <| IO.userError s!"valid response stream decoded as {(toJson other).compress}"

  let correlatedResponseJson :=
    toJson <| StreamMessage.response (some "req-response") response
  requireJsonString "correlated response stream" "clientRequestId" "req-response"
    correlatedResponseJson
  let correlatedResponsePayload ←
    requireObjVal "correlated response stream" "payload" correlatedResponseJson
  requireFieldAbsent "correlated response payload" "clientRequestId" correlatedResponsePayload
  let validCorrelatedResponse ← expectOk "valid correlated response stream" <|
    fromJson? (α := StreamMessage) correlatedResponseJson
  match validCorrelatedResponse with
  | .response clientRequestId? decodedResponse =>
      require "valid correlated response stream preserves envelope request id"
        (clientRequestId? == some "req-response")
      require "valid correlated response stream preserves response payload"
        (decodedResponse.result?.isSome)
  | other =>
      throw <| IO.userError s!"valid correlated response decoded as {(toJson other).compress}"

  let progress : SyncFileProgress := { updates := 2, done := false }
  let validProgress ← expectOk "valid progress stream" <|
    fromJson? (α := StreamMessage) (toJson <| StreamMessage.fileProgress (some "req-1") progress)
  match validProgress with
  | .fileProgress clientRequestId? decodedProgress =>
      require "valid progress stream preserves request id" (clientRequestId? == some "req-1")
      require "valid progress stream preserves payload" (decodedProgress.updates == 2)
  | other => throw <| IO.userError s!"valid progress stream decoded as {(toJson other).compress}"

  let diagnostic : StreamDiagnostic := {
    path := "Demo.lean"
    uri := "file:///repo/Demo.lean"
    version? := some 3
    severity? := some .warning
    range := lspRange 0 0 1
    message := "unused variable"
  }
  let validDiagnostic ← expectOk "valid diagnostic stream" <|
    fromJson? (α := StreamMessage) <|
      toJson <| StreamMessage.diagnostic (some "req-2") diagnostic
  match validDiagnostic with
  | .diagnostic clientRequestId? decodedDiagnostic =>
      require "valid diagnostic stream preserves request id" (clientRequestId? == some "req-2")
      require "valid diagnostic stream preserves payload"
        (decodedDiagnostic.path == "Demo.lean" && decodedDiagnostic.message == "unused variable")
  | other =>
      throw <| IO.userError s!"valid diagnostic stream decoded as {(toJson other).compress}"

  let responseJson := toJson response
  let progressJson := toJson progress
  let diagnosticJson := toJson diagnostic
  expectDecodeFailure StreamMessage "response stream missing payload" <|
    Json.mkObj [("kind", toJson "response")]
  expectDecodeFailure StreamMessage "progress stream with response payload" <|
    Json.mkObj [("kind", toJson "fileProgress"), ("payload", responseJson)]
  expectDecodeFailure StreamMessage "response stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "response"), ("response", responseJson)]
  expectDecodeFailure StreamMessage "progress stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "fileProgress"), ("fileProgress", progressJson)]
  expectDecodeFailure StreamMessage "diagnostic stream with legacy variant payload field" <|
    Json.mkObj [("kind", toJson "diagnostic"), ("diagnostic", diagnosticJson)]
  expectDecodeFailure StreamMessage "response stream with nested request id" <|
    Json.mkObj [
      ("kind", toJson "response"),
      ("payload", (toJson response).setObjVal! "clientRequestId" (toJson "req-response")),
      ("clientRequestId", toJson "req-response")
    ]
  expectDecodeFailure StreamMessage "stream with undeclared field" <|
    Json.mkObj [
      ("kind", toJson "fileProgress"),
      ("payload", progressJson),
      ("extra", toJson true)
    ]

private def checkResponseJsonDecode : IO Unit := do
  let success ← decodeResponse "success" <| Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  unless success.ok do
    throw <| IO.userError s!"success: expected ok=true, got {(toJson success).compress}"

  let error ← decodeResponse "error" <| Json.mkObj [
    ("ok", toJson false),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  if error.ok then
    throw <| IO.userError s!"error: expected ok=false, got {(toJson error).compress}"

  expectDecodeFailure Response "missing ok success" <| Json.mkObj [
    ("result", Json.mkObj [("value", toJson (1 : Nat))])
  ]
  expectDecodeFailure Response "missing ok error" <| Json.mkObj [
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "error with result" <| Json.mkObj [
    ("ok", toJson false),
    ("result", Json.null),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "ok with error" <| Json.mkObj [
    ("ok", toJson true),
    ("error", toJson ({ code := "invalidParams", message := "bad request" } : Error))
  ]
  expectDecodeFailure Response "ok=false without error" <| Json.mkObj [
    ("ok", toJson false)
  ]
  expectDecodeFailure Response "ok=true without result" <| Json.mkObj [
    ("ok", toJson true)
  ]
  expectDecodeFailure Response "response with undeclared field" <| Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj []),
    ("extra", toJson true)
  ]
private def checkSaveResultJsonDecode : IO Unit := do
  let saveResult : SaveOleanResult := {
    module := "Demo"
    sourceHash := "9a9bdc9950870951"
    olean := "/tmp/Demo.olean"
    ilean := "/tmp/Demo.ilean"
    c := "/tmp/Demo.c"
    trace := "/tmp/Demo.olean.trace"
    oleanServer? := some "/tmp/Demo.olean.server"
    irSig? := some "/tmp/Demo.ir.sig"
    sync := syncResultFor 7
  }
  let decodedSave ← expectOk "save result round-trip" <|
    fromJson? (α := SaveOleanResult) (toJson saveResult)
  require "save result round-trip preserves source hash"
    (decodedSave.sourceHash == saveResult.sourceHash)
  require "save result round-trip preserves IR signature"
    (decodedSave.irSig? == saveResult.irSig?)
  require "save result derives its path from nested sync"
    (decodedSave.path == "Demo.lean")
  require "save result derives its version from nested sync"
    (decodedSave.version == 7)
  require "save result round-trip preserves nested sync version"
    (decodedSave.sync.version == saveResult.sync.version)

  let closeSaveResult : CloseSaveResult := { saved := saveResult }
  let decodedCloseSave ← expectOk "close-save result round-trip" <|
    fromJson? (α := CloseSaveResult) (toJson closeSaveResult)
  require "close-save result round-trip preserves closure and nested save"
    (decodedCloseSave.closed && decodedCloseSave.saved.module == saveResult.module)

  let stale : SaveFinalizationStaleData := { saved := saveResult, currentVersion? := some 7 }
  let staleJson := toJson stale
  requireJsonString "same-version stale close reason" "reason" "savedDocumentChanged" staleJson
  requireJsonBool "stale close did not close replacement" "closed" false staleJson
  requireJsonInt "stale close can retain the public version" "currentVersion" 7 staleJson
  let retainedSave ← expectOk "stale close retains typed save" <|
    staleJson.getObjValAs? SaveOleanResult "saved"
  require "stale close retains committed source evidence" (retainedSave.sourceHash == saveResult.sourceHash)
  requireFieldAbsent "absent current document" "currentVersion" <|
    toJson ({ saved := saveResult } : SaveFinalizationStaleData)
  for originalData in [Json.mkObj [("detail", toJson "original typed data")], toJson "opaque data", Json.null] do
    let failed := toJson ({ saved := saveResult, originalData? := some originalData } : SaveFinalizationFailureData)
    requireFieldAbsent "ambiguous delivery failure" "closed" failed
    let retainedData ← expectOk "post-save failure retains arbitrary original JSON" <|
      failed.getObjVal? "originalData"
    require "post-save failure preserves original data" (retainedData.compress == originalData.compress)

  let missingOlean :=
    match toJson saveResult with
    | .obj fields => Json.obj <| fields.erase "olean"
    | other => other
  expectDecodeFailure SaveOleanResult "save result missing required artifact" missingOlean

  expectDecodeFailure SaveOleanResult "save result path does not match nested sync" <|
    (toJson saveResult).setObjVal! "path" (toJson "Other.lean")
  expectDecodeFailure SaveOleanResult "save result version does not match nested sync" <|
    (toJson saveResult).setObjVal! "version" (toJson (8 : Nat))

  let malformedNestedSave := Json.mkObj [
    ("closed", toJson true),
    ("saved", (toJson saveResult).setObjVal! "extra" (toJson true))
  ]
  expectDecodeFailure CloseSaveResult
    "close-save result with malformed nested save" malformedNestedSave
  expectDecodeFailure CloseSaveResult "close-save result reports closed=false" <|
    (toJson closeSaveResult).setObjVal! "closed" (toJson false)

private def fieldsAppearInOrder (text : String) : List String → Bool
  | [] => true
  | field :: rest =>
      match text.splitOn field with
      | [] | [_] => false
      | _ :: suffix => fieldsAppearInOrder (String.intercalate field suffix) rest

private def checkOrderedJsonPretty : IO Unit := do
  let resp : Response :=
    (Response.success <| toJson <| syncResultFor 3).withFileProgress {
      updates := 2
      done := true
      rangeEndLine? := some 1
    }
  let json := toJson resp
  let rendered := Beam.orderedJsonPretty json
  let expected := String.intercalate "\n" [
    "{",
    "  \"ok\": true,",
    "  \"result\": {",
    "    \"path\": \"Demo.lean\",",
    "    \"version\": 3,",
    "    \"diagnostics\": {",
    "      \"counts\": {",
    "        \"error\": 0,",
    "        \"warning\": 0,",
    "        \"information\": 0,",
    "        \"hint\": 0,",
    "        \"unknown\": 0,",
    "        \"total\": 0",
    "      }",
    "    },",
    "    \"readiness\": {",
    "      \"saveReady\": true,",
    "      \"reason\": \"ok\",",
    "      \"blockingErrorCount\": 0,",
    "      \"blockingDiagnostics\": [],",
    "      \"blockingMessages\": []",
    "    }",
    "  },",
    "  \"fileProgress\": {",
    "    \"done\": true,",
    "    \"updates\": 2,",
    "    \"rangeEndLine\": 1",
    "  }",
    "}"
  ]
  if rendered != expected then
    throw <| IO.userError s!"ordered JSON pretty output changed:\n{rendered}"
  let parsed ← expectOk "ordered JSON pretty parse" (Json.parse rendered)
  require "ordered JSON pretty output should round-trip" (parsed.compress == json.compress)
  let progress ← requireObjVal "ordered JSON pretty output" "fileProgress" json
  requireFieldAbsent "ordered JSON pretty progress" "line" progress
  requireFieldAbsent "ordered JSON pretty progress" "totalLines" progress
  requireJsonInt "ordered JSON pretty progress" "rangeEndLine" 1 progress

  let runAtJson := Json.mkObj [
    ("ok", toJson true),
    ("result", Json.mkObj [
      ("success", toJson true),
      ("messages", Json.arr #[]),
      ("next_handle", Json.mkObj [("session", toJson "session")]),
      ("document_progress", Json.mkObj [("done", toJson true)])
    ])
  ]
  for rendered in #[Beam.orderedJsonCompact runAtJson, Beam.orderedJsonPretty runAtJson] do
    require "run-at success and next handle should precede document progress"
      (fieldsAppearInOrder rendered ["\"success\"", "\"messages\"", "\"next_handle\"",
        "\"document_progress\""])

private def checkSyncFileResultDecode : IO Unit := do
  let valid := syncFileResultJson 7 (syncReadinessJson true)
  discard <| IO.ofExcept <| fromJson? (α := SyncFileResult) valid
  expectDecodeFailure SyncDiagnosticCounts "diagnostic total differs from severity sum" <|
    syncDiagnosticCountsJson.setObjVal! "total" (toJson (1 : Nat))
  for field in #[
    "saveReady",
    "errorCount",
    "warningCount",
    "saveReadyReason",
    "blockingDiagnostics",
    "blockingCommandMessages",
    "stateErrorCount",
    "stateCommandErrorCount"
  ] do
    expectDecodeFailure SyncFileResult s!"sync result removed top-level field {field}" <|
      valid.setObjVal! field Json.null
  let incompleteReadiness := Json.mkObj [
    ("reason", toJson "ok"),
    ("blockingErrorCount", toJson (0 : Nat)),
    ("blockingDiagnostics", toJson (#[] : Array SyncBlockingDiagnostic)),
    ("blockingMessages", toJson (#[] : Array SyncBlockingCommandMessage))
  ]
  expectDecodeFailure SyncFileResult "sync result missing saveReady" <|
    syncFileResultJson 7 incompleteReadiness

private def checkFailureResponseConversions : IO Unit := do
  for code in BrokerFailureCode.all do
    require s!"broker failure code '{code.name}' should round-trip from its wire name"
      (BrokerFailureCode.ofName? code.name == some code)
  require "unknown broker failure code should remain unknown"
    (BrokerFailureCode.ofName? "not-a-broker-failure" |>.isNone)

  let data := Json.mkObj [("uri", toJson "file:///A.lean")]
  let failure : BrokerFailure := {
    code := .contentModified
    message := "file changed"
    data? := some data
  }
  let err ← requireError "broker failure response" "contentModified" "file changed" <|
    failure.toResponse
  match err.data? with
  | some actual =>
      if actual.compress != data.compress then
        throw <| IO.userError s!"broker failure response: expected data {data.compress}, got {actual.compress}"
  | none =>
      throw <| IO.userError "broker failure response: expected error data"

  let progress : SyncFileProgress := { updates := 3, done := false, rangeEndLine? := some 17 }
  let responseFailure : ResponseFailure := {
    error := { code := "backendSpecific", message := "backend failed", data? := some data }
    fileProgress? := some progress
  }
  match responseFailure.toResponse with
  | .successResult .. =>
      throw <| IO.userError "response failure converted to a successful response"
  | .errorResult failure =>
      require "response failure preserves an arbitrary backend code"
        (failure.error.code == "backendSpecific")
      require "response failure preserves progress metadata"
        (failure.fileProgress? == some progress)

private def checkLakeHelperOutputCodec : IO Unit := do
  let required := ["oleanPath", "ileanPath", "cPath", "tracePath"]
  let optional := ["oleanServerPath", "oleanPrivatePath", "irPath", "irSigPath", "bcPath"]
  let pathRoot := if System.Platform.isWindows then "C:\\fixture\\" else "/fixture/"
  let path := fun field => pathRoot ++ field ++ " spaces λ \"quote\" \\slash"
  for includeOptional in [false, true] do
    let fields := required ++ if includeOptional then optional else []
    let wire := Json.mkObj <| fields.map (fun field => (field, toJson (path field))) ++ [
      ("traceMetadata", Json.mkObj [("depHash", toJson ("retained" : String))]),
      ("moduleName", toJson ("Saved" : String))
    ]
    let decoded ← IO.ofExcept <| fromJson? (α := LeanSaveSpec) wire
    require "helper specification preserves the flat golden wire shape"
      ((toJson decoded).compress == wire.compress)
    for field in fields do
      require "path data preserves Unicode, quotes, backslashes and native spelling"
        ((← IO.ofExcept <| (toJson decoded).getObjValAs? String field) == path field)
    for field in optional do
      require "optional fields have explicit absence semantics"
        (((toJson decoded).getObjVal? field).isOk == includeOptional)

private def checkDocumentVersionMismatchErrorData : IO Unit := do
  let data := documentVersionMismatchErrorData 1 2
    (currentVersion? := some 2)
    (uri? := some "file:///A.lean")
  requireJsonString "version mismatch data" "reason" "documentVersionMismatch" data
  requireJsonInt "version mismatch data" "expectedVersion" 1 data
  requireJsonInt "version mismatch data" "acceptedVersion" 2 data
  requireJsonInt "version mismatch data" "currentVersion" 2 data
  requireJsonString "version mismatch data" "uri" "file:///A.lean" data

private def checkReadinessBoundary : IO Unit := do
  let uri := "file:///workspace/SaveSmoke/A.lean"
  let clean := decideSyncBarrier uri 7 (some { updates := 1, done := true }) none false #[]
  require "clean readiness barrier should be complete" (!clean.incomplete)
  require "clean readiness barrier preserves prior progress"
    (clean.fileProgress? == some { updates := 1, done := true })

  let fatalBusy := decideSyncBarrier uri 7 none (some { updates := 2, done := false }) true #[]
  require "fatal snapshot with busy progress should leave the barrier incomplete" fatalBusy.incomplete
  require "fatal snapshot should explain the incomplete barrier"
    (fatalBusy.message?.any (·.contains "Lean diagnostics barrier did not complete"))

  let completed := decideSyncBarrier uri 7 none (some { updates := 2, done := false }) false #[]
  require "accepted completed snapshot overrides a delayed progress notification" (!completed.incomplete)
  require "completed snapshot retains progress evidence and marks completion"
    (completed.fileProgress? == some { updates := 2, done := true })
  let fatal := decideSyncBarrier uri 7 none (some { updates := 2, done := true }) true #[]
  require "fatal snapshot cannot be completed by a progress notification" fatal.incomplete

  let incompleteDiagnostic := diagnostic .information "Failed to build module dependencies."
  let diagnosticBarrier :=
    decideSyncBarrier uri 7 none (some { updates := 4, done := true }) false #[incompleteDiagnostic]
  require "stale dependency diagnostic should force an incomplete barrier" diagnosticBarrier.incomplete
  require "stale dependency diagnostic should force progress done=false"
    (diagnosticBarrier.fileProgress? == some { updates := 4, done := false })

  let hints : Array StaleDirectDepHint := #[{
    module := "SaveSmoke.B"
    path := "SaveSmoke/B.lean"
    needsSave := true
  }, {
    module := "SaveSmoke.C"
    path := "SaveSmoke/C.lean"
    needsSave := false
  }, {
    module := "SaveSmoke.D"
    path := "SaveSmoke/D.lean"
    needsSave := true
  }]
  let incompleteResp :=
    (syncBarrierIncompleteFailure uri 7 "SaveSmoke/A.lean" hints #[incompleteDiagnostic]
      diagnosticBarrier.fileProgress?).toResponse
  let err ← requireError
    "readiness incomplete response"
    syncBarrierIncompleteCode
    (syncBarrierIncompleteMessage uri 7)
    incompleteResp
  require "readiness failure must stop on a failed recovery step"
    (err.message.contains "stop if a step fails")
  require "readiness failure must require cleanup before external builds"
    (err.message.contains "rebuild only after cleanup completes")
  require "readiness failure should not duplicate internal progress JSON"
    (!err.message.contains "fileProgress=")
  require "readiness incomplete response should preserve fileProgress"
    (incompleteResp.fileProgress? == diagnosticBarrier.fileProgress?)
  let data ← requireErrorData "readiness incomplete response" err
  requireJsonString "readiness incomplete response data" "targetPath" "SaveSmoke/A.lean" data
  let saveDepsJson ← requireObjVal "readiness incomplete response data" "saveDeps" data
  let saveDeps ← expectOk "readiness saveDeps decode"
    (fromJson? (α := Array String) saveDepsJson)
  require "readiness incomplete response should include only unsaved dependencies in order"
    (saveDeps == #["SaveSmoke/B.lean", "SaveSmoke/D.lean"])
  let completionBlocking ← requireObjVal
    "readiness incomplete response data" "completionBlockingDiagnostics" data
  let completionBlockingItems ← expectOk "readiness completion-blocking diagnostics decode"
    (fromJson? (α := Array SyncBlockingDiagnostic) completionBlocking)
  require "readiness incomplete response should flag completion-blocking diagnostics"
    (completionBlockingItems.any (fun diagnostic =>
      diagnostic.completionBlocking &&
        diagnostic.message.contains "Failed to build module dependencies."))
  let recoveryPlanJson ← requireObjVal "readiness incomplete response data" "recoveryPlan" data
  let recoveryPlan ← expectOk "readiness recovery plan decode"
    (fromJson? (α := Array String) recoveryPlanJson)
  require "readiness recovery plan should save only unsaved dependencies then refresh the target"
    (recoveryPlan == #[
      "lean-beam save \"SaveSmoke/B.lean\"",
      "lean-beam save \"SaveSmoke/D.lean\"",
      "lean-beam refresh \"SaveSmoke/A.lean\""])

  for (label, extraHints) in #[("no hints", #[]), ("saved dependency", #[{
      module := "SaveSmoke.C"
      path := "SaveSmoke/C.lean"
      needsSave := false
    }])] do
    let emptyPlanData := staleSyncErrorData "SaveSmoke/A.lean" extraHints
    let emptyPlan ← requireObjVal label "recoveryPlan" emptyPlanData
    let emptyPlan ← expectOk s!"{label} recovery plan decode"
      (fromJson? (α := Array String) emptyPlan)
    require s!"{label} recovery plan should refresh only the target"
      (emptyPlan == #["lean-beam refresh \"SaveSmoke/A.lean\""])

  let successResp := syncFileSuccessResponse
    (syncResultFor 9 (saveReady := false) (reason := "documentErrors")
      (blockingErrorCount := 1))
    (some { updates := 5, done := true })
  require "readiness success response should be ok" successResp.ok
  require "readiness success response should keep fileProgress"
    (successResp.fileProgress? == some { updates := 5, done := true })
  let successResult ← requireResponseResult "readiness success response" successResp
  requireJsonInt "readiness success payload" "version" 9 successResult
  requireJsonString "readiness success payload" "path" "Demo.lean" successResult
  requireFieldAbsent "readiness success payload" "warningCount" successResult
  requireFieldAbsent "readiness success payload" "stateErrorCount" successResult
  requireFieldAbsent "readiness success payload" "stateCommandErrorCount" successResult
  requireFieldAbsent "readiness success payload" "blockingDiagnostics" successResult
  requireFieldAbsent "readiness success payload" "blockingCommandMessages" successResult
  requireFieldAbsent "readiness success payload" "saveReady" successResult
  requireFieldAbsent "readiness success payload" "saveReadyReason" successResult
  let successSyncResult ← expectOk "readiness success payload decode" <|
    fromJson? (α := SyncFileResult) successResult
  require "readiness success payload nested saveReady"
    (!successSyncResult.readiness.saveReady)
  require "readiness success payload distinguishes blocking evidence from diagnostic counts"
    (successSyncResult.readiness.blockingErrorCount == 1 &&
      successSyncResult.diagnostics.counts.error == 0)

  let streamedErrorDiagnostic := diagnostic .error "streamed error only"
  let stableCountsResp := syncFileSuccessResponse
    (syncResultFor 10 (saveReady := false) (reason := "documentErrors")
      (blockingErrorCount := 1) (warningCount := 5))
    none
  let stableCountsResult ← requireResponseResult "readiness stable-count response" stableCountsResp
  requireFieldAbsent "readiness stable-count payload" "errorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "warningCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "stateCommandErrorCount" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingDiagnostics" stableCountsResult
  requireFieldAbsent "readiness stable-count payload" "blockingCommandMessages" stableCountsResult

  if syncErrorCount #[streamedErrorDiagnostic] != 1 then
    throw <| IO.userError
      s!"readiness diagnostic fixture should count as an error, got {syncErrorCount #[streamedErrorDiagnostic]}"

  let interactiveOnlyResp := syncFileSuccessResponse (syncResultFor 11) none
  let interactiveOnlyResult ← requireResponseResult
    "readiness interactive-only diagnostic response" interactiveOnlyResp
  requireFieldAbsent "readiness interactive-only payload" "errorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateErrorCount" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "stateCommandErrorCount"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingDiagnostics"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "blockingCommandMessages"
    interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReady" interactiveOnlyResult
  requireFieldAbsent "readiness interactive-only payload" "saveReadyReason"
    interactiveOnlyResult
  let interactiveOnlySyncResult ← expectOk "readiness interactive-only payload decode" <|
    fromJson? (α := SyncFileResult) interactiveOnlyResult
  require "readiness interactive-only payload nested saveReady"
    interactiveOnlySyncResult.readiness.saveReady

private def checkStaleDirectDepHints : IO Unit := do
  let directImports := #["SaveSmoke.B"]

  let unsavedHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 9
      lastSaveEventSeq := 2
      lastRawSourceHash? := some 11
      lastTextChangeEventSeq := 9
    } : ModuleHistory)
  let unsavedHints := collectStaleDirectDepHints directImports 7 unsavedHistory
  let some unsavedHint := unsavedHints[0]?
    | throw <| IO.userError "expected unsaved stale direct dependency hint"
  require "unsaved stale direct dependency should need save" unsavedHint.needsSave
  require "unsaved stale direct dependency should name module"
    (unsavedHint.module == "SaveSmoke.B")
  require "unsaved stale direct dependency should name path"
    (unsavedHint.path == "SaveSmoke/B.lean")

  let savedHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 9
      lastSaveEventSeq := 10
      lastRawSourceHash? := some 11
      lastTextChangeEventSeq := 9
    } : ModuleHistory)
  let savedHints := collectStaleDirectDepHints directImports 7 savedHistory
  let some savedHint := savedHints[0]?
    | throw <| IO.userError "expected saved stale direct dependency hint"
  require "saved stale direct dependency should not need save" (!savedHint.needsSave)

  let noopSyncHistory : DocumentState.ModuleHistories :=
    Std.TreeMap.empty.insert "SaveSmoke.B" ({
      path := "SaveSmoke/B.lean"
      lastSyncEventSeq := 10
      lastSaveEventSeq := 2
      lastRawSourceHash? := some 11
      lastTextChangeEventSeq := 4
    } : ModuleHistory)
  let noopSyncHints := collectStaleDirectDepHints directImports 7 noopSyncHistory
  require "no-op dependency sync after target should not create stale hint"
    noopSyncHints.isEmpty

private def checkRequestBoundary : IO Unit := do
  let handleJson := toJson sampleHandle
  requireFieldAbsent "handle has no language selector" "backend" handleJson
  let decodedHandle ← expectOk "handle identity round trip" <| fromJson? (α := Handle) handleJson
  require "handle round trip preserves workspace, epoch, session, and raw identity"
    (toJson decodedHandle == handleJson)
  for extra in #["backend", "unknown"] do
    expectDecodeFailure Handle s!"handle rejects undeclared field {extra}" <|
      handleJson.setObjVal! extra (toJson "lean")
  for required in #["workspaceId", "epoch", "session", "raw"] do
    let .obj fields := handleJson | throw <| IO.userError "expected handle object"
    expectDecodeFailure Handle s!"handle requires {required}" <| .obj (fields.erase required)
  let goalsJson := toJson (sampleRequest .goals)
  for mode in #[GoalMode.before, .after] do
    let decoded ← expectOk s!"Lean goals mode {mode.key}" <|
      fromJson? (α := Request) (goalsJson.setObjVal! "mode" (toJson mode))
    let .goals goals := decoded.payload
      | throw <| IO.userError "goals request decoded as another operation"
    require "Lean goal mode should round trip" (goals.mode? == some mode)
  for (field, value) in #[
      ("text", toJson "split."), ("compact", toJson true), ("ppFormat", toJson "Box")] do
    expectDecodeFailure Request s!"removed Rocq goals field '{field}'" <|
      goalsJson.setObjVal! field value
  expectDecodeFailure Request "run_at request missing version" <| Json.mkObj [
    ("op", toJson "run_at"),
    ("path", toJson "Demo.lean"),
    ("line", toJson 1),
    ("character", toJson 2),
    ("text", toJson "exact trivial")
  ]
  expectDecodeFailure Request "run_at request missing text" <| Json.mkObj [
    ("op", toJson "run_at"),
    ("path", toJson "Demo.lean"),
    ("version", toJson 7),
    ("line", toJson 1),
    ("character", toJson 2)
  ]

  expectDecodeFailure Request "code_action_resolve request missing codeAction" <| Json.mkObj [
    ("op", toJson "code_action_resolve"),
    ("path", toJson "Demo.lean"),
    ("version", toJson 7)
  ]

private def checkWorkspaceRoutingFields : IO Unit := do
  let processWideOps := #[Op.listWorkspaces, .shutdown]
  let optionallyScopedOps := #[Op.openDocs, .stats]

  for op in Op.all do
    let expectedScope :=
      if processWideOps.contains op then
        WorkspaceScope.none
      else if optionallyScopedOps.contains op then
        .optional
      else
        .required
    require s!"{op.key} has the wrong workspace scope"
      (op.workspaceScope == expectedScope)
    let expectedTracking := op != .cancel && op != .shutdown
    require s!"{op.key} has the wrong active-request tracking policy"
      (op.tracksActiveRequest == expectedTracking)
    let request := sampleRequest op
    let requestJson := toJson request
    requireFieldAbsent s!"flat {op.key} request" "payload" requestJson
    let decoded ← expectOk s!"minimal {op.key} request round trip" <|
      fromJson? (α := Request) requestJson
    require s!"minimal {op.key} request lost its operation" (decoded.op == op)
    require s!"minimal {op.key} request changed its flat JSON wire shape"
      (toJson decoded == requestJson)
    requireFieldAbsent s!"{op.key} has no language selector" "backend" requestJson
    expectDecodeFailure Request s!"{op.key} rejects a removed language selector" <|
      requestJson.setObjVal! "backend" (toJson "lean")
    let expectedSession := op.workspaceScope == .required &&
      !#[Op.cancel, .initWorkspace, .dropWorkspace].contains op
    require s!"{op.key} has the wrong session policy" (op.usesSession == expectedSession)

  for (field, value) in [("leanCmd", "lean"), ("leanPlugin", "/beam/libbeam.so")] do
    match fromJson? (α := Request) <| Json.mkObj [
        ("op", toJson "init_workspace"), ("workspaceId", toJson "fixture"),
        ("root", toJson "/workspace"), (field, toJson value)] with
    | .ok _ => throw <| IO.userError "wire workspace initialization accepted component selection"
    | .error err => require "rejected component field must be named" (err.contains field)

  let unscopedReq := Request.stats
  require "missing workspace id remains unscoped" unscopedReq.resolvedWorkspaceId?.isNone
  requireFieldAbsent "stats request serialization" "backend" (toJson unscopedReq)

  let leanReq := Request.ensure
  requireFieldAbsent "Lean session request serialization" "backend" (toJson leanReq)

  let explicitReq : Request := { Request.stats with
    workspaceId? := some "fixture"
  }
  require "explicit workspace id wins" (explicitReq.resolvedWorkspaceId? == some "fixture")

  let handleReq : Request := {
    payload := .runWith {
      path := "Demo.lean"
      text := "exact trivial"
      handle := sampleHandle
    }
  }
  require "handle workspace id routes omitted request workspace"
    (handleReq.resolvedWorkspaceId? == some "handle-workspace")

  let releaseReq : Request := {
    payload := .release { path := "Demo.lean", handle := sampleHandle }
  }
  for (label, request) in #[
      ("run_with", handleReq),
      ("release", releaseReq)
    ] do
    requireFieldAbsent s!"{label} request uses handle workspace" "backend" (toJson request)
    expectDecodeFailure Request s!"{label} request rejects redundant backend" <|
      (toJson request).setObjVal! "backend" (toJson "lean")
    expectDecodeFailure Request s!"{label} rejects the removed handle backend" <|
      (toJson request).setObjVal! "handle" <|
        (toJson sampleHandle).setObjVal! "backend" (toJson "lean")

  let explicitHandleReq : Request := {
    payload := .runWith {
      path := "Demo.lean"
      text := "exact trivial"
      handle := sampleHandle
    }
    workspaceId? := some "explicit"
  }
  require "handle workspace remains authoritative with an explicit workspace id"
    (explicitHandleReq.resolvedWorkspaceId? == some "handle-workspace")
  match explicitHandleReq.validateFields with
  | .ok _ => throw <| IO.userError "request accepted a workspace that conflicts with its handle"
  | .error err =>
      require "conflicting handle workspace has a specific validation error"
        (err.contains "does not match handle workspace")

  match fromJson? (α := Request) <| Json.mkObj [
      ("op", toJson "stats"),
      ("root", toJson "/workspace")
    ] with
  | .ok _ => throw <| IO.userError "stats decoded an obsolete request-local root"
  | .error err =>
    require "stats rejects caller-selected workspace roots"
      (err.contains "unrelated" && err.contains "root")

  for (label, json, field) in #[
      ("unknown broker field", Json.mkObj [
        ("op", toJson "stats"),
        ("mystery", toJson true)
      ], "mystery"),
      ("known field owned by another operation", Json.mkObj [
        ("op", toJson "stats"),
        ("query", toJson "ignored-before-strict-validation")
      ], "query"),
      ("backend on process operation", Json.mkObj [
        ("op", toJson "stats"),
        ("backend", toJson "lean")
      ], "backend")
    ] do
    match fromJson? (α := Request) json with
    | .ok _ => throw <| IO.userError s!"{label} decoded unexpectedly"
    | .error err =>
        require s!"{label} error should identify '{field}'"
          (err.contains field)

  for obsoleteField in #["fullDiagnostics", "includeDiagnostics"] do
    let json := Json.mkObj [
      ("op", toJson "sync_file"),
      ("workspaceId", toJson "fixture"),
      ("path", toJson "Demo.lean"),
      (obsoleteField, toJson true)
    ]
    match fromJson? (α := Request) json with
    | .ok _ => throw <| IO.userError s!"broker accepted obsolete field {obsoleteField}"
    | .error err =>
        require s!"obsolete broker field error should identify {obsoleteField}"
          (err.contains obsoleteField)

  match fromJson? (α := Request) <| Json.mkObj [
      ("op", toJson "sync_file"),
      ("workspaceId", toJson "fixture"),
      ("path", toJson "Demo.lean"),
      ("diagnosticScope", toJson true)
    ] with
  | .ok _ => throw <| IO.userError "broker accepted boolean diagnosticScope"
  | .error err =>
      require "invalid diagnosticScope error should name the enum values"
        (err.contains "errors" && err.contains "all")

  match fromJson? (α := Request) <| Json.mkObj [
      ("op", toJson "init_workspace"),
      ("workspaceMode", toJson "unsupported")
    ] with
  | .ok _ => throw <| IO.userError "unsupported typed workspace mode decoded unexpectedly"
  | .error err =>
      require "unsupported workspace mode error should name accepted values"
        (err.contains "'set', 'verify', or 'reset'")

private def checkWorkspaceLifecycleProtocol : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  let previous := System.FilePath.mk "/previous-workspace"
  let emptyRuntimeIdRejected ←
    try
      discard <| Beam.Broker.ServerRuntime.create ({ root } : Beam.Broker.BrokerConfig) ""
      pure false
    catch err =>
      pure <| err.toString.contains "workspace id must be non-empty"
  require "broker runtime constructor should reject an empty workspace id" emptyRuntimeIdRejected

  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
  require "broker workspace query should expose the constructor workspace"
    ((← runtime.workspaceRoot? "fixture") == some root)
  require "broker workspace query should reject an unknown workspace"
    ((← runtime.workspaceRoot? "unknown") == none)
  for op in #[Op.ensure, .initWorkspace, .dropWorkspace] do
    let missingWorkspaceResp ← runtime.dispatchRequest (sampleRequest op)
    require s!"{op.key} should reject omitted workspace identity"
      (missingWorkspaceResp.error?.any fun err =>
        err.code == "invalidParams" && err.message.contains "workspaceId is required")
  let processStatsResp ← runtime.dispatchRequest Request.stats
  let some processStats := processStatsResp.result?
    | throw <| IO.userError s!"process-wide stats failed: {(toJson processStatsResp).compress}"
  requireFieldAbsent "process-wide stats" "root" processStats
  requireFieldAbsent "process-wide stats" "session" processStats
  requireFieldAbsent "process-wide stats" "metrics" processStats
  discard <| IO.ofExcept <| processStats.getObjVal? "workspaces"
  let scopedStatsResp ← runtime.dispatchRequest { Request.stats with workspaceId? := some "fixture" }
  let some scopedStats := scopedStatsResp.result?
    | throw <| IO.userError s!"workspace stats failed: {(toJson scopedStatsResp).compress}"
  requireFieldAbsent "workspace stats" "sessions" scopedStats
  requireFieldAbsent "workspace stats" "byBackend" scopedStats
  let session ← requireObjVal "workspace stats" "session" scopedStats
  requireJsonBool "workspace session" "active" false session
  let metrics ← requireObjVal "workspace stats" "metrics" scopedStats
  let starts ← IO.ofExcept <| metrics.getObjValAs? Nat "sessionStarts"
  require "inspection should not start a session" (starts == 0)

  let seedMetrics := runtime.state.atomically do
    let state ← get
    let some workspace := state.workspaces.get? "fixture"
      | throw <| IO.userError "metrics fixture workspace is missing"
    let metrics : WorkspaceMetrics := {
      sessionStarts := 2
      sessionRestarts := 1
      requestCount := 1
      successCount := 1
      ops := ({} : Std.TreeMap String OpStats).insert "run_at" {
        count := 1, successCount := 1
      }
    }
    set { state with workspaces := state.workspaces.insert "fixture" { workspace with metrics } }
  let requireFreshMetrics := fun label => do
    let response ← runtime.dispatchRequest { Request.stats with workspaceId? := some "fixture" }
    let some payload := response.result?
      | throw <| IO.userError s!"{label}: stats failed: {(toJson response).compress}"
    let metrics ← requireObjVal label "metrics" payload
    for field in #["sessionStarts", "sessionRestarts", "requestCount", "successCount",
        "errorCount", "cancelledCount", "workerExitedCount", "invalidParamsCount"] do
      let count ← IO.ofExcept <| metrics.getObjValAs? Nat field
      require s!"{label} clears {field}" (count == 0)
    let ops ← requireObjVal label "ops" metrics
    require s!"{label} clears per-operation counters" (ops == Json.mkObj [])
  seedMetrics
  match ← runtime.initWorkspaceWithConfig "fixture" ({ root } : BrokerConfig) (some .reset) with
  | .error failure =>
      throw <| IO.userError s!"metrics fixture reset failed: {failure.error.message}"
  | .ok _ => pure ()
  requireFreshMetrics "workspace reset"
  seedMetrics

  let resetResult : Beam.Workspace.InitResult := {
    workspaceId := "fixture"
    root
    mode := .reset
    runtimeReused := false
    previousRoot? := some previous
    invalidatedHandles := true
  }
  let resetJson := toJson resetResult
  requireJsonString "reset result json" "workspace_id" "fixture" resetJson
  requireJsonString "reset result json" "root" root.toString resetJson
  requireFieldAbsent "reset result json" "active_root" resetJson
  requireJsonString "reset result json" "previous_root" previous.toString resetJson
  requireJsonBool "reset result json" "invalidated_handles" true resetJson
  requireJsonBool "reset result json" "runtime_reused" false resetJson
  let decodedReset ← expectOk "decode typed workspace initialization result" <|
    fromJson? (α := Beam.Workspace.InitResult) resetJson
  require "typed workspace initialization result preserves lifecycle state"
    (decodedReset.workspaceId == "fixture" && decodedReset.root == root &&
      decodedReset.previousRoot? == some previous && decodedReset.invalidatedHandles)

  let setResultJson := toJson ({
    workspaceId := "fixture"
    root
    mode := .set
    runtimeReused := false
    invalidatedHandles := false
  } : Beam.Workspace.InitResult)
  requireJsonString "set result json" "workspace_id" "fixture" setResultJson
  requireJsonBool "set result json" "invalidated_handles" false setResultJson
  requireFieldAbsent "set result json" "previous_root" setResultJson

  let listJson := toJson ({ workspaces := #[{
    workspaceId := "fixture"
    root
    leanActive := true
  }] } : Beam.Workspace.ListResult)
  let decodedList ← expectOk "decode typed workspace list" <|
    fromJson? (α := Beam.Workspace.ListResult) listJson
  let some decodedEntry := decodedList.workspaces[0]?
    | throw <| IO.userError "typed workspace list lost its entry"
  require "typed workspace list preserves workspace id" (decodedEntry.workspaceId == "fixture")
  require "typed workspace list preserves root" (decodedEntry.root == root)
  require "typed workspace list preserves backend activity"
    decodedEntry.leanActive

  let dropJson := toJson ({
    workspaceId := "fixture"
    dropped := true
    invalidatedHandles := true
  } : Beam.Workspace.DropResult)
  let decodedDrop ← expectOk "decode typed workspace drop result" <|
    fromJson? (α := Beam.Workspace.DropResult) dropJson
  require "typed workspace drop preserves lifecycle state"
    (decodedDrop.workspaceId == "fixture" && decodedDrop.dropped && decodedDrop.invalidatedHandles)
  let dropResult ← runtime.dropWorkspace "fixture"
  match dropResult with
  | .error failure =>
      throw <| IO.userError s!"broker workspace drop failed: {failure.error.message}"
  | .ok dropped =>
      require "broker workspace drop should succeed" dropped.dropped
      require "broker workspace drop should invalidate handles" dropped.invalidatedHandles
  require "broker workspace query should observe a dropped workspace"
    ((← runtime.workspaceRoot? "fixture") == none)

  match ← runtime.initWorkspaceWithConfig "fixture" ({ root } : Beam.Broker.BrokerConfig) with
  | .error failure =>
      throw <| IO.userError s!"typed broker workspace initialization failed: {failure.error.message}"
  | .ok initialized =>
      require "typed broker workspace initialization should return its workspace"
        (initialized.workspaceId == "fixture" && initialized.root == root)
      require "typed broker workspace initialization should report a new runtime"
        (!initialized.runtimeReused && !initialized.invalidatedHandles)
  requireFreshMetrics "workspace recreation after drop"

private inductive LifecycleTeardown where
  | reset
  | drop

private def LifecycleTeardown.label : LifecycleTeardown → String
  | .reset => "reset"
  | .drop => "drop"

private partial def waitForPath
    (path : System.FilePath)
    (tries : Nat := 200) : IO Bool := do
  if ← path.pathExists then
    pure true
  else if tries == 0 then
    pure false
  else
    IO.sleep 10
    waitForPath path (tries - 1)

private partial def waitForTaskBefore
    (task : Task α)
    (blockedBy : Task β)
    (tries : Nat := 300) : IO (Option α) := do
  if ← IO.hasFinished blockedBy then
    pure none
  else if ← IO.hasFinished task then
    pure <| some (← IO.wait task)
  else if tries == 0 then
    pure none
  else
    IO.sleep 10
    waitForTaskBefore task blockedBy (tries - 1)

private inductive ShutdownBehavior where
  | exit
  | stall

/-- Reap an owned fixture if it is still running, without waiting indefinitely or re-signalling it. -/
private def cleanupFixtureChild
    (process : BackendProcess) : IO Unit := do
  match ← process.terminate 1000 with
  | .exited _ => pure ()
  | .unconfirmed (some err) _ => throw err
  | .unconfirmed none signalError? =>
      throw <| IO.userError <|
        "owned fixture child did not exit within its cleanup bound" ++
          (signalError?.map (fun error => s!": {error}")).getD ""

private def withFixtureChild
    (args : IO.Process.SpawnArgs)
    (act : IO.Process.Child args.toStdioConfig → BackendProcess → IO α) : IO α := do
  let child ← IO.Process.spawn args
  let process ← BackendProcess.create (Beam.processChildPid child) child.tryWait child.kill
  try act child process
  finally cleanupFixtureChild process

private def checkFixtureCleanupRejectsWaitFailure : IO Unit := do
  let process ← BackendProcess.create 0
    (throw <| IO.userError "controlled fixture wait failure") (pure ())
  let outcome : Except IO.Error Unit ←
    try
      cleanupFixtureChild process
      pure (.ok ())
    catch err => pure (.error err)
  match outcome with
  | .error (.userError "controlled fixture wait failure") => pure ()
  | _ => throw <| IO.userError "fixture cleanup accepted an unverified process reap"

private def checkFixtureChildCleanupOnFailure : IO Unit := do
  let childRef ← IO.mkRef (none : Option BackendProcess)
  try
    let outcome : Except IO.Error Unit ←
      try
        withFixtureChild {
          toStdioConfig := brokerStdio
          cmd := "python3"
          args := #["-c", "import time\nwhile True: time.sleep(1)\n"]
        } fun _ process => do
          childRef.set (some process)
          -- Fail before constructing a Session or adopting the child into broker state.
          throw <| IO.userError "fixture setup failed"
        pure (.ok ())
      catch err => pure (.error err)
    match outcome with
    | .error (.userError "fixture setup failed") => pure ()
    | _ => throw <| IO.userError "fixture cleanup changed the setup failure"
    let some child ← childRef.get
      | throw <| IO.userError "fixture setup did not spawn its child"
    let status ← IO.Process.output {
      cmd := "ps"
      args := #["-p", toString child.pid, "-o", "stat="]
    }
    require "failed fixture setup kills and reaps its child" (status.exitCode != 0)
  finally
    if let some child ← childRef.get then
      cleanupFixtureChild child

private def withShutdownObservedSession
    (workspaceId : WorkspaceId)
    (root sentinel : System.FilePath)
    (behavior : ShutdownBehavior)
    (act : Session → IO α) : IO α :=
  withFixtureChild {
    toStdioConfig := brokerStdio
    cmd := "python3"
    args := #[
      "-c",
      "import signal, sys, time\n" ++
      "if sys.argv[3] == 'stall': signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" ++
      "sys.stdin.buffer.readline()\n" ++
      "with open(sys.argv[1], 'a') as stream:\n" ++
      " stream.write(sys.argv[2] + '\\n')\n" ++
      "if sys.argv[3] == 'stall':\n" ++
      " while True: time.sleep(1)\n",
      sentinel.toString,
      workspaceId,
      (match behavior with | .exit => "exit" | .stall => "stall")
    ]
  } fun child proc => do
    let pending ← PendingRequestStore.create
    let stderrCapture ← startBackendStderrCapture child.stderr
    act {
      workspaceId
      workspaceGeneration := 1
      root
      epoch := 1
      sessionToken := s!"shutdown-observed-{workspaceId}"
      proc
      stdin := IO.FS.Stream.ofHandle child.stdin
      stdout := IO.FS.Stream.ofHandle child.stdout
      stderrCapture
      pending
    }

private def awaitFixtureSignal (label : String) (signal : IO.Promise Unit) : IO Unit := do
  let some (some ()) ← Beam.waitTaskWithTimeout signal.result? 5000
    | throw <| IO.userError s!"{label}: fixture signal did not arrive"

private def awaitFixtureTask
    (label : String) (task : Task (Except IO.Error Unit)) : IO Unit := do
  match ← Beam.waitTaskWithTimeout task 5000 with
  | some (.ok ()) => pure ()
  | some (.error err) => throw err
  | none => throw <| IO.userError s!"{label}: fixture task did not finish"

private inductive LateWriteFailure where
  | open
  | closed
  | cancelled
  deriving BEq

/-- A write admitted before closure must retain the channel's typed failure and cancellation. -/
private def checkLateWriteFailure (kind : LateWriteFailure) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-late-write-failure-{← IO.monoNanosNow}"
  let workspaceId := "late-write-failure"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } workspaceId
  let failure := BrokerFailure.toResponseFailure {
    code := .workerExited
    message := "controlled channel failure before write error"
    data? := some <| Json.mkObj [("source", toJson ("reader" : String))]
  }
  try
    withShutdownObservedSession workspaceId base (base / "shutdown") .stall fun initial => do
      let writes ← IO.mkRef (0 : Nat)
      let admitted ← IO.mkRef false
      let cancelled ← IO.mkRef false
      let session := { initial with
        stdin := { initial.stdin with putStr := fun text => do
          if text.contains "\"method\":\"workspace/symbol\"" then
            writes.modify (· + 1)
            admitted.set (!(← PendingRequestStore.snapshot initial.pending).isEmpty)
            if kind == .cancelled then
              if let some active ← ActiveRequestRegistry.markCancelled runtime.activeRequests
                  (some workspaceId) "late-write" then
                cancelled.set (← active.cancelRef.get)
            if kind != .open then
              PendingRequestStore.close initial.pending failure
            throw <| IO.userError "controlled broken pipe"
          else initial.stdin.putStr text
        }
      }
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "late-write fixture workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let task ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequest {
        workspaceId? := some workspaceId
        clientRequestId? := some "late-write"
        payload := .workspaceSymbols { query := "late-write" }
      }
      try
        let some (.ok response) ← Beam.waitTaskWithTimeout task 3000
          | throw <| IO.userError "late write failure left its caller blocked"
        require "late write fixture fails an admitted request" ((← admitted.get) && (← writes.get) == 1)
        match kind with
        | .open =>
            require "open-channel write errors retain their existing internal error"
              (response.error?.any fun error =>
                error.code == "internalError" && error.message.contains "controlled broken pipe")
        | .closed =>
            require "late write failure preserves the typed reader failure and data"
              (response.error?.any fun error => toJson error == toJson failure.error)
        | .cancelled =>
            require "late write fixture marked the exact active cancellation identity" (← cancelled.get)
            require "cancelled late write keeps cancellation precedence"
              (response.error?.any (·.code == "requestCancelled"))
        require "late write failure removes its pending request"
          ((← PendingRequestStore.snapshot initial.pending).isEmpty)
        let retained ← PendingRequestStore.failure? initial.pending
        require "late write failure preserves channel admission state"
          (if kind == .open then retained.isNone
           else retained.any fun actual => toJson actual.error == toJson failure.error)
      finally
        PendingRequestStore.close initial.pending failure
        discard <| IO.wait task
  finally
    try runtime.close finally IO.FS.removeDirAll base

private inductive ShutdownReply where
  | success
  | error
  | timeout
  | writeFailure
  deriving BEq

/-- A failed graceful attempt must reach mandatory cleanup without another synchronous write. -/
private def checkShutdownReplyCleanup (reply : ShutdownReply) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-shutdown-reply-{← IO.monoNanosNow}"
  let workspaceId := "shutdown-reply"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } workspaceId
  try
    withShutdownObservedSession workspaceId base (base / "shutdown") .stall fun initial => do
      let releaseExit ← IO.Promise.new
      let shutdownWrites ← IO.mkRef (0 : Nat)
      let exitWrites ← IO.mkRef (0 : Nat)
      let ordinary : PendingRequest := {
        promise := ← IO.Promise.new
        progressRef := ← IO.mkRef none
        diagnosticsRef := ← IO.mkRef #[]
        diagnosticsSeenRef := ← IO.mkRef false
        seenDiagnosticKeysRef := ← IO.mkRef {}
      }
      discard <| PendingRequestStore.register initial.pending 0 ordinary
      let session := { initial with
        stdin := { initial.stdin with
          putStr := fun text => do
            if text.contains "\"method\":\"shutdown\"" then
              shutdownWrites.modify (· + 1)
              if reply == .writeFailure then
                throw <| IO.userError "controlled shutdown write failure"
              initial.stdin.putStr text
              if reply == .success || reply == .error then
                let id : Lean.JsonRpc.RequestID := initial.nextId
                let some pending ← PendingRequestStore.remove initial.pending id
                  | throw <| IO.userError "controlled shutdown request was not registered"
                if reply == .success then
                  PendingRequest.resolveResponse pending Json.null
                else
                  pending.promise.resolve (.error <|
                    responseFailureFor .internalError "controlled shutdown reply failure")
            else if text.contains "\"method\":\"exit\"" then
              -- Count before blocking: an assertion thrown here could be swallowed by cleanup.
              exitWrites.modify (· + 1)
              if reply != .success then
                discard <| IO.wait releaseExit.result?
              initial.stdin.putStr text
            else initial.stdin.putStr text
        }
      }
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "shutdown-reply fixture workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let closeTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
      try
        let some (some (.error failure)) ← Beam.waitTaskWithTimeout ordinary.promise.result? 4000
          | throw <| IO.userError "shutdown cleanup left ordinary pending work behind an exit write"
        require "shutdown cleanup settles ordinary pending work with a typed worker exit"
          (failure.error.code == "workerExited")
        awaitFixtureTask "shutdown-reply runtime close" closeTask
        require "shutdown cleanup attempts exactly one shutdown request" ((← shutdownWrites.get) == 1)
        require "only a successful shutdown reply permits an exit notification"
          ((← exitWrites.get) == if reply == .success then 1 else 0)
        require "shutdown cleanup settles every pending request"
          ((← PendingRequestStore.snapshot session.pending).isEmpty)
        let some (.exited _) ← session.proc.observe
          | throw <| IO.userError "shutdown cleanup did not confirm termination of its stalled child"
      finally
        -- A broken implementation may be held inside the forbidden notification write.
        releaseExit.resolve ()
        discard <| Beam.waitTaskWithTimeout closeTask 5000
  finally
    try runtime.close finally IO.FS.removeDirAll base

private inductive CleanupOrder where
  | readerFirst
  | closeFirst

/-- Hold both callers inside their I/O boundaries, then release each completion order explicitly. -/
private def checkReaderFailureOverlapsClose (order : CleanupOrder) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-reader-close-{← IO.monoNanosNow}"
  let workspaceId := "reader-close"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } workspaceId
  try
    withShutdownObservedSession workspaceId base (base / "shutdown") .stall fun initial => do
      let readerStarted ← IO.Promise.new
      let failReader ← IO.Promise.new
      let shutdownStarted ← IO.Promise.new
      let releaseShutdown ← IO.Promise.new
      let writes ← IO.mkRef (0 : Nat)
      let session := { initial with
        stdin := { initial.stdin with
          putStr := fun text => do
            let count ← writes.get
            writes.set (count + 1)
            if count == 0 then
              shutdownStarted.resolve ()
              discard <| IO.wait releaseShutdown.result?
            initial.stdin.putStr text
        }
        stdout := { initial.stdout with
          getLine := do
            readerStarted.resolve ()
            discard <| IO.wait failReader.result?
            throw <| IO.userError "controlled reader failure"
        }
      }
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "reader-close fixture workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let readerTask ← IO.asTask (prio := Task.Priority.dedicated) <| sessionReaderLoop session
      let closeTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
      try
        awaitFixtureSignal "reader-close reader" readerStarted
        awaitFixtureSignal "reader-close shutdown" shutdownStarted
        let entries ← PendingRequestStore.snapshotEntries session.pending
        require "overlapping close has exactly one pending shutdown" (entries.size == 1)
        let some (id, pending) := entries[0]?
          | throw <| IO.userError "overlapping close did not publish its shutdown request"
        match order with
        | .readerFirst =>
            failReader.resolve ()
            awaitFixtureTask "reader cleanup before close" readerTask
            require "close remains inside its controlled write until reader cleanup completes"
              (!(← IO.hasFinished closeTask))
            releaseShutdown.resolve ()
        | .closeFirst =>
            discard <| PendingRequestStore.remove session.pending id
            PendingRequest.resolveResponse pending Json.null
            releaseShutdown.resolve ()
            awaitFixtureTask "close cleanup before reader" closeTask
            require "reader remains inside its controlled read until close cleanup completes"
              (!(← IO.hasFinished readerTask))
            failReader.resolve ()
        awaitFixtureTask "overlapping reader cleanup" readerTask
        awaitFixtureTask "overlapping runtime close" closeTask
        match order, ← pending.awaitOutcome with
        | .readerFirst, .error failure =>
            require "reader failure resolves the overlapping shutdown with its worker-exit cause"
              (failure.error.code == "workerExited" &&
                failure.error.message.contains "controlled reader failure")
        | .closeFirst, .ok _ => pure ()
        | _, _ => throw <| IO.userError "overlapping cleanup changed the pending shutdown outcome"
        require "overlapping cleanup leaves no pending requests"
          ((← PendingRequestStore.snapshot session.pending).isEmpty)
        runtime.state.atomically do
          let some workspace := (← get).workspaces.get? workspaceId
            | throw <| IO.userError "overlapping close removed its workspace"
          require "overlapping cleanup detaches its session exactly once"
            (workspace.lean.session?.isNone && workspace.lean.nextEpoch == 3)
        let status ← IO.Process.output {
          cmd := "ps"
          args := #["-p", toString session.proc.pid, "-o", "stat="]
        }
        require "overlapping cleanup kills and reaps its child" (status.exitCode != 0)
        let writesBefore ← writes.get
        runtime.close
        require "repeated close after reader cleanup sends no additional messages"
          ((← writes.get) == writesBefore)
      finally
        failReader.resolve ()
        releaseShutdown.resolve ()
        discard <| Beam.waitTaskWithTimeout readerTask 5000
        discard <| Beam.waitTaskWithTimeout closeTask 5000
  finally
    try
      runtime.close
    finally
      IO.FS.removeDirAll base

/-- Model an exited worker whose descendant keeps the session pipes open during bounded cleanup. -/
private def exitedSessionWithInheritedStdio
    (workspaceId : WorkspaceId)
    (root pipesReady release done : System.FilePath) : IO Session := do
  let childScript :=
    "import pathlib, sys, time\n" ++
    "pathlib.Path(sys.argv[1]).write_text('pipes-open')\n" ++
    "deadline = time.monotonic() + 30\n" ++
    "while not pathlib.Path(sys.argv[2]).exists() and time.monotonic() < deadline:\n" ++
    " time.sleep(0.01)\n" ++
    "pathlib.Path(sys.argv[2]).unlink(missing_ok=True)\n" ++
    "pathlib.Path(sys.argv[3]).write_text('done')\n"
  let child ← IO.Process.spawn {
    toStdioConfig := brokerStdio
    cmd := "python3"
    args := #[
      "-c",
      "import subprocess, sys\nsubprocess.Popen([sys.executable, '-c', sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]])",
      childScript,
      pipesReady.toString,
      release.toString,
      done.toString
    ]
  }
  let pending ← PendingRequestStore.create
  let stderrCapture ← startBackendStderrCapture child.stderr
  let proc ← BackendProcess.create (Beam.processChildPid child) child.tryWait child.kill
  let some (.exited _) ← proc.waitForExit 1000
    | throw <| IO.userError "inherited-stdio fixture leader did not exit"
  pure {
    workspaceId
    workspaceGeneration := 1
    root
    epoch := 1
    sessionToken := s!"exited-{workspaceId}"
    proc
    stdin := IO.FS.Stream.ofHandle child.stdin
    stdout := IO.FS.Stream.ofHandle child.stdout
    stderrCapture
    pending
  }

private def runLifecycleTeardown
    (kind : LifecycleTeardown)
    (runtime : ServerRuntime)
    (workspaceId : WorkspaceId)
    (replacement : BrokerConfig) : IO (Except ResponseFailure Bool) := do
  match kind with
  | .reset =>
      match ← runtime.initWorkspaceWithConfig workspaceId replacement (some .reset) with
      | .ok result => pure <| .ok result.invalidatedHandles
      | .error failure => pure <| .error failure
  | .drop =>
      match ← runtime.dropWorkspace workspaceId with
      | .ok result => pure <| .ok result.invalidatedHandles
      | .error failure => pure <| .error failure

private def checkLifecycleTeardownReleasesStateMutex
    (kind : LifecycleTeardown) : IO Unit := do
  let nonce ← IO.monoNanosNow
  let targetId := "teardown-target"
  let observerId := "teardown-observer"
  let targetRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-target-{nonce}"
  let replacementRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-replacement-{nonce}"
  let observerRoot := System.FilePath.mk s!"/tmp/beam-{kind.label}-observer-{nonce}"
  let sentinel := System.FilePath.mk s!"/tmp/beam-{kind.label}-shutdown-{nonce}"
  let targetConfig : BrokerConfig := { root := targetRoot }
  let replacementConfig : BrokerConfig := { root := replacementRoot }
  let observerConfig : BrokerConfig := { root := observerRoot }
  let runtime ← ServerRuntime.create targetConfig targetId
  try
    withShutdownObservedSession targetId targetRoot sentinel .stall fun session => do
      runtime.state.atomically do
        let state ← get
        let targetWorkspace : WorkspaceState := {
          generation := 1
          config := targetConfig
          lean := { nextEpoch := 2, session? := some session }
        }
        let observerWorkspace : WorkspaceState := { generation := 2, config := observerConfig }
        let workspaces := state.workspaces.insert targetId targetWorkspace
        let workspaces := workspaces.insert observerId observerWorkspace
        set { state with workspaces }
      let teardownTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        runLifecycleTeardown kind runtime targetId replacementConfig
      unless ← waitForPath sentinel do
        throw <| IO.userError s!"{kind.label}: backend did not enter shutdown"
      require s!"{kind.label}: teardown fixture should still be waiting for the backend"
        (!(← IO.hasFinished teardownTask))

      let queryTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        runtime.workspaceRoot? observerId
      let some queryOutcome ← waitForTaskBefore queryTask teardownTask
        | throw <| IO.userError s!"{kind.label}: unrelated workspace query blocked on teardown"
      let queryRoot ←
        match queryOutcome with
        | .ok queryRoot => pure queryRoot
        | .error err => throw err
      require s!"{kind.label}: unrelated workspace query should retain its root"
        (queryRoot == some observerRoot)
      require s!"{kind.label}: unrelated workspace query should finish before teardown"
        (!(← IO.hasFinished teardownTask))

      let teardownOutcome ← IO.wait teardownTask
      let teardownResult ←
        match teardownOutcome with
        | .ok result => pure result
        | .error err => throw err
      match teardownResult with
      | .error failure =>
          throw <| IO.userError s!"{kind.label}: lifecycle transition failed: {failure.error.message}"
      | .ok invalidatedHandles =>
          require s!"{kind.label}: lifecycle transition should invalidate handles" invalidatedHandles
  finally
    if ← sentinel.pathExists then
      IO.FS.removeFile sentinel

private def checkLifecycleTeardownConcurrency : IO Unit := do
  checkLifecycleTeardownReleasesStateMutex .reset
  checkLifecycleTeardownReleasesStateMutex .drop

private def failedStderrCapture
    (path : System.FilePath)
    (mode : IO.FS.Mode) : IO (BackendStderrCapture × IO.Error) :=
  IO.FS.withFile path mode fun source => do
    let capture ← startBackendStderrCapture source
    match ← capture.awaitCompletion with
    | .sourceFailed err => pure (capture, err)
    | .drained | .pipeStillOpen => throw <| IO.userError "stderr source failure fixture did not fail"

private inductive UnconfirmedProcess where
  | signalFailure
  | exitNotObserved
  | waitFailure
  deriving BEq

private inductive CleanupConsumer where
  | runtimeClose
  | readerFailure
  | reset
  | drop
  deriving BEq

private def cleanupPending (cancelRef? : Option (IO.Ref Bool) := none) : IO PendingRequest := do
  pure {
    cancelRef?
    promise := ← IO.Promise.new
    progressRef := ← IO.mkRef none
    diagnosticsRef := ← IO.mkRef #[]
    diagnosticsSeenRef := ← IO.mkRef false
    seenDiagnosticKeysRef := ← IO.mkRef {}
  }

/-- An unconfirmed process result must not skip pending settlement or independent stderr cleanup. -/
private def checkUnconfirmedCleanup
    (consumer : CleanupConsumer)
    (scenario : UnconfirmedProcess)
    (stderrFails : Bool := false) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-unconfirmed-cleanup-{← IO.monoNanosNow}"
  let workspaceId := "unconfirmed"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } workspaceId
  try
    withShutdownObservedSession workspaceId base (base / "shutdown") .stall fun initial => do
      let polls ← IO.mkRef (0 : Nat)
      let signals ← IO.mkRef (0 : Nat)
      let writes ← IO.mkRef (0 : Nat)
      -- This owner uses controlled operations only. The fixture retains its independent real
      -- child owner, which always kills and reaps the child when this scope finishes.
      let process ← BackendProcess.create 0
        (do
          polls.modify (· + 1)
          if scenario == .waitFailure then throw <| IO.userError "controlled cleanup wait failure"
          pure none)
        (do
          signals.modify (· + 1)
          if scenario == .signalFailure then throw <| IO.userError "controlled cleanup signal failure")
      let capture ←
        if stderrFails then
          Prod.fst <$> failedStderrCapture (base / "write-only-stderr") .write
        else pure initial.stderrCapture
      let session := { initial with
        proc := process
        stderrCapture := capture
        stdin := { initial.stdin with putStr := fun _ => do
          writes.modify (· + 1)
          throw <| IO.userError "controlled cleanup shutdown write failure"
        }
        stdout := { initial.stdout with
          getLine := throw <| IO.userError "controlled cleanup reader failure"
        }
      }
      let ordinary ← cleanupPending
      let cancelled ← cleanupPending (some (← IO.mkRef true))
      discard <| PendingRequestStore.register session.pending 0 ordinary
      discard <| PendingRequestStore.register session.pending 99 cancelled
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "unconfirmed cleanup workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let act := match consumer with
        | .runtimeClose => runtime.close
        | .readerFailure => sessionReaderLoop session
        | .reset => discard <| runtime.initWorkspaceWithConfig workspaceId { root := base / "new" } (some .reset)
        | .drop => discard <| runtime.dropWorkspace workspaceId
      let outcome : Except IO.Error Unit ← try act *> pure (.ok ()) catch error => pure (.error error)
      let some (some (.error pendingFailure)) ← Beam.waitTaskWithTimeout ordinary.promise.result? 1000
        | throw <| IO.userError "incomplete cleanup skipped ordinary pending settlement"
      require "unconfirmed cleanup settles pending work with a typed worker failure"
        (pendingFailure.error.code == "workerExited")
      require "unconfirmed cleanup empties the pending store"
        ((← PendingRequestStore.snapshot session.pending).isEmpty)
      match ← cancelled.awaitOutcome with
      | .error failure =>
          require "cleanup preserves cancellation precedence"
            (failure.error.code == "requestCancelled")
      | .ok _ => throw <| IO.userError "cleanup changed cancellation into success"
      let message ← match consumer, outcome with
        | .readerFailure, .ok () => pure pendingFailure.error.message
        | .readerFailure, .error error => throw error
        | _, .error (.userError message) => pure message
        | _, _ => throw <| IO.userError "unconfirmed process cleanup returned success"
      require "all teardown paths report unconfirmed process exit"
        (message.contains "backend process exit was not confirmed")
      if consumer == .readerFailure then
        require "unconfirmed termination never advertises automatic backend replacement"
          (pendingFailure.error.data?.bind (fun data =>
            (data.getObjValAs? WorkerRecovery "recovery").toOption) == some .restartWorkspace)
        require "cleanup preserves the original reader failure"
          (message.contains "controlled cleanup reader failure")
      if scenario == .signalFailure then
        require "cleanup retains the signalling failure" (message.contains "controlled cleanup signal failure")
      if scenario == .waitFailure then
        require "cleanup retains the wait failure" (message.contains "controlled cleanup wait failure")
      if stderrFails then
        require "process failure does not hide an independent stderr failure"
          (message.contains "backend stderr source failed while draining:")
      let pollCount ← polls.get
      let signalCount ← signals.get
      require "a retained wait failure forbids further raw process operations"
        (if scenario == .waitFailure then pollCount == 1 && signalCount == 0
         else signalCount == 1)
      require "failed reader or wait never enters the graceful protocol"
        ((← writes.get) == if scenario == .waitFailure || consumer == .readerFailure then 0 else 1)
      match consumer with
      | .runtimeClose =>
          let repeated : Except IO.Error Unit ←
            try runtime.close *> pure (.ok ()) catch error => pure (.error error)
          match repeated with
          | .error (.userError actual) => require "repeated close retains incomplete cleanup" (actual == message)
          | _ => throw <| IO.userError "repeated close lost its cleanup failure"
      | .reset =>
          require "failed cleanup retains the committed replacement"
            ((← runtime.workspaceRoot? workspaceId) == some (base / "new"))
      | .drop =>
          require "failed cleanup retains the committed removal"
            ((← runtime.workspaceRoot? workspaceId).isNone)
      | .readerFailure => pure ()
  finally
    try runtime.close catch _ => pure ()
    IO.FS.removeDirAll base

/-- Failed readers reject both captured and runtime requests without fencing a healthy backend. -/
private def checkFailedReaderAdmission : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-failed-reader-admission-{← IO.monoNanosNow}"
  let failedId := "failed-reader"
  let healthyId := "healthy-reader"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } failedId
  try
    let text := "def openedBeforeReaderFailure := 1\n"
    let path := base / "Open.lean"
    IO.FS.writeFile path text
    let uri := sessionUri (← IO.FS.realPath path)
    let doc ← BeamTest.Broker.DocumentFixture.accepted (DocumentState.FileSnapshot.ofText text default)
    withShutdownObservedSession failedId base (base / "failed-shutdown") .stall fun initial => do
      withShutdownObservedSession healthyId (base / "healthy") (base / "healthy-shutdown") .stall fun healthy => do
        let exitCode ← IO.mkRef (none : Option UInt32)
        let failedWrites ← IO.mkRef (0 : Nat)
        let healthyRequests ← IO.mkRef (0 : Nat)
        let cancelOnObserve ← IO.mkRef (none : Option String)
        let observationCancelled ← IO.mkRef false
        let closeAfterReply ← IO.mkRef false
        let replyCancelled ← IO.mkRef false
        -- Controlled operations leave the real child with the fixture's independent owner.
        let process ← BackendProcess.create 0
          (do
            if let some clientRequestId ← cancelOnObserve.get then
              if let some active ← ActiveRequestRegistry.markCancelled runtime.activeRequests
                  (some failedId) clientRequestId then
                observationCancelled.set (← active.cancelRef.get)
            exitCode.get)
          (throw <| IO.userError "controlled reader termination failure")
        let failed := { initial with
          proc := process
          docs := initial.docs.insert uri doc
          stdin := { initial.stdin with putStr := fun _ => failedWrites.modify (· + 1) }
          stdout := { initial.stdout with
            getLine := throw <| IO.userError "controlled admission reader failure"
          }
        }
        let healthy := { healthy with
          stdin := { healthy.stdin with putStr := fun text => do
            unless text.contains "\"method\":\"workspace/symbol\"" do
              throw <| IO.userError "unexpected healthy-backend fixture write"
            healthyRequests.modify (· + 1)
            let [_, body] := text.splitOn "\r\n\r\n"
              | throw <| IO.userError "healthy-backend fixture expected a complete LSP frame"
            let request ← IO.ofExcept <| Json.parse body
            let id ← IO.ofExcept <| request.getObjValAs? Lean.JsonRpc.RequestID "id"
            let some pending ← PendingRequestStore.remove healthy.pending id
              | throw <| IO.userError "healthy-backend request was not registered"
            PendingRequest.resolveResponse pending (Json.arr #[])
            if ← closeAfterReply.get then
              if let some active ← ActiveRequestRegistry.markCancelled runtime.activeRequests
                  (some healthyId) "cancel-after-reply" then
                replyCancelled.set (← active.cancelRef.get)
              PendingRequestStore.close healthy.pending
                (responseFailureFor .workerExited "controlled channel failure after reply")
          }
        }
        match ← runtime.initWorkspaceWithConfig healthyId { root := base / "healthy" } with
        | .ok _ => pure ()
        | .error failure => throw <| IO.userError failure.error.message
        runtime.state.atomically do
          for session in #[failed, healthy] do
            let state ← get
            let some workspace := state.workspaces.get? session.workspaceId
              | throw <| IO.userError "reader-admission fixture workspace is missing"
            let session := { session with workspaceGeneration := workspace.generation }
            let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
            set { state with workspaces := state.workspaces.insert session.workspaceId workspace }
        let ordinary ← cleanupPending
        require "reader-admission fixture registers ordinary pending work"
          (← PendingRequestStore.register failed.pending 0 ordinary)
        sessionReaderLoop failed
        let some (some (.error failure)) ← Beam.waitTaskWithTimeout ordinary.promise.result? 1000
          | throw <| IO.userError "reader failure did not settle admitted work"
        require "reader failure retains its typed cause and incomplete cleanup"
          (failure.error.code == "workerExited" &&
            failure.error.message.contains "controlled admission reader failure" &&
            failure.error.message.contains "backend process exit was not confirmed")
        require "unconfirmed reader termination explains workspace recovery"
          (failure.error.message.contains "drop this workspace" &&
            failure.error.message.contains "lean-beam --root <workspace-root> stop" &&
            failure.error.message.contains "lean-beam --root <workspace-root> serve")
        require "failed-reader fixture still has unconfirmed process exit" ((← process.observe).isNone)
        let lateTask ← IO.asTask (prio := Task.Priority.dedicated) <|
          sendRequestJsonTrackedDetailed failed "textDocument/hover" Json.null
        try
          let some (.ok (.error actual)) ← Beam.waitTaskWithTimeout lateTask 1000
            | throw <| IO.userError "failed reader admitted a request without a response consumer"
          require "captured session retains the typed reader failure"
            (toJson actual.error == toJson failure.error)
        finally
          PendingRequestStore.close failed.pending failure
          discard <| IO.wait lateTask
        -- A document close sends only a notification, so request registration cannot reject it.
        let rejectedClose ← runtime.dispatchRequest {
          workspaceId? := some failedId
          payload := .close { path := "Open.lean" }
        }
        require "failed reader rejects notification-only close with the retained failure"
          (rejectedClose.error?.any fun actual => toJson actual == toJson failure.error)
        require "rejected notification-only close does not write" ((← failedWrites.get) == 0)
        runtime.state.atomically do
          let some session := (← get).workspaces.get? failedId |>.bind (·.lean.session?)
            | throw <| IO.userError "rejected notification-only close detached the failed session"
          require "rejected notification-only close preserves the opened document"
            (session.docs.contains uri)
        let rejected ← runtime.dispatchRequest {
          workspaceId? := some failedId
          payload := .workspaceSymbols { query := "failed" }
        }
        require "runtime rejects reuse with the original typed reader failure"
          (rejected.error?.any fun actual => toJson actual == toJson failure.error)
        -- Cancellation can be marked while observation holds the broker state mutex, before
        -- cancellation forwarding can acquire that mutex. Both request kinds use the same policy.
        for (clientRequestId, payload) in #[
            ("cancel-query", RequestPayload.workspaceSymbols { query := "cancelled" }),
            ("cancel-close", RequestPayload.close { path := "Open.lean" })
          ] do
          observationCancelled.set false
          cancelOnObserve.set (some clientRequestId)
          let cancelled ← runtime.dispatchRequest {
            workspaceId? := some failedId
            clientRequestId? := some clientRequestId
            payload
          }
          cancelOnObserve.set none
          require "process observation marked the exact active cancellation identity"
            (← observationCancelled.get)
          require "marked cancellation wins retained-channel rejection"
            (cancelled.error?.any (·.code == "requestCancelled"))
        let unmarked ← runtime.dispatchRequest {
          workspaceId? := some failedId
          payload := .workspaceSymbols { query := "unmarked" }
        }
        require "cancelled callers do not change the shared reader failure"
          (unmarked.error?.any fun actual => toJson actual == toJson failure.error)
        runtime.state.atomically do
          let some session := (← get).workspaces.get? failedId |>.bind (·.lean.session?)
            | throw <| IO.userError "cancelled close detached the failed session"
          require "cancelled notification-only close preserves the opened document"
            (session.docs.contains uri)
        let answered ← runtime.dispatchRequest {
          workspaceId? := some healthyId
          payload := .workspaceSymbols { query := "healthy" }
        }
        let healthyRequestCount ← healthyRequests.get
        require "reader failure leaves an unrelated active backend usable"
          (answered.ok && healthyRequestCount == 1)
        -- A backend reply can succeed before a later channel failure rejects broker finalization.
        closeAfterReply.set true
        let cancelledAfterReply ← runtime.dispatchRequest {
          workspaceId? := some healthyId
          clientRequestId? := some "cancel-after-reply"
          payload := .workspaceSymbols { query := "answered-before-failure" }
        }
        require "reply fixture marked the active cancellation identity" (← replyCancelled.get)
        require "later session validation uses the same channel-failure cancellation policy"
          (cancelledAfterReply.error?.any (·.code == "requestCancelled"))
        require "later validation follows a completed backend exchange" ((← healthyRequests.get) == 2)
        let retained ← PendingRequestStore.failure? healthy.pending
        require "later cancellation preserves the shared channel failure"
          (retained.any fun actual => actual.error.code == "workerExited" &&
            actual.error.message == "controlled channel failure after reply")
        exitCode.set (some 0)
        let recovered ← runtime.dispatchRequest {
          workspaceId? := some failedId
          payload := .close { path := "Open.lean" }
        }
        require "confirmed exit permits detachment of a failed reader" recovered.ok
        runtime.state.atomically do
          let some workspace := (← get).workspaces.get? failedId
            | throw <| IO.userError "recovered reader-admission workspace is missing"
          require "confirmed exit clears the failed session and advances its epoch"
            (workspace.lean.session?.isNone && workspace.lean.nextEpoch == 3)
        require "terminally rejected requests and retained exit never write to the failed channel"
          ((← failedWrites.get) == 0)
  finally
    try runtime.close catch _ => pure ()
    IO.FS.removeDirAll base

private def checkLifecycleCleanupFailureCommits
    (kind : LifecycleTeardown)
    (behavior : ShutdownBehavior := .exit) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-{kind.label}-cleanup-failure-{← IO.monoNanosNow}"
  let workspaceId := "cleanup-failure"
  let oldRoot := base / "old"
  let replacement : BrokerConfig := { root := base / "replacement" }
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := oldRoot } workspaceId
  try
    let (capture, sourceFailure) ← failedStderrCapture (base / "write-only-source") .write
    withShutdownObservedSession workspaceId oldRoot (base / "shutdown") behavior fun session => do
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "cleanup failure fixture workspace is missing"
        let session := { session with stderrCapture := capture }
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let outcome ←
        try
          pure (.ok (← runLifecycleTeardown kind runtime workspaceId replacement) :
            Except IO.Error (Except ResponseFailure Bool))
        catch err => pure (.error err)
      match outcome with
      | .error (.userError message) =>
          require s!"{kind.label}: cleanup preserves its typed I/O failure"
            (message == s!"backend stderr source failed while draining: {sourceFailure}")
      | _ => throw <| IO.userError s!"{kind.label}: expected the cleanup I/O failure"
      match behavior with
      | .exit => pure ()
      | .stall =>
          let status ← IO.Process.output {
            cmd := "ps"
            args := #["-p", toString session.proc.pid, "-o", "stat="]
          }
          require "forced cleanup kills and reaps a backend that ignores SIGTERM" (status.exitCode != 0)
      runtime.state.atomically do
        let workspace? := (← get).workspaces.get? workspaceId
        match kind, workspace? with
        | .reset, some workspace =>
            require "failed reset cleanup retains the replacement root"
              (workspace.config.root == replacement.root)
            require "failed reset cleanup retains the fresh generation" (workspace.generation != 1)
            require "failed reset cleanup never restores the detached session"
              (workspace.lean.session?.isNone && workspace.lean.nextEpoch == 1)
        | .drop, none => pure ()
        | _, _ => throw <| IO.userError s!"{kind.label}: cleanup failure rolled back workspace state"
  finally
    try
      runtime.close
    finally
      IO.FS.removeDirAll base

private def checkRuntimeCloseDetachesAllSessions (failShutdown : Bool) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-close-sessions-{← IO.monoNanosNow}"
  let shutdownLog := base / "shutdown-order"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base / "first" } "first"
  try
    for workspaceId in ["idle", "last"] do
      match ← runtime.initWorkspaceWithConfig workspaceId { root := base / workspaceId } with
      | .ok _ => pure ()
      | .error failure => throw <| IO.userError failure.error.message
    withShutdownObservedSession "first" (base / "first") shutdownLog .exit fun firstSession =>
      withShutdownObservedSession "last" (base / "last") shutdownLog .exit fun lastSession => do
        let mut firstFailure? : Option IO.Error := none
        for (workspaceId, initialSession) in [("first", firstSession), ("last", lastSession)] do
          let mut session := initialSession
          if failShutdown then
            -- A write-only file and a directory fail differently on read, without platform-specific
            -- errno assertions. Both captures finish before close so this test has no timing race.
            let (capture, sourceFailure) ←
              if workspaceId == "first" then
                failedStderrCapture (base / "write-only-source") .write
              else
                failedStderrCapture base .read
            let failureMessage := s!"backend stderr source failed while draining: {sourceFailure}"
            if let some (.userError firstMessage) := firstFailure? then
              require "shutdown failures must distinguish first from last"
                (failureMessage != firstMessage)
            firstFailure? := firstFailure? <|> some (IO.userError failureMessage)
            session := { session with stderrCapture := capture }
          runtime.state.atomically do
            let state ← get
            let some workspace := state.workspaces.get? workspaceId
              | throw <| IO.userError "close fixture workspace is missing"
            let session := { session with workspaceGeneration := workspace.generation }
            let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
            set { state with workspaces := state.workspaces.insert workspaceId workspace }
        -- Both close calls must preserve the first typed failure instead of skipping a later session,
        -- replacing it with the last failure, or turning the repeated close into a success.
        for _ in [:2] do
          let outcome ←
            try
              runtime.close
              pure (.ok () : Except IO.Error Unit)
            catch err => pure (.error err)
          match firstFailure?, outcome with
          | none, .ok () => pure ()
          | some (.userError expected), .error (.userError actual) =>
              require "runtime close retains the first typed shutdown failure" (actual == expected)
          | _, _ => throw <| IO.userError "runtime close changed its typed shutdown outcome"
          require "runtime close shuts down sessions once in workspace order, including after a failure"
            ((← IO.FS.readFile shutdownLog) == "first\nlast\n")
        -- Repeated close must neither detach again nor advance an idle workspace's epoch.
        runtime.state.atomically do
          let state ← get
          for (workspaceId, expectedEpoch) in [("first", 3), ("idle", 1), ("last", 3)] do
            let some workspace := state.workspaces.get? workspaceId
              | throw <| IO.userError "runtime close erased a workspace"
            require s!"runtime close detaches {workspaceId}'s session" workspace.lean.session?.isNone
            require s!"runtime close advances {workspaceId}'s epoch exactly once"
              (workspace.lean.nextEpoch == expectedEpoch)
  finally
    try
      runtime.close
    catch _ =>
      pure ()
    finally
      IO.FS.removeDirAll base

private def checkDeadSessionCleanupReleasesStateMutex : IO Unit := do
  let nonce ← IO.monoNanosNow
  let targetId := "dead-session-target"
  let observerId := "dead-session-observer"
  let targetRoot := System.FilePath.mk s!"/tmp/beam-dead-session-target-{nonce}"
  let replacementRoot := System.FilePath.mk s!"/tmp/beam-dead-session-replacement-{nonce}"
  let observerRoot := System.FilePath.mk s!"/tmp/beam-dead-session-observer-{nonce}"
  let pipesReady := System.FilePath.mk s!"/tmp/beam-dead-session-pipes-{nonce}"
  let release := System.FilePath.mk s!"/tmp/beam-dead-session-release-{nonce}"
  let done := System.FilePath.mk s!"/tmp/beam-dead-session-done-{nonce}"
  let targetConfig : BrokerConfig := { root := targetRoot }
  let replacementConfig : BrokerConfig := { root := replacementRoot }
  let observerConfig : BrokerConfig := { root := observerRoot }
  let runtime ← ServerRuntime.create targetConfig targetId
  let session ← exitedSessionWithInheritedStdio targetId targetRoot pipesReady release done
  unless ← waitForPath pipesReady do
    throw <| IO.userError "dead-session fixture did not retain its inherited pipes"
  let cleanupPending : PendingRequest := {
    promise := ← IO.Promise.new
    progressRef := ← IO.mkRef none
    diagnosticsRef := ← IO.mkRef #[]
    diagnosticsSeenRef := ← IO.mkRef false
    seenDiagnosticKeysRef := ← IO.mkRef {}
  }
  discard <| PendingRequestStore.register session.pending 0 cleanupPending
  runtime.state.atomically do
    let state ← get
    let targetWorkspace : WorkspaceState := {
      generation := 1
      config := targetConfig
      lean := { nextEpoch := 2, session? := some session }
    }
    let observerWorkspace : WorkspaceState := { generation := 2, config := observerConfig }
    let workspaces := state.workspaces.insert targetId targetWorkspace
    let workspaces := workspaces.insert observerId observerWorkspace
    set { state with workspaces }
  let closeTask ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequest {
    payload := .close { path := "Dead.lean" }
    workspaceId? := some targetId
  }
  try
    -- Pending settlement precedes stderr draining; no shutdown write is needed for an exited child.
    let some (some (.error failure)) ←
        Beam.waitTaskWithTimeout cleanupPending.promise.result? 5000
      | throw <| IO.userError "dead-session cleanup did not settle its pending request"
    require "dead-session cleanup settles pending work before waiting on inherited pipes"
      (failure.error.code == "workerExited")
    require "dead-session cleanup fixture should retain the inherited pipes"
      (!(← IO.hasFinished closeTask))

    match ← runtime.initWorkspaceWithConfig targetId replacementConfig (some .reset) with
    | .error failure =>
        throw <| IO.userError s!"dead-session workspace reset failed: {failure.error.message}"
    | .ok result =>
        require "dead-session workspace reset should invalidate the old generation"
          result.invalidatedHandles
    require "dead-session workspace reset should finish before cleanup"
      (!(← IO.hasFinished closeTask))
    require "dead-session workspace reset should retain its replacement root"
      ((← runtime.workspaceRoot? targetId) == some replacementRoot)

    let queryTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      runtime.workspaceRoot? observerId
    let some queryOutcome ← waitForTaskBefore queryTask closeTask
      | throw <| IO.userError "unrelated workspace query blocked on dead-session cleanup"
    let queryRoot ←
      match queryOutcome with
      | .ok queryRoot => pure queryRoot
      | .error err => throw err
    require "unrelated workspace query should retain its root"
      (queryRoot == some observerRoot)
    require "unrelated workspace query should finish before dead-session cleanup"
      (!(← IO.hasFinished closeTask))

    let response ← IO.ofExcept <| ← IO.wait closeTask
    require "an old-generation close should be rejected after reset"
      (response.error?.any fun err =>
        err.code == "contentModified" && err.message.contains "changed while")
    let replacement ← runtime.state.atomically do
      let state ← get
      let some workspace := state.workspaces.get? targetId
        | throw <| IO.userError "replacement workspace disappeared after old-generation close"
      pure workspace
    require "an old-generation close should not alter the replacement root"
      (replacement.config.root == replacementRoot)
    require "an old-generation close should not restore its detached session"
      replacement.lean.session?.isNone
    require "an old-generation close should not update replacement metrics"
      (replacement.metrics.requestCount == 0)
  finally
    if !(← release.pathExists) then
      IO.FS.writeFile release "release"
    discard <| waitForPath done
    try
      runtime.close
    catch _ =>
      pure ()
    for path in [pipesReady, done] do
      if ← path.pathExists then
        IO.FS.removeFile path

/-- Observe exit without consuming the child's wait status. -/
private partial def waitForUnreapedExit
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (tries : Nat := 200) : IO Unit := do
  let status ← IO.Process.output {
    cmd := "ps"
    args := #["-p", toString (Beam.processChildPid child), "-o", "stat="]
  }
  if status.exitCode == 0 && status.stdout.trimAscii.toString.startsWith "Z" then
    pure ()
  else if tries == 0 then
    throw <| IO.userError "owned fixture process did not exit before cleanup"
  else
    IO.sleep 10
    waitForUnreapedExit child (tries - 1)

private inductive ExitedSessionCleanup where
  | request
  | runtimeClose

private def checkExitedSessionCleanupFailure
    (alreadyObserved : Bool)
    (cleanup : ExitedSessionCleanup := .request) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-exited-cleanup-{← IO.monoNanosNow}"
  let workspaceId := "exited-cleanup"
  IO.FS.createDirAll base
  let runtime ← ServerRuntime.create { root := base } workspaceId
  try
    let (capture, sourceFailure) ← failedStderrCapture (base / "write-only-source") .write
    withFixtureChild {
      toStdioConfig := brokerStdio
      cmd := "python3"
      args := #["-c", "import sys; sys.exit(23)"]
    } fun child proc => do
      waitForUnreapedExit child
      if alreadyObserved then
        let some (.exited 23) ← proc.observe
          | throw <| IO.userError "fixture did not retain its distinct exit status"
      let writes ← IO.mkRef (0 : Nat)
      let stdin : IO.FS.Stream := { IO.FS.Stream.ofHandle child.stdin with
        putStr := fun _ => do
          writes.modify (· + 1)
          throw <| IO.userError "cannot write to an exited fixture"
      }
      let session : Session := {
        workspaceId
        workspaceGeneration := 1
        root := base
        epoch := 1
        sessionToken := "exited-cleanup"
        proc
        stdin
        stdout := IO.FS.Stream.ofHandle child.stdout
        stderrCapture := capture
        pending := ← PendingRequestStore.create
      }
      let pending : PendingRequest := {
        promise := ← IO.Promise.new
        progressRef := ← IO.mkRef none
        diagnosticsRef := ← IO.mkRef #[]
        diagnosticsSeenRef := ← IO.mkRef false
        seenDiagnosticKeysRef := ← IO.mkRef {}
      }
      discard <| PendingRequestStore.register session.pending 0 pending
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "exited cleanup fixture workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      let expected := s!"backend stderr source failed while draining: {sourceFailure}"
      match cleanup with
      | .request =>
          let response ← runtime.dispatchRequest {
            workspaceId? := some workspaceId
            payload := .close { path := "Dead.lean" }
          }
          require "exited-session cleanup retains stderr source failures, including after an earlier reap"
            (response.error?.any fun error => error.code == "internalError" &&
              error.message.contains expected)
      | .runtimeClose =>
          let outcome : Except IO.Error Unit ←
            try
              runtime.close
              pure (.ok ())
            catch err => pure (.error err)
          match outcome with
          | .error (.userError actual) =>
              require "runtime close preserves an exited worker's stderr source failure" (actual == expected)
          | _ => throw <| IO.userError "exited-worker runtime close lost its stderr source failure"
      require "exited-session cleanup never writes shutdown or exit messages" ((← writes.get) == 0)
      require "exited-session cleanup leaves no pending requests without a reader"
        ((← PendingRequestStore.snapshot session.pending).isEmpty)
      let some (some (.error failure)) ← Beam.waitTaskWithTimeout pending.promise.result? 5000
        | throw <| IO.userError "exited-session cleanup did not resolve its pending request"
      require "exited-session cleanup reports a typed worker exit to its pending request"
        (failure.error.code == "workerExited")
      require "exited-session cleanup retains the original exit status after an earlier observation"
        (failure.error.message == "backend process exited with code 23")
      runtime.state.atomically do
        let some workspace := (← get).workspaces.get? workspaceId
          | throw <| IO.userError "exited cleanup removed its workspace"
        require "exited-session cleanup detaches exactly once"
          (workspace.lean.session?.isNone && workspace.lean.nextEpoch == 3)
  finally
    try
      runtime.close
    catch _ => pure ()
    IO.FS.removeDirAll base

private def documentAdmissionRequests (workspaceId path : String) : Array Request :=
  let handle := { sampleHandle with workspaceId }
  let requests : Array Request := #[
    Beam.Cli.leanUpdateRequest path,
    Beam.Cli.leanSyncRequest path .errors,
    Beam.Cli.leanRefreshRequest path .errors,
    Beam.Cli.leanRunAtRequest path 1 0 0 "#check Nat",
    Beam.Cli.leanHoverRequest path 1 0 0,
    Beam.Cli.leanDocumentSymbolsRequest path 1,
    { payload := .codeActionResolve { path, version := 1, codeAction := { title := "fixture" } } },
    { payload := .goals { path, version := 1, line := 0, character := 0 } },
    Beam.Cli.leanRunWithRequest path handle "skip",
    Beam.Cli.leanReleaseRequest path handle,
    Beam.Cli.leanSaveRequest path .errors,
    Beam.Cli.leanCloseSaveRequest path .errors
  ]
  requests.map fun request => { request with workspaceId? := some workspaceId }

private def requireDocumentBoundaryFailure
    (root path : System.FilePath) (response : Response) : IO Unit := do
  discard <| requireError "document admission" "invalidParams"
    s!"document '{path}' resolves outside workspace root '{root}'; select a workspace containing the document"
    response

private def admissionSymlink (target link : System.FilePath) : IO Unit := do
  let result ← IO.Process.output { cmd := "ln", args := #["-s", target.toString, link.toString] }
  require "document admission fixture creates its owned symlink" (result.exitCode == 0)

private def heldSourceWriter
    (fifo writerReady releaseWriter : System.FilePath) : IO.Process.SpawnArgs := {
  cmd := "python3"
  args := #["-c",
    "import pathlib, sys, time\nwith open(sys.argv[1], 'w') as stream:\n pathlib.Path(sys.argv[2]).write_text('ready')\n while not pathlib.Path(sys.argv[3]).exists(): time.sleep(0.01)\n stream.write('def admittedFixture : Nat := 1\\n')",
    fifo.toString, writerReady.toString, releaseWriter.toString]
}

/-- Capture one real regular-file read, then hold only its return; later reads remain independent. -/
private def heldSourceRead (path : System.FilePath) :
    IO ((System.FilePath → IO ByteArray) × Task (Option Unit) × IO Unit) := do
  let path ← Beam.resolveExistingPath path
  let armed ← Std.Mutex.new true
  let entered ← IO.Promise.new
  let released ← IO.Promise.new
  let readSource := fun selected => do
    let bytes ← IO.FS.readBinFile selected
    let hold ← armed.atomically do
      let active ← get
      let hold := active && Beam.sameCanonicalPath selected path
      if hold then set false
      pure hold
    if hold then
      entered.resolve ()
      discard <| IO.wait released.result?
    pure bytes
  pure (readSource, entered.result?, do released.resolve ())

/-- A controlled LSP channel records document operations and answers the real sync barrier. -/
private def withDocumentAdmissionSession
    (root : System.FilePath)
    (act : ServerRuntime → IO.Ref (Array (String × Json)) → IO Unit)
    (replyBarrier : PendingRequest → Json → IO Unit := PendingRequest.resolveResponse)
    (readSource : System.FilePath → IO ByteArray := IO.FS.readBinFile) : IO Unit := do
  let workspaceId := "document-admission"
  let runtime ← ServerRuntime.create { root } workspaceId (readSource := readSource)
  try
    withShutdownObservedSession workspaceId root (root / "shutdown") .exit fun initial => do
      let writes ← IO.mkRef (#[] : Array (String × Json))
      let opened ← IO.mkRef (none : Option TextDocumentItem)
      let session := { initial with stdin := { initial.stdin with putStr := fun text => do
        let [_, body] := text.splitOn "\r\n\r\n"
          | throw <| IO.userError "document admission fixture expected one complete LSP frame"
        let message ← IO.ofExcept <| Json.parse body
        let method ← IO.ofExcept <| message.getObjValAs? String "method"
        writes.modify (·.push (method, message))
        if method == "textDocument/didOpen" then
          let params ← IO.ofExcept <| message.getObjVal? "params"
          let params : DidOpenTextDocumentParams ← IO.ofExcept <| fromJson? params
          opened.set (some params.textDocument)
        else if method == "textDocument/didChange" then
          let params ← IO.ofExcept <| message.getObjVal? "params"
          let document ← IO.ofExcept <| params.getObjVal? "textDocument"
          let changes ← IO.ofExcept <| params.getObjValAs? (Array Json) "contentChanges"
          let [change] := changes.toList
            | throw <| IO.userError "document admission fixture expected one full change"
          opened.set <| some {
            uri := ← IO.ofExcept <| document.getObjValAs? String "uri"
            languageId := "lean"
            version := ← IO.ofExcept <| document.getObjValAs? Nat "version"
            text := ← IO.ofExcept <| change.getObjValAs? String "text"
          }
        else if method == diagnosticsBarrierMethod || method == "shutdown" then
          let id ← IO.ofExcept <| message.getObjValAs? Lean.JsonRpc.RequestID "id"
          let some pending ← PendingRequestStore.remove initial.pending id
            | throw <| IO.userError "document admission fixture request was not registered"
          if method == "shutdown" then
            PendingRequest.resolveResponse pending Json.null
          else
            let some document ← opened.get
              | throw <| IO.userError "document admission barrier preceded didOpen"
            let barrier : DiagnosticsBarrierResult := {
              version := document.version
              hasFatalSnapshot := false
              saveReadiness := {
                version := document.version
                textHash := hash document.text.crlfToLf
              }
            }
            replyBarrier pending (toJson barrier)
        else if method == "exit" then
          initial.stdin.putStr "\n"
      } }
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "document admission fixture workspace is missing"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        set { state with workspaces := state.workspaces.insert workspaceId workspace }
      try act runtime writes
      finally runtime.close
  finally runtime.close

private def requireSourceInputFailure (label : String) (response : Response) : IO Unit := do
  let some error := response.error?
    | throw <| IO.userError s!"{label}: expected a document input failure"
  require s!"{label}: expected invalidParams, got {error.code}: {error.message}"
    (error.code == "invalidParams")

private def requireReleasedDocumentScopes (label : String) (runtime : ServerRuntime) : IO Unit :=
  runtime.state.atomically do
    for (_, workspace) in (← get).workspaces.toList do
      require s!"{label}: document scopes are released" workspace.documents.entries.isEmpty

private def checkDocumentSourceInputs : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-source-inputs-{← IO.monoNanosNow}"
  IO.FS.createDirAll base
  let root ← Beam.resolveExistingPath base
  let main := root / "Main.lean"
  let reads ← IO.mkRef (0 : Nat)
  let readSource := fun (path : System.FilePath) => do
    reads.modify (· + 1)
    -- Record a forbidden call before an assertion that the handler may catch; never block on FIFO.
    require "a content reader receives only regular sources" ((← path.metadata).type == .file)
    IO.FS.readBinFile path
  let cold ← ServerRuntime.create { root } "document-admission" (readSource := readSource)
  try
    IO.FS.writeFile main "def sourceInputFixture : Nat := 1\n"
    IO.FS.writeFile (root / "notes.txt") "ordinary notes\n"
    IO.FS.writeFile (root / "UPPER.LEAN") "def uppercaseFixture := 1\n"
    IO.FS.createDirAll (root / "Directory.lean")
    admissionSymlink main (root / "Alias.txt")
    admissionSymlink (root / "notes.txt") (root / "Notes.lean")
    admissionSymlink (root / "Missing.lean") (root / "Dangling.lean")
    admissionSymlink (root / "Loop.lean") (root / "Loop.lean")
    let fifo := root / "Stream.lean"
    let made ← IO.Process.output { cmd := "mkfifo", args := #[fifo.toString] }
    require "source-kind fixture creates a nonregular input" (made.exitCode == 0)
    let rejected := #["Missing.lean", "Absent/Child.lean", "Absent/../Main.lean", "Main.lean/x", "",
      "Directory.lean", "notes.txt", "UPPER.LEAN", "Notes.lean", "Dangling.lean",
      "Loop.lean", "Loop.lean/Child.lean", "Stream.lean"]
    for path in rejected do
      for request in documentAdmissionRequests "document-admission" path do
        let response ← cold.dispatchRequest request
        requireSourceInputFailure s!"cold source {path}" response
        if #["Missing.lean", "Absent/Child.lean", "Absent/../Main.lean", "Dangling.lean"].contains path then
          require "missing sources are reported directly"
            (response.error?.any (·.message.contains "does not exist"))
        if #["Loop.lean", "Loop.lean/Child.lean"].contains path then
          require "unresolvable sources are not reported as missing"
            (response.error?.any (·.message.contains "cannot be resolved"))
        requireReleasedDocumentScopes "rejected cold source" cold
    let denied := root / "Denied"
    let deniedSource := denied / "Main.lean"
    IO.FS.createDir denied
    IO.FS.writeFile deniedSource "def deniedSourceFixture := 1\n"
    let restricted ← IO.Process.output { cmd := "chmod", args := #["000", denied.toString] }
    require "restrict source ancestor permissions" (restricted.exitCode == 0)
    try
      match ← deniedSource.metadata.toBaseIO with
      | .error (.permissionDenied ..) =>
          let response ← cold.dispatchRequest {
            workspaceId? := some "document-admission"
            payload := .updateFile { path := deniedSource.toString }
          }
          require "source resolution preserves a genuine permission failure"
            (response.error?.any (·.code == "internalError"))
          requireReleasedDocumentScopes "inaccessible source" cold
          IO.println "source permission fixture: inaccessible ancestor retains internalError"
      | .ok _ =>
          IO.println "source permission fixture: process can access restricted ancestor; skipped"
      | .error error => throw error
    finally
      let restored ← IO.Process.output { cmd := "chmod", args := #["700", denied.toString] }
      require "restore source ancestor permissions" (restored.exitCode == 0)
    require "rejected source inputs never invoke the content reader" ((← reads.get) == 0)
    cold.state.atomically do
      let some workspace := (← get).workspaces.get? "document-admission"
        | throw <| IO.userError "source-input workspace is missing"
      require "rejected source inputs never allocate a backend"
        (workspace.lean.session?.isNone && workspace.metrics.sessionStarts == 0)
    withDocumentAdmissionSession root (readSource := readSource) fun runtime writes => do
      for path in #["Main.lean", "Alias.txt"] do
        require "aliases follow the canonical Lean target" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .updateFile { path }
        }).ok
      require "aliases of one Lean target share didOpen"
        ((← writes.get).map Prod.fst == #["textDocument/didOpen", importBasisCaptureMethod])
      for (path, text) in #[("Empty.lean", ""), ("Space λ.lean", "-- λ\r\ndef crlfFixture := 1\r\n"),
          ("Malformed.lean", "this is not valid Lean\n")] do
        IO.FS.writeFile (root / path) text
        require "source admission does not filter source contents" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .updateFile { path }
        }).ok
      let before ← writes.get
      let readCount ← reads.get
      for path in rejected do
        for request in documentAdmissionRequests "document-admission" path do
          requireSourceInputFailure s!"warm source {path}" (← runtime.dispatchRequest request)
      require "rejected warm inputs do not read source" ((← reads.get) == readCount)
      require "rejected warm inputs do not write document operations" ((← writes.get) == before)
      requireReleasedDocumentScopes "rejected warm source" runtime
      -- A formerly admitted source can cease to be a regular file; cleanup still owns its URI.
      IO.FS.removeFile main
      IO.FS.createDir main
      requireSourceInputFailure "refresh of a replaced source" (← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .refreshFile { path := "Main.lean" }
      })
      require "failed refresh preserves the tracked document" ((← writes.get) == before)
      for (path, closed) in #[("Never.lean", false), ("notes.txt", false),
          ("Main.lean", true), ("Main.lean", false)] do
        let result ← requireResponseResult "plain close removal" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .close { path }
        })
        requireJsonBool "plain close removal" "closed" closed result
      require "plain close sends exactly one didClose"
        (((← writes.get).filter (fun write => write.1 == "textDocument/didClose")).size == 1)
      require "cleanup never reads contents" ((← reads.get) == readCount)
      requireSourceInputFailure "an unresolvable cleanup path" (← runtime.dispatchRequest {
        workspaceId? := some "document-admission"
        payload := .close { path := "Absent/../Main.lean" }
      })
      requireReleasedDocumentScopes "plain close" runtime
  finally
    try cold.close
    finally IO.FS.removeDirAll base

private def checkSourceEncoding : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-source-encoding-{← IO.monoNanosNow}"
  IO.FS.createDirAll base
  let root ← Beam.resolveExistingPath base
  let path := root / "Encoding.lean"
  let source := "-- valid λ\r\ndef encodingFixture := 1\r\n"
  let invalid := ByteArray.mk #[0xff]
  let requireEncodingFailure := fun label response => do
    requireSourceInputFailure label response
    require s!"{label}: identifies invalid encoding"
      (response.error?.any (·.message.contains "not valid UTF-8"))
  let cold ← ServerRuntime.create { root } "document-admission"
  try
    IO.FS.writeBinFile path invalid
    for request in documentAdmissionRequests "document-admission" path.toString do
      requireEncodingFailure "cold source encoding" (← cold.dispatchRequest request)
    requireReleasedDocumentScopes "cold source encoding" cold
    cold.state.atomically do
      let some workspace := (← get).workspaces.get? "document-admission"
        | throw <| IO.userError "source-encoding workspace is missing"
      require "invalid source encoding never allocates a backend"
        (workspace.lean.session?.isNone && workspace.metrics.sessionStarts == 0)
    withDocumentAdmissionSession root fun runtime writes => do
      IO.FS.writeFile path source
      let before ← requireResponseResult "valid UTF-8 source" (← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .updateFile { path := path.toString }
      })
      let version ← IO.ofExcept <| before.getObjValAs? Nat "version"
      let sent ← writes.get
      IO.FS.writeBinFile path invalid
      for request in documentAdmissionRequests "document-admission" path.toString do
        requireEncodingFailure "warm source encoding" (← runtime.dispatchRequest request)
      require "invalid source encoding preserves the tracked document" ((← writes.get) == sent)
      requireReleasedDocumentScopes "warm source encoding" runtime
      IO.FS.writeFile path source
      let repaired ← requireResponseResult "repaired UTF-8 source" (← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .updateFile { path := path.toString }
      })
      require "repair preserves the last accepted source version"
        ((← IO.ofExcept <| repaired.getObjValAs? Nat "version") == version)
      requireJsonBool "repair preserves the last accepted source contents" "changed" false repaired
      IO.FS.writeBinFile path invalid
      for closed in #[true, false] do
        let result ← requireResponseResult "close an invalid UTF-8 source" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .close { path := path.toString }
        })
        requireJsonBool "close an invalid UTF-8 source" "closed" closed result
      require "invalid source cleanup sends exactly one didClose"
        ((← writes.get).map Prod.fst == (sent.map Prod.fst).push "textDocument/didClose")
      requireReleasedDocumentScopes "invalid source cleanup" runtime
  finally
    try cold.close
    finally IO.FS.removeDirAll base

private def checkSourceObservationFailures : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-source-observation-{← IO.monoNanosNow}"
  IO.FS.createDirAll base
  let root ← Beam.resolveExistingPath base
  let path := root / "Fault.lean"
  let errors : Array (String × Option IO.Error) := #[
    ("deleted during read", none),
    ("permission", some <| .permissionDenied (some path.toString) 0 "fixture permission failure"),
    ("resource", some <| .resourceExhausted (some path.toString) 0 "fixture resource failure"),
    ("hardware", some <| .hardwareFault 0 "fixture hardware failure"),
    ("invalid read argument", some <| .invalidArgument (some path.toString) 0 "fixture read failure"),
    ("unexpected reader fault", some <| .userError "fixture unexpected reader fault")
  ]
  try
    for (label, error?) in errors do
      IO.FS.writeFile path "def observationFixture := 1\n"
      let reads ← IO.mkRef (0 : Nat)
      let readSource := fun selected => do
        reads.modify (· + 1)
        let bytes ← IO.FS.readBinFile selected
        if let some error := error? then throw error
        -- Exercise the actual mtime race, after strict admission and a successful content read.
        IO.FS.removeFile selected
        pure bytes
      withDocumentAdmissionSession root (readSource := readSource) fun runtime writes => do
        let response ← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .updateFile { path := path.toString }
        }
        let some error := response.error?
          | throw <| IO.userError s!"{label}: expected an observation failure"
        require s!"{label}: preserves the observation failure category"
          (error.code == if error?.isNone then "invalidParams" else "internalError")
        require s!"{label}: exercises a real content read" ((← reads.get) == 1)
        require s!"{label}: failure precedes backend document writes" (← writes.get).isEmpty
        requireReleasedDocumentScopes label runtime
  finally IO.FS.removeDirAll base

private def checkDocumentAdmission : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-document-admission-{← IO.monoNanosNow}"
  let selectedRoot := base / "workspace"
  let external := base / "external"
  let sibling := base / "workspace-other"
  IO.FS.createDirAll (selectedRoot / "sub")
  IO.FS.createDirAll (external / "nested")
  IO.FS.createDirAll sibling
  let root ← Beam.resolveExistingPath selectedRoot
  let inside := root / "Main.lean"
  let outside := external / "Other.lean"
  let source := "def admissionFixture : Nat := 1\n"
  try
    for path in #[inside, outside, external / "nested" / "Other.lean", sibling / "Other.lean"] do
      IO.FS.writeFile path source
    admissionSymlink inside (root / "inside-alias.lean")
    admissionSymlink outside (root / "outside-alias.lean")
    admissionSymlink (external / "nested") (root / "outside-directory")
    admissionSymlink (root / "sub") (base / "root-alias")
    admissionSymlink root (base / "workspace-alias")
    let cold ← ServerRuntime.create { root } "document-admission"
    try
      for path in #[outside.toString, (sibling / "Other.lean").toString,
          "../external/Other.lean", "outside-alias.lean", "outside-directory/Other.lean",
          "outside-directory/../Other.lean",
          (base / "root-alias" / ".." / ".." / "external" / "Other.lean").toString] do
        let canonical ← Beam.resolvePathAgainstRoot root (System.FilePath.mk path)
        for request in documentAdmissionRequests "document-admission" path do
          requireDocumentBoundaryFailure root canonical (← cold.dispatchRequest request)
      require "plain close permits cleanup without opening an external document"
        (← cold.dispatchRequest {
          workspaceId? := some "document-admission"
          payload := .close { path := outside.toString }
        }).ok
      let stats ← requireResponseResult "rejected document stats" <|
        ← cold.dispatchRequest { Request.stats with workspaceId? := some "document-admission" }
      let session ← requireObjVal "rejected document stats" "session" stats
      requireJsonBool "rejected document session" "active" false session
      let metrics ← requireObjVal "rejected document stats" "metrics" stats
      require "rejected documents start no session"
        ((← IO.ofExcept <| metrics.getObjValAs? Nat "sessionStarts") == 0)
    finally cold.close
    withDocumentAdmissionSession root fun runtime writes => do
      for path in #["Main.lean", inside.toString, "sub/../Main.lean", "inside-alias.lean",
          (base / "root-alias" / ".." / "Main.lean").toString] do
        let response ← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .updateFile { path }
        }
        require "in-root aliases are admitted" response.ok
      require "in-root aliases share one didOpen"
        ((← writes.get).map Prod.fst == #["textDocument/didOpen", importBasisCaptureMethod])
      for request in documentAdmissionRequests "document-admission" outside.toString do
        requireDocumentBoundaryFailure root (← Beam.resolveExistingPath outside)
          (← runtime.dispatchRequest request)
      require "plain close remains harmless for an untracked external path"
        (← runtime.dispatchRequest {
          workspaceId? := some "document-admission"
          payload := .close { path := outside.toString }
        }).ok
      require "rejected document requests do not write to an existing session"
        ((← writes.get).map Prod.fst == #["textDocument/didOpen", importBasisCaptureMethod])
      let dependencyRoot := root / ".lake" / "packages" / "dependency"
      let dependency := dependencyRoot / "Dep.lean"
      IO.FS.createDirAll dependencyRoot
      IO.FS.writeFile dependency source
      let response ← runtime.dispatchRequest {
        workspaceId? := some "document-admission"
        payload := .updateFile { path := dependency.toString }
      }
      require "dependency sources physically within the root are admitted" response.ok
      let gone := root / "Gone.lean"
      IO.FS.writeFile gone source
      require "deleted-source fixture opens its document" (← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .syncFile { path := gone.toString }
      }).ok
      let before ← writes.get
      -- This owned fixture simulates an editor deleting a tracked source file.
      IO.FS.removeFile gone
      let failedRefresh ← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .refreshFile { path := gone.toString }
      }
      require "refresh reports a structured failure for missing source" failedRefresh.error?.isSome
      require "failed refresh leaves the tracked document open" ((← writes.get) == before)
      for _ in [:2] do
        require "plain close remains available after source deletion" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission", payload := .close { path := gone.toString }
        }).ok
      require "repeated missing-source close sends exactly one didClose"
        ((← writes.get).map Prod.fst == (before.map Prod.fst).push "textDocument/didClose")
      runtime.state.atomically do
        let some workspace := (← get).workspaces.get? "document-admission"
          | throw <| IO.userError "deleted-source fixture workspace is missing"
        let some session := workspace.lean.session?
          | throw <| IO.userError "deleted-source fixture session is missing"
        require "missing-source close removes the tracked document"
          (!(session.docs.contains (sessionUri gone)))
        require "missing-source cleanup releases every admission" workspace.documents.entries.isEmpty
    withDocumentAdmissionSession (base / "workspace-alias") fun runtime writes => do
      let response ← runtime.dispatchRequest {
        workspaceId? := some "document-admission", payload := .updateFile { path := "Main.lean" }
      }
      require "a symlinked workspace root admits its canonical document" response.ok
      require "a symlinked workspace root opens exactly one document"
        ((← writes.get).map Prod.fst == #["textDocument/didOpen", importBasisCaptureMethod])
  finally IO.FS.removeDirAll base

/-- Rejection must finish while an attempted source read would be blocked by the owned writer. -/
private def checkDocumentAdmissionBeforeRead : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-document-admission-read-{← IO.monoNanosNow}"
  IO.FS.createDirAll (base / "workspace")
  let root ← Beam.resolveExistingPath (base / "workspace")
  let fifo := base / "Outside.lean"
  let writerReady := base / "writer-ready"
  let releaseWriter := base / "release-writer"
  let runtime ← ServerRuntime.create { root } "document-admission"
  try
    let result ← IO.Process.output { cmd := "mkfifo", args := #[fifo.toString] }
    require "document admission fixture creates its owned FIFO" (result.exitCode == 0)
    withFixtureChild (heldSourceWriter fifo writerReady releaseWriter) fun _ writer => do
      let task ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequest {
        workspaceId? := some "document-admission"
        payload := .updateFile { path := fifo.toString }
      }
      try
        let some (.ok response) ← Beam.waitTaskWithTimeout task 5000
          | throw <| IO.userError "external document rejection waited for source contents"
        requireDocumentBoundaryFailure root (← Beam.resolveExistingPath fifo) response
        require "external document rejection did not open its source stream"
          (!(← writerReady.pathExists))
      finally
        IO.FS.writeFile releaseWriter "release"
        cleanupFixtureChild writer
        let some _ ← Beam.waitTaskWithTimeout task 5000
          | throw <| IO.userError "document admission fixture left a source read running"
  finally
    try runtime.close
    finally IO.FS.removeDirAll base

private inductive RefreshRace where
  | retargetAlias
  | newerUpdate
  | pendingSync
  deriving BEq

/-- Refresh keeps its admitted identity and preserves newer accepted reads and their live permits. -/
private def checkRefreshAdmittedIdentity (race : RefreshRace := .retargetAlias) : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-refresh-admitted-identity-{← IO.monoNanosNow}"
  IO.FS.createDirAll (base / "workspace")
  let root ← Beam.resolveExistingPath (base / "workspace")
  let path := root / "Refresh.lean"
  let alias := root / "alias.lean"
  let outside := base / "Outside.lean"
  let newerRead := race != .retargetAlias
  let heldBarrier ← Std.Mutex.new
    (race == .pendingSync, (none : Option (PendingRequest × Json)))
  let barrierEntered ← IO.Promise.new
  let releaseBarrier : IO Unit := do
    let held? ← heldBarrier.atomically do
      let (_, pending?) ← get
      set (false, (none : Option (PendingRequest × Json)))
      pure pending?
    if let some (pending, result) := held? then pending.resolveResponse result
  let newerTask? ← IO.mkRef (none : Option (Task (Except IO.Error Response)))
  try
    IO.FS.writeFile path "def admittedFixture : Nat := 1\n"
    let (readSource, readEntered, releaseRead) ← heldSourceRead path
    admissionSymlink path alias
    IO.FS.writeFile outside "def outsideFixture := 2\n"
    withDocumentAdmissionSession root (readSource := readSource) (replyBarrier := fun pending result => do
      let hold ← heldBarrier.atomically do
        let (armed, _) ← get
        if armed then set (false, some (pending, result))
        pure armed
      if hold then
        barrierEntered.resolve ()
      else
        pending.resolveResponse result) fun runtime writes => do
      let newerDoc ← IO.mkRef (none : Option DocState)
      let newerPermit? ← IO.mkRef (none : Option DocumentAdmission.Permit)
      let uri := sessionUri (← Beam.resolveExistingPath path)
      let prior ← BeamTest.Broker.DocumentFixture.accepted <|
        DocumentState.FileSnapshot.ofText "def prior := 0\n" default
      runtime.state.atomically do
        let state ← get
        let some workspace := state.workspaces.get? "document-admission"
          | throw <| IO.userError "refresh fixture workspace is missing"
        let some session := workspace.lean.session?
          | throw <| IO.userError "refresh fixture session is missing"
        let session := { session with docs := session.docs.insert uri prior }
        let workspace := { workspace with
          nextFileSnapshotSeq := prior.syncSnapshotSeq + 1
          lean := { workspace.lean with session? := some session } }
        set { state with workspaces := state.workspaces.insert "document-admission" workspace }
      let task ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequest {
        workspaceId? := some "document-admission"
        payload := .refreshFile { path := alias.toString }
      }
      try
        let some (some ()) ← Beam.waitTaskWithTimeout readEntered 5000
          | throw <| IO.userError "refresh fixture did not capture its admitted read"
        require "refresh does not close before its source read completes" (← writes.get).isEmpty
        if newerRead then
          -- The old read retains its captured bytes; newer reads see the changed regular file.
          IO.FS.writeFile path "def newestFixture : Nat := 2\n"
          if race == .pendingSync then
            let newer ← IO.asTask (prio := .dedicated) <| runtime.dispatchRequest {
              workspaceId? := some "document-admission"
              payload := .syncFile { path := path.toString }
            }
            newerTask?.set (some newer)
            let some (some ()) ← Beam.waitTaskWithTimeout barrierEntered.result? 5000
              | throw <| IO.userError "newer sync did not reach its diagnostics barrier"
            newerPermit?.set <| some <| ← runtime.state.atomically do
              let some workspace := (← get).workspaces.get? "document-admission"
                | throw <| IO.userError "pending-sync fixture workspace is missing"
              let some (permit, phase) := workspace.documents.entries.head?
                | throw <| IO.userError "pending sync has no admission permit"
              require "newer sync retains a live permit" (phase == .reading && permit.uri == uri)
              pure permit
          else
            let updated ← runtime.dispatchRequest {
              workspaceId? := some "document-admission"
              payload := .updateFile { path := path.toString }
            }
            require "a newer source read completes while refresh is held" updated.ok
          newerDoc.set <| ← runtime.state.atomically do
            let state ← get
            pure <| state.workspaces.get? "document-admission"
              |>.bind (·.lean.session?) |>.bind (·.docs.get? uri)
        else
          IO.FS.removeFile alias
          admissionSymlink outside alias
        releaseRead
        let some (.ok response) ← Beam.waitTaskWithTimeout task 5000
          | throw <| IO.userError "refresh did not complete its admitted snapshot"
        require "refresh of the admitted source succeeds" response.ok
        let sent ← writes.get
        let expected :=
          if race == .pendingSync then
            #["textDocument/didChange", "textDocument/didSave", importBasisCaptureMethod,
              diagnosticsBarrierMethod, diagnosticsBarrierMethod]
          else if newerRead then
            #["textDocument/didChange", "textDocument/didSave", importBasisCaptureMethod,
              diagnosticsBarrierMethod]
          else
            #["textDocument/didClose", "textDocument/didOpen", importBasisCaptureMethod,
              diagnosticsBarrierMethod]
        require "refresh only closes its current admitted source read" (sent.map Prod.fst == expected)
        if newerRead then
          let some newer ← newerDoc.get
            | throw <| IO.userError "refresh fixture lost its newer document"
          let current ← runtime.state.atomically do
            let state ← get
            pure <| state.workspaces.get? "document-admission"
              |>.bind (·.lean.session?) |>.bind (·.docs.get? uri)
          let some current := current
            | throw <| IO.userError "old refresh erased the newer document"
          require "old refresh preserves the newer read, source and accepted basis"
            (DocumentState.basis current == DocumentState.basis newer &&
              current.rawSourceHash == newer.rawSourceHash &&
              current.syncSnapshotSeq == newer.syncSnapshotSeq)
        if let some permit ← newerPermit?.get then
          runtime.state.atomically do
            let some workspace := (← get).workspaces.get? "document-admission"
              | throw <| IO.userError "pending-sync fixture workspace is missing"
            require "stale refresh does not revoke the newer pending sync"
              ((workspace.documents.check permit).isOk)
          let some newer ← newerTask?.get
            | throw <| IO.userError "pending-sync fixture lost its task"
          require "newer sync still awaits its controlled barrier" (!(← IO.hasFinished newer))
          releaseBarrier
          let some (.ok response) ← Beam.waitTaskWithTimeout newer 5000
            | throw <| IO.userError "newer sync did not complete after its barrier"
          require "newer sync succeeds after stale refresh" response.ok
          runtime.state.atomically do
            let some workspace := (← get).workspaces.get? "document-admission"
              | throw <| IO.userError "pending-sync fixture workspace is missing"
            require "refresh and newer sync release their own permits"
              workspace.documents.entries.isEmpty
        for (method, message) in sent do
          let params ← IO.ofExcept <| message.getObjVal? "params"
          if method == diagnosticsBarrierMethod then
            require "refresh barrier retains the admitted canonical URI"
              (params == toJson (WaitForDiagnosticsParams.mk uri (if newerRead then 2 else 1)))
          else
            let document ← IO.ofExcept <| params.getObjVal? "textDocument"
            require "refresh retains the admitted canonical URI"
              ((← IO.ofExcept <| document.getObjValAs? String "uri") == uri)
      finally
        releaseBarrier
        releaseRead
        let some _ ← Beam.waitTaskWithTimeout task 5000
          | throw <| IO.userError "refresh fixture left a source read running"
        if let some newer ← newerTask?.get then
          let some _ ← Beam.waitTaskWithTimeout newer 5000
            | throw <| IO.userError "refresh fixture left a newer sync running"
  finally IO.FS.removeDirAll base

private def checkRefreshFencesOlderRead : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-refresh-older-read-{← IO.monoNanosNow}"
  IO.FS.createDirAll base
  let root ← Beam.resolveExistingPath base
  let path := root / "Refresh.lean"
  try
    IO.FS.writeFile path "def admittedFixture : Nat := 1\n"
    let (readSource, readEntered, releaseRead) ← heldSourceRead path
    withDocumentAdmissionSession root (readSource := readSource) fun runtime writes => do
      let older ← IO.asTask (prio := .dedicated) <| runtime.dispatchRequest {
        workspaceId? := some "document-admission"
        payload := .updateFile { path := path.toString }
      }
      try
        let some (some ()) ← Beam.waitTaskWithTimeout readEntered 5000
          | throw <| IO.userError "older source read did not capture its admitted contents"
        IO.FS.writeFile path "def refreshedFixture : Nat := 2\n"
        require "current refresh completes while an older read is held" (← runtime.dispatchRequest {
          workspaceId? := some "document-admission"
          payload := .refreshFile { path := path.toString }
        }).ok
        let before ← runtime.state.atomically do
          let some workspace := (← get).workspaces.get? "document-admission"
            | throw <| IO.userError "older-read fixture workspace is missing"
          let some session := workspace.lean.session?
            | throw <| IO.userError "older-read fixture session is missing"
          DocumentState.requireDocState session.docs (sessionUri path)
        let sent ← writes.get
        releaseRead
        let some (.ok response) ← Beam.waitTaskWithTimeout older 5000
          | throw <| IO.userError "older admitted read did not finish"
        let some error := response.error?
          | throw <| IO.userError "old admission survived refresh"
        require "current refresh rejects the older admission" (error.code == "contentModified")
        requireJsonString "refresh retains a typed admission failure" "reason"
          "documentAdmissionExpired" (← requireErrorData "older refresh admission" error)
        require "older read sends no document operations after refresh" ((← writes.get) == sent)
        runtime.state.atomically do
          let some workspace := (← get).workspaces.get? "document-admission"
            | throw <| IO.userError "older-read fixture workspace is missing"
          let some session := workspace.lean.session?
            | throw <| IO.userError "older-read fixture session is missing"
          let current ← DocumentState.requireDocState session.docs (sessionUri path)
          require "older read preserves the refreshed basis and contents"
            (DocumentState.basis current == DocumentState.basis before &&
              current.rawSourceHash == before.rawSourceHash &&
              current.syncSnapshotSeq == before.syncSnapshotSeq)
          require "refresh and old-read scopes release their own permits"
            workspace.documents.entries.isEmpty
      finally
        releaseRead
        let some _ ← Beam.waitTaskWithTimeout older 5000
          | throw <| IO.userError "older-read fixture left a source read running"
  finally IO.FS.removeDirAll base

private def checkWorkspaceSnapshotResetIsolation : IO Unit := do
  let nonce ← IO.monoNanosNow
  let workspaceId := "snapshot-reset"
  let oldRoot := System.FilePath.mk s!"/tmp/beam-snapshot-old-{nonce}"
  let newRoot := System.FilePath.mk s!"/tmp/beam-snapshot-new-{nonce}"
  let path := oldRoot / "Slow.lean"
  IO.FS.createDirAll oldRoot
  IO.FS.createDirAll newRoot
  IO.FS.writeFile path "def slowSnapshot : Nat := 1\n"
  let (readSource, readEntered, releaseRead) ← heldSourceRead path
  let runtime ← ServerRuntime.create ({ root := oldRoot } : BrokerConfig) workspaceId
    (readSource := readSource)
  let requestTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    runtime.dispatchRequest {
      payload := .updateFile { path := "Slow.lean" }
      workspaceId? := some workspaceId
    }
  try
    let some (some ()) ← Beam.waitTaskWithTimeout readEntered 5000
      | throw <| IO.userError "snapshot-reset read did not capture its admitted contents"
    let oldGeneration ← runtime.state.atomically do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "snapshot-reset workspace disappeared before reset"
      pure workspace.generation
    match ← runtime.initWorkspaceWithConfig workspaceId { root := newRoot } (some .reset) with
    | .error failure =>
        throw <| IO.userError s!"snapshot-reset workspace reset failed: {failure.error.message}"
    | .ok result =>
        require "snapshot-reset should invalidate the previous workspace generation"
          result.invalidatedHandles
    let newGeneration ← runtime.state.atomically do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "snapshot-reset workspace disappeared after reset"
      pure workspace.generation
    require "workspace reset should allocate a fresh generation" (newGeneration != oldGeneration)
    releaseRead
    let some (.ok response) ← Beam.waitTaskWithTimeout requestTask 5000
      | throw <| IO.userError "snapshot-reset request did not settle"
    require "an old-generation source snapshot should be rejected as stale"
      (response.error?.any fun err =>
        err.code == "contentModified" && err.message.contains "changed while")
    let leanSessionActive ← runtime.state.atomically do
      let state ← get
      pure <| state.workspaces.get? workspaceId |>.bind (fun workspace => workspace.lean.session?)
        |>.isSome
    require "a stale snapshot should not start a backend in the replacement workspace"
      !leanSessionActive
  finally
    releaseRead
    let some _ ← Beam.waitTaskWithTimeout requestTask 5000
      | throw <| IO.userError "snapshot-reset fixture left a source read running"
    runtime.close
    if ← oldRoot.pathExists then
      IO.FS.removeDirAll oldRoot
    if ← newRoot.pathExists then
      IO.FS.removeDirAll newRoot

private def pendingOnlySession
    (workspaceId : WorkspaceId)
    (root exit : System.FilePath) : IO Session := do
  let proc ← IO.Process.spawn {
    toStdioConfig := brokerStdio
    cmd := "python3"
    args := #[
      "-c",
      "import pathlib, sys, time\nwhile not pathlib.Path(sys.argv[1]).exists(): time.sleep(0.01)",
      exit.toString
    ]
  }
  let pending ← PendingRequestStore.create
  let stderrCapture ← startBackendStderrCapture proc.stderr
  pure {
    workspaceId
    workspaceGeneration := 1
    root
    epoch := 1
    sessionToken := s!"pending-only-{workspaceId}"
    proc := ← BackendProcess.create proc.pid proc.tryWait proc.kill
    stdin := IO.FS.Stream.ofHandle proc.stdin
    stdout := IO.FS.Stream.ofHandle proc.stdout
    stderrCapture
    pending
  }

private partial def takePendingRequests
    (store : PendingRequestStore)
    (count : Nat)
    (tries : Nat := 200) : IO (Array PendingRequest) := do
  let entries ← PendingRequestStore.snapshotEntries store
  if entries.size >= count then
    let mut pending := #[]
    for (id, _) in entries.take count do
      if let some request ← PendingRequestStore.remove store id then
        pending := pending.push request
    pure pending
  else if tries == 0 then
    throw <| IO.userError s!"timed out waiting for {count} pending backend request(s)"
  else
    IO.sleep 10
    takePendingRequests store count (tries - 1)

private partial def waitForWorkspaceRoot
    (runtime : ServerRuntime)
    (workspaceId : WorkspaceId)
    (expected : System.FilePath)
    (tries : Nat := 200) : IO Bool := do
  if (← runtime.workspaceRoot? workspaceId) == some expected then
    pure true
  else if tries == 0 then
    pure false
  else
    IO.sleep 10
    waitForWorkspaceRoot runtime workspaceId expected (tries - 1)

private def checkCompletedRequestResetIsolation : IO Unit := do
  let nonce ← IO.monoNanosNow
  let workspaceId := s!"completed-reset-{nonce}"
  let oldRoot := System.FilePath.mk s!"/tmp/beam-completed-reset-old-{nonce}"
  let newRoot := System.FilePath.mk s!"/tmp/beam-completed-reset-new-{nonce}"
  let exit := oldRoot / "exit-backend"
  IO.FS.createDirAll oldRoot
  IO.FS.createDirAll newRoot
  IO.FS.writeFile (oldRoot / "Demo.lean") "def demo : Nat := 1\n"
  let config : BrokerConfig := { root := oldRoot }
  let runtime ← ServerRuntime.create config workspaceId
  let session ← pendingOnlySession workspaceId oldRoot exit
  let documentHandle ← IO.mkRef (none : Option RequestHandle)
  runtime.state.atomically do
    let state ← get
    let some workspace := state.workspaces.get? workspaceId
      | throw <| IO.userError "completed-reset workspace disappeared"
    let workspace := { workspace with
      lean := { nextEpoch := 2, session? := some session }
    }
    set { state with workspaces := state.workspaces.insert workspaceId workspace }
  let documentTask ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequestWithHandle {
    payload := .runAt {
      path := "Demo.lean"
      version := 1
      line := 0
      character := 0
      text := "rfl"
    }
    workspaceId? := some workspaceId
  } fun handle => do
    documentHandle.set (some handle)
    pure true
  let symbolsTask ← IO.asTask (prio := Task.Priority.dedicated) <| runtime.dispatchRequest {
    payload := .workspaceSymbols { query := "demo" }
    workspaceId? := some workspaceId
  }
  try
    let requests ← takePendingRequests session.pending 2
    try
      let resetTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        runtime.initWorkspaceWithConfig workspaceId { root := newRoot } (some .reset)
      unless ← waitForWorkspaceRoot runtime workspaceId newRoot do
        throw <| IO.userError "completed-reset workspace reset did not commit"
      let some handle ← documentHandle.get
        | throw <| IO.userError "completed-reset document request has no cancellation handle"
      require "reset fixture marks cancellation before its successful backend reply" (← handle.cancel)
      for request in requests do
        PendingRequest.resolveResponse request (Json.mkObj [])
      for (label, task) in [("document request", documentTask), ("workspace symbols", symbolsTask)] do
        let response ← IO.ofExcept <| ← IO.wait task
        require s!"{label}: an old-session result should be rejected after reset"
          (response.error?.any fun err => err.code == "workerExited")
      let shutdownRequests ← takePendingRequests session.pending 1
      for request in shutdownRequests do
        PendingRequest.resolveResponse request Json.null
      IO.FS.writeFile exit "exit"
      match ← IO.ofExcept <| ← IO.wait resetTask with
      | .ok result =>
          require "completed reset should invalidate the old session" result.invalidatedHandles
      | .error failure =>
          throw <| IO.userError s!"completed workspace reset failed: {failure.error.message}"
    finally
      -- These promises were removed from the store, so runtime closure cannot settle them.
      for request in requests do
        request.resolveFailure (responseFailureFor .internalError "completed-reset fixture cleanup")
  finally
    if !(← exit.pathExists) then
      IO.FS.writeFile exit "exit"
    try
      runtime.close
    catch _ =>
      pure ()
    try
      discard <| session.proc.terminate 1000
    catch _ =>
      pure ()
    if ← oldRoot.pathExists then
      IO.FS.removeDirAll oldRoot
    if ← newRoot.pathExists then
      IO.FS.removeDirAll newRoot

private partial def waitForCancellation
    (cancelRef : IO.Ref Bool)
    (tries : Nat := 100) : IO Unit := do
  if ← cancelRef.get then
    pure ()
  else if tries == 0 then
    throw <| IO.userError "timed out waiting for runtime close cancellation"
  else
    IO.sleep 10
    waitForCancellation cancelRef (tries - 1)

private def checkSessionCloseAdmission : IO Unit := do
  let root := System.FilePath.mk "/tmp/beam-session-close-admission"
  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
  let beforeClose ← runtime.dispatchRequest Request.stats
  require "stats should be admitted before session close" beforeClose.ok
  let active ←
    match ← ActiveRequestRegistry.register runtime.activeRequests none (some "close-drain") with
    | .ok active => pure active
    | .error failure => throw <| IO.userError failure.message
  let closeTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
  waitForCancellation active.cancelRef
  let concurrentCloseTask ← IO.asTask (prio := Task.Priority.dedicated) runtime.close
  IO.sleep 10
  require "runtime close should wait for admitted dispatch scopes"
    (!(← IO.hasFinished closeTask))
  require "concurrent runtime close should share the same drain"
    (!(← IO.hasFinished concurrentCloseTask))
  ActiveRequestRegistry.unregister runtime.activeRequests (some active)
  match ← IO.wait closeTask with
  | .ok () => pure ()
  | .error err => throw err
  match ← IO.wait concurrentCloseTask with
  | .ok () => pure ()
  | .error err => throw err
  runtime.close
  let afterClose ← runtime.dispatchRequest Request.stats
  require "ordinary requests should be rejected after session close"
    (afterClose.error?.any fun err => err.code == "requestCancelled")
  let shutdown ← runtime.dispatchRequest Request.shutdown
  require "shutdown remains idempotent after admission closes" shutdown.ok
  require "closed admission should leave no active request"
    ((← ActiveRequestRegistry.count runtime.activeRequests) == 0)

private def checkBrokerConfigBoundary : IO Unit := do
  expectDecodeFailure Request "Rocq workspace option belongs to rocq-beam" <| Json.mkObj [
    ("op", toJson "init_workspace"),
    ("workspaceId", toJson "test"),
    ("root", toJson "/workspace"),
    ("rocqCmd", toJson "coq-lsp")
  ]
  let root := System.FilePath.mk "/workspace"
  let plugin := System.FilePath.mk "/beam/libbeam.so"
  let helper := System.FilePath.mk "/beam/bin/daemon"
  let config := BrokerConfig.ofRuntime root {
    command := "lean", plugin, daemonBin := helper
    toolchain := "fixture", identity := ⟨"/beam", "fixture"⟩
  }
  match config.lean? with
  | some leanConfig =>
      require "broker config preserves the Lean command" (leanConfig.command == "lean")
      require "broker config preserves the Lean plugin" (leanConfig.plugin == plugin)
      require "broker config requires the recorded helper" (leanConfig.lakeHelper == helper)
  | none => throw <| IO.userError "complete broker config lost the Lean backend"

private def checkWrapperDaemonAuthorization : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-wrapper-daemon-authorization-{← IO.monoNanosNow}"
  let rootPath := base / "workspace"
  IO.FS.createDirAll rootPath
  let root ← Beam.resolveExistingPath rootPath
  let capability := "generation-secret"
  let runtime ← Beam.Broker.ServerRuntime.create
    ({ root } : Beam.Broker.BrokerConfig) "fixture"
    (.wrapper { daemonId := "generation-a", configHash := "config-a" } capability)
  try
    for (label, capability?) in [
        ("missing", none),
        ("wrong", some "another-generation-secret")
      ] do
      let response ← runtime.dispatchRequest { Request.stats with
        daemonCapability? := capability?
      }
      require s!"wrapper daemon should reject {label} capability"
        (response.error?.any fun err =>
          err.code == "invalidParams" && err.message.contains "invalid Beam daemon capability")

    let stats ← runtime.dispatchRequest { Request.stats with
      daemonCapability? := some capability
    }
    require "wrapper daemon should admit the exact generation capability" stats.ok

    for op in [Op.initWorkspace, .listWorkspaces, .dropWorkspace] do
      let response ← runtime.dispatchRequest { sampleRequest op with
        workspaceId? := some "fixture"
        daemonCapability? := some capability
      }
      require s!"wrapper daemon should disable dynamic {op.key}"
        (response.error?.any fun err =>
          err.code == "invalidParams" && err.message.contains "wrapper-owned daemon mode")
  finally
    try
      runtime.close
    finally
      IO.FS.removeDirAll base

def main : IO Unit := do
  checkExactErrorAssertions
  checkDaemonReadinessProtocol
  checkServerHelloProtocol
  checkResponseJsonShape
  checkStreamMessageDecode
  checkResponseJsonDecode
  checkSaveResultJsonDecode
  checkOrderedJsonPretty
  checkSyncFileResultDecode
  checkFailureResponseConversions
  checkLakeHelperOutputCodec
  checkDocumentVersionMismatchErrorData
  checkReadinessBoundary
  checkStaleDirectDepHints
  checkRequestBoundary
  checkWorkspaceRoutingFields
  checkWorkspaceLifecycleProtocol
  PublicationClaimTest.run
  checkFixtureChildCleanupOnFailure
  checkFixtureCleanupRejectsWaitFailure
  checkLateWriteFailure .open
  checkLateWriteFailure .closed
  checkLateWriteFailure .cancelled
  checkShutdownReplyCleanup .timeout
  checkShutdownReplyCleanup .success
  checkShutdownReplyCleanup .error
  checkShutdownReplyCleanup .writeFailure
  checkReaderFailureOverlapsClose .readerFirst
  checkReaderFailureOverlapsClose .closeFirst
  checkUnconfirmedCleanup .runtimeClose .signalFailure true
  checkUnconfirmedCleanup .runtimeClose .exitNotObserved
  checkUnconfirmedCleanup .runtimeClose .waitFailure
  checkUnconfirmedCleanup .readerFailure .signalFailure true
  checkUnconfirmedCleanup .readerFailure .waitFailure
  checkFailedReaderAdmission
  checkUnconfirmedCleanup .reset .signalFailure
  checkUnconfirmedCleanup .drop .exitNotObserved
  checkLifecycleTeardownConcurrency
  checkLifecycleCleanupFailureCommits .reset
  checkLifecycleCleanupFailureCommits .drop
  checkLifecycleCleanupFailureCommits .drop .stall
  checkRuntimeCloseDetachesAllSessions false
  checkRuntimeCloseDetachesAllSessions true
  checkDeadSessionCleanupReleasesStateMutex
  checkExitedSessionCleanupFailure false
  checkExitedSessionCleanupFailure true
  checkExitedSessionCleanupFailure false .runtimeClose
  checkExitedSessionCleanupFailure true .runtimeClose
  checkDocumentAdmission
  checkDocumentSourceInputs
  checkSourceEncoding
  checkSourceObservationFailures
  checkDocumentAdmissionBeforeRead
  checkRefreshAdmittedIdentity
  checkRefreshAdmittedIdentity .newerUpdate
  checkRefreshAdmittedIdentity .pendingSync
  checkRefreshFencesOlderRead
  checkWorkspaceSnapshotResetIsolation
  checkCompletedRequestResetIsolation
  checkSessionCloseAdmission
  checkBrokerConfigBoundary
  checkWrapperDaemonAuthorization

end BeamTest.Broker.ProtocolTest

def main := BeamTest.Broker.ProtocolTest.main
