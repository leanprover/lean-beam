/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.JsonFields
import Beam.Broker.Protocol
import Beam.Broker.OpenDocs
import Beam.Workspace.Protocol
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

/-- A transport-neutral presentation error. `data` is opaque typed error detail from the owner. -/
structure OutputError where
  code : String
  message : String := ""
  data? : Option Json := none
  documentProgress? : Option Beam.Broker.SyncFileProgress := none
  deriving Inhabited

namespace OutputError

def fromBrokerError (error : Beam.Broker.Error)
    (documentProgress? : Option Beam.Broker.SyncFileProgress := none) : OutputError := {
  code := error.code
  message := error.message
  data? := error.data?
  documentProgress?
}

def fromBrokerFailure (failure : Beam.Broker.ResponseFailure) : OutputError :=
  fromBrokerError failure.error failure.fileProgress?

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

private def optionalField? [FromJson α] (json : Json) (name : String) : Except String (Option α) := do
  match json.getObjVal? name with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error error => throw s!"invalid '{name}': {error}"
  | .error _ => pure none

private instance : FromJson RunAtBrokerResult where
  fromJson? json := do
    requireOnlyJsonFields "runAt result" #["success", "messages", "traces", "handle", "proofState"] json
    let success ← json.getObjValAs? Bool "success"
    let messages ← json.getObjValAs? (Array Beam.LSP.RunAt.Message) "messages"
    let traces ← json.getObjValAs? (Array String) "traces"
    let handle? ← optionalField? (α := Beam.Broker.Handle) json "handle"
    let proofState? ← optionalField? (α := Beam.LSP.Lib.ProofState) json "proofState"
    pure {
      success
      messages
      traces
      handle?
      proofState?
    }

private def runAtResultJson (result : RunAtBrokerResult) : Json := Json.mkObj <|
  [
    ("success", toJson result.success),
    ("messages", Json.arr <| result.messages.map runAtMessageJson),
    ("traces", toJson result.traces)
  ] ++
  (match result.proofState? with
  | some proofState => [("proof_state", proofStateJson proofState)]
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

private def todoItemJson (item : Beam.LSP.Todo.TodoItem) : Json := Json.mkObj <|
  [
    ("kind", toJson item.kind),
    ("range", toJson item.range),
    ("run_at_position", toJson item.runAtPosition)
  ] ++
  (match item.runAtText? with
  | some text => [("run_at_text", toJson text)]
  | none => []) ++
  (match item.message? with
  | some message => [("message", toJson message)]
  | none => []) ++
  (match item.severity? with
  | some severity => [("severity", toJson <| diagnosticSeverityName (some severity))]
  | none => []) ++
  (match item.diagnostic? with
  | some diagnostic => [("diagnostic", toJson diagnostic)]
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
  | .errorResult failure => throw <| OutputError.fromBrokerFailure failure
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
        | other => Json.mkObj [("result", other)]
      match progress? with
      | some progress =>
          pure <| projected.setObjVal! "document_progress" (Beam.Output.documentProgressJson progress)
      | none => pure projected

end Beam.Output
