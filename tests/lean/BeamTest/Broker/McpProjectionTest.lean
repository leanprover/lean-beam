/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Broker.Metrics
import Beam.Broker.Readiness
import Beam.Broker.StaleDirectDeps
import Beam.Cli.Output
import Beam.JsonPretty
import Beam.Mcp.Projection
import Beam.Mcp.Protocol
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpProjectionTest

private def expectToolOk (label : String) (result : Except Beam.Output.OutputError Json) : IO Json := do
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: {err.code}: {err.message}"

private def expectToolError (label expectedCode : String) (result : Except Beam.Output.OutputError Json) :
    IO Beam.Output.OutputError := do
  match result with
  | .ok json =>
      throw <| IO.userError s!"{label}: expected error {expectedCode}, got {json.compress}"
  | .error err =>
      if err.code != expectedCode then
        throw <| IO.userError s!"{label}: expected error {expectedCode}, got {err.code}: {err.message}"
      pure err

private def expectRequestPayload
    (label : String)
    (request : Beam.Broker.Request)
    (project : Beam.Broker.RequestPayload → Option α) : IO α := do
  let some payload := project request.payload
    | throw <| IO.userError s!"{label}: unexpected broker operation {request.op.key}"
  pure payload

private def sampleBrokerHandle : Beam.Broker.Handle := {
  workspaceId := "local:/repo"
  epoch := 3
  session := "session"
  raw := toJson ({ value := "raw-handle" } : Beam.LSP.RunAt.Handle)
}

private def expectedLeanOperationSurface : Array Beam.Lean.Operation := #[
  .runAt,
  .runAtHandle,
  .hover,
  .signatureHelp,
  .definition,
  .references,
  .documentSymbols,
  .workspaceSymbols,
  .goals,
  .todo,
  .codeActionResolve,
  .runWith,
  .runWithLinear,
  .release,
  .update,
  .sync,
  .refresh,
  .save,
  .closeSave,
  .close
]

private def requireSameOperationSurface
    (label : String)
    (actual expected : Array Beam.Lean.Operation) : IO Unit := do
  require s!"{label}: expected size {expected.size}, got {actual.size}"
    (actual.size == expected.size)
  for op in expected do
    require s!"{label}: missing operation {repr op}" (actual.contains op)
  for op in actual do
    require s!"{label}: unexpected operation {repr op}" (expected.contains op)

private def checkToolNames : IO Unit := do
  let cases : Array (String × Beam.Mcp.ToolName) := #[
    ("beam_version", .beamVersion),
    ("beam_stats", .beamStats),
    ("beam_feedback_report", .beamFeedbackReport),
    ("lean_drop_workspace", .leanDropWorkspace),
    ("lean_run_at", .leanOperation .runAt),
    ("lean_hover", .leanOperation .hover),
    ("lean_signature_help", .leanOperation .signatureHelp),
    ("lean_definition", .leanOperation .definition),
    ("lean_references", .leanOperation .references),
    ("lean_document_symbols", .leanOperation .documentSymbols),
    ("lean_workspace_symbols", .leanOperation .workspaceSymbols),
    ("lean_goals", .leanOperation .goals),
    ("lean_todo", .leanOperation .todo),
    ("lean_code_action_resolve", .leanOperation .codeActionResolve),
    ("lean_refresh", .leanOperation .refresh),
    ("lean_close_save", .leanOperation .closeSave)
  ]
  for (key, expected) in cases do
    let decoded ← expectOk s!"decode {key}" <|
      fromJson? (α := Beam.Mcp.ToolName) (Json.str key)
    require s!"decode {key}: wrong tool" (decoded == expected)

  match fromJson? (α := Beam.Mcp.ToolName) (Json.str Beam.LSP.RunAt.method) with
  | .ok tool =>
      throw <| IO.userError s!"raw LSP method decoded as MCP tool: {repr tool}"
  | .error _ =>
      pure ()

  match fromJson? (α := Beam.Mcp.ToolName) (Json.str "lean_request_at") with
  | .ok tool =>
      throw <| IO.userError s!"raw request escape hatch decoded as MCP tool: {repr tool}"
  | .error _ =>
      pure ()

private def checkToolDescriptors : IO Unit := do
  requireSameOperationSurface "curated Lean operation surface"
    Beam.Lean.Operation.all
    expectedLeanOperationSurface
  require "tool descriptor count tracks tool name count"
    (Beam.Mcp.toolDescriptors.size == Beam.Mcp.toolNames.size)
  let mut seenToolKeys : Array String := #[]
  for tool in Beam.Mcp.toolNames do
    require s!"duplicate MCP tool name {tool.key}" (!seenToolKeys.contains tool.key)
    seenToolKeys := seenToolKeys.push tool.key
    let decoded ← expectOk s!"decode generated tool key {tool.key}" <|
      fromJson? (α := Beam.Mcp.ToolName) (Json.str tool.key)
    require s!"generated tool key should decode back to {repr tool}" (decoded == tool)
  require "Lean operation tool names track shared operation surface"
    (Beam.Mcp.ToolName.leanOperationTools.size == Beam.Lean.Operation.all.size)
  require "tool names are server tools, cache eviction, plus shared Lean operations"
    (Beam.Mcp.toolNames.size == Beam.Lean.Operation.all.size + 4)
  for op in Beam.Lean.Operation.all do
    let projectedTool : Beam.Mcp.ToolName := .leanOperation op
    require s!"Lean operation {repr op} should derive MCP key from operation key"
      (projectedTool.key == "lean_" ++ op.key)
    require s!"shared Lean operation {repr op} should not contain MCP transport guidance"
      (!op.description.contains "tools/call" && !op.description.contains "progressToken")
    require s!"projected MCP operation {repr op} should leave progress controls to instructions"
      (!projectedTool.descriptor.description.contains "progressToken")
    let matchingTools := Beam.Mcp.ToolName.leanOperationTools.filter (fun tool =>
      tool == .leanOperation op)
    require s!"Lean operation {repr op} should have exactly one MCP tool"
      (matchingTools.size == 1)
  -- Bound discovery text independently of how a client selects or caches tools. Shared guidance
  -- belongs in the server instructions; raising this budget needs a reason.
  let descriptionChars := Beam.Mcp.toolDescriptors.foldl (· + ·.description.length) 0
  require s!"MCP tool descriptions total {descriptionChars} characters, over their 4500 budget"
    (descriptionChars ≤ 4500)
  let some versionDesc := Beam.Mcp.toolDescriptors.find? (·.name == .beamVersion)
    | throw <| IO.userError "beam version descriptor is missing"
  let versionSchemaProperties ← requireObjVal "beam version schema" "properties" versionDesc.inputSchema
  require "beam version schema should have no input properties" (versionSchemaProperties == Json.mkObj [])
  let some statsDesc := Beam.Mcp.toolDescriptors.find? (·.name == .beamStats)
    | throw <| IO.userError "beam stats descriptor is missing"
  let statsSchemaProperties ← requireObjVal "beam stats schema" "properties" statsDesc.inputSchema
  require "beam stats schema should have no input properties" (statsSchemaProperties == Json.mkObj [])
  let some feedbackDesc := Beam.Mcp.toolDescriptors.find? (·.name == .beamFeedbackReport)
    | throw <| IO.userError "beam feedback report descriptor is missing"
  require "beam feedback report description states the no-upload contract"
    (feedbackDesc.description.startsWith "Beam does not upload or submit feedback.")
  require "beam feedback report description warns before public posting"
    (feedbackDesc.description.contains "review it before posting")
  require "beam feedback report description explains retained confidential narrative"
    (feedbackDesc.description.contains "retain caller-authored narrative")
  let feedbackSchemaProperties ←
    requireObjVal "beam feedback report schema" "properties" feedbackDesc.inputSchema
  let expectedFeedbackProperties :=
    Beam.Feedback.inputFields ++ #["workspace", "include_collected"]
  let .obj feedbackFields := feedbackSchemaProperties
    | throw <| IO.userError "beam feedback report schema properties must be an object"
  let actualFeedbackProperties :=
    (Std.TreeMap.Raw.toList feedbackFields).map (fun (field, _) => field) |>.toArray
  require "beam feedback report schema and runtime decoder should expose the same field count"
    (actualFeedbackProperties.size == expectedFeedbackProperties.size)
  for field in expectedFeedbackProperties do
    require s!"beam feedback report schema is missing runtime field {field}"
      (actualFeedbackProperties.contains field)
  for field in actualFeedbackProperties do
    require s!"beam feedback report schema exposes unsupported runtime field {field}"
      (expectedFeedbackProperties.contains field)
  let confidentialSchema ←
    requireObjVal "beam feedback report schema properties" "confidential" feedbackSchemaProperties
  let confidentialDescription ← expectOk "beam feedback report confidential schema description" <|
    confidentialSchema.getObjValAs? String "description"
  require "beam feedback report confidential schema explains retained caller narrative"
    (confidentialDescription.contains "retains other caller-authored narrative" &&
      confidentialDescription.contains "without scanning it for arbitrary secrets")
  require "beam feedback report confidential schema names every omitted caller payload"
    (confidentialDescription.contains "request" && confidentialDescription.contains "response" &&
      confidentialDescription.contains "evidence" &&
      confidentialDescription.contains "echoed workspace descriptor")
  let includeCollectedSchema ←
    requireObjVal "beam feedback report schema properties" "include_collected" feedbackSchemaProperties
  let includeCollectedDescription ←
    expectOk "beam feedback report include_collected schema description" <|
      includeCollectedSchema.getObjValAs? String "description"
  require "beam feedback report include_collected schema explains confidential restriction"
    (includeCollectedDescription.contains "only the restricted runtime identity")
  let some dropDesc := Beam.Mcp.toolDescriptors.find? (·.name == .leanDropWorkspace)
    | throw <| IO.userError "drop workspace descriptor is missing"
  let dropSchemaProperties ← requireObjVal "drop workspace schema" "properties" dropDesc.inputSchema
  let workspaceSchema ← requireObjVal "drop workspace schema properties" "workspace" dropSchemaProperties
  let workspaceProperties ← requireObjVal "workspace descriptor schema" "properties" workspaceSchema
  discard <| requireObjVal "workspace descriptor schema properties" "root" workspaceProperties
  let augmentedSchema ← expectOk "augment object schema" <|
    Beam.JsonSchema.withRequiredProperty Beam.Mcp.emptyInputSchema "workspace"
      (Beam.JsonSchema.string "Workspace selector.")
  let augmentedRequired ← IO.ofExcept <|
    augmentedSchema.getObjValAs? (Array String) "required"
  require "schema augmentation adds required workspace selector"
    (augmentedRequired == #["workspace"])
  for (label, malformed) in #[
      ("missing properties", Json.mkObj [("required", toJson (#[] : Array String))]),
      ("non-object properties", Json.mkObj [
        ("properties", toJson "bad"),
        ("required", toJson (#[] : Array String))
      ]),
      ("non-array required", Json.mkObj [
        ("properties", Json.mkObj []),
        ("required", toJson "bad")
      ])
    ] do
    match Beam.JsonSchema.withRequiredProperty malformed "workspace"
        (Beam.JsonSchema.string "Workspace selector.") with
    | .ok schema =>
        throw <| IO.userError s!"{label} schema augmented unexpectedly: {schema.compress}"
    | .error _ => pure ()
private def checkBrokerRequestAdapters : IO Unit := do
  let root := "/repo"
  let workspaceId := "local:/repo"
  let inWorkspace (json : Json) : Json :=
    json.setObjVal! "workspace" (toJson ({ root } : Beam.Workspace.Descriptor))

  for tool in Beam.Mcp.toolNames do
    let input := Json.mkObj [("__undeclared", toJson true)]
    match tool.validateInputFields input with
    | .ok _ => throw <| IO.userError s!"{tool.key} accepted an undeclared input field"
    | .error err =>
        require s!"{tool.key} undeclared field error names the closed input boundary"
          (err.contains "undeclared input fields")

  for operation in Beam.Lean.Operation.all do
    let input := Json.mkObj [("__undeclared", toJson true)]
    match operation.toBrokerRequest input with
    | .ok _ => throw <| IO.userError s!"{operation.key} accepted an undeclared operation field"
    | .error err =>
        require s!"{operation.key} undeclared field error names the operation input boundary"
          (err.contains "undeclared input fields")

  let runAtInput : Beam.Mcp.RunAtInput := {
    path := "Demo.lean"
    version := 12
    line := 4
    character := 2
    text := "exact h"
  }
  let runAtReq ← expectOk "runAt tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .runAt workspaceId (inWorkspace <| toJson runAtInput)
  let runAt ← expectRequestPayload "runAt tool request" runAtReq fun
    | .runAt request => some request
    | _ => none
  require "runAt op" (runAtReq.op == .runAt)
  require "runAt path" (runAt.path == "Demo.lean")
  require "runAt version" (runAt.version == 12)
  require "runAt line" (runAt.line == 4)
  require "runAt character" (runAt.character == 2)
  require "runAt text" (runAt.text == "exact h")
  require "runAt does not store by default" runAt.storeHandle?.isNone
  requireFieldAbsent "runAt input json" "root" (toJson runAtInput)
  requireFieldAbsent "runAt input json" "workspace" (toJson runAtInput)

  let runAtWorkspaceJson := inWorkspace <| toJson runAtInput
  let runAtWorkspaceReq ← expectOk "runAt workspace tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .runAt workspaceId runAtWorkspaceJson
  require "runAt workspace id is the private canonical cache key"
    (runAtWorkspaceReq.workspaceId? == some workspaceId)

  let runAtHandleReq ← expectOk "runAt handle tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .runAtHandle workspaceId
      (inWorkspace <| toJson runAtInput)
  let runAtHandle ← expectRequestPayload "runAt handle tool request" runAtHandleReq fun
    | .runAt request => some request
    | _ => none
  require "runAt handle stores state" (runAtHandle.storeHandle? == some true)

  let positionInput : Beam.Mcp.PositionInput := {
    path := "Demo.lean"
    version := 13
    line := 7
    character := 3
  }
  let hoverReq ← expectOk "hover tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .hover workspaceId (inWorkspace <| toJson positionInput)
  let hover ← expectRequestPayload "hover tool request" hoverReq fun
    | .hover request => some request
    | _ => none
  require "hover op" (hoverReq.op == .hover)
  require "hover version" (hover.version == 13)

  let signatureHelpReq ← expectOk "signature-help tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .signatureHelp workspaceId
      (inWorkspace <| toJson positionInput)
  let signatureHelp ← expectRequestPayload "signature-help tool request" signatureHelpReq fun
    | .signatureHelp request => some request
    | _ => none
  require "signature-help op" (signatureHelpReq.op == .signatureHelp)
  require "signature-help version" (signatureHelp.version == 13)

  let definitionReq ← expectOk "definition tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .definition workspaceId
      (inWorkspace <| toJson positionInput)
  let definition ← expectRequestPayload "definition tool request" definitionReq fun
    | .definition request => some request
    | _ => none
  require "definition op" (definitionReq.op == .definition)
  require "definition version" (definition.version == 13)

  let referencesInput : Beam.Mcp.ReferencesInput := {
    path := "Demo.lean"
    version := 13
    line := 7
    character := 3
    includeDeclaration? := some false
  }
  let referencesReq ← expectOk "references tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .references workspaceId
      (inWorkspace <| toJson referencesInput)
  let references ← expectRequestPayload "references tool request" referencesReq fun
    | .references request => some request
    | _ => none
  require "references op" (referencesReq.op == .references)
  require "references version" (references.version == 13)
  require "references include declaration" (references.includeDeclaration? == some false)
  let referencesJson := toJson referencesInput
  requireJsonBool "references input json" "include_declaration" false referencesJson
  requireFieldAbsent "references input json" "includeDeclaration" referencesJson
  let decodedReferences ← expectOk "decode references input" <|
    fromJson? (α := Beam.Mcp.ReferencesInput) referencesJson
  require "decoded references include declaration" (decodedReferences.includeDeclaration? == some false)

  let documentSymbolsInput : Beam.Mcp.DocumentSymbolsInput := {
    path := "Demo.lean"
    version := 13
  }
  let documentSymbolsReq ← expectOk "document-symbols tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .documentSymbols workspaceId
      (inWorkspace <| toJson documentSymbolsInput)
  let documentSymbols ← expectRequestPayload "document-symbols tool request" documentSymbolsReq fun
    | .documentSymbols request => some request
    | _ => none
  require "document-symbols op" (documentSymbolsReq.op == .documentSymbols)
  require "document-symbols path" (documentSymbols.path == "Demo.lean")
  require "document-symbols version" (documentSymbols.version == 13)

  let workspaceSymbolsInput : Beam.Mcp.WorkspaceSymbolsInput := {
    query := "Demo"
  }
  let workspaceSymbolsReq ← expectOk "workspace-symbols tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .workspaceSymbols workspaceId
      (inWorkspace <| toJson workspaceSymbolsInput)
  let workspaceSymbols ← expectRequestPayload "workspace-symbols tool request" workspaceSymbolsReq fun
    | .workspaceSymbols request => some request
    | _ => none
  require "workspace-symbols op" (workspaceSymbolsReq.op == .workspaceSymbols)
  require "workspace-symbols query" (workspaceSymbols.query == "Demo")

  let goalsBeforeInput : Beam.Mcp.GoalsInput := {
    path := "Demo.lean"
    version := 13
    line := 7
    character := 3
    mode := .before
  }
  let goalsBeforeReq ← expectOk "goals before tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .goals workspaceId
      (inWorkspace <| toJson goalsBeforeInput)
  let goalsBefore ← expectRequestPayload "goals before tool request" goalsBeforeReq fun
    | .goals request => some request
    | _ => none
  require "goals before op" (goalsBeforeReq.op == .goals)
  require "goals before mode" (goalsBefore.mode? == some .before)
  requireJsonString "goals before input json" "mode" "before" (toJson goalsBeforeInput)
  requireJsonString "goals before broker request json" "mode" "before" (toJson goalsBeforeReq)

  let goalsAfterInput : Beam.Mcp.GoalsInput := {
    path := "Demo.lean"
    version := 13
    line := 7
    character := 3
    mode := .after
  }
  let goalsAfterReq ← expectOk "goals after tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .goals workspaceId
      (inWorkspace <| toJson goalsAfterInput)
  let goalsAfter ← expectRequestPayload "goals after tool request" goalsAfterReq fun
    | .goals request => some request
    | _ => none
  require "goals after op" (goalsAfterReq.op == .goals)
  require "goals after mode" (goalsAfter.mode? == some .after)
  requireJsonString "goals after broker request json" "mode" "after" (toJson goalsAfterReq)

  let todoInput : Beam.Mcp.TodoInput := {
    path := "Demo.lean"
    version := 14
    range? := some { start := { line := 1, character := 0 }, «end» := { line := 8, character := 3 } }
    kinds? := some #[.sorry, .incompleteProof]
  }
  let todoReq ← expectOk "todo tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .todo workspaceId (inWorkspace <| toJson todoInput)
  let todo ← expectRequestPayload "todo tool request" todoReq fun
    | .todo request => some request
    | _ => none
  require "todo op" (todoReq.op == .todo)
  require "todo version" (todo.version == 14)
  require "todo range" (todo.range? == todoInput.range?)
  require "todo kinds" (todo.kinds? == some #[.sorry, .incompleteProof])
  let todoJson := toJson todoInput
  requireJsonString "todo input json" "path" "Demo.lean" todoJson
  requireFieldAbsent "todo input json" "startLine" todoJson
  requireFieldAbsent "todo input json" "root" todoJson
  let wholeFileInput : Beam.Mcp.TodoInput := { path := "Demo.lean", version := 14 }
  requireFieldAbsent "whole-file todo input json" "start_line" (toJson wholeFileInput)
  let wholeFileReq ← expectOk "whole-file todo tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .todo workspaceId (inWorkspace <| toJson wholeFileInput)
  let wholeFile ← expectRequestPayload "whole-file todo tool request" wholeFileReq fun
    | .todo request => some request
    | _ => none
  require "whole-file todo has no range" wholeFile.range?.isNone
  let partialRange := (toJson wholeFileInput).setObjVal! "start_line" (toJson 1)
  match Beam.Mcp.leanOperationToBrokerRequest .todo workspaceId (inWorkspace partialRange) with
  | .ok _ => throw <| IO.userError "todo accepted a partial range"
  | .error _ => pure ()

  let codeAction : Lean.Lsp.CodeAction := {
    title := "Replace fixture hole with zero"
    kind? := some "quickfix"
    data? := some <| Json.mkObj [("marker", toJson "resolve-data")]
  }
  let codeActionResolveInput : Beam.Mcp.CodeActionResolveInput := {
    path := "Demo.lean"
    version := 15
    codeAction
  }
  let codeActionResolveReq ← expectOk "code-action-resolve tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .codeActionResolve workspaceId
      (inWorkspace <| toJson codeActionResolveInput)
  let codeActionResolve ← expectRequestPayload
      "code-action-resolve tool request" codeActionResolveReq fun
    | .codeActionResolve request => some request
    | _ => none
  require "code-action-resolve op" (codeActionResolveReq.op == .codeActionResolve)
  require "code-action-resolve version" (codeActionResolve.version == 15)
  require "code-action-resolve title" (codeActionResolve.codeAction.title == codeAction.title)
  let codeActionResolveJson := toJson codeActionResolveInput
  discard <| requireObjVal "code-action-resolve input json" "code_action" codeActionResolveJson
  requireFieldAbsent "code-action-resolve input json" "codeAction" codeActionResolveJson
  requireFieldAbsent "code-action-resolve input json" "root" codeActionResolveJson

  let runWithInput : Beam.Mcp.RunWithInput := {
    path := "Demo.lean"
    handle := sampleBrokerHandle
    text := "simp"
  }
  let runWithReq ← expectOk "runWith tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .runWithLinear workspaceId
      (inWorkspace <| toJson runWithInput)
  let runWith ← expectRequestPayload "runWith tool request" runWithReq fun
    | .runWith request => some request
    | _ => none
  require "runWith op" (runWithReq.op == .runWith)
  require "runWith stores successor handle" (runWith.storeHandle? == some true)
  require "runWith linear flag" (runWith.linear? == some true)
  require "runWith handle present" (runWith.handle.session == sampleBrokerHandle.session)
  requireFieldAbsent "runWith input json" "root" (toJson runWithInput)

  let pathInput : Beam.Mcp.PathInput := { path := "Demo.lean" }
  let updateReq ← expectOk "update tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .update workspaceId (inWorkspace <| toJson pathInput)
  require "update op" (updateReq.op == .updateFile)
  let closeReq ← expectOk "close tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .close workspaceId (inWorkspace <| toJson pathInput)
  require "close op" (closeReq.op == .close)

  let syncInput : Beam.Mcp.SyncInput := {
    path := "Demo.lean",
    diagnosticScope? := some .all,
    diagnosticsInResult? := some true
  }
  let syncReq ← expectOk "sync tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .sync workspaceId (inWorkspace <| toJson syncInput)
  let sync ← expectRequestPayload "sync tool request" syncReq fun
    | .syncFile request => some request
    | _ => none
  require "sync op" (syncReq.op == .syncFile)
  require "sync diagnostic scope" (sync.diagnosticScope? == some .all)
  require "sync diagnostics in result" (sync.diagnosticsInResult? == some true)
  let refreshReq ← expectOk "refresh tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .refresh workspaceId (inWorkspace <| toJson syncInput)
  let refresh ← expectRequestPayload "refresh tool request" refreshReq fun
    | .refreshFile request => some request
    | _ => none
  require "refresh op" (refreshReq.op == .refreshFile)
  require "refresh diagnostic scope" (refresh.diagnosticScope? == some .all)
  require "refresh diagnostics in result" (refresh.diagnosticsInResult? == some true)
  let saveInput : Beam.Mcp.SaveInput := {
    path := "Demo.lean",
    diagnosticScope? := some .all
  }
  let saveReq ← expectOk "save tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .save workspaceId (inWorkspace <| toJson saveInput)
  let save ← expectRequestPayload "save tool request" saveReq fun
    | .saveOlean request => some request
    | _ => none
  require "save op" (saveReq.op == .saveOlean)
  require "save diagnostic scope" (save.diagnosticScope? == some .all)
  let closeSaveReq ← expectOk "close-save tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .closeSave workspaceId
      (inWorkspace <| toJson saveInput)
  let closeSave ← expectRequestPayload "close-save tool request" closeSaveReq fun
    | .close request => some request
    | _ => none
  require "close-save op" (closeSaveReq.op == .close)
  require "close-save requests artifact save" (closeSave.saveArtifacts? == some true)
  require "close-save diagnostic scope" (closeSave.diagnosticScope? == some .all)
  let syncJson := toJson syncInput
  requireJsonString "sync input json" "diagnostic_scope" "all" syncJson
  requireJsonBool "sync input json" "diagnostics_in_result" true syncJson
  requireFieldAbsent "sync input json" "diagnosticScope" syncJson
  requireFieldAbsent "sync input json" "diagnosticsInResult" syncJson
  requireFieldAbsent "sync input json" "root" syncJson
  let decodedSync ← expectOk "decode sync input" <| fromJson? (α := Beam.Mcp.SyncInput) syncJson
  require "decoded sync diagnostic scope" (decodedSync.diagnosticScope? == some .all)
  require "decoded sync diagnostics in result" (decodedSync.diagnosticsInResult? == some true)
  let saveJson := toJson saveInput
  requireFieldAbsent "save input json" "diagnostics_in_result" saveJson
  let decodedSave ← expectOk "decode save input" <| fromJson? (α := Beam.Mcp.SaveInput) saveJson
  require "decoded save diagnostic scope" (decodedSave.diagnosticScope? == some .all)
  match Beam.Mcp.leanOperationToBrokerRequest .save workspaceId (inWorkspace syncJson) with
  | .ok _ => throw <| IO.userError "save tool accepted sync-only diagnostics_in_result"
  | .error err =>
      require "save tool rejection identifies diagnostics_in_result"
        (err.contains "diagnostics_in_result")

private def checkPublicInputDiagnostics : IO Unit := do
  let position := Json.mkObj [
    ("path", toJson "A.lean"), ("version", toJson (1 : Nat)),
    ("line", toJson (0 : Nat)), ("character", toJson (0 : Nat))]
  let run := position.setObjVal! "text" (toJson "#check Nat")
  let missingVersion := Json.mkObj [
    ("path", toJson "A.lean"), ("line", toJson (0 : Nat)),
    ("character", toJson (0 : Nat)), ("text", toJson "#check Nat")]
  let badHandle := Json.mkObj [
    ("path", toJson "A.lean"), ("handle", Json.mkObj [("bogus", toJson true)]),
    ("text", toJson "#check Nat")]
  let cases : Array (Beam.Lean.Operation × Json × String) := #[
    (.runAt, Json.mkObj [], "path: required value is missing (string expected)"),
    (.runAt, run.setObjVal! "path" (toJson (3 : Nat)), "path: string expected"),
    (.runAt, missingVersion, "version: required value is missing (non-negative integer expected)"),
    (.hover, position.setObjVal! "line" (toJson "0"), "line: non-negative integer expected"),
    (.hover, position.setObjVal! "line" (toJson (-1 : Int)), "line: non-negative integer expected"),
    (.definition, position.setObjVal! "character" (toJson false), "character: non-negative integer expected"),
    (.goals, position.setObjVal! "mode" (toJson "unknown"), "mode: 'before' or 'after' expected"),
    (.runWith, badHandle, "handle: handle returned by Beam expected; broker handle accepts no undeclared fields: bogus"),
    (.runWith, badHandle.setObjVal! "handle" (toJson "abc"),
      "handle: handle returned by Beam expected; broker handle must be an object, got \"abc\"")]
  for (operation, input, expected) in cases do
    match operation.toBrokerRequest input with
    | .ok _ => throw <| IO.userError s!"{operation.key} accepted malformed input: {input.compress}"
    | .error message =>
      require s!"{operation.key} diagnostic uses the public field and expected shape"
        (message == expected)

private def checkRunAtNormalization : IO Unit := do
  let semanticFailure := Json.mkObj [
    ("success", toJson false),
    ("messages", toJson (#[] : Array Beam.LSP.RunAt.Message)),
    ("traces", toJson (#[] : Array String))
  ]
  let normalizedFailure ← expectToolOk "normalize semantic failure" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt)
      (Beam.Broker.Response.success semanticFailure)
  requireJsonBool "semantic failure result" "success" false normalizedFailure
  requireFieldAbsent "semantic failure result" "next_handle" normalizedFailure
  requireFieldAbsent "semantic failure result" "proof_state" normalizedFailure
  requireFieldAbsent "semantic failure result" "ok" normalizedFailure
  requireFieldAbsent "semantic failure result" "handle" normalizedFailure
  requireFieldAbsent "semantic failure result" "proofState" normalizedFailure

  let openGoal : Beam.LSP.Lib.ProofState := { goals := #[{ target := "True" }] }
  let successfulGoalProbe := Json.mkObj [
    ("success", toJson true),
    ("messages", toJson (#[] : Array Beam.LSP.RunAt.Message)),
    ("traces", toJson (#[] : Array String)),
    ("proofState", toJson openGoal)
  ]
  let normalizedGoal ← expectToolOk "normalize successful runAt with an open goal" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt)
      (Beam.Broker.Response.success successfulGoalProbe)
  requireJsonBool "successful runAt with an open goal" "success" true normalizedGoal
  let proofState ← requireObjVal "successful runAt with an open goal" "proof_state" normalizedGoal
  let goals ← IO.ofExcept <| proofState.getObjValAs? (Array Json) "goals"
  require "successful runAt retains its open goal" (goals.size == 1)
  let some goal := goals[0]? | throw <| IO.userError "successful runAt goal missing"
  requireJsonString "successful runAt goal" "target" "True" goal

  discard <| expectToolError "malformed runAt result without required success" "invalidResult" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt)
      (Beam.Broker.Response.success <| Json.mkObj [])

  let successWithHandle := Json.mkObj [
    ("success", toJson true),
    ("messages", toJson (#[] : Array Beam.LSP.RunAt.Message)),
    ("traces", toJson (#[] : Array String)),
    ("handle", toJson sampleBrokerHandle)
  ]
  let normalizedHandle ← expectToolOk "normalize handle result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAtHandle) <|
      ((Beam.Broker.Response.success successWithHandle).withFileProgress
        { updates := 2, done := true })
  let nextHandle ← requireObjVal "handle result" "next_handle" normalizedHandle
  requireJsonString "next handle" "session" "session" nextHandle
  let rawHandle ← requireObjVal "next handle" "raw" nextHandle
  requireJsonString "next handle raw" "value" "raw-handle" rawHandle
  requireFieldAbsent "handle result" "file_progress" normalizedHandle
  let handleProgress ← requireObjVal "handle result" "document_progress" normalizedHandle
  requireJsonBool "handle document progress" "done" true handleProgress
  requireFieldAbsent "handle result" "client_request_id" normalizedHandle
  requireFieldAbsent "handle result" "handle" normalizedHandle

private def sampleSyncResult : Beam.Broker.SyncFileResult := {
  path := "Demo.lean"
  version := 7
  diagnostics := {
    counts := { error := 1, warning := 1 }
    items? := some #[{
      path := "Demo.lean"
      uri := "file:///repo/Demo.lean"
      version? := some 7
      severity? := some .warning
      range := { start := { line := 1, character := 2 }, «end» := { line := 1, character := 5 } }
      message := "unused variable"
    }]
  }
  readiness := {
    saveReady := false
    reason := "documentErrors"
    blockingErrorCount := 1
    blockingMessages := #[{
      message := "declaration has errors"
      saveBlocking := true
    }]
  }
}

private def checkCrossSurfaceResultParity : IO Unit := do
  let progress : Beam.Broker.SyncFileProgress := {
    updates := 4, done := true, rangeStartLine? := some 1, rangeEndLine? := some 20
  }
  let syncResponse := (Beam.Broker.Response.success <| toJson sampleSyncResult).withFileProgress progress
  let mcpSyncPublic ← expectToolOk "MCP sync result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) syncResponse
  let workspaceRoot := System.FilePath.mk "/repo"
  let mcpSyncResult := Beam.Workspace.addWorkspaceDescriptor workspaceRoot mcpSyncPublic
  let mcpSyncEnvelope := Beam.Mcp.callToolResult mcpSyncResult
  requireJsonBool "MCP sync envelope" "isError" false mcpSyncEnvelope
  let mcpContent ← IO.ofExcept <| mcpSyncEnvelope.getObjValAs? (Array Json) "content"
  require "MCP success has a single content block" (mcpContent.size == 1)
  let some mcpTextContent := mcpContent[0]?
    | throw <| IO.userError "MCP sync content block missing"
  requireJsonString "MCP sync content block" "type" "text" mcpTextContent
  let cliSyncEnvelope ← expectToolOk "CLI sync result" <|
    (Beam.Cli.prepareOperationResponse (.broker .syncFile) syncResponse
      (some "parity-request") (some workspaceRoot)).map (·.json)
  requireJsonBool "CLI sync envelope" "ok" true cliSyncEnvelope
  requireJsonString "CLI sync envelope" "client_request_id" "parity-request" cliSyncEnvelope
  let cliSync ← requireObjVal "CLI sync envelope" "result" cliSyncEnvelope
  let mcpStructured ← requireObjVal "MCP sync envelope" "structuredContent" mcpSyncEnvelope
  require "CLI and MCP complete envelopes contain the same public sync result"
    (cliSync == mcpStructured)
  let cliWorkspace ← requireObjVal "CLI sync result" "workspace" cliSync
  requireJsonString "CLI sync workspace" "root" "/repo" cliWorkspace
  requireFieldAbsent "CLI sync result" "client_request_id" cliSync
  requireFieldAbsent "MCP structured sync result" "client_request_id" mcpStructured
  let mcpText ← IO.ofExcept <| mcpTextContent.getObjValAs? String "text"
  let parsedMcpText ← IO.ofExcept <| Json.parse mcpText
  require "MCP text content parses to its structured result" (parsedMcpText == mcpStructured)
  require "MCP text content follows the ordered compact JSON presentation"
    (mcpText == Beam.orderedJsonCompact mcpStructured)
  let orderedProbe := Json.mkObj [
    ("traces", Json.arr #[]), ("messages", Json.arr #[]), ("success", toJson true)
  ]
  let orderedEnvelope := Beam.Mcp.callToolResult orderedProbe
  let orderedContent ← IO.ofExcept <| orderedEnvelope.getObjValAs? (Array Json) "content"
  let some orderedTextContent := orderedContent[0]?
    | throw <| IO.userError "ordered MCP text content missing"
  let orderedText ← IO.ofExcept <| orderedTextContent.getObjValAs? String "text"
  require "MCP text orders runAt success before details"
    (orderedText == "{\"success\":true,\"messages\":[],\"traces\":[]}")
  require "MCP text order differs from generic JSON compression"
    (orderedText != orderedProbe.compress)
  let orderedParsed ← IO.ofExcept <| Json.parse orderedText
  require "ordered MCP text preserves its JSON value" (orderedParsed == orderedProbe)
  let cliProgress ← requireObjVal "CLI sync result" "document_progress" cliSync
  let mcpProgress ← requireObjVal "MCP sync result" "document_progress" mcpStructured
  require "both surfaces preserve the same document progress" (cliProgress == mcpProgress)
  let readiness ← requireObjVal "shared sync result" "readiness" cliSync
  requireFieldAbsent "shared readiness" "saveReady" readiness
  requireFieldAbsent "shared readiness" "blockingErrorCount" readiness
  requireJsonInt "shared readiness" "blocking_error_count" 1 readiness
  let diagnostics ← requireObjVal "shared sync result" "diagnostics" cliSync
  let items ← IO.ofExcept <| diagnostics.getObjValAs? (Array Json) "items"
  let some item := items[0]?
    | throw <| IO.userError "shared sync result lost its diagnostic"
  requireJsonString "shared diagnostic severity" "severity" "warning" item
  let range ← requireObjVal "shared diagnostic" "range" item
  let start ← requireObjVal "shared diagnostic range" "start" range
  requireJsonInt "shared diagnostic range start" "line" 1 start
  requireJsonInt "shared diagnostic range start" "character" 2 start

  let sampleSave : Beam.Broker.SaveOleanResult := {
    module := "Demo"
    sourceHash := "abc"
    olean := "/tmp/Demo.olean"
    ilean := "/tmp/Demo.ilean"
    c := "/tmp/Demo.c"
    trace := "/tmp/Demo.olean.trace"
    oleanServer? := some "/tmp/Demo.olean.server"
    irSig? := some "/tmp/Demo.ir.sig"
    sync := sampleSyncResult
  }
  let saveResponse := (Beam.Broker.Response.success <| toJson sampleSave).withFileProgress progress
  let mcpSave ← expectToolOk "MCP save result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) saveResponse
  let cliSaveEnvelope ← expectToolOk "CLI save result" <|
    (Beam.Cli.prepareOperationResponse (.broker .saveOlean) saveResponse).map (·.json)
  let cliSave ← requireObjVal "CLI save envelope" "result" cliSaveEnvelope
  require "CLI and MCP save projections have identical decoded results" (cliSave == mcpSave)
  requireFieldAbsent "shared save result" "sourceHash" cliSave
  requireJsonString "shared save result" "source_hash" "abc" cliSave

  let closeSaveResponse := (Beam.Broker.Response.success <|
    toJson ({ saved := sampleSave } : Beam.Broker.CloseSaveResult)).withFileProgress progress
  let mcpCloseSave ← expectToolOk "MCP close-save result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .closeSave) closeSaveResponse
  let cliCloseSaveEnvelope ← expectToolOk "CLI close-save result" <|
    (Beam.Cli.prepareOperationResponse .closeSave closeSaveResponse).map (·.json)
  let cliCloseSave ← requireObjVal "CLI close-save envelope" "result" cliCloseSaveEnvelope
  require "CLI and MCP close-save projections have identical decoded results"
    (cliCloseSave == mcpCloseSave)

  let semanticFailure := Beam.Broker.Response.success <| Json.mkObj [
    ("success", toJson false),
    ("messages", toJson (#[] : Array Beam.LSP.RunAt.Message)),
    ("traces", toJson (#[] : Array String))
  ]
  let mcpFailure ← expectToolOk "MCP semantic failure" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) semanticFailure
  let cliFailureEnvelope ← expectToolOk "CLI semantic failure" <|
    (Beam.Cli.prepareOperationResponse (.broker .runAt) semanticFailure).map (·.json)
  let cliFailure ← requireObjVal "CLI semantic failure envelope" "result" cliFailureEnvelope
  require "CLI and MCP preserve semantic failure as an operation result" (cliFailure == mcpFailure)
  requireFieldAbsent "semantic failure" "proof_state" cliFailure
  requireFieldAbsent "semantic failure" "next_handle" cliFailure

  requireFieldAbsent "unrequested profile" "profile" cliFailure
  let profiledResult : Beam.LSP.RunAt.Result := {
    success := false
    profile? := some {
      elapsedMs := 3.5
      spans := #[
        { thread := 7, category := "elaborate", tag := "root", startMs := 0, durationMs := 3 },
        { parent? := some 0, thread := 7, category := "tactic", tag := "simp",
          startMs := 1, durationMs := 2, range? := some {
            start := { line := 0, character := 0 }, «end» := { line := 0, character := 4 } } }
      ]
    }
  }
  let profiledResponse := Beam.Broker.Response.success <| toJson profiledResult
  let mcpProfile ← expectToolOk "MCP profiled failure" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) profiledResponse
  let cliProfileEnvelope ← expectToolOk "CLI profiled failure" <|
    (Beam.Cli.prepareOperationResponse (.broker .runAt) profiledResponse).map (·.json)
  let cliProfile ← requireObjVal "CLI profiled envelope" "result" cliProfileEnvelope
  require "CLI/MCP profile parity" (cliProfile == mcpProfile)
  requireJsonBool "profiled semantic failure" "success" false cliProfile
  let profile ← requireObjVal "profiled result" "profile" cliProfile
  requireFieldAbsent "public profile" "elapsedMs" profile
  requireFieldAbsent "public profile" "thresholdMs" profile
  requireFieldAbsent "public profile" "initialThresholdMs" profile
  requireFieldAbsent "no legacy threshold alias" "threshold_ms" profile
  require "elapsed wall clock preserved" ((← requireObjVal "profile" "elapsed_ms" profile) == toJson (3.5 : Float))
  requireJsonInt "initial profiling threshold" "initial_threshold_ms" 1 profile
  requireJsonBool "profile boundedness" "truncated" false profile
  let spans ← IO.ofExcept <| profile.getObjValAs? (Array Json) "spans"
  require "profile spans preserved" (spans.size == 2)
  requireFieldAbsent "root span" "parent" spans[0]!
  requireFieldAbsent "root span" "range" spans[0]!
  requireFieldAbsent "public span" "startMs" spans[1]!
  requireFieldAbsent "public span" "durationMs" spans[1]!
  requireJsonInt "child span" "parent" 0 spans[1]!
  require "span duration preserved" ((← requireObjVal "span" "duration_ms" spans[1]!) == toJson (2 : Float))
  let emptyProfile := Beam.Broker.Response.success <| toJson ({
    profile? := some { elapsedMs := 0 }
  } : Beam.LSP.RunAt.Result)
  let projectedEmpty ← expectToolOk "empty profiling evidence" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) emptyProfile
  let emptyEvidence ← requireObjVal "empty profile" "profile" projectedEmpty
  require "known empty spans retained" ((← requireObjVal "empty profile" "spans" emptyEvidence) == Json.arr #[])

  let emptySync := Beam.Broker.Response.success <| toJson ({
    path := "Clean.lean",
    version := 1
    diagnostics := { counts := {} }
    readiness := { saveReady := true, reason := "ok" }
  } : Beam.Broker.SyncFileResult)
  let mcpEmpty ← expectToolOk "MCP empty sync" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) emptySync
  let cliEmptyEnvelope ← expectToolOk "CLI empty sync" <|
    (Beam.Cli.prepareOperationResponse (.broker .syncFile) emptySync).map (·.json)
  let cliEmpty ← requireObjVal "CLI empty sync envelope" "result" cliEmptyEnvelope
  require "empty sync result parity" (cliEmpty == mcpEmpty)
  let emptyReadiness ← requireObjVal "empty sync result" "readiness" cliEmpty
  let blockingDiagnostics ← IO.ofExcept <| emptyReadiness.getObjValAs? (Array Json) "blocking_diagnostics"
  let blockingMessages ← IO.ofExcept <| emptyReadiness.getObjValAs? (Array Json) "blocking_messages"
  require "known-empty readiness arrays remain present" (blockingDiagnostics.isEmpty && blockingMessages.isEmpty)

  let diagnostics ← requireObjVal "empty sync result" "diagnostics" cliEmpty
  requireFieldAbsent "empty sync without replay" "items" diagnostics

  let arrayResponse := (Beam.Broker.Response.success <| Json.arr #[toJson (7 : Nat)])
    |>.withFileProgress progress
  let mcpArray ← expectToolOk "MCP array result with progress" <|
    Beam.Mcp.normalizeBrokerResponse .beamVersion arrayResponse
  let cliArrayEnvelope ← expectToolOk "CLI array result with progress" <|
    (Beam.Cli.prepareOperationResponse .opaque arrayResponse).map (·.json)
  let cliArray ← requireObjVal "CLI array response" "result" cliArrayEnvelope
  require "MCP and CLI safely wrap non-object results carrying progress" (mcpArray == cliArray)
  let wrappedArray ← IO.ofExcept <| cliArray.getObjValAs? (Array Json) "value"
  require "non-object result payload is retained" (wrappedArray == #[toJson (7 : Nat)])
  discard <| requireObjVal "array result progress" "document_progress" cliArray

  let arrayWithoutProgress := Beam.Broker.Response.success <| Json.arr #[toJson (8 : Nat)]
  let mcpPlainArray ← expectToolOk "MCP array result without progress" <|
    Beam.Mcp.normalizeBrokerResponse .beamVersion arrayWithoutProgress
  let cliPlainArrayEnvelope ← expectToolOk "CLI array result without progress" <|
    (Beam.Cli.prepareOperationResponse .opaque arrayWithoutProgress).map (·.json)
  let cliPlainArray ← requireObjVal "CLI array response without progress" "result" cliPlainArrayEnvelope
  require "array result shape is consistent without progress" (mcpPlainArray == cliPlainArray)
  let wrappedPlainArray ← IO.ofExcept <| cliPlainArray.getObjValAs? (Array Json) "value"
  require "array payload is retained without progress" (wrappedPlainArray == #[toJson (8 : Nat)])
  requireFieldAbsent "array result without progress" "document_progress" cliPlainArray

private def checkProjectionFailureEvidence : IO Unit := do
  let partialReceipt := Json.mkObj [("module", toJson "Main"), ("sourceHash", toJson "saved")]
  let cases : Array (Beam.Output.Operation × Beam.Mcp.ToolName × Json) := #[
    (.broker .saveOlean, .leanOperation .save, partialReceipt),
    (.closeSave, .leanOperation .closeSave,
      Json.mkObj [("closed", toJson true), ("saved", partialReceipt)])
  ]
  for (operation, tool, receipt) in cases do
    let response := (Beam.Broker.Response.success receipt).withFileProgress { updates := 2, done := true }
    let mcpError ← expectToolError "MCP projection receipt evidence" "invalidResult" <|
      Beam.Mcp.normalizeBrokerResponse tool response
    let cliOutputError ← expectToolError "CLI projection receipt evidence" "invalidResult" <|
      (Beam.Cli.prepareOperationResponse operation response).map (·.json)
    let cliFailure := Beam.Cli.operationOutputFailure response cliOutputError
    let cliEnvelope := Beam.Cli.prepareFailureResponse cliFailure |>.json
    requireJsonBool "CLI projection failure envelope" "ok" false cliEnvelope
    let cliError ← requireObjVal "CLI projection failure envelope" "error" cliEnvelope
    require "projection failure parity" (mcpError.json == cliError)
    let data ← requireObjVal "projection failure" "data" cliError
    let observed ← requireObjVal "projection failure data" "observed_response" data
    require "projection failure retains typed observed receipt" (observed == toJson response)
    let progress ← requireObjVal "projection failure" "document_progress" cliError
    requireJsonBool "projection failure progress" "done" true progress

private def checkExplicitResultScope : IO Unit := do
  let globalRequest := Beam.Broker.Request.stats
  let localRequest := { globalRequest with workspaceId? := some "local:/repo" }
  require "global stats scope comes from request"
    (Beam.Output.Operation.ofRequest globalRequest == .globalStats)
  require "workspace stats scope comes from request"
    (Beam.Output.Operation.ofRequest localRequest == .workspaceStats)
  let workspaceStatsEntry := Json.mkObj [
    ("id", toJson "local:/repo"), ("root", toJson "/repo"),
    ("session", Json.mkObj [("active", toJson false)]),
    ("metrics", Beam.Broker.workspaceMetricsJson {})
  ]
  let globalStats := Json.mkObj [
    ("uptimeMs", toJson (1 : Nat)),
    ("workspaces", Json.mkObj [("local:/repo", workspaceStatsEntry)]),
    ("daemonIdentity", toJson ({ daemonId := "test", configHash := "config" } : Beam.Broker.DaemonIdentity))
  ]
  let localStats := workspaceStatsEntry.setObjVal! "uptimeMs" (toJson (1 : Nat))
  let projected ← expectToolOk "global stats projection" <|
    Beam.Mcp.normalizeBrokerResponse .beamStats (.success globalStats)
  let identity ← requireObjVal "global stats" "daemon_identity" projected
  requireJsonString "stats identity" "daemon_id" "test" identity
  discard <| expectToolOk "workspace stats projection" <|
    Beam.Output.projectResult .workspaceStats localStats
  discard <| expectToolOk "global workspace stats entry projection" <|
    Beam.Output.projectResult .globalStats globalStats
  discard <| expectToolError "global payload cannot masquerade as workspace stats" "invalidResult" <|
    Beam.Output.projectResult .workspaceStats globalStats
  discard <| expectToolError "workspace payload cannot masquerade as global stats" "invalidResult" <|
    Beam.Output.projectResult .globalStats localStats
  discard <| expectToolError "scoped stats require producer uptime" "invalidResult" <|
    Beam.Output.projectResult .workspaceStats workspaceStatsEntry
  let unexpectedNestedScopeFields := Json.mkObj [
    ("uptimeMs", toJson (1 : Nat)), ("workspaces", Json.mkObj [
      ("local:/repo", workspaceStatsEntry.setObjVal! "uptimeMs" (toJson (1 : Nat)))
    ])
  ]
  discard <| expectToolError "global workspace entries reject scoped-only uptime" "invalidResult" <|
    Beam.Output.projectResult .globalStats unexpectedNestedScopeFields
  let activeStats := localStats.setObjVal! "session" <| Json.mkObj [
    ("active", toJson true), ("epoch", toJson (3 : Nat)), ("openDocCount", toJson (2 : Nat))
  ]
  let activeProjected ← expectToolOk "active workspace stats projection" <|
    Beam.Output.projectResult .workspaceStats activeStats
  let activeSession ← requireObjVal "active workspace stats" "session" activeProjected
  requireJsonInt "active session stats" "open_doc_count" 2 activeSession
  discard <| expectToolError "active session stats require epoch" "invalidResult" <|
    Beam.Output.projectResult .workspaceStats <| localStats.setObjVal! "session" <| Json.mkObj [
      ("active", toJson true), ("openDocCount", toJson (2 : Nat))
    ]
  discard <| expectToolError "active session stats require open document count" "invalidResult" <|
    Beam.Output.projectResult .workspaceStats <| localStats.setObjVal! "session" <| Json.mkObj [
      ("active", toJson true), ("epoch", toJson (3 : Nat))
    ]
  discard <| expectToolError "inactive session stats omit epoch and document count" "invalidResult" <|
    Beam.Output.projectResult .workspaceStats <| localStats.setObjVal! "session" <| Json.mkObj [
      ("active", toJson false), ("epoch", toJson (3 : Nat))
    ]
  let localDocs := Json.mkObj [
    ("root", toJson "/repo"),
    ("session", Json.mkObj [("active", toJson false), ("files", Json.arr #[])])
  ]
  let globalDocs := Json.mkObj [("workspaces", Json.mkObj [("local:/repo", localDocs)])]
  discard <| expectToolOk "global open-doc projection" <|
    Beam.Output.projectResult .globalOpenDocs globalDocs
  discard <| expectToolOk "workspace open-doc projection" <|
    Beam.Output.projectResult .workspaceOpenDocs localDocs
  discard <| expectToolError "open-doc scope cannot be inferred from payload" "invalidResult" <|
    Beam.Output.projectResult .workspaceOpenDocs globalDocs

private def checkCrossSurfaceErrorParity : IO Unit := do
  let staleData := Json.mkObj [
    ("reason", toJson "documentVersionMismatch"),
    ("expectedVersion", toJson (3 : Nat)),
    ("acceptedVersion", toJson (4 : Nat))
  ]
  let progress : Beam.Broker.SyncFileProgress := { updates := 2, done := false }
  let errors := #[
    Beam.Broker.errorResponseFor .contentModified "stale document" (some staleData) |>.withFileProgress progress,
    Beam.Broker.errorResponseFor .syncBarrierIncomplete "dependency barrier incomplete"
      (some <| Beam.Broker.staleSyncErrorData "W/B.lean" #[
        { module := "W.A", path := "W/A.lean", needsSave := true }
      ]) |>.withFileProgress progress,
    Beam.Broker.errorResponseFor .requestCancelled "caller cancelled",
    Beam.Broker.errorResponseFor .internalError "explicit null error data" (some Json.null)
  ]
  for response in errors do
    let cliFailure ← match Beam.Cli.prepareOperationResponse (.broker .syncFile) response
        (some "error-parity-request") with
      | .ok _ => throw <| IO.userError "broker error unexpectedly prepared as success"
      | .error error =>
          pure <| Beam.Cli.operationOutputFailure response error (some "error-parity-request")
    let some outputError := cliFailure.publicError?
      | throw <| IO.userError "prepared operation failure lost its public projection"
    let mcpError ← match Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) response with
      | .ok _ => throw <| IO.userError "MCP broker error unexpectedly projected as success"
      | .error error => pure error
    require "MCP retains shared typed error code" (mcpError.code == outputError.code)
    require "MCP retains shared typed error message" (mcpError.message == outputError.message)
    require "MCP retains shared structured error data" (mcpError.data? == outputError.data?)
    require "MCP retains optional document progress" (mcpError.documentProgress? == outputError.documentProgress?)
    if mcpError.message == "explicit null error data" then
      requireJsonNull "explicit null error data" "data" mcpError.json
    let cliErrorEnvelope := Beam.Cli.prepareFailureResponse cliFailure |>.json
    requireJsonBool "CLI error envelope" "ok" false cliErrorEnvelope
    requireJsonString "CLI error envelope" "client_request_id" "error-parity-request" cliErrorEnvelope
    let cliError ← requireObjVal "CLI error envelope" "error" cliErrorEnvelope
    require "CLI and MCP share error code/message/data/progress presentation"
      (cliError == outputError.json)
    let mcpErrorEnvelope := Beam.Mcp.callToolErrorResult outputError
    let mcpStructured ← requireObjVal "MCP tool error envelope" "structuredContent" mcpErrorEnvelope
    require "CLI and MCP expose identical decoded error objects" (cliError == mcpStructured)
    requireJsonBool "MCP tool error envelope" "isError" true mcpErrorEnvelope
    let mcpContent ← IO.ofExcept <| mcpErrorEnvelope.getObjValAs? (Array Json) "content"
    require "MCP error has one content block" (mcpContent.size == 1)
    let some mcpErrorText := mcpContent[0]?
      | throw <| IO.userError "MCP error content block missing"
    let text ← IO.ofExcept <| mcpErrorText.getObjValAs? String "text"
    let parsed ← IO.ofExcept <| Json.parse text
    require "MCP error text parses to its structured error" (parsed == mcpStructured)
    require "MCP error text follows ordered compact JSON"
      (text == Beam.orderedJsonCompact mcpStructured)

private def sampleSaveResult : Beam.Broker.SaveOleanResult := {
  module := "Demo"
  sourceHash := "source-hash"
  olean := "/tmp/Demo.olean"
  ilean := "/tmp/Demo.ilean"
  c := "/tmp/Demo.c"
  trace := "/tmp/Demo.trace"
  sync := sampleSyncResult
}

private def sampleSaveImportsChangedData : Json :=
  (Beam.Broker.syncResultErrorData sampleSyncResult)
    |>.setObjVal! "path" (toJson sampleSyncResult.path)
    |>.setObjVal! "changedImports" (toJson (#[("Old.Dep" : String), "New.Dep"] : Array String))
    |>.setObjVal! "unresolvedImports" (toJson (#[] : Array String))
    |>.setObjVal! "recoveryPlan"
      (toJson (#[s!"lean-beam refresh \"{sampleSyncResult.path}\""] : Array String))

private def representativeBrokerFailure
    (code : Beam.Broker.BrokerFailureCode) : Beam.Mcp.ToolName × Beam.Broker.ResponseFailure := Id.run do
  let tool := match code with
    | .invalidParams => .leanOperation .save
    | .requestCancelled => .leanOperation .runAt
    | .contentModified => .leanOperation .sync
    | .workerExited => .leanOperation .sync
    | .syncBarrierIncomplete => .leanOperation .sync
    | .saveTraceStale => .leanOperation .save
    | .saveImportsChanged => .leanOperation .save
    | .saveUnsupportedSetup => .leanOperation .save
    | .saveTargetNotModule => .leanOperation .save
    | .internalError => .leanOperation .runAt
  let data? := match code with
    | .invalidParams => some <| Beam.Broker.syncResultErrorData sampleSyncResult
    | .requestCancelled => none
    | .contentModified => some <| Beam.Broker.documentVersionMismatchErrorData 3 4
        (currentVersion? := some 4) (uri? := some "file:///repo/Demo.lean")
    | .workerExited => some <| Beam.Broker.workerRecoveryData .newBackend
    | .syncBarrierIncomplete => some <| Beam.Broker.staleSyncErrorData "Demo.lean" #[]
    | .saveTraceStale => none
    | .saveImportsChanged => some sampleSaveImportsChangedData
    | .saveUnsupportedSetup => some <| Json.mkObj [
        ("reason", toJson "unsupportedZeroBuildConfiguration"), ("path", toJson "Demo.lean")
      ]
    | .saveTargetNotModule => none
    | .internalError => none
  let failure : Beam.Broker.BrokerFailure := {
    code, message := s!"representative {code.name} producer failure", data?
  }
  return (tool, failure.toResponseFailure)

private def hasUppercaseAscii (value : String) : Bool :=
  value.toList.any fun character => character.toNat >= 65 && character.toNat <= 90

private def isOpaquePublicEvidence (path : Array String) (key : String) : Bool :=
  ["original_data", "observed_response", "operation_response", "helper_error"].contains key ||
    (path == #["operation_outcome"] && key == "error")

private partial def requirePublicSnakeCaseAt
    (label : String) (path : Array String) (json : Json) : IO Unit := do
  match json with
  | .obj fields =>
      for (key, value) in fields.toList do
        if isOpaquePublicEvidence path key then
          continue
        require s!"{label}: public key {String.intercalate "." (path.push key).toList} contains uppercase"
          (!hasUppercaseAscii key)
        requirePublicSnakeCaseAt label (path.push key) value
  | .arr values =>
      for value in values do
        requirePublicSnakeCaseAt label path value
  | _ => pure ()

private def requireProjectionFallback
    (label : String) (data? : Option Json) (raw : Json) : IO Unit := do
  let some data := data? | throw <| IO.userError s!"{label}: expected projected error evidence"
  let original ← requireObjVal label "original_data" data
  require s!"{label}: original error data was changed" (original == raw)
  let projectionError ← IO.ofExcept <| data.getObjValAs? String "projection_error"
  require s!"{label}: projection error is empty" (!projectionError.isEmpty)
  requireFieldAbsent label "sync" data
  let .obj fields := data | throw <| IO.userError s!"{label}: fallback is not an object"
  require s!"{label}: fallback contains unexpected fields" (fields.toList.length == 2)

private def requireOpaqueErrorData
    (label : String) (data? : Option Json) (raw : Json) : IO Unit := do
  let some data := data? | throw <| IO.userError s!"{label}: expected preserved error data"
  let original ← requireObjVal label "original_data" data
  require s!"{label}: original error data was changed" (original == raw)
  requireFieldAbsent label "projection_error" data
  let .obj fields := data | throw <| IO.userError s!"{label}: opaque data wrapper is not an object"
  require s!"{label}: opaque wrapper contains unexpected fields" (fields.toList.length == 1)

private def checkBrokerFailureCodeCompleteness : IO Unit := do
  for code in Beam.Broker.BrokerFailureCode.all do
    let (tool, failure) := representativeBrokerFailure code
    let output ← expectToolError s!"broker failure code {code.name}" code.name <|
      Beam.Mcp.normalizeBrokerResponse tool (.errorResult failure)
    require s!"{code.name}: error message changed" (output.message == failure.error.message)
    require s!"{code.name}: error data presence changed"
      (output.data?.isSome == failure.error.data?.isSome)
    if let some data := output.data? then
      requirePublicSnakeCaseAt s!"{code.name} public error data" #[] data
      match code with
      | .invalidParams =>
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "sync" data
      | .requestCancelled => pure ()
      | .contentModified =>
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "expected_version" data
      | .workerExited =>
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "recovery" data
      | .syncBarrierIncomplete =>
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "target_path" data
      | .saveTraceStale => pure ()
      | .saveImportsChanged =>
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "changed_imports" data
          discard <| requireObjVal code.name "unresolved_imports" data
      | .saveUnsupportedSetup =>
          -- This pre-sync producer reports a simple reason/path pair. Preserve its exact
          -- lower-case public fields instead of classifying its Beam-owned data as opaque.
          requireFieldAbsent code.name "original_data" data
          discard <| requireObjVal code.name "reason" data
          discard <| requireObjVal code.name "path" data
      | .saveTargetNotModule => pure ()
      | .internalError => pure ()

private def checkSaveImportsChangedProjection : IO Unit := do
  let raw := sampleSaveImportsChangedData
  let failure : Beam.Broker.ResponseFailure := {
    error := { code := "saveImportsChanged", message := "imports changed after sync", data? := some raw }
  }
  let output ← expectToolError "save imports changed projection" "saveImportsChanged" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) (.errorResult failure)
  let data := output.data?.getD Json.null
  let sync ← requireObjVal "save imports changed" "sync" data
  let expectedSync ← expectToolOk "project expected sync result" <|
    Beam.Output.projectResult (.broker .syncFile) (toJson sampleSyncResult)
  require "save imports changed retains the same public sync shape" (sync == expectedSync)
  requireJsonString "save imports changed" "path" sampleSyncResult.path data
  let changedImports ← IO.ofExcept <| data.getObjValAs? (Array String) "changed_imports"
  require "changed imports are retained" (changedImports == #["Old.Dep", "New.Dep"])
  let unresolvedImports ← IO.ofExcept <| data.getObjValAs? (Array String) "unresolved_imports"
  require "empty unresolved imports are retained" (unresolvedImports.isEmpty)
  let recoveryPlan ← IO.ofExcept <| data.getObjValAs? (Array String) "recovery_plan"
  require "recovery plan is retained" (recoveryPlan == #["lean-beam refresh \"Demo.lean\""])
  requireFieldAbsent "save imports changed" "changedImports" data
  requireFieldAbsent "save imports changed" "unresolvedImports" data
  requireFieldAbsent "save imports changed" "recoveryPlan" data
  requireFieldAbsent "save imports changed" "original_data" data
  requirePublicSnakeCaseAt "save imports changed public data" #[] data

  let malformedRaw := raw.setObjVal! "path" (toJson "Other.lean")
  let malformedFailure : Beam.Broker.ResponseFailure := {
    error := { code := "saveImportsChanged", message := "imports changed", data? := some malformedRaw }
  }
  let malformed ← expectToolError "save imports changed path mismatch" "saveImportsChanged" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) (.errorResult malformedFailure)
  requireProjectionFallback "save imports changed path mismatch" malformed.data? malformedRaw

private def checkErrorProjectionFallbacks : IO Unit := do
  let malformedVersion := Json.mkObj [
    ("reason", toJson "documentVersionMismatch"), ("expectedVersion", toJson "three"),
    ("acceptedVersion", toJson (4 : Nat))
  ]
  let malformedVersionError ← expectToolError "malformed typed data fallback" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .contentModified "stale" (some malformedVersion)
  requireProjectionFallback "malformed typed data" malformedVersionError.data? malformedVersion

  let extraVersion := Json.mkObj [
    ("reason", toJson "documentVersionMismatch"), ("expectedVersion", toJson (3 : Nat)),
    ("acceptedVersion", toJson (4 : Nat)), ("unexpectedField", toJson true)
  ]
  let extraVersionError ← expectToolError "extra typed data field fallback" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .contentModified "stale" (some extraVersion)
  requireProjectionFallback "extra typed data field" extraVersionError.data? extraVersion

  let syncWithExtra := (Beam.Broker.syncResultErrorData sampleSyncResult)
    |>.setObjVal! "hintCount" (toJson (2 : Nat))
  let syncExtraError ← expectToolError "sync error with extra field fallback" "invalidParams" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .invalidParams "save rejected" (some syncWithExtra)
  requireProjectionFallback "sync error extra field" syncExtraError.data? syncWithExtra

  let unknownBackendData := Json.mkObj [("backendCamel", Json.mkObj [("nestedCamel", toJson true)])]
  let unknownCodeError ← expectToolError "unknown error data fallback" "externalError" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) <|
      Beam.Broker.Response.errorResult {
        error := { code := "externalError", message := "backend failure", data? := some unknownBackendData }
      }
  requireOpaqueErrorData "unknown backend error data" unknownCodeError.data? unknownBackendData

  let nullError ← expectToolError "explicit null error data" "invalidParams" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) <|
      Beam.Broker.errorResponseFor .invalidParams "bad params" (some Json.null)
  require "explicit null error data remains null" (nullError.data? == some Json.null)

private def checkControlProjectionCatalog : IO Unit := do
  let command := "lean-beam --root /repo recover"
  let argument := Json.mkObj [
    ("field", toJson "text"), ("preview", toJson "short"), ("omittedChars", toJson (5 : Nat))
  ]
  let operationResponse := Json.mkObj [
    ("result", Json.mkObj [("backendCamel", toJson true)])
  ]
  let catalog : Array (String × Array (String × String)) := #[
    ("invalidParams", #[("argument", "argument")]),
    ("internalError", #[("argument", "argument"),
      ("operationMayHaveCompleted", "operation_may_have_completed"),
      ("operationResponse", "operation_response")]),
    ("setupError", #[("remedyCommand", "remedy_command"),
      ("installationRoot", "installation_root"), ("sessionDir", "session_dir"),
      ("descriptorPath", "descriptor_path"),
      ("recoveryPrecondition", "recovery_precondition"),
      ("recordedConfigHash", "recorded_config_hash"),
      ("requestedConfigHash", "requested_config_hash")]),
    ("sessionRecoveryRequired", #[("remedyCommand", "remedy_command"),
      ("sessionDir", "session_dir"), ("descriptorPath", "descriptor_path"),
      ("recoveryPrecondition", "recovery_precondition"),
      ("recordedConfigHash", "recorded_config_hash"),
      ("requestedConfigHash", "requested_config_hash")]),
    ("sessionUnresponsive", #[("remedyCommand", "remedy_command"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition"),
      ("recordedConfigHash", "recorded_config_hash"),
      ("requestedConfigHash", "requested_config_hash")]),
    ("noLiveSession", #[("remedyCommand", "remedy_command"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition"),
      ("recordedConfigHash", "recorded_config_hash"),
      ("requestedConfigHash", "requested_config_hash")]),
    ("sessionShutdownUnconfirmed", #[("remedyCommand", "remedy_command"),
      ("recoveryCommand", "recovery_command"), ("installationRoot", "installation_root"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition")]),
    ("sessionInstallationMismatch", #[("remedyCommand", "remedy_command"),
      ("installationRoot", "installation_root"),
      ("currentInstallationRoot", "current_installation_root"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition")]),
    ("requestCancelled", #[("operationMayHaveCompleted", "operation_may_have_completed"),
      ("operationResponse", "operation_response")]),
    ("brokerUnavailable", #[("operationMayHaveCompleted", "operation_may_have_completed"),
      ("operationResponse", "operation_response")])
  ]
  require "control error data code list has complete fixture coverage"
    (Beam.Output.controlErrorDataCodes == catalog.map Prod.fst)
  let commonFields : Array (String × String) := #[
    ("root", "root"), ("path", "path"), ("generation", "generation"),
    ("detail", "detail"), ("diagnostics", "diagnostics")
  ]
  for (code, specificFields) in catalog do
    let fields := commonFields ++ specificFields
    let rawFields := fields.map fun (key, _) =>
      (key, match key with
        | "argument" => argument
        | "operationMayHaveCompleted" => toJson true
        | "operationResponse" => operationResponse
        | "remedyCommand" | "recoveryCommand" => toJson command
        | "installationRoot" | "currentInstallationRoot" => toJson "/installation"
        | "descriptorPath" => toJson "/session/descriptor.json"
        | "sessionDir" => toJson "/session"
        | "recoveryPrecondition" => toJson "confirm the original worker has stopped"
        | "recordedConfigHash" => toJson "recorded-config"
        | "requestedConfigHash" => toJson "requested-config"
        | "root" => toJson "/repo"
        | "path" => toJson "Demo.lean"
        | "generation" => toJson "generation-7"
        | "detail" => toJson "control fixture"
        | "diagnostics" => toJson "fixture diagnostics"
        | _ => Json.null)
    let raw := Json.mkObj rawFields.toList
    let failure : Beam.Broker.ResponseFailure := {
      error := { code, message := "catalogued control failure", data? := some raw }
    }
    let prepared := Beam.Cli.prepareControlResponse (.errorResult failure) (some "catalog-request")
    let err ← requireObjVal s!"control catalog {code}" "error" prepared.json
    let actual ← requireObjVal s!"control catalog {code}" "data" err
    let expected := Json.mkObj <| fields.toList.map fun (rawKey, publicKey) =>
      (publicKey, match rawKey with
        | "argument" => Json.mkObj [
            ("field", toJson "text"), ("preview", toJson "short"), ("omitted_chars", toJson (5 : Nat))
          ]
        | "operationResponse" => operationResponse
        | "operationMayHaveCompleted" => toJson true
        | "remedyCommand" | "recoveryCommand" => toJson command
        | "installationRoot" | "currentInstallationRoot" => toJson "/installation"
        | "descriptorPath" => toJson "/session/descriptor.json"
        | "sessionDir" => toJson "/session"
        | "recoveryPrecondition" => toJson "confirm the original worker has stopped"
        | "recordedConfigHash" => toJson "recorded-config"
        | "requestedConfigHash" => toJson "requested-config"
        | "root" => toJson "/repo"
        | "path" => toJson "Demo.lean"
        | "generation" => toJson "generation-7"
        | "detail" => toJson "control fixture"
        | "diagnostics" => toJson "fixture diagnostics"
        | _ => Json.null)
    require s!"control catalog {code}: output differs from exact public field inventory" (actual == expected)
    requirePublicSnakeCaseAt s!"control catalog {code}" #[] actual

  let doctorLines := toJson (#["project root: /repo", "daemon status: recovery required"] : Array String)
  let doctorFailure : Beam.Broker.ResponseFailure := {
    error := { code := "sessionRecoveryRequired", message := "doctor recovery", data? := some <|
      Json.mkObj [("diagnostics", doctorLines), ("remedyCommand", toJson command)] }
  }
  let doctorData := (Beam.Output.OutputError.fromControlFailure doctorFailure).data?.getD Json.null
  require "doctor diagnostic lines remain structured" ((← requireObjVal "doctor" "diagnostics" doctorData) == doctorLines)
  requireFieldAbsent "doctor diagnostics" "projection_error" doctorData
  let invalidDoctorData := Json.mkObj [("diagnostics", Json.arr #[toJson (1 : Nat)])]
  let invalidDoctor := { doctorFailure with
    error := { doctorFailure.error with data? := some invalidDoctorData } }
  requireProjectionFallback "invalid doctor diagnostic line"
    (Beam.Output.OutputError.fromControlFailure invalidDoctor).data?
    (invalidDoctor.error.data?.getD Json.null)

  let malformedArgument := Json.mkObj [
    ("field", toJson "text"), ("preview", toJson "short"), ("omittedChars", toJson (5 : Nat)),
    ("backendExtra", toJson true)
  ]
  let malformedRaw := Json.mkObj [("argument", malformedArgument)]
  let malformedFailure : Beam.Broker.ResponseFailure := {
    error := { code := "invalidParams", message := "invalid input", data? := some malformedRaw }
  }
  let malformed := Beam.Output.OutputError.fromControlFailure malformedFailure
  requireProjectionFallback "control argument extra field" malformed.data? malformedRaw

  let unknownControlRaw := Json.mkObj [
    ("remedyCommand", toJson command),
    ("backendFieldCamel", Json.mkObj [("nestedCamel", toJson true)])
  ]
  let unknownControlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "noLiveSession", message := "no session", data? := some unknownControlRaw }
  }
  let unknownControl := Beam.Output.OutputError.fromControlFailure unknownControlFailure
  requireProjectionFallback "unknown field for recognized control code" unknownControl.data? unknownControlRaw

  let unknownCodeFailure : Beam.Broker.ResponseFailure := {
    error := { code := "externalError", message := "backend failure", data? := some unknownControlRaw }
  }
  let unknownCode := Beam.Output.OutputError.fromControlFailure unknownCodeFailure
  requireOpaqueErrorData "unknown control code" unknownCode.data? unknownControlRaw

private def checkTypedErrorDataProjection : IO Unit := do
  let versionData := Beam.Broker.documentVersionMismatchErrorData 3 4
    (currentVersion? := some 4) (uri? := some "file:///repo/Demo.lean")
  let versionError ← expectToolError "version mismatch projection" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .contentModified "stale" (some versionData)
  let versionProjected := versionError.data?.getD Json.null
  requirePublicSnakeCaseAt "version mismatch" #[] versionProjected
  requireJsonInt "version mismatch" "expected_version" 3 versionProjected
  requireJsonInt "version mismatch" "accepted_version" 4 versionProjected
  requireJsonInt "version mismatch" "current_version" 4 versionProjected
  requireFieldAbsent "version mismatch" "expectedVersion" versionProjected

  let changedData := Json.mkObj [
    ("reason", toJson "documentChanged"), ("uri", toJson "file:///repo/Demo.lean")
  ]
  let changedError ← expectToolError "document changed projection" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) <|
      Beam.Broker.errorResponseFor .contentModified "changed" (some changedData)
  let changed ← IO.ofExcept <| (changedError.data?.getD Json.null).getObjVal? "reason"
  require "document changed without version stays projectable" (changed == toJson "documentChanged")
  requirePublicSnakeCaseAt "document changed" #[] (changedError.data?.getD Json.null)

  let hashData := Json.mkObj [
    ("expectedHash", toJson (11 : Nat)), ("actualHash", toJson (12 : Nat)),
    ("uri", toJson "file:///repo/Demo.lean")
  ]
  let hashError ← expectToolError "hash mismatch projection" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .contentModified "hash changed" (some hashData)
  let hashProjected := hashError.data?.getD Json.null
  requirePublicSnakeCaseAt "hash mismatch" #[] hashProjected
  requireJsonInt "hash mismatch" "expected_hash" 11 hashProjected
  requireJsonInt "hash mismatch" "actual_hash" 12 hashProjected
  requireFieldAbsent "hash mismatch" "expectedHash" hashProjected

  let hints := #[
    ({ module := "Dep", path := "Dep.lean", needsSave := true } : Beam.Broker.StaleDirectDepHint),
    ({ module := "Other", path := "Other.lean", needsSave := false } : Beam.Broker.StaleDirectDepHint)
  ]
  let staleData := Beam.Broker.staleSyncErrorData "Demo.lean" hints
  let staleError ← expectToolError "stale dependency projection" "syncBarrierIncomplete" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .syncBarrierIncomplete "barrier incomplete" (some staleData)
  let staleProjected := staleError.data?.getD Json.null
  requirePublicSnakeCaseAt "stale dependency" #[] staleProjected
  requireJsonString "stale dependency data" "target_path" "Demo.lean" staleProjected
  let staleHints ← IO.ofExcept <| staleProjected.getObjValAs? (Array Json) "stale_direct_deps"
  let some firstHint := staleHints[0]? | throw <| IO.userError "stale dependency hint missing"
  requireJsonBool "stale dependency hint" "needs_save" true firstHint
  let plan ← IO.ofExcept <| staleProjected.getObjValAs? (Array String) "recovery_plan"
  require "recovery plan preserves the broker's copyable commands"
    (plan == #["lean-beam save \"Dep.lean\"", "lean-beam refresh \"Demo.lean\""])
  require "normal stale-dependency recovery does not request an external build"
    (!plan.any (·.contains "lake build"))

  let noStaleDeps := Beam.Broker.staleSyncErrorData "Demo.lean" #[
    { module := "Saved", path := "Saved.lean", needsSave := false }
  ]
  let noStaleError ← expectToolError "saved dependency projection" "syncBarrierIncomplete" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .syncBarrierIncomplete "barrier incomplete" (some noStaleDeps)
  let noStaleProjected := noStaleError.data?.getD Json.null
  let noStalePlan ← IO.ofExcept <| noStaleProjected.getObjValAs? (Array String) "recovery_plan"
  require "already-saved dependency recovery only refreshes the target"
    (noStalePlan == #["lean-beam refresh \"Demo.lean\""])

  let successfulSync ← expectToolOk "successful sync for error-data comparison" <|
    Beam.Output.projectResult (.broker .syncFile) (toJson sampleSyncResult)
  let syncErrorData := Beam.Broker.syncResultErrorData sampleSyncResult
  let invalidParamsSyncError ← expectToolError "invalidParams sync error projection" "invalidParams" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .invalidParams "save rejected" (some syncErrorData)
  let invalidParamsData := invalidParamsSyncError.data?.getD Json.null
  requirePublicSnakeCaseAt "invalidParams embedded sync" #[] invalidParamsData
  let invalidParamsSync ← IO.ofExcept <| invalidParamsData.getObjVal? "sync"
  require "save rejection embedded sync matches the successful sync projection"
    (invalidParamsSync == successfulSync)

  let batchOnlyReason := "Lake module uses batch-only moreLeanArgs"
  let batchOnlyData := syncErrorData
    |>.setObjVal! "reason" (toJson batchOnlyReason)
    |>.setObjVal! "path" (toJson sampleSyncResult.path)
  let batchOnlyError ← expectToolError "batch-only setup with sync receipt" "saveUnsupportedSetup" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .saveUnsupportedSetup "unsupported save" (some batchOnlyData)
  let batchOnlyPublic := batchOnlyError.data?.getD Json.null
  let batchOnlySync ← requireObjVal "batch-only setup" "sync" batchOnlyPublic
  require "batch-only embedded sync matches the successful public projection" (batchOnlySync == successfulSync)
  requireJsonString "batch-only setup" "reason" batchOnlyReason batchOnlyPublic
  requireJsonString "batch-only setup" "path" sampleSyncResult.path batchOnlyPublic
  requireFieldAbsent "batch-only setup" "projection_error" batchOnlyPublic
  requirePublicSnakeCaseAt "batch-only setup" #[] batchOnlyPublic

  let deferredSyncErrorData := syncErrorData
    |>.setObjVal! "reason" (toJson Beam.LSP.Save.saveReadinessDeferredCompilationReason)
    |>.setObjVal! "path" (toJson sampleSyncResult.path)
  let syncError ← expectToolError "embedded sync error projection" "saveUnsupportedSetup" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .saveUnsupportedSetup "unsupported save" (some deferredSyncErrorData)
  let projectedSync ← IO.ofExcept <| (syncError.data?.getD Json.null).getObjVal? "sync"
  requirePublicSnakeCaseAt "deferred compilation sync" #[] (syncError.data?.getD Json.null)
  require "deferred-save embedded sync matches the successful sync projection"
    (projectedSync == successfulSync)

  let saveData := Json.mkObj [
    ("saved", toJson sampleSaveResult),
    ("originalData", Json.mkObj [("backendCamel", toJson true)])
  ]
  let saveFailure : Beam.Broker.ResponseFailure := {
    error := { code := "rpcNeedsReconnect", message := "close notification failed", data? := some saveData }
  }
  let saveError ← expectToolError "committed save error projection" "rpcNeedsReconnect" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .closeSave) (.errorResult saveFailure)
  let saveErrorData := saveError.data?.getD Json.null
  requirePublicSnakeCaseAt "committed save failure" #[] saveErrorData
  let saved ← IO.ofExcept <| saveErrorData.getObjVal? "saved"
  requireJsonString "committed save" "source_hash" "source-hash" saved
  discard <| requireObjVal "committed save" "sync" saved
  let original ← requireObjVal "committed save error" "original_data" saveErrorData
  requireJsonBool "opaque original data" "backendCamel" true original

  let workerData := Beam.Broker.workerRecoveryData (.sync "file:///repo/Demo.lean")
    (some <| Json.mkObj [("untrustedCamel", toJson "preserved")])
  let workerFailure : Beam.Broker.ResponseFailure := {
    error := { code := "workerCrashed", message := "worker exited", data? := some workerData }
  }
  let workerError ← expectToolError "worker recovery projection" "workerCrashed" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) (.errorResult workerFailure)
  let workerProjected := workerError.data?.getD Json.null
  requirePublicSnakeCaseAt "worker recovery" #[] workerProjected
  let recovery ← requireObjVal "worker recovery" "recovery" workerProjected
  requireJsonString "worker recovery" "kind" "sync" recovery
  requireJsonString "worker recovery" "uri" "file:///repo/Demo.lean" recovery
  let original ← requireObjVal "worker recovery" "original_data" workerProjected
  requireJsonString "worker original data" "untrustedCamel" "preserved" original

  let operationResponse := Beam.Broker.Response.success <| Json.mkObj [("producerCamel", toJson true)]
  let helperErrorValue : Beam.Broker.Error := {
    code := "internalError"
    message := "helper operation failed"
    data? := some <| Json.mkObj [("backendCamel", toJson "opaque")]
  }
  let cleanupData := Json.mkObj [
    ("reason", toJson "helperCleanupFailed"),
    ("operation", toJson "save"),
    ("operationOutcome", Json.mkObj [
      ("status", toJson "failed"), ("error", toJson helperErrorValue)
    ]),
    ("cleanup", Json.mkObj [("processJob", toJson "process did not exit")]),
    ("operationResponse", toJson operationResponse)
  ]
  let cleanupError ← expectToolError "helper cleanup failure projection" "internalError" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .internalError "cleanup failed" (some cleanupData)
  let cleanupProjected := cleanupError.data?.getD Json.null
  requirePublicSnakeCaseAt "helper cleanup" #[] cleanupProjected
  let outcome ← requireObjVal "helper cleanup error" "operation_outcome" cleanupProjected
  let nestedError ← requireObjVal "helper operation outcome" "error" outcome
  require "nested helper error remains opaque typed evidence" (nestedError == toJson helperErrorValue)
  let rawResponse ← requireObjVal "helper cleanup error" "operation_response" cleanupProjected
  require "operation response evidence is preserved" (rawResponse == toJson operationResponse)
  let cleanup ← requireObjVal "helper cleanup error" "cleanup" cleanupProjected
  requireJsonString "helper cleanup" "process_job" "process did not exit" cleanup

  let helperWrapper := Json.mkObj [("helperError", toJson helperErrorValue)]
  let helperWrapperError ← expectToolError "helper error wrapper projection" "internalError" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      Beam.Broker.errorResponseFor .internalError "helper failed" (some helperWrapper)
  let helperProjected := helperWrapperError.data?.getD Json.null
  requirePublicSnakeCaseAt "helper wrapper" #[] helperProjected
  let helperDetail ← requireObjVal "helper error wrapper" "helper_error" helperProjected
  require "helper error remains opaque typed evidence" (helperDetail == toJson helperErrorValue)

  let malformedData := Json.mkObj [
    ("reason", toJson "documentVersionMismatch"), ("expectedVersion", toJson "three"),
    ("acceptedVersion", toJson (4 : Nat)), ("backendCamel", toJson "keep")
  ]
  let malformedError ← expectToolError "malformed known error data remains evidence" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      Beam.Broker.errorResponseFor .contentModified "stale" (some malformedData)
  requireProjectionFallback "malformed known error data" malformedError.data? malformedData
  let opaqueData := Json.mkObj [("backendCamel", Json.mkObj [("nestedCamel", toJson true)])]
  let opaqueError ← expectToolError "unknown backend error data remains opaque" "internalError" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) <|
      Beam.Broker.errorResponseFor .internalError "backend failure" (some opaqueData)
  requireOpaqueErrorData "unknown nested backend JSON" opaqueError.data? opaqueData

  let externalData := Beam.Broker.syncResultErrorData sampleSyncResult
  let externalFailure : Beam.Broker.ResponseFailure := {
    error := { code := "externalError", message := "backend-defined error", data? := some externalData }
  }
  let externalError ← expectToolError "unknown error code does not infer a sync wrapper" "externalError" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) (.errorResult externalFailure)
  requireOpaqueErrorData "unknown code preserves sync-shaped backend data"
    externalError.data? externalData
  let externalControlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "externalError", message := "backend-defined error", data? := some <|
      Json.mkObj [("argument", Json.mkObj [
        ("field", toJson "text"), ("preview", toJson "short"), ("omittedChars", toJson (5 : Nat))
      ])] }
  }
  let externalControl := Beam.Output.OutputError.fromControlFailure externalControlFailure
  requireOpaqueErrorData "control projection does not rename unknown error data"
    externalControl.data? (externalControlFailure.error.data?.getD Json.null)

  let controlData := Json.mkObj [
    ("argument", Json.mkObj [
      ("field", toJson "text"), ("preview", toJson "short"), ("omittedChars", toJson (5 : Nat))
    ])
  ]
  let controlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "invalidParams", message := "invalid input", data? := some controlData }
  }
  let controlError := Beam.Output.OutputError.fromControlFailure controlFailure
  let controlProjected := controlError.data?.getD Json.null
  let argument ← requireObjVal "control error" "argument" controlProjected
  requireJsonInt "control argument preview" "omitted_chars" 5 argument
  requireFieldAbsent "control argument preview" "omittedChars" argument
  requirePublicSnakeCaseAt "control argument projection" #[] controlProjected

  let recoveryControlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "sessionRecoveryRequired", message := "recover session", data? := some <|
      Json.mkObj [
        ("remedyCommand", toJson "lean-beam status"),
        ("sessionDir", toJson "/tmp/beam-session"),
        ("recoveryPrecondition", toJson "verify owner stopped")
      ] }
  }
  let recoveryControl := Beam.Output.OutputError.fromControlFailure recoveryControlFailure
  let recoveryControlData := recoveryControl.data?.getD Json.null
  requireJsonString "control remedy" "remedy_command" "lean-beam status" recoveryControlData
  requireJsonString "control error" "session_dir" "/tmp/beam-session" recoveryControlData
  requireJsonString "control error" "recovery_precondition" "verify owner stopped" recoveryControlData

  -- Session-control metadata is public recovery data, including conditional commands. Keep
  -- exact command text and opaque details; only the owning error code permits each rename.
  let sessionCases : Array (String × Array (String × String)) := #[
    ("sessionShutdownUnconfirmed", #[("remedyCommand", "remedy_command"),
      ("recoveryCommand", "recovery_command"), ("installationRoot", "installation_root"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition")]),
    ("sessionInstallationMismatch", #[("remedyCommand", "remedy_command"),
      ("installationRoot", "installation_root"), ("currentInstallationRoot", "current_installation_root"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition")]),
    ("setupError", #[("remedyCommand", "remedy_command"), ("installationRoot", "installation_root"),
      ("sessionDir", "session_dir"), ("recoveryPrecondition", "recovery_precondition"),
      ("recordedConfigHash", "recorded_config_hash"), ("requestedConfigHash", "requested_config_hash")]),
    ("sessionRecoveryRequired", #[("remedyCommand", "remedy_command"),
      ("recoveryPrecondition", "recovery_precondition")])
  ]
  let command := "'/owning installation/bin/lean-beam' --root '/project' recover --generation 'generation-7'"
  let unchanged := [("generation", toJson "generation-7"), ("root", toJson "/project"),
    ("detail", toJson "owner state is unconfirmed"), ("diagnostics", toJson "probe output")]
  for (code, fields) in sessionCases do
    let fieldValue := fun (key : String) => match key with
      | "remedyCommand" => if code == "sessionShutdownUnconfirmed" then
          "'/owning installation/bin/lean-beam' --root '/project' status" else command
      | "recoveryCommand" => command
      | "installationRoot" => "/owning installation"
      | "currentInstallationRoot" => "/current installation"
      | "sessionDir" => "/session directory"
      | "recoveryPrecondition" => "independently verify all original producers have stopped"
      | "recordedConfigHash" => "recorded-config"
      | "requestedConfigHash" => "requested-config"
      | _ => "unexpected fixture field"
    let data := Json.mkObj <| fields.toList.map (fun (raw, _) => (raw, toJson (fieldValue raw))) ++ unchanged
    let failure : Beam.Broker.ResponseFailure := {
      error := { code, message := "session control failed", data? := some data }
    }
    let response := Beam.Cli.prepareControlResponse (.errorResult failure) (some "session-request")
    let error ← requireObjVal "session-control envelope" "error" response.json
    let actual ← requireObjVal "session-control error" "data" error
    let expected := Json.mkObj <| fields.toList.map (fun (raw, publicKey) => (publicKey, toJson (fieldValue raw))) ++ unchanged
    require "session-control fields use only public spellings" (actual == expected)
    require "session-control preparation retains original evidence" (toJson response.observed == toJson (Beam.Broker.Response.errorResult failure))
    requireJsonString "session-control correlation" "client_request_id" "session-request" response.json
    let malformed := data.setObjVal! "remedyCommand" (toJson (7 : Nat))
    let malformedFailure := { failure with error := { failure.error with data? := some malformed } }
    requireProjectionFallback "malformed session metadata"
      (Beam.Output.OutputError.fromControlFailure malformedFailure).data? malformed
  let noConditionalRecovery : Beam.Broker.ResponseFailure := {
    error := { code := "sessionShutdownUnconfirmed", message := "check status", data? := some <|
      Json.mkObj [("remedyCommand", toJson "lean-beam status")] }
  }
  let noConditionalData := (Beam.Output.OutputError.fromControlFailure noConditionalRecovery).data?.getD Json.null
  requireFieldAbsent "no conditional recovery supplied" "recovery_command" noConditionalData
  requireJsonString "status remedy without recovery" "remedy_command" "lean-beam status" noConditionalData
  let unrelatedRecovery : Beam.Broker.ResponseFailure := {
    error := { code := "externalError", message := "opaque backend", data? := some <|
      Json.mkObj [("recoveryCommand", toJson command), ("installationRoot", toJson "/opaque")] }
  }
  requireOpaqueErrorData "unknown codes retain recovery-shaped opaque data"
    (Beam.Output.OutputError.fromControlFailure unrelatedRecovery).data?
    (unrelatedRecovery.error.data?.getD Json.null)

  let uncertainControlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "brokerUnavailable", message := "delivery uncertain", data? := some <|
      Json.mkObj [
        ("operationMayHaveCompleted", toJson true),
        ("operationResponse", toJson operationResponse)
      ] }
  }
  let uncertainControl := Beam.Output.OutputError.fromControlFailure uncertainControlFailure
  let uncertainControlData := uncertainControl.data?.getD Json.null
  requireJsonBool "control error" "operation_may_have_completed" true uncertainControlData
  let operationReceipt ← requireObjVal "control error" "operation_response" uncertainControlData
  require "control operation response remains opaque" (operationReceipt == toJson operationResponse)

  let malformedControl := controlData.setObjVal! "argument" <| Json.mkObj [
    ("field", toJson "text"), ("preview", toJson "short"), ("omittedChars", toJson "five")
  ]
  let malformedControlFailure : Beam.Broker.ResponseFailure := {
    error := { code := "invalidParams", message := "invalid input", data? := some malformedControl }
  }
  let malformedControlError := Beam.Output.OutputError.fromControlFailure malformedControlFailure
  requireProjectionFallback "malformed control metadata" malformedControlError.data? malformedControl


private def checkSyncAndSaveNormalization : IO Unit := do
  let normalizedSync ← expectToolOk "normalize sync result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .sync) <|
      (Beam.Broker.Response.success <| toJson sampleSyncResult).withFileProgress {
        updates := 4
        done := true
        rangeStartLine? := some 1
        rangeEndLine? := some 20
      }
  requireJsonString "sync result" "path" "Demo.lean" normalizedSync
  requireJsonInt "sync result" "version" 7 normalizedSync
  let diagnostics ← requireObjVal "sync result" "diagnostics" normalizedSync
  let counts ← requireObjVal "sync diagnostics" "counts" diagnostics
  requireJsonInt "sync diagnostic counts" "error" 1 counts
  let items ← IO.ofExcept <| diagnostics.getObjValAs? (Array Json) "items"
  let some item := items[0]?
    | throw <| IO.userError "sync diagnostic items should contain the warning"
  requireJsonString "sync diagnostic item" "severity" "warning" item
  requireJsonBool "sync diagnostic item" "completion_blocking" false item
  requireFieldAbsent "sync diagnostic item" "completionBlocking" item
  let readiness ← requireObjVal "sync result" "readiness" normalizedSync
  requireJsonBool "sync readiness" "save_ready" false readiness
  requireJsonString "sync readiness" "reason" "documentErrors" readiness
  requireJsonInt "sync readiness" "blocking_error_count" 1 readiness
  discard <| requireObjVal "sync readiness" "blocking_messages" readiness
  let progress ← requireObjVal "sync result" "document_progress" normalizedSync
  requireJsonBool "sync document progress" "done" true progress
  requireJsonInt "sync document progress" "range_start_line" 1 progress
  requireJsonInt "sync document progress" "range_end_line" 20 progress
  requireFieldAbsent "sync result" "file_progress" normalizedSync
  requireFieldAbsent "sync result" "syncSummary" normalizedSync

  let rawSave := Json.mkObj [
    ("path", toJson "Demo.lean"),
    ("module", toJson "Demo"),
    ("version", toJson (7 : Nat)),
    ("sourceHash", toJson "abc"),
    ("olean", toJson "/tmp/Demo.olean"),
    ("ilean", toJson "/tmp/Demo.ilean"),
    ("c", toJson "/tmp/Demo.c"),
    ("trace", toJson "/tmp/Demo.olean.trace"),
    ("oleanServer", toJson "/tmp/Demo.olean.server"),
    ("irSig", toJson "/tmp/Demo.ir.sig"),
    ("sync", toJson sampleSyncResult)
  ]
  let normalizedSave ← expectToolOk "normalize save result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      (Beam.Broker.Response.success rawSave).withFileProgress { updates := 4, done := true }
  requireJsonString "save result" "source_hash" "abc" normalizedSave
  requireJsonString "save result" "olean_server" "/tmp/Demo.olean.server" normalizedSave
  requireJsonString "save result" "ir_sig" "/tmp/Demo.ir.sig" normalizedSave
  requireFieldAbsent "save result" "irSig" normalizedSave
  requireFieldAbsent "save result" "sourceHash" normalizedSave
  let saveSync ← requireObjVal "save result" "sync" normalizedSave
  discard <| requireObjVal "save sync result" "readiness" saveSync
  discard <| requireObjVal "save result" "document_progress" normalizedSave

  let normalizedCloseSave ← expectToolOk "normalize close-save result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .closeSave) <| Beam.Broker.Response.success <|
      Json.mkObj [
        ("closed", toJson true),
        ("saved", rawSave)
      ]
  requireJsonBool "close-save result" "closed" true normalizedCloseSave
  let saved ← requireObjVal "close-save result" "saved" normalizedCloseSave
  discard <| requireObjVal "close-save saved result" "sync" saved

  let savedCheckpoint ← expectOk "typed committed checkpoint" <|
    fromJson? (α := Beam.Broker.SaveOleanResult) rawSave
  let staleData := toJson ({ saved := savedCheckpoint, currentVersion? := some 7 } :
    Beam.Broker.SaveFinalizationStaleData)
  let stale ← expectToolError "normalize committed stale close" "contentModified" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .closeSave) <|
      Beam.Broker.errorResponseFor .contentModified "document reopened" (some staleData)
  let staleDataProjected := stale.data?.getD Json.null
  let staleSaved ← requireObjVal "stale close" "saved" staleDataProjected
  requireJsonString "stale close saved receipt" "source_hash" "abc" staleSaved
  requireJsonInt "stale close" "current_version" 7 staleDataProjected
  requireFieldAbsent "stale close" "currentVersion" staleDataProjected

  discard <| expectToolError "save result with undeclared field" "invalidResult" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <| Beam.Broker.Response.success <|
      rawSave.setObjVal! "extra" (toJson true)
  discard <| expectToolError "close-save result with undeclared field" "invalidResult" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .closeSave) <| Beam.Broker.Response.success <|
      Json.mkObj [
        ("closed", toJson true),
        ("saved", rawSave),
        ("extra", toJson true)
      ]

private def checkTransportErrorNormalization : IO Unit := do
  let err ← expectToolError "normalize transport error" "invalidParams" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt) <|
      Beam.Broker.errorResponseFor .invalidParams "bad position"
  require "transport error message" (err.message == "bad position")

private def checkTodoNormalization : IO Unit := do
  let rawTodo := Json.mkObj [
    ("version", toJson (1 : Nat)),
    ("range", toJson ({ start := { line := 0, character := 0 }, «end» := { line := 2, character := 0 } } : Lean.Lsp.Range)),
    ("items", Json.arr #[
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.incompleteProof),
        ("range", toJson ({ start := { line := 1, character := 2 }, «end» := { line := 1, character := 7 } } : Lean.Lsp.Range)),
        ("runAtPosition", toJson ({ line := 1, character := 7 } : Lean.Lsp.Position)),
        ("proofState", toJson ({ goals := #[] } : Beam.LSP.Lib.ProofState))
      ],
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.codeAction),
        ("range", toJson ({ start := { line := 1, character := 10 }, «end» := { line := 1, character := 11 } } : Lean.Lsp.Range)),
        ("runAtPosition", toJson ({ line := 1, character := 10 } : Lean.Lsp.Position)),
        ("codeAction", Json.mkObj [
          ("title", toJson ("Replace fixture hole with zero" : String)),
          ("kind", toJson ("quickfix" : String))
        ])
      ],
      -- Goals that no source position selects, such as those left after a branch bullet.
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.incompleteProof),
        ("range", toJson ({ start := { line := 2, character := 4 }, «end» := { line := 2, character := 9 } } : Lean.Lsp.Range)),
        ("proofState", toJson ({ goals := #[] } : Beam.LSP.Lib.ProofState))
      ]
    ])
  ]
  let normalized ← expectToolOk "normalize todo result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .todo)
      (Beam.Broker.Response.success rawTodo)
  let items ← requireObjVal "todo result" "items" normalized
  let item ←
    match items with
    | Json.arr items =>
        match items[0]? with
        | some item => pure item
        | none => throw <| IO.userError "todo result: expected first item"
    | _ => throw <| IO.userError s!"todo result: expected items array, got {items.compress}"
  discard <| requireObjVal "todo item" "run_at_position" item
  discard <| requireObjVal "todo item" "proof_state" item
  requireFieldAbsent "todo item" "runAtPosition" item
  requireFieldAbsent "todo item" "proofState" item
  let codeActionItem ←
    match items with
    | Json.arr items =>
        match items[1]? with
        | some item => pure item
        | none => throw <| IO.userError "todo result: expected second item"
    | _ => throw <| IO.userError s!"todo result: expected items array, got {items.compress}"
  discard <| requireObjVal "todo code action item" "code_action" codeActionItem
  requireFieldAbsent "todo code action item" "codeAction" codeActionItem
  let unselectableItem ←
    match items with
    | Json.arr items =>
        match items[2]? with
        | some item => pure item
        | none => throw <| IO.userError "todo result: expected third item"
    | _ => throw <| IO.userError s!"todo result: expected items array, got {items.compress}"
  requireFieldAbsent "todo item without a position" "run_at_position" unselectableItem
  requireFieldAbsent "todo item without a position" "runAtPosition" unselectableItem
  discard <| requireObjVal "todo item without a position" "proof_state" unselectableItem

private def checkCodeActionResolveNormalization : IO Unit := do
  let rawResult := Json.mkObj [
    ("version", toJson (15 : Nat)),
    ("codeAction", Json.mkObj [
      ("title", toJson ("Replace fixture hole with zero" : String)),
      ("kind", toJson ("quickfix" : String))
    ])
  ]
  let normalized ← expectToolOk "normalize code_action_resolve result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .codeActionResolve)
      (Beam.Broker.Response.success rawResult)
  discard <| requireObjVal "code_action_resolve result" "code_action" normalized
  requireFieldAbsent "code_action_resolve result" "codeAction" normalized

def main : IO Unit := do
  checkToolNames
  checkToolDescriptors
  checkBrokerRequestAdapters
  checkPublicInputDiagnostics
  checkRunAtNormalization
  checkSyncAndSaveNormalization
  checkCrossSurfaceResultParity
  checkCrossSurfaceErrorParity
  checkBrokerFailureCodeCompleteness
  checkSaveImportsChangedProjection
  checkErrorProjectionFallbacks
  checkControlProjectionCatalog
  checkTypedErrorDataProjection
  checkExplicitResultScope
  checkProjectionFailureEvidence
  checkTransportErrorNormalization
  checkTodoNormalization
  checkCodeActionResolveNormalization

end BeamTest.Broker.McpProjectionTest

def main := BeamTest.Broker.McpProjectionTest.main
