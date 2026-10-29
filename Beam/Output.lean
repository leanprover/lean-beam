/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.JsonFields
import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.OpenDocs
import Beam.Workspace.Protocol
import Beam.LSP.Save
import Beam.LSP.RunAt
import Beam.LSP.Lib.Goal
import Beam.LSP.Todo

open Lean

namespace Beam.Output

def documentProgressJson (progress : Beam.Broker.SyncFileProgress) : Json := Json.mkObj <|
  [
    ("updates", toJson progress.updates),
    ("done", toJson progress.done)
  ] ++
  (match progress.rangeStartLine? with
  | some line => [("range_start_line", toJson line)]
  | none => []) ++
  (match progress.rangeEndLine? with
  | some line => [("range_end_line", toJson line)]
  | none => [])

/-- A transport-neutral presentation error. Recognized Beam-owned data uses public field names;
unrecognized data and opaque evidence retain their supplied JSON. -/
structure OutputError where
  code : String
  message : String := ""
  data? : Option Json := none
  documentProgress? : Option Beam.Broker.SyncFileProgress := none
  deriving Inhabited

namespace OutputError

def invalidResult (message : String) : OutputError := { code := "invalidResult", message }

def invalidInput (message : String) : OutputError := { code := "invalidInput", message }

def json (error : OutputError) : Json := Json.mkObj <|
  [("code", Lean.toJson error.code), ("message", Lean.toJson error.message)] ++
  (match error.data? with
  | some data => [("data", data)]
  | none => []) ++
  (match error.documentProgress? with
  | some progress => [("document_progress", Beam.Output.documentProgressJson progress)]
  | none => [])

end OutputError

/-- Result family selects a typed public projection without inspecting a result envelope. -/
inductive Operation where
  | broker (op : Beam.Broker.Op)
  | closeSave
  | globalStats
  | workspaceStats
  | globalOpenDocs
  | workspaceOpenDocs
  | opaque
  deriving BEq, Repr

namespace Operation

def ofRequest (request : Beam.Broker.Request) : Operation :=
  match request.payload with
  | .stats => if request.workspaceId?.isSome then .workspaceStats else .globalStats
  | .openDocs => if request.workspaceId?.isSome then .workspaceOpenDocs else .globalOpenDocs
  | .close close =>
      if close.saveArtifacts?.getD false then .closeSave else .broker .close
  | payload => .broker payload.op

end Operation

/-- One normalized public runAt message. -/
private def runAtMessageJson (message : Beam.LSP.RunAt.Message) : Json := Json.mkObj [
  ("severity", toJson message.severity),
  ("text", toJson message.text)
]

private def goalHypJson (hyp : Beam.LSP.Lib.GoalHyp) : Json := Json.mkObj <|
  [("names", toJson hyp.names), ("type", toJson hyp.type)] ++
  match hyp.value? with
  | some value => [("value", toJson value)]
  | none => []

private def goalJson (goal : Beam.LSP.Lib.Goal) : Json := Json.mkObj <|
  (match goal.userName? with
  | some name => [("user_name", toJson name)]
  | none => []) ++
  [
    ("goal_prefix", toJson goal.goalPrefix),
    ("target", toJson goal.target),
    ("hyps", Json.arr <| goal.hyps.map goalHypJson)
  ]

private def proofStateJson (proofState : Beam.LSP.Lib.ProofState) : Json := Json.mkObj [
  ("goals", Json.arr <| proofState.goals.map goalJson)
]

private structure RunAtBrokerResult where
  success : Bool := true
  messages : Array Beam.LSP.RunAt.Message := #[]
  traces : Array String := #[]
  handle? : Option Beam.Broker.Handle := none
  proofState? : Option Beam.LSP.Lib.ProofState := none
  profile? : Option Beam.LSP.RunAt.Profile.Result := none

private def optionalField? [FromJson α] (json : Json) (name : String) : Except String (Option α) := do
  match json.getObjVal? name with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error error => throw s!"invalid '{name}': {error}"
  | .error _ => pure none

private instance : FromJson RunAtBrokerResult where
  fromJson? json := do
    requireOnlyJsonFields "runAt result" #["success", "messages", "traces", "handle", "proofState", "profile"] json
    let success ← json.getObjValAs? Bool "success"
    let messages ← json.getObjValAs? (Array Beam.LSP.RunAt.Message) "messages"
    let traces ← json.getObjValAs? (Array String) "traces"
    let handle? ← optionalField? (α := Beam.Broker.Handle) json "handle"
    let proofState? ← optionalField? (α := Beam.LSP.Lib.ProofState) json "proofState"
    let profile? ← optionalField? (α := Beam.LSP.RunAt.Profile.Result) json "profile"
    pure {
      success
      messages
      traces
      handle?
      proofState?
      profile?
    }

private def profileSpanJson (span : Beam.LSP.RunAt.Profile.Span) : Json := Json.mkObj <|
  [("thread", toJson span.thread), ("category", toJson span.category),
   ("tag", toJson span.tag), ("start_ms", toJson span.startMs),
   ("duration_ms", toJson span.durationMs)] ++
  (match span.parent? with | some parent => [("parent", toJson parent)] | none => []) ++
  (match span.range? with | some range => [("range", toJson range)] | none => [])

private def profileJson (profile : Beam.LSP.RunAt.Profile.Result) : Json := Json.mkObj [
  ("elapsed_ms", toJson profile.elapsedMs), ("initial_threshold_ms", toJson profile.initialThresholdMs),
  ("spans", Json.arr <| profile.spans.map profileSpanJson),
  ("truncated", toJson profile.truncated)
]

private def runAtResultJson (result : RunAtBrokerResult) : Json := Json.mkObj <|
  [
    ("success", toJson result.success),
    ("messages", Json.arr <| result.messages.map runAtMessageJson),
    ("traces", toJson result.traces)
  ] ++
  (match result.proofState? with
  | some proofState => [("proof_state", proofStateJson proofState)]
  | none => []) ++
  (match result.profile? with
  | some profile => [("profile", profileJson profile)]
  | none => []) ++
  (match result.handle? with
  | some handle => [("next_handle", toJson handle)]
  | none => [])

private def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

/-- Project a broker diagnostic onto the transport-neutral diagnostic representation. -/
def diagnosticJson (diagnostic : Beam.Broker.StreamDiagnostic) : Json := Json.mkObj <|
  [
    ("path", toJson diagnostic.path),
    ("uri", toJson diagnostic.uri),
    ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
    ("range", toJson diagnostic.range),
    ("message", toJson diagnostic.message),
    ("completion_blocking", toJson diagnostic.completionBlocking)
  ] ++
  (match diagnostic.saveBlocking? with
  | some saveBlocking => [("save_blocking", toJson saveBlocking)]
  | none => []) ++
  (match diagnostic.version? with
  | some version => [("version", toJson version)]
  | none => [])

private def blockingDiagnosticJson (diagnostic : Beam.Broker.SyncBlockingDiagnostic) : Json := Json.mkObj [
  ("range", toJson diagnostic.range),
  ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
  ("message", toJson diagnostic.message),
  ("save_blocking", toJson diagnostic.saveBlocking),
  ("completion_blocking", toJson diagnostic.completionBlocking)
]

private def blockingMessageJson (message : Beam.Broker.SyncBlockingCommandMessage) : Json := Json.mkObj [
  ("message", toJson message.message),
  ("save_blocking", toJson message.saveBlocking),
  ("completion_blocking", toJson message.completionBlocking)
]

private def syncResultJson (result : Beam.Broker.SyncFileResult) : Json :=
  let diagnosticFields := match result.diagnostics.items? with
    | some items => [("items", Json.arr <| items.map diagnosticJson)]
    | none => []
  Json.mkObj [
    ("path", toJson result.path),
    ("version", toJson result.version),
    ("diagnostics", Json.mkObj <| [("counts", toJson result.diagnostics.counts)] ++ diagnosticFields),
    ("readiness", Json.mkObj [
      ("save_ready", toJson result.readiness.saveReady),
      ("reason", toJson result.readiness.reason),
      ("blocking_error_count", toJson result.readiness.blockingErrorCount),
      ("blocking_diagnostics", Json.arr <| result.readiness.blockingDiagnostics.map blockingDiagnosticJson),
      ("blocking_messages", Json.arr <| result.readiness.blockingMessages.map blockingMessageJson)
    ])
  ]

private def saveResultJson (result : Beam.Broker.SaveOleanResult) : Json := Json.mkObj <|
  [
    ("path", toJson result.path),
    ("module", toJson result.module),
    ("version", toJson result.version),
    ("source_hash", toJson result.sourceHash),
    ("olean", toJson result.olean),
    ("ilean", toJson result.ilean),
    ("c", toJson result.c),
    ("trace", toJson result.trace)
  ] ++
  (match result.oleanServer? with
  | some path => [("olean_server", toJson path)]
  | none => []) ++
  (match result.oleanPrivate? with
  | some path => [("olean_private", toJson path)]
  | none => []) ++
  (match result.ir? with
  | some path => [("ir", toJson path)]
  | none => []) ++
  (match result.irSig? with
  | some path => [("ir_sig", toJson path)]
  | none => []) ++
  (match result.bc? with
  | some path => [("bc", toJson path)]
  | none => []) ++
  [("sync", syncResultJson result.sync)]

private def closeSaveResultJson (result : Beam.Broker.CloseSaveResult) : Json := Json.mkObj [
  ("closed", toJson result.closed),
  ("saved", saveResultJson result.saved)
]

private def projectWorkerRecoveryData (data : Json) : Except String Json := do
  requireOnlyJsonFields "worker recovery data" #["recovery", "originalData"] data
  let recoveryJson ← data.getObjVal? "recovery"
  requireOnlyJsonFields "worker recovery" #["kind", "uri"] recoveryJson
  let recovery ← fromJson? (α := Beam.Broker.WorkerRecovery) recoveryJson
  unless toJson recovery == recoveryJson do throw "worker recovery fields do not match its kind"
  let originalData? ← optionalField? (α := Json) data "originalData"
  pure <| Json.mkObj <|
    [("recovery", toJson recovery)] ++
      originalData?.toList.map (fun original => ("original_data", original))

private def projectVersionMismatchData (data : Json) : Except String Json := do
  requireOnlyJsonFields "document version mismatch data"
    #["reason", "expectedVersion", "acceptedVersion", "currentVersion", "uri"] data
  let reason ← data.getObjValAs? String "reason"
  unless reason == "documentVersionMismatch" do throw "unrecognized version mismatch reason"
  let expectedVersion ← data.getObjValAs? Nat "expectedVersion"
  let acceptedVersion ← data.getObjValAs? Nat "acceptedVersion"
  let currentVersion? ← optionalField? (α := Nat) data "currentVersion"
  let uri? ← optionalField? (α := String) data "uri"
  pure <| Json.mkObj <|
    [("reason", toJson reason), ("expected_version", toJson expectedVersion),
      ("accepted_version", toJson acceptedVersion)] ++
    currentVersion?.toList.map (fun value => ("current_version", toJson value)) ++
    uri?.toList.map (fun value => ("uri", toJson value))

private def projectDocumentStateData (data : Json) : Except String Json := do
  requireOnlyJsonFields "document state error data" #["reason", "uri", "currentVersion"] data
  let reason ← data.getObjValAs? String "reason"
  unless ["documentClosing", "documentAdmissionExpired", "documentChanged"].contains reason do
    throw "unrecognized document state reason"
  let uri ← data.getObjValAs? String "uri"
  let currentVersion? ← optionalField? (α := Nat) data "currentVersion"
  if reason != "documentChanged" && currentVersion?.isSome then
    throw "document state version field does not match its reason"
  pure <| Json.mkObj <|
    [("reason", toJson reason), ("uri", toJson uri)] ++
      currentVersion?.toList.map (fun value => ("current_version", toJson value))

private def projectTextHashMismatchData (data : Json) : Except String Json := do
  requireOnlyJsonFields "document hash mismatch data" #["expectedHash", "actualHash", "uri"] data
  let expectedHash ← data.getObjValAs? Nat "expectedHash"
  let actualHash ← data.getObjValAs? Nat "actualHash"
  let uri ← data.getObjValAs? String "uri"
  pure <| Json.mkObj [
    ("expected_hash", toJson expectedHash),
    ("actual_hash", toJson actualHash),
    ("uri", toJson uri)
  ]

private def projectSyncErrorData (data : Json) : Except String Json := do
  requireOnlyJsonFields "sync error data" #["sync", "reason", "path"] data
  let sync ← data.getObjValAs? Beam.Broker.SyncFileResult "sync"
  let reason? ← optionalField? (α := String) data "reason"
  let path? ← optionalField? (α := String) data "path"
  match reason?, path? with
  | none, none => pure <| Json.mkObj [("sync", syncResultJson sync)]
  | some reason, some path =>
      -- The owning error code identifies the receipt shape. Reason is producer-supplied
      -- explanation (including Lake setup refusals), not a second schema discriminator.
      unless path == sync.path do throw "sync error path does not match its sync result"
      pure <| Json.mkObj [
        ("sync", syncResultJson sync),
        ("reason", toJson reason),
        ("path", toJson path)
      ]
  | _, _ => throw "sync error reason and path must appear together"

private def projectSaveSetupData (data : Json) : Except String Json := do
  requireOnlyJsonFields "save setup error data" #["reason", "path"] data
  let reason ← data.getObjValAs? String "reason"
  let path ← data.getObjValAs? String "path"
  pure <| Json.mkObj [("reason", toJson reason), ("path", toJson path)]

private def projectSaveImportsChangedData (data : Json) : Except String Json := do
  requireOnlyJsonFields "save imports changed data"
    #["sync", "path", "changedImports", "unresolvedImports", "recoveryPlan"] data
  let sync ← data.getObjValAs? Beam.Broker.SyncFileResult "sync"
  let path ← data.getObjValAs? String "path"
  let changed ← data.getObjValAs? (Array String) "changedImports"
  let unresolved ← data.getObjValAs? (Array String) "unresolvedImports"
  let recovery ← data.getObjValAs? (Array String) "recoveryPlan"
  unless path == sync.path do throw "save imports path does not match its sync result"
  pure <| Json.mkObj [
    ("sync", syncResultJson sync), ("path", toJson path),
    ("changed_imports", toJson changed), ("unresolved_imports", toJson unresolved),
    ("recovery_plan", toJson recovery)
  ]

private def projectSavedDocumentChangedData (data : Json) : Except String Json := do
  requireOnlyJsonFields "saved document changed data"
    #["reason", "closed", "saved", "currentVersion"] data
  let reason ← data.getObjValAs? String "reason"
  unless reason == "savedDocumentChanged" do throw "unrecognized save finalization reason"
  let closed ← data.getObjValAs? Bool "closed"
  unless !closed do throw "saved document changed data reports a closed document"
  let saved ← data.getObjValAs? Beam.Broker.SaveOleanResult "saved"
  let currentVersion? ← optionalField? (α := Nat) data "currentVersion"
  pure <| Json.mkObj <|
    [("reason", toJson reason), ("closed", toJson false), ("saved", saveResultJson saved)] ++
    currentVersion?.toList.map (fun value => ("current_version", toJson value))

private def projectSavedFailureData (data : Json) : Except String Json := do
  requireOnlyJsonFields "save failure data" #["saved", "originalData"] data
  let saved ← data.getObjValAs? Beam.Broker.SaveOleanResult "saved"
  let originalData? ← optionalField? (α := Json) data "originalData"
  pure <| Json.mkObj <|
    [("saved", saveResultJson saved)] ++
      originalData?.toList.map (fun original => ("original_data", original))

private def projectStaleSyncData (data : Json) : Except String Json := do
  requireOnlyJsonFields "stale sync data" #[
    "targetPath", "staleDirectDeps", "saveDeps", "completionBlockingDiagnostics", "recoveryPlan"
  ] data
  let targetPath ← data.getObjValAs? String "targetPath"
  let rawHints ← data.getObjValAs? (Array Json) "staleDirectDeps"
  let mut hints := #[]
  for rawHint in rawHints do
    requireOnlyJsonFields "stale direct dependency" #["module", "path", "needsSave"] rawHint
    let moduleName ← rawHint.getObjValAs? String "module"
    let path ← rawHint.getObjValAs? String "path"
    let needsSave ← rawHint.getObjValAs? Bool "needsSave"
    hints := hints.push <| Json.mkObj [
      ("module", toJson moduleName), ("path", toJson path), ("needs_save", toJson needsSave)
    ]
  let saveDeps ← data.getObjValAs? (Array String) "saveDeps"
  let diagnostics ← data.getObjValAs? (Array Beam.Broker.SyncBlockingDiagnostic)
    "completionBlockingDiagnostics"
  let recoveryPlan ← data.getObjValAs? (Array String) "recoveryPlan"
  pure <| Json.mkObj [
    ("target_path", toJson targetPath),
    ("stale_direct_deps", Json.arr hints),
    ("save_deps", toJson saveDeps),
    ("completion_blocking_diagnostics", Json.arr <| diagnostics.map blockingDiagnosticJson),
    ("recovery_plan", toJson recoveryPlan)
  ]

private def projectCleanupFailureData (data : Json) : Except String Json := do
  requireOnlyJsonFields "helper cleanup failure data"
    #["reason", "operation", "operationOutcome", "cleanup", "operationResponse"] data
  let reason ← data.getObjValAs? String "reason"
  unless reason == "helperCleanupFailed" do throw "unrecognized helper failure reason"
  let operation ← data.getObjValAs? String "operation"
  let outcome ← data.getObjValAs? Json "operationOutcome"
  requireOnlyJsonFields "helper operation outcome" #["status", "error"] outcome
  let status ← outcome.getObjValAs? String "status"
  unless status == "succeeded" || status == "failed" do throw "invalid helper operation status"
  let error? ← optionalField? (α := Json) outcome "error"
  unless (status == "failed") == error?.isSome do throw "helper operation error does not match status"
  if let some rawError := error? then
    requireOnlyJsonFields "helper operation error" #["code", "message", "data"] rawError
    let _ ← fromJson? (α := Beam.Broker.Error) rawError
  let cleanup ← data.getObjValAs? Json "cleanup"
  requireOnlyJsonFields "helper cleanup details"
    #["processJob", "temporaryDirectory", "outputCapture"] cleanup
  let processJob? ← optionalField? (α := String) cleanup "processJob"
  let temporaryDirectory? ← optionalField? (α := String) cleanup "temporaryDirectory"
  let outputCapture? ← optionalField? (α := String) cleanup "outputCapture"
  unless processJob?.isSome || temporaryDirectory?.isSome || outputCapture?.isSome do
    throw "helper cleanup failure has no cleanup evidence"
  let operationResponse? ← optionalField? (α := Json) data "operationResponse"
  pure <| Json.mkObj <|
    [("reason", toJson reason), ("operation", toJson operation),
      ("operation_outcome", Json.mkObj <|
        [("status", toJson status)] ++ error?.toList.map (fun value => ("error", value))),
      ("cleanup", Json.mkObj <|
        processJob?.toList.map (fun value => ("process_job", toJson value)) ++
        temporaryDirectory?.toList.map (fun value => ("temporary_directory", toJson value)) ++
        outputCapture?.toList.map (fun value => ("output_capture", toJson value)))] ++
      operationResponse?.toList.map (fun value => ("operation_response", value))

private def projectHelperErrorData (data : Json) : Except String Json := do
  requireOnlyJsonFields "helper error wrapper" #["helperError"] data
  let helperError ← data.getObjVal? "helperError"
  requireOnlyJsonFields "helper error" #["code", "message", "data"] helperError
  let _ ← fromJson? (α := Beam.Broker.Error) helperError
  pure <| Json.mkObj [("helper_error", helperError)]

/-- Preserve unrecognized backend evidence behind an explicit opaque boundary. -/
private def opaqueErrorData (data : Json) : Json :=
  if data == Json.null then Json.null else Json.mkObj [("original_data", data)]

/-- Schema drift must not silently change the public recovery contract. Retain the original
error code and all evidence, while making the failed projection visible to clients. -/
private def errorDataProjectionFailure (data : Json) (detail : String) : Json :=
  Json.mkObj [("projection_error", toJson detail), ("original_data", data)]

private def attemptErrorProjection (project : Json → Except String Json) (data : Json) : Option Json :=
  some <| match project data with
  | .ok projected => projected
  | .error detail => errorDataProjectionFailure data detail

private def isSaveOperation (operation : Operation) : Bool :=
  operation == .closeSave || operation == .broker .saveOlean

private def projectBrokerErrorData (operation : Operation) (code : String) (data : Json) : Option Json :=
  let reason? := (data.getObjValAs? String "reason").toOption
  if code == "contentModified" then
    match reason? with
    | some "documentVersionMismatch" => attemptErrorProjection projectVersionMismatchData data
    | some "documentClosing" | some "documentAdmissionExpired" | some "documentChanged" =>
        attemptErrorProjection projectDocumentStateData data
    | some "savedDocumentChanged" =>
        if isSaveOperation operation then attemptErrorProjection projectSavedDocumentChangedData data
        else none
    | _ =>
        if isSaveOperation operation && (data.getObjVal? "saved").isOk then
          attemptErrorProjection projectSavedFailureData data
        else if (data.getObjVal? "expectedHash").isOk then
          attemptErrorProjection projectTextHashMismatchData data
        else none
  else if code == Beam.Broker.BrokerFailureCode.syncBarrierIncomplete.name &&
      (data.getObjVal? "targetPath").isOk then
    attemptErrorProjection projectStaleSyncData data
  else if code == "saveImportsChanged" then
    attemptErrorProjection projectSaveImportsChangedData data
  else if (code == "invalidParams" || code == "saveUnsupportedSetup") &&
      (data.getObjVal? "sync").isOk then
    attemptErrorProjection projectSyncErrorData data
  else if code == "saveUnsupportedSetup" then
    attemptErrorProjection projectSaveSetupData data
  else if (code == "workerExited" || code == "workerCrashed") &&
      (data.getObjVal? "recovery").isOk then
    attemptErrorProjection projectWorkerRecoveryData data
  else if code == "internalError" && (data.getObjVal? "reason").isOk then
    attemptErrorProjection projectCleanupFailureData data
  else if code == "internalError" && (data.getObjVal? "helperError").isOk then
    attemptErrorProjection projectHelperErrorData data
  else if isSaveOperation operation && (data.getObjVal? "saved").isOk then
    attemptErrorProjection projectSavedFailureData data
  else
    none

private structure ArgumentPreviewData where
  field : String
  preview : String
  omittedChars : Nat
  deriving FromJson

private def projectArgumentPreview (json : Json) : Except String Json := do
  requireOnlyJsonFields "argument preview" #["field", "preview", "omittedChars"] json
  let preview ← fromJson? (α := ArgumentPreviewData) json
  pure <| Json.mkObj [
    ("field", toJson preview.field),
    ("preview", toJson preview.preview),
    ("omitted_chars", toJson preview.omittedChars)
  ]

private def validateStringField (json : Json) : Except String Json := do
  let _ ← fromJson? (α := String) json
  pure json

private def validateControlDiagnostics (json : Json) : Except String Json := do
  match json with
  | .str _ => pure json
  | _ =>
      let _ ← fromJson? (α := Array String) json
      pure json

private def validateBoolField (json : Json) : Except String Json := do
  let _ ← fromJson? (α := Bool) json
  pure json

/-- CLI-owned codes with structured recovery metadata. Contract tests require representative
producer coverage for every entry; backend-only codes are not inferred from payload keys. -/
def controlErrorDataCodes : Array String := #[
  "invalidParams", "internalError", "setupError", "sessionRecoveryRequired", "sessionUnresponsive",
  "noLiveSession", "sessionShutdownUnconfirmed", "sessionInstallationMismatch",
  "requestCancelled", "brokerUnavailable"
]

private def controlCodeOwns (code field : String) : Bool :=
  match field with
  | "root" | "path" | "generation" | "detail" | "diagnostics" =>
      controlErrorDataCodes.contains code
  | "argument" => code == "invalidParams" || code == "internalError"
  | "remedyCommand" =>
      ["setupError", "sessionRecoveryRequired", "sessionUnresponsive", "noLiveSession",
        "sessionShutdownUnconfirmed", "sessionInstallationMismatch"].contains code
  | "descriptorPath" => code == "setupError" || code == "sessionRecoveryRequired"
  | "recoveryCommand" => code == "sessionShutdownUnconfirmed"
  | "installationRoot" =>
      ["setupError", "sessionShutdownUnconfirmed", "sessionInstallationMismatch"].contains code
  | "currentInstallationRoot" => code == "sessionInstallationMismatch"
  | "operationMayHaveCompleted" | "operationResponse" =>
      ["requestCancelled", "brokerUnavailable", "internalError"].contains code
  | "recordedConfigHash" | "requestedConfigHash" =>
      ["sessionUnresponsive", "sessionRecoveryRequired", "setupError", "noLiveSession"].contains code
  | "sessionDir" | "recoveryPrecondition" =>
      ["sessionUnresponsive", "sessionRecoveryRequired", "setupError", "noLiveSession",
        "sessionShutdownUnconfirmed", "sessionInstallationMismatch"].contains code
  | _ => false

private def projectControlErrorDataImpl (code : String) (data : Json) : Except String (Option Json) := do
  if !controlErrorDataCodes.contains code then return none
  let .obj fields := data | pure none
  let mut recognized := false
  let mut projected := []
  for (key, value) in fields.toList do
    let (publicKey, publicValue, isOwned) ← if !controlCodeOwns code key then
      throw s!"unrecognized {code} control error field '{key}'"
    else match key with
      | "root" | "path" | "generation" | "detail" =>
          (validateStringField value).map (fun projected => (key, projected, true))
      | "diagnostics" =>
          (validateControlDiagnostics value).map (fun projected => (key, projected, true))
      | "argument" => (projectArgumentPreview value).map (fun projected => ("argument", projected, true))
      | "remedyCommand" => (validateStringField value).map (fun projected => ("remedy_command", projected, true))
      | "descriptorPath" =>
          (validateStringField value).map (fun projected => ("descriptor_path", projected, true))
      | "recoveryCommand" =>
          (validateStringField value).map (fun projected => ("recovery_command", projected, true))
      | "installationRoot" =>
          (validateStringField value).map (fun projected => ("installation_root", projected, true))
      | "currentInstallationRoot" =>
          (validateStringField value).map (fun projected => ("current_installation_root", projected, true))
      | "operationMayHaveCompleted" =>
          (validateBoolField value).map (fun projected => ("operation_may_have_completed", projected, true))
      | "operationResponse" => pure ("operation_response", value, true)
      | "sessionDir" => (validateStringField value).map (fun projected => ("session_dir", projected, true))
      | "recoveryPrecondition" =>
          (validateStringField value).map (fun projected => ("recovery_precondition", projected, true))
      | "recordedConfigHash" =>
          (validateStringField value).map (fun projected => ("recorded_config_hash", projected, true))
      | "requestedConfigHash" =>
          (validateStringField value).map (fun projected => ("requested_config_hash", projected, true))
      | _ => pure (key, value, false)
    recognized := recognized || isOwned
    projected := projected ++ [(publicKey, publicValue)]
  pure <| if recognized then some <| Json.mkObj projected else none

private def projectControlErrorData (code : String) (data : Json) : Option Json :=
  match projectControlErrorDataImpl code data with
  | .ok projected => projected
  | .error detail => some <| errorDataProjectionFailure data detail

/-- Present one operation failure's recognized Beam-owned data fields as the shared public shape. -/
def OutputError.fromOperationFailure (operation : Operation)
    (failure : Beam.Broker.ResponseFailure) : OutputError :=
  {
    code := failure.error.code
    message := failure.error.message
    data? := failure.error.data?.map fun data =>
      (projectBrokerErrorData operation failure.error.code data).getD (opaqueErrorData data)
    documentProgress? := failure.fileProgress?
  }

/-- Present known CLI/control error metadata; unknown or malformed data stays opaque as evidence.
Call this only at a control-error boundary; operation failures use their typed operation contract. -/
def OutputError.fromControlFailure (failure : Beam.Broker.ResponseFailure) : OutputError :=
  let projectData (data : Json) :=
    match projectBrokerErrorData .opaque failure.error.code data with
    | some projected => projected
    | none => (projectControlErrorData failure.error.code data).getD (opaqueErrorData data)
  {
    code := failure.error.code
    message := failure.error.message
    data? := failure.error.data?.map projectData
    documentProgress? := failure.fileProgress?
  }

private def todoItemJson (item : Beam.LSP.Todo.TodoItem) : Json := Json.mkObj <|
  [
    ("kind", toJson item.kind),
    ("range", toJson item.range)
  ] ++
  (match item.runAtPosition? with
  | some position => [("run_at_position", toJson position)]
  | none => []) ++
  (match item.message? with
  | some message => [("message", toJson message)]
  | none => []) ++
  (match item.severity? with
  | some severity => [("severity", toJson <| diagnosticSeverityName (some severity))]
  | none => []) ++
  (match item.codeAction? with
  | some codeAction => [("code_action", toJson codeAction)]
  | none => []) ++
  (match item.proofState? with
  | some proofState => [("proof_state", proofStateJson proofState)]
  | none => [])

private def todoResultJson (result : Beam.LSP.Todo.TodoResult) : Json := Json.mkObj [
  ("version", toJson result.version),
  ("range", toJson result.range),
  ("items", Json.arr <| result.items.map todoItemJson)
]

/--
Map only the Beam-owned fields in its stats result. Nested operation names and arbitrary values are
protocol-owned and kept intact; the structures are decoded above this point by their producer.
-/
private def statsFields : List (String × String) := [
  ("uptimeMs", "uptime_ms"), ("daemonIdentity", "daemon_identity"),
  ("daemonId", "daemon_id"), ("configHash", "config_hash"),
  ("openDocCount", "open_doc_count"),
  ("sessionStarts", "session_starts"), ("sessionRestarts", "session_restarts"),
  ("requestCount", "request_count"), ("successCount", "success_count"),
  ("errorCount", "error_count"), ("cancelledCount", "cancelled_count"),
  ("workerExitedCount", "worker_exited_count"), ("invalidParamsCount", "invalid_params_count"),
  ("avgLatencyMs", "avg_latency_ms"), ("maxLatencyMs", "max_latency_ms"),
  ("lastLatencyMs", "last_latency_ms")
]

private def renameFields (json : Json) (renames : List (String × String)) : Json :=
  match json with
  | .obj fields => Json.mkObj <| fields.toList.map fun (key, value) =>
      ((renames.find? fun (sourceName, _) => sourceName == key).map Prod.snd |>.getD key, value)
  | _ => json

private def outputObject (label : String) (allowed : Array String) (json : Json) :
    Except OutputError Json := do
  match json with
  | .obj _ => pure ()
  | _ => throw <| OutputError.invalidResult s!"{label} must be an object"
  (Beam.requireOnlyJsonFields label allowed json).mapError OutputError.invalidResult
  pure json

private def outputField (α : Type) [FromJson α] (label : String) (json : Json) (name : String) :
    Except OutputError α :=
  (json.getObjValAs? α name).mapError fun error =>
    OutputError.invalidResult s!"invalid {label} field '{name}': {error}"

private def statsOperationEntry (json : Json) : Except OutputError Json := do
  let names := #["count", "successCount", "errorCount", "cancelledCount",
    "workerExitedCount", "invalidParamsCount", "avgLatencyMs", "maxLatencyMs",
    "lastLatencyMs"]
  let json ← outputObject "operation stats" names json
  for name in names do
    let _ ← outputField Nat "operation stats" json name
  pure <| renameFields json statsFields

private def statsMetrics (json : Json) : Except OutputError Json := do
  let names := #["sessionStarts", "sessionRestarts", "requestCount", "successCount",
    "errorCount", "cancelledCount", "workerExitedCount", "invalidParamsCount", "ops"]
  let json ← outputObject "workspace metrics" names json
  for name in names.filter (· != "ops") do
    let _ ← outputField Nat "workspace metrics" json name
  let operations ← outputField Json "workspace metrics" json "ops"
  let .obj operations := operations
    | throw <| OutputError.invalidResult "workspace metrics 'ops' must be an object"
  let mut entries := []
  for (name, stats) in operations.toList do
    entries := entries ++ [(name, ← statsOperationEntry stats)]
  pure <| (renameFields json statsFields).setObjVal! "ops" (Json.mkObj entries)

private def statsSession (json : Json) : Except OutputError Json := do
  let json ← outputObject "session stats" #["active", "epoch", "openDocCount"] json
  let active ← outputField Bool "session stats" json "active"
  if active then
    let epoch ← outputField Nat "session stats" json "epoch"
    let openDocCount ← outputField Nat "session stats" json "openDocCount"
    pure <| Json.mkObj [
      ("active", toJson true),
      ("epoch", toJson epoch),
      ("open_doc_count", toJson openDocCount)
    ]
  else
    match json.getObjVal? "epoch", json.getObjVal? "openDocCount" with
    | .error _, .error _ => pure <| Json.mkObj [("active", toJson false)]
    | _, _ => throw <| OutputError.invalidResult "inactive session stats must omit 'epoch' and 'openDocCount'"

private def statsWorkspaceFields (json : Json) (isScoped : Bool) : Except OutputError Json := do
  let names := if isScoped then
    #["id", "root", "session", "metrics", "uptimeMs", "daemonIdentity"]
  else
    #["id", "root", "session", "metrics"]
  let json ← outputObject "workspace stats" names json
  let _ ← outputField String "workspace stats" json "id"
  let _ ← outputField String "workspace stats" json "root"
  let session ← outputField Json "workspace stats" json "session"
  let metrics ← outputField Json "workspace stats" json "metrics"
  if isScoped then
    let _ ← outputField Nat "workspace stats" json "uptimeMs"
  let session ← statsSession session
  let metrics ← statsMetrics metrics
  let mut json := renameFields json statsFields
  json := json.setObjVal! "session" session |>.setObjVal! "metrics" metrics
  if let .ok identity := json.getObjVal? "daemon_identity" then
    let identity ← outputObject "daemon identity" #["daemonId", "configHash"] identity
    let _ ← outputField String "daemon identity" identity "daemonId"
    let _ ← outputField String "daemon identity" identity "configHash"
    json := json.setObjVal! "daemon_identity" <| renameFields identity
      [("daemonId", "daemon_id"), ("configHash", "config_hash")]
  pure json

private def globalStatsResultJson (json : Json) : Except OutputError Json := do
  let json ← outputObject "stats" #["uptimeMs", "workspaces", "daemonIdentity"] json
  let _ ← outputField Nat "stats" json "uptimeMs"
  let workspaces ← outputField Json "stats" json "workspaces"
  let .obj workspaces := workspaces
    | throw <| OutputError.invalidResult "stats 'workspaces' must be an object"
  let mut entries := []
  for (name, workspace) in workspaces.toList do
    entries := entries ++ [(name, ← statsWorkspaceFields workspace false)]
  let mut json := renameFields json statsFields
  json := json.setObjVal! "workspaces" (Json.mkObj entries)
  if let .ok identity := json.getObjVal? "daemon_identity" then
    let identity ← outputObject "daemon identity" #["daemonId", "configHash"] identity
    let _ ← outputField String "daemon identity" identity "daemonId"
    let _ ← outputField String "daemon identity" identity "configHash"
    json := json.setObjVal! "daemon_identity" <| renameFields identity
      [("daemonId", "daemon_id"), ("configHash", "config_hash")]
  pure json

private def diskStatus : Json → Except OutputError Json
  | .str "matchesTracked" => pure <| toJson "matches_tracked"
  | .str "differsFromTracked" => pure <| toJson "differs_from_tracked"
  | .str "missing" => pure <| toJson "missing"
  | .str "unknown" => pure <| toJson "unknown"
  | _ => throw <| OutputError.invalidResult "open-doc disk status is invalid"

private def openDocsFile (json : Json) : Except OutputError Json := do
  let names := #["uri", "version", "diskStatus", "checkpointed", "path", "fileProgress", "workerError"]
  let json ← outputObject "open-doc file" names json
  let _ ← outputField String "open-doc file" json "uri"
  let _ ← outputField Nat "open-doc file" json "version"
  let status ← outputField Json "open-doc file" json "diskStatus"
  let status ← diskStatus status
  let _ ← outputField Bool "open-doc file" json "checkpointed"
  let mut fields := [
    ("uri", ← outputField Json "open-doc file" json "uri"),
    ("version", toJson (← outputField Nat "open-doc file" json "version")),
    ("disk_status", status),
    ("checkpointed", toJson (← outputField Bool "open-doc file" json "checkpointed"))
  ]
  if let .ok path := json.getObjVal? "path" then
    let path ← fromJson? (α := String) path |>.mapError fun error =>
      OutputError.invalidResult s!"invalid open-doc file field 'path': {error}"
    fields := fields ++ [("path", toJson path)]
  if let .ok progress := json.getObjVal? "fileProgress" then
    let progress ← fromJson? (α := Beam.Broker.SyncFileProgress) progress |>.mapError fun error =>
      OutputError.invalidResult s!"invalid open-doc file field 'fileProgress': {error}"
    fields := fields ++ [("document_progress", Beam.Output.documentProgressJson progress)]
  if let .ok error := json.getObjVal? "workerError" then
    fields := fields ++ [("worker_error", error)]
  pure <| Json.mkObj fields

private def openDocsSession (json : Json) : Except OutputError Json := do
  let json ← outputObject "open-doc session" #["active", "files"] json
  let active ← outputField Bool "open-doc session" json "active"
  let files ← outputField Json "open-doc session" json "files"
  let .arr files := files
    | throw <| OutputError.invalidResult "open-doc session 'files' must be an array"
  let mut projected := #[]
  for file in files do
    projected := projected.push (← openDocsFile file)
  pure <| Json.mkObj [("active", toJson active), ("files", Json.arr projected)]

private def openDocsWorkspace (json : Json) : Except OutputError Json := do
  let json ← outputObject "open-doc workspace" #["root", "session", "workspace_id"] json
  let root ← outputField String "open-doc workspace" json "root"
  let session ← outputField Json "open-doc workspace" json "session"
  let session ← openDocsSession session
  let mut fields := [("root", toJson root), ("session", session)]
  if let .ok workspaceId := json.getObjVal? "workspace_id" then
    let workspaceId ← fromJson? (α := String) workspaceId |>.mapError fun error =>
      OutputError.invalidResult s!"invalid open-doc workspace field 'workspace_id': {error}"
    fields := fields ++ [("workspace_id", toJson workspaceId)]
  pure <| Json.mkObj fields

private def globalOpenDocsResultJson (json : Json) : Except OutputError Json := do
  let json ← outputObject "open-docs" #["workspaces"] json
  let workspaces ← outputField Json "open-docs" json "workspaces"
  let .obj workspaces := workspaces
    | throw <| OutputError.invalidResult "open-docs 'workspaces' must be an object"
  let mut entries := []
  for (name, workspace) in workspaces.toList do
    entries := entries ++ [(name, ← openDocsWorkspace workspace)]
  pure <| Json.mkObj [("workspaces", Json.mkObj entries)]

private def decodeResult [FromJson α] (op : String) (json : Json) (present : α → Json) :
    Except OutputError Json := do
  match fromJson? json with
  | .ok result => pure <| present result
  | .error error => throw <| OutputError.invalidResult s!"{op} result is invalid: {error}"

/-- Project one broker result into the shared CLI and MCP field names. -/
def projectResult (operation : Operation) (json : Json) : Except OutputError Json := do
  match operation with
  | .opaque => pure json
  | .globalStats => globalStatsResultJson json
  | .workspaceStats => statsWorkspaceFields json true
  | .globalOpenDocs => globalOpenDocsResultJson json
  | .workspaceOpenDocs => openDocsWorkspace json
  | .closeSave =>
      decodeResult "close-save" json closeSaveResultJson
  | .broker op =>
    match op with
    | .runAt | .runWith =>
        decodeResult "runAt" json runAtResultJson
    | .todo =>
        decodeResult "todo" json todoResultJson
    | .codeActionResolve =>
        decodeResult (α := Beam.Broker.CodeActionResolveResult) "code action resolve" json fun result => Json.mkObj [
          ("version", toJson result.version), ("code_action", toJson result.codeAction)
        ]
    | .syncFile | .refreshFile =>
        decodeResult "sync" json syncResultJson
    | .saveOlean =>
        decodeResult "save" json saveResultJson
    | .goals =>
        decodeResult "goals" json proofStateJson
    | .stats | .openDocs => throw <| OutputError.invalidResult "result operation requires explicit workspace scope"
    | .ensure | .cancel | .updateFile | .close | .hover | .signatureHelp | .definition
    | .references | .documentSymbols | .workspaceSymbols | .release | .initWorkspace
    | .listWorkspaces | .dropWorkspace | .shutdown => pure json

/--
Project a typed broker response into the shared result shape. Diagnostic progress belongs to the
operation response and is preserved at this boundary for both CLI and MCP, including failures.
-/
def projectResponse (operation : Operation) (response : Beam.Broker.Response) :
    Except OutputError Json := do
  match response with
  | .errorResult failure => throw <| OutputError.fromOperationFailure operation failure
  | .successResult result progress? =>
      let projected ← match projectResult operation result with
        | .ok projected => pure projected
        | .error error =>
            -- The operation may have committed before its public projection failed. Retain the
            -- typed broker receipt as evidence; a presentation failure never erases that outcome.
            throw { error with
              data? := some <| Json.mkObj [("observed_response", toJson response)]
              documentProgress? := progress? }
      -- MCP structured results are objects. Keep the same shape on both surfaces, independent
      -- of whether this request happened to observe document progress.
      let projected := match projected with
        | .obj _ => projected
        | other => Json.mkObj [("value", other)]
      match progress? with
      | some progress =>
          pure <| projected.setObjVal! "document_progress" (Beam.Output.documentProgressJson progress)
      | none => pure projected

end Beam.Output
