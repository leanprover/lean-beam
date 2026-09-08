/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.Feedback
import Beam.JsonSchema
import Beam.Mcp.Json
import Beam.Version
import Beam.Workspace
import Beam.LSP.Lib.Goal
import Beam.LSP.RunAt

open Lean

namespace Beam.Mcp

/--
Agent-facing MCP tool names supported by the Lean projection.

This is intentionally smaller than the broker and LSP surfaces. In particular, raw LSP method names
such as `$/lean/runAt` are not accepted here.
-/
inductive ToolName where
  | beamVersion
  | beamStats
  | beamFeedbackReport
  | leanDropWorkspace
  | leanOperation (operation : Beam.Lean.Operation)
  deriving BEq, Repr

private def leanOperationToolKey (operation : Beam.Lean.Operation) : String :=
  "lean_" ++ operation.key

def ToolName.leanOperationTools : Array ToolName :=
  Beam.Lean.Operation.all.map ToolName.leanOperation

def ToolName.all : Array ToolName :=
  #[
    .beamVersion,
    .beamStats,
    .beamFeedbackReport,
    .leanDropWorkspace
  ] ++ ToolName.leanOperationTools

def ToolName.key (tool : ToolName) : String :=
  match tool with
  | .beamVersion => "beam_version"
  | .beamStats => "beam_stats"
  | .beamFeedbackReport => "beam_feedback_report"
  | .leanDropWorkspace => "lean_drop_workspace"
  | .leanOperation operation => leanOperationToolKey operation

def ToolName.fromKey? (key : String) : Option ToolName :=
  ToolName.all.find? (fun tool => tool.key == key)

instance : ToJson ToolName where
  toJson tool := toJson tool.key

instance : FromJson ToolName where
  fromJson?
    | .str key =>
        match ToolName.fromKey? key with
        | some tool => .ok tool
        | none => .error s!"expected Lean MCP tool name, got {toJson key |>.compress}"
    | j => .error s!"expected Lean MCP tool name, got {j.compress}"

/--
Effective MCP tool effect annotations, including the protocol defaults. Serialization emits only
fields whose values differ from those defaults.
-/
structure ToolEffectAnnotations where
  readOnlyHint : Bool := false
  destructiveHint : Bool := true
  idempotentHint : Bool := false
  deriving BEq, Repr

def ToolEffectAnnotations.toJson? (annotations : ToolEffectAnnotations) : Option Json :=
  let fields :=
    (if annotations.readOnlyHint then
      [("readOnlyHint", toJson true)]
    else
      []) ++
    (if !annotations.destructiveHint then
      [("destructiveHint", toJson false)]
    else
      []) ++
    (if annotations.idempotentHint then
      [("idempotentHint", toJson true)]
    else
      [])
  if fields.isEmpty then none else some <| Json.mkObj fields

/--
Advisory MCP classification of each tool's Beam-managed effects. Speculative execution is not an OS
sandbox for user-supplied Lean code.
-/
def ToolName.annotations : ToolName → ToolEffectAnnotations
  | .beamVersion
  | .beamStats
  | .leanOperation .runAt
  | .leanOperation .hover
  | .leanOperation .signatureHelp
  | .leanOperation .definition
  | .leanOperation .references
  | .leanOperation .documentSymbols
  | .leanOperation .workspaceSymbols
  | .leanOperation .goals
  | .leanOperation .todo
  | .leanOperation .codeActionResolve => { readOnlyHint := true }
  | .leanOperation .runAtHandle
  | .leanOperation .runWith => { destructiveHint := false }
  | .leanDropWorkspace
  | .leanOperation .close => { idempotentHint := true }
  | .beamFeedbackReport
  | .leanOperation .runWithLinear
  | .leanOperation .release
  | .leanOperation .update
  | .leanOperation .sync
  | .leanOperation .refresh
  | .leanOperation .save
  | .leanOperation .closeSave => {}

def leanOperationToBrokerRequest
    (operation : Beam.Lean.Operation)
    (workspaceId : Beam.Workspace.WorkspaceId)
    (input : Json) : Except String Beam.Broker.Request := do
  let operationInput ←
    match input with
    | .obj fields => pure <| Json.obj (fields.erase "workspace")
    | other => throw s!"Lean operation input must be an object, got {other.compress}"
  let req ← operation.toBrokerRequest operationInput
  pure { req with workspaceId? := some workspaceId }

def beamVersionDescription : String :=
  "Return the running Lean Beam MCP server identity for bug reports and refresh checks."

def beamStatsDescription : String :=
  "Return process-wide debug Beam broker runtime statistics for lazily cached workspaces."

private def progressDiscovery (delayedActivity : String) : String :=
  "For detailed live updates, clients can pass `tools/call` `_meta.progressToken`; without one, " ++
    s!"Beam emits one status log when {delayedActivity} and the request's logging policy admits " ++
    "notice-level events."

def beamFeedbackReportDescription : String :=
  String.intercalate " " [
    "Beam does not upload or submit feedback. This tool creates and returns a pasteable feedback report for one explicit workspace.",
    "Non-confidential output may contain project context and caller payloads, so review it before posting.",
    "Set confidential for non-public workspaces; confidential results retain caller-authored narrative",
    "except for HOME-path redaction and do not scan it for other secrets; never post them publicly.",
    "A local evidence bundle is optional.",
    progressDiscovery "collection is delayed"
  ]

open Beam.JsonSchema in
def emptyInputSchema : Json :=
  inputObject [] #[]

private def anyJsonSchema (description : String) : Json :=
  Json.mkObj [
    ("description", toJson description)
  ]

private def arraySchema (description : String) (items : Json) : Json :=
  Json.mkObj [
    ("type", toJson "array"),
    ("description", toJson description),
    ("items", items)
  ]

private def evidenceInputSchema : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson "Optional inline or file evidence to copy into a feedback bundle."),
    ("properties", Json.mkObj [
      ("name", Beam.JsonSchema.string "Simple evidence filename, without path separators."),
      ("content", anyJsonSchema "Inline JSON or text evidence to write into the bundle."),
      ("path", Beam.JsonSchema.string
        "Path to a local evidence file under the known root or selected Beam session directory.")
    ]),
    ("required", toJson (#[("name" : String)] : Array String)),
    ("additionalProperties", toJson false)
  ]

private def workspaceDescriptorSchema : Json :=
  Json.mkObj [
    ("type", toJson "object"),
    ("description", toJson "Explicit local Lean workspace descriptor."),
    ("properties", Json.mkObj [
      ("root", Beam.JsonSchema.string "Absolute Lean/Lake project root path.")
    ]),
    ("required", toJson (#["root"] : Array String)),
    ("additionalProperties", toJson false)
  ]

open Beam.JsonSchema in
def feedbackReportInputSchema : Json :=
  inputObject [
    ("workspace", workspaceDescriptorSchema),
    ("title", string "Short report title."),
    ("summary", string "What went wrong or what feedback should be reviewed."),
    ("reproduction", string "Concrete steps or commands needed to reproduce the behavior."),
    ("expected", string "Expected behavior."),
    ("actual", string "Observed behavior."),
    ("kind", enumString "Optional triage category." Beam.Feedback.reportKindKeys),
    ("severity", enumString "Optional triage severity." Beam.Feedback.reportSeverityKeys),
    ("impact", string "Optional user impact."),
    ("workaround", string "Optional workaround."),
    ("tags", arraySchema "Optional short labels for routing the report." (string "Feedback tag.")),
    ("client_request_id", string "Optional caller-side correlation id."),
    ("request", object "Optional request payload relevant to the report."),
    ("response", object "Optional response payload relevant to the report."),
    ("evidence", arraySchema "Optional evidence entries to include in a bundle." evidenceInputSchema),
    ("bundle", enumString "Optional evidence bundle mode. Defaults to none." Beam.Feedback.bundleModeKeys),
    ("redact", bool "Whether to redact the user's home directory from the rendered report. Defaults to true."),
    ("confidential", bool "Set true for a non-public workspace. Forces HOME-path redaction; omits automatically collected project debug context, caller-supplied request, response, evidence, and the echoed workspace descriptor; retains other caller-authored narrative without scanning it for arbitrary secrets; and marks the report as confidential. Defaults to false."),
    ("include_collected", bool "When true, include collected Beam debug context inline in the MCP result. In confidential mode, include only the restricted runtime identity. Defaults to false.")
  ] (Beam.Feedback.requiredInputFields.push "workspace")

def dropWorkspaceDescription : String :=
  String.intercalate " " [
    "Evict one local Lean workspace cache and invalidate its retained proof handles.",
    "A later request recreates it lazily.",
    progressDiscovery "eviction is delayed"
  ]

open Beam.JsonSchema in
def dropWorkspaceInputSchema : Json :=
  inputObject [
    ("workspace", workspaceDescriptorSchema)
  ] #["workspace"]

private def schemaWithWorkspace (schema : Json) : Json :=
  match Beam.JsonSchema.withRequiredProperty schema "workspace" workspaceDescriptorSchema with
  | .ok schema => schema
  | .error err => panic! s!"invalid generated Lean operation schema: {err}"

/-- Minimal descriptor for the MCP tool list. -/
structure ToolDescriptor where
  name : ToolName
  description : String
  inputSchema : Json
  annotations : ToolEffectAnnotations

def toolNames : Array ToolName :=
  ToolName.all

private def leanOperationProjectionGuidance : Beam.Lean.Operation → List String
  | .runAt | .runAtHandle | .runWith | .runWithLinear =>
      ["In MCP, this means: only then call lean_sync."]
  | .codeActionResolve =>
      ["Pass the CodeAction payload returned by lean_todo."]
  | _ => []

def ToolName.descriptor (tool : ToolName) : ToolDescriptor :=
  let (description, inputSchema) :=
    match tool with
    | .beamVersion => (beamVersionDescription, emptyInputSchema)
    | .beamStats => (beamStatsDescription, emptyInputSchema)
    | .beamFeedbackReport => (beamFeedbackReportDescription, feedbackReportInputSchema)
    | .leanOperation op =>
        (String.intercalate " " <|
          [op.behaviorDescription] ++
          leanOperationProjectionGuidance op ++
          [
            progressDiscovery "setup or a long-running request is detected",
            Beam.Lean.sourceFileInvariant
          ], schemaWithWorkspace op.inputSchema)
    | .leanDropWorkspace => (dropWorkspaceDescription, dropWorkspaceInputSchema)
  { name := tool, description, inputSchema, annotations := tool.annotations }

def toolDescriptors : Array ToolDescriptor :=
  toolNames.map ToolName.descriptor

/-- Reject fields outside the closed schema advertised for one MCP tool. -/
def ToolName.validateInputFields (tool : ToolName) (input : Json) : Except String Unit :=
  Beam.JsonSchema.validateInputFields tool.key tool.descriptor.inputSchema input

abbrev RunAtInput := Beam.Lean.RunAtInput
abbrev PositionInput := Beam.Lean.PositionInput
abbrev ReferencesInput := Beam.Lean.ReferencesInput
abbrev DocumentSymbolsInput := Beam.Lean.DocumentSymbolsInput
abbrev WorkspaceSymbolsInput := Beam.Lean.WorkspaceSymbolsInput
abbrev GoalsInput := Beam.Lean.GoalsInput
abbrev TodoInput := Beam.Lean.TodoInput
abbrev CodeActionResolveInput := Beam.Lean.CodeActionResolveInput
abbrev RunWithInput := Beam.Lean.RunWithInput
abbrev ReleaseInput := Beam.Lean.ReleaseInput
abbrev PathInput := Beam.Lean.PathInput
abbrev SyncInput := Beam.Lean.SyncInput
abbrev SaveInput := Beam.Lean.SaveInput

private def optionJson (value? : Option α) [ToJson α] : Json :=
  match value? with
  | some value => toJson value
  | none => Json.null

/-- Broker-level `runAt` result shape after the broker has wrapped any retained handle. -/
structure RunAtBrokerResult where
  success : Bool := true
  messages : Array Beam.LSP.RunAt.Message := #[]
  traces : Array String := #[]
  handle? : Option Beam.Broker.Handle := none
  proofState? : Option Beam.LSP.Lib.ProofState := none

instance : FromJson RunAtBrokerResult where
  fromJson? j := do
    let success? ← optionalField? (α := Bool) j "success"
    let messages? ← optionalField? (α := Array Beam.LSP.RunAt.Message) j "messages"
    let traces? ← optionalField? (α := Array String) j "traces"
    let handle? ← optionalField? (α := Beam.Broker.Handle) j "handle"
    let proofState? ← optionalField? (α := Beam.LSP.Lib.ProofState) j "proofState"
    pure {
      success := success?.getD true
      messages := messages?.getD #[]
      traces := traces?.getD #[]
      handle?
      proofState?
    }

structure ToolError where
  code : String
  message : String := ""
  data? : Option Json := none
  deriving ToJson

def ToolError.fromBrokerError (err : Beam.Broker.Error) : ToolError :=
  { code := err.code, message := err.message, data? := err.data? }

def ToolError.invalidResult (message : String) : ToolError :=
  { code := "invalidResult", message }

def ToolError.invalidInput (message : String) : ToolError :=
  { code := "invalidInput", message }

/--
Normalize a broker-level `runAt` result into the agent-facing field names.

The MCP surface uses `next_handle` and `proof_state` rather than the Lean/LSP payload's
`handle`/`proofState` names. `next_handle` is the broker-wrapped handle that follow-up tools pass
back unchanged.
-/
def runAtResultJson (result : RunAtBrokerResult) : Json :=
  Json.mkObj [
    ("success", toJson result.success),
    ("messages", toJson result.messages),
    ("traces", toJson result.traces),
    ("proof_state", optionJson result.proofState?),
    ("next_handle", optionJson result.handle?)
  ]

def normalizeRunAtResult (result : Json) : Except ToolError Json := do
  match fromJson? (α := RunAtBrokerResult) result with
  | .ok parsed => pure <| runAtResultJson parsed
  | .error err => throw <| ToolError.invalidResult err

private def todoItemKey (key : String) : String :=
  match key with
  | "runAtPosition" => "run_at_position"
  | "runAtText" => "run_at_text"
  | "codeAction" => "code_action"
  | "proofState" => "proof_state"
  | other => other

private def normalizeTodoItemJson : Json → Json
  | Json.obj fields =>
      let fields :=
        fields.foldl (init := []) fun acc key value =>
          (todoItemKey key, value) :: acc
      Json.mkObj fields.reverse
  | other => other

private def normalizeTodoResult (result : Json) : Except ToolError Json := do
  match result.getObjVal? "items" with
  | .ok (Json.arr items) =>
      pure <| result.setObjVal! "items" (Json.arr (items.map normalizeTodoItemJson))
  | .ok _ =>
      throw <| ToolError.invalidResult "todo result 'items' must be an array"
  | .error err =>
      throw <| ToolError.invalidResult s!"todo result missing 'items': {err}"

private def normalizeCodeActionResolveResult : Json → Except ToolError Json
  | Json.obj fields =>
      let fields :=
        fields.foldl (init := []) fun acc key value =>
          let key :=
            if key == "codeAction" then
              "code_action"
            else
              key
          (key, value) :: acc
      pure <| Json.mkObj fields.reverse
  | other =>
      throw <| ToolError.invalidResult
        s!"code_action_resolve result must be an object, got {other.compress}"

private def diagnosticSeverityName : Option Lean.Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "information"
  | some .hint => "hint"
  | none => "unknown"

/-- Project a broker diagnostic onto the shared MCP log and result representation. -/
def diagnosticJson (diagnostic : Beam.Broker.StreamDiagnostic) : Json :=
  Json.mkObj <|
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
    match diagnostic.snapshot? with
    | some snapshot => [("snapshot", toJson snapshot)]
    | none => []

private def blockingDiagnosticJson (diagnostic : Beam.Broker.SyncBlockingDiagnostic) : Json :=
  Json.mkObj [
    ("range", toJson diagnostic.range),
    ("severity", toJson <| diagnosticSeverityName diagnostic.severity?),
    ("message", toJson diagnostic.message),
    ("save_blocking", toJson diagnostic.saveBlocking),
    ("completion_blocking", toJson diagnostic.completionBlocking)
  ]

private def blockingMessageJson (message : Beam.Broker.SyncBlockingCommandMessage) : Json :=
  Json.mkObj [
    ("message", toJson message.message),
    ("save_blocking", toJson message.saveBlocking),
    ("completion_blocking", toJson message.completionBlocking)
  ]

private def syncResultJson (result : Beam.Broker.SyncFileResult) : Json :=
  let diagnosticFields :=
    match result.diagnostics.items? with
    | some items => [("items", Json.arr <| items.map diagnosticJson)]
    | none => []
  Json.mkObj [
    ("path", toJson result.path),
    ("snapshot", toJson result.snapshot),
    ("diagnostics", Json.mkObj <|
      [("counts", toJson result.diagnostics.counts)] ++ diagnosticFields),
    ("readiness", Json.mkObj [
      ("save_ready", toJson result.readiness.saveReady),
      ("reason", toJson result.readiness.reason),
      ("blocking_error_count", toJson result.readiness.blockingErrorCount),
      ("blocking_diagnostics", Json.arr <|
        result.readiness.blockingDiagnostics.map blockingDiagnosticJson),
      ("blocking_messages", Json.arr <|
        result.readiness.blockingMessages.map blockingMessageJson)
    ])
  ]

private def normalizeSyncResult (result : Json) : Except ToolError Json :=
  match fromJson? (α := Beam.Broker.SyncFileResult) result with
  | .ok result => pure <| syncResultJson result
  | .error err => throw <| ToolError.invalidResult s!"sync result is invalid: {err}"

private def saveResultJson (result : Beam.Broker.SaveOleanResult) : Json :=
  Json.mkObj <|
    [
      ("path", toJson result.path),
      ("module", toJson result.module),
      ("snapshot", toJson result.snapshot),
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
    (match result.bc? with
    | some path => [("bc", toJson path)]
    | none => []) ++
    [("sync", syncResultJson result.sync)]

private def normalizeSaveResult (result : Json) : Except ToolError Json :=
  match fromJson? (α := Beam.Broker.SaveOleanResult) result with
  | .ok result => pure <| saveResultJson result
  | .error err => throw <| ToolError.invalidResult s!"save result is invalid: {err}"

private def normalizeCloseSaveResult (result : Json) : Except ToolError Json := do
  let closeSaveResult ←
    fromJson? (α := Beam.Broker.CloseSaveResult) result
      |>.mapError fun err => ToolError.invalidResult s!"close-save result is invalid: {err}"
  pure <| Json.mkObj [
    ("closed", toJson closeSaveResult.closed),
    ("saved", saveResultJson closeSaveResult.saved)
  ]

private inductive ResultProjection where
  | identity
  | runAt
  | todo
  | codeActionResolve
  | sync
  | save
  | closeSave

private def ToolName.resultProjection : ToolName → ResultProjection
  | .leanOperation .runAt
  | .leanOperation .runAtHandle
  | .leanOperation .runWith
  | .leanOperation .runWithLinear => .runAt
  | .leanOperation .todo => .todo
  | .leanOperation .codeActionResolve => .codeActionResolve
  | .leanOperation .sync
  | .leanOperation .refresh => .sync
  | .leanOperation .save => .save
  | .leanOperation .closeSave => .closeSave
  | _ => .identity

private def normalizeResult (tool : ToolName) (result : Json) : Except ToolError Json :=
  match tool.resultProjection with
  | .identity => pure result
  | .runAt => normalizeRunAtResult result
  | .todo => normalizeTodoResult result
  | .codeActionResolve => normalizeCodeActionResolveResult result
  | .sync => normalizeSyncResult result
  | .save => normalizeSaveResult result
  | .closeSave => normalizeCloseSaveResult result

private def ensureObject (json : Json) : Json :=
  match json with
  | .obj _ => json
  | other => Json.mkObj [("result", other)]

private def documentProgressJson (progress : Beam.Broker.SyncFileProgress) : Json :=
  Json.mkObj <|
    [
      ("updates", toJson progress.updates),
      ("done", toJson progress.done)
    ] ++
    (match progress.rangeStartLine? with
    | some line => [("range_start_line", toJson line)]
    | none => []) ++
    match progress.rangeEndLine? with
    | some line => [("range_end_line", toJson line)]
    | none => []

private def ToolName.reportsDocumentProgress : ToolName → Bool
  | .leanOperation .sync
  | .leanOperation .refresh
  | .leanOperation .save
  | .leanOperation .closeSave => true
  | _ => false

private def withDocumentProgress
    (tool : ToolName)
    (json : Json)
    (fileProgress? : Option Beam.Broker.SyncFileProgress) : Json :=
  let json := ensureObject json
  if !tool.reportsDocumentProgress then
    json
  else
    match fileProgress? with
    | some progress =>
        json.setObjVal! "document_progress" <| documentProgressJson progress
    | none => json

/--
Normalize a broker response into MCP tool result content.

Broker-level failures become `ToolError`s so an MCP server can map them to tool/JSON-RPC errors.
Semantic Lean failures remain normal tool results with `success = false`.
-/
def normalizeBrokerResponse (tool : ToolName) (resp : Beam.Broker.Response) : Except ToolError Json := do
  match resp with
  | .errorResult failure =>
      throw <| ToolError.fromBrokerError failure.error
  | .successResult result fileProgress? =>
      let result ← normalizeResult tool result
      pure <| withDocumentProgress tool result fileProgress?

end Beam.Mcp
