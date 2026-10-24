/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation
import Beam.Output
import Beam.Feedback
import Beam.JsonSchema
import Beam.Mcp.Json
import Beam.Version
import Beam.Workspace
import Beam.LSP.Lib.Goal
import Beam.LSP.RunAt

open Lean

namespace Beam.Mcp

open Beam.Output

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

/-- Rules shared by every tool, stated once instead of in each tool description. -/
def serverInstructions : String :=
  String.intercalate " " [
    "Use an explicit local workspace descriptor on every workspace-bound Beam tool call.",
    Beam.Lean.sourceFileInvariant,
    "Edit and save files with your own tools, then call lean_update or lean_sync before version-bound queries.",
    "For detailed live updates, clients can pass `tools/call` `_meta.progressToken`; without one,",
    "Beam emits at most one `beam.status` notice when setup or a slow call is detected and the",
    "request's logging policy admits notice-level events."
  ]

def beamFeedbackReportDescription : String :=
  String.intercalate " " [
    "Beam does not upload or submit feedback. This tool creates and returns a pasteable feedback report for one explicit workspace.",
    "Non-confidential output may contain project context and caller payloads, so review it before posting.",
    "Set confidential for non-public workspaces; confidential results retain caller-authored narrative",
    "except for HOME-path redaction and do not scan it for other secrets; never post them publicly.",
    "A local evidence bundle is optional."
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
    "A later request recreates it lazily."
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
          [op.description (syncOperation := "lean_sync")] ++
          leanOperationProjectionGuidance op, schemaWithWorkspace op.inputSchema)
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

/-- Map the MCP tool selector to the shared transport-neutral output operation. -/
def ToolName.outputOperation : ToolName → Beam.Output.Operation
  | .beamStats => .globalStats
  | .leanOperation .runAt
  | .leanOperation .runAtHandle => .broker .runAt
  | .leanOperation .runWith
  | .leanOperation .runWithLinear => .broker .runWith
  | .leanOperation .todo => .broker .todo
  | .leanOperation .codeActionResolve => .broker .codeActionResolve
  | .leanOperation .sync => .broker .syncFile
  | .leanOperation .refresh => .broker .refreshFile
  | .leanOperation .save => .broker .saveOlean
  | .leanOperation .closeSave => .closeSave
  | .leanOperation .update => .broker .updateFile
  | .leanOperation .close => .broker .close
  | .leanOperation .hover => .broker .hover
  | .leanOperation .signatureHelp => .broker .signatureHelp
  | .leanOperation .definition => .broker .definition
  | .leanOperation .references => .broker .references
  | .leanOperation .documentSymbols => .broker .documentSymbols
  | .leanOperation .workspaceSymbols => .broker .workspaceSymbols
  | .leanOperation .goals => .broker .goals
  | .leanOperation .release => .broker .release
  | .beamVersion
  | .beamFeedbackReport
  | .leanDropWorkspace => .opaque

/-- Project a broker response into the common CLI and MCP result contract. -/
def normalizeBrokerResponse (tool : ToolName) (resp : Beam.Broker.Response) :
    Except Beam.Output.OutputError Json :=
  Beam.Output.projectResponse tool.outputOperation resp

end Beam.Mcp
