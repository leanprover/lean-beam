/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Errors
import Beam.Mcp.Projection
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpProjectionTest

private def expectToolOk (label : String) (result : Except Beam.Mcp.ToolError Json) : IO Json := do
  match result with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label}: {err.code}: {err.message}"

private def expectToolError (label expectedCode : String) (result : Except Beam.Mcp.ToolError Json) :
    IO Beam.Mcp.ToolError := do
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
  backend := .lean
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
    require s!"projected MCP operation {repr op} should advertise MCP progress controls"
      (projectedTool.descriptor.description.contains "tools/call" &&
        projectedTool.descriptor.description.contains "_meta.progressToken")
    let matchingTools := Beam.Mcp.ToolName.leanOperationTools.filter (fun tool =>
      tool == .leanOperation op)
    require s!"Lean operation {repr op} should have exactly one MCP tool"
      (matchingTools.size == 1)
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
    snapshot := ⟨"test-session", 12⟩
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
  require "runAt backend" (runAt.backend == .lean)
  require "runAt path" (runAt.path == "Demo.lean")
  require "runAt snapshot" (runAt.snapshot == ⟨"test-session", 12⟩)
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
    snapshot := ⟨"test-session", 13⟩
    line := 7
    character := 3
  }
  let hoverReq ← expectOk "hover tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .hover workspaceId (inWorkspace <| toJson positionInput)
  let hover ← expectRequestPayload "hover tool request" hoverReq fun
    | .hover request => some request
    | _ => none
  require "hover op" (hoverReq.op == .hover)
  require "hover snapshot" (hover.snapshot == ⟨"test-session", 13⟩)

  let signatureHelpReq ← expectOk "signature-help tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .signatureHelp workspaceId
      (inWorkspace <| toJson positionInput)
  let signatureHelp ← expectRequestPayload "signature-help tool request" signatureHelpReq fun
    | .signatureHelp request => some request
    | _ => none
  require "signature-help op" (signatureHelpReq.op == .signatureHelp)
  require "signature-help backend" (signatureHelp.backend == .lean)
  require "signature-help snapshot" (signatureHelp.snapshot == ⟨"test-session", 13⟩)

  let definitionReq ← expectOk "definition tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .definition workspaceId
      (inWorkspace <| toJson positionInput)
  let definition ← expectRequestPayload "definition tool request" definitionReq fun
    | .definition request => some request
    | _ => none
  require "definition op" (definitionReq.op == .definition)
  require "definition backend" (definition.backend == .lean)
  require "definition snapshot" (definition.snapshot == ⟨"test-session", 13⟩)

  let referencesInput : Beam.Mcp.ReferencesInput := {
    path := "Demo.lean"
    snapshot := ⟨"test-session", 13⟩
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
  require "references snapshot" (references.snapshot == ⟨"test-session", 13⟩)
  require "references include declaration" (references.includeDeclaration? == some false)
  let referencesJson := toJson referencesInput
  requireJsonBool "references input json" "include_declaration" false referencesJson
  requireFieldAbsent "references input json" "includeDeclaration" referencesJson
  let decodedReferences ← expectOk "decode references input" <|
    fromJson? (α := Beam.Mcp.ReferencesInput) referencesJson
  require "decoded references include declaration" (decodedReferences.includeDeclaration? == some false)

  let documentSymbolsInput : Beam.Mcp.DocumentSymbolsInput := {
    path := "Demo.lean"
    snapshot := ⟨"test-session", 13⟩
  }
  let documentSymbolsReq ← expectOk "document-symbols tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .documentSymbols workspaceId
      (inWorkspace <| toJson documentSymbolsInput)
  let documentSymbols ← expectRequestPayload "document-symbols tool request" documentSymbolsReq fun
    | .documentSymbols request => some request
    | _ => none
  require "document-symbols op" (documentSymbolsReq.op == .documentSymbols)
  require "document-symbols path" (documentSymbols.path == "Demo.lean")
  require "document-symbols snapshot" (documentSymbols.snapshot == ⟨"test-session", 13⟩)

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
    snapshot := ⟨"test-session", 13⟩
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
    snapshot := ⟨"test-session", 13⟩
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
    snapshot := ⟨"test-session", 14⟩
    startLine := 1
    startCharacter := 0
    endLine := 8
    endCharacter := 3
    kinds? := some #[.sorry, .incompleteProof]
    suggest? := some .basic
  }
  let todoReq ← expectOk "todo tool request" <|
    Beam.Mcp.leanOperationToBrokerRequest .todo workspaceId (inWorkspace <| toJson todoInput)
  let todo ← expectRequestPayload "todo tool request" todoReq fun
    | .todo request => some request
    | _ => none
  require "todo op" (todoReq.op == .todo)
  require "todo backend" (todo.backend == .lean)
  require "todo snapshot" (todo.snapshot == ⟨"test-session", 14⟩)
  require "todo start line" (todo.line == 1)
  require "todo start character" (todo.character == 0)
  require "todo end line" (todo.endLine == 8)
  require "todo end character" (todo.endCharacter == 3)
  require "todo kinds" (todo.kinds? == some #[.sorry, .incompleteProof])
  require "todo suggest" (todo.suggest? == some .basic)
  let todoJson := toJson todoInput
  requireJsonString "todo input json" "path" "Demo.lean" todoJson
  requireFieldAbsent "todo input json" "startLine" todoJson
  requireFieldAbsent "todo input json" "root" todoJson

  let codeAction : Lean.Lsp.CodeAction := {
    title := "Replace fixture hole with zero"
    kind? := some "quickfix"
    data? := some <| Json.mkObj [("marker", toJson "resolve-data")]
  }
  let codeActionResolveInput : Beam.Mcp.CodeActionResolveInput := {
    path := "Demo.lean"
    snapshot := ⟨"test-session", 15⟩
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
  require "code-action-resolve backend" (codeActionResolve.backend == .lean)
  require "code-action-resolve snapshot" (codeActionResolve.snapshot == ⟨"test-session", 15⟩)
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

private def checkRunAtNormalization : IO Unit := do
  let semanticFailure := Json.mkObj [("success", toJson false)]
  let normalizedFailure ← expectToolOk "normalize semantic failure" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .runAt)
      (Beam.Broker.Response.success semanticFailure)
  requireJsonBool "semantic failure result" "success" false normalizedFailure
  requireJsonNull "semantic failure result" "next_handle" normalizedFailure
  requireJsonNull "semantic failure result" "proof_state" normalizedFailure
  requireFieldAbsent "semantic failure result" "ok" normalizedFailure
  requireFieldAbsent "semantic failure result" "handle" normalizedFailure
  requireFieldAbsent "semantic failure result" "proofState" normalizedFailure

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
  requireFieldAbsent "handle result" "document_progress" normalizedHandle
  requireFieldAbsent "handle result" "client_request_id" normalizedHandle
  requireFieldAbsent "handle result" "handle" normalizedHandle

private def sampleSyncResult : Beam.Broker.SyncFileResult := {
  path := "Demo.lean"
  snapshot := ⟨"test-session", 7⟩
  diagnostics := {
    counts := { error := 1, warning := 1 }
    items? := some #[{
      path := "Demo.lean"
      uri := "file:///repo/Demo.lean"
      snapshot? := some ⟨"test-session", 7⟩
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
  requireJsonString "sync result" "snapshot" "test-session/7" normalizedSync
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
    ("snapshot", toJson "test-session/7"),
    ("sourceHash", toJson "abc"),
    ("olean", toJson "/tmp/Demo.olean"),
    ("ilean", toJson "/tmp/Demo.ilean"),
    ("c", toJson "/tmp/Demo.c"),
    ("trace", toJson "/tmp/Demo.olean.trace"),
    ("oleanServer", toJson "/tmp/Demo.olean.server"),
    ("sync", toJson sampleSyncResult)
  ]
  let normalizedSave ← expectToolOk "normalize save result" <|
    Beam.Mcp.normalizeBrokerResponse (.leanOperation .save) <|
      (Beam.Broker.Response.success rawSave).withFileProgress { updates := 4, done := true }
  requireJsonString "save result" "source_hash" "abc" normalizedSave
  requireJsonString "save result" "olean_server" "/tmp/Demo.olean.server" normalizedSave
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
    ("snapshot", toJson "test-session/1"),
    ("range", toJson ({ start := { line := 0, character := 0 }, «end» := { line := 2, character := 0 } } : Lean.Lsp.Range)),
    ("items", Json.arr #[
      Json.mkObj [
        ("kind", toJson Beam.LSP.Todo.TodoKind.incompleteProof),
        ("range", toJson ({ start := { line := 1, character := 2 }, «end» := { line := 1, character := 7 } } : Lean.Lsp.Range)),
        ("runAtPosition", toJson ({ line := 1, character := 7 } : Lean.Lsp.Position)),
        ("runAtText", toJson ("exact ?_" : String)),
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
  requireJsonString "todo item" "run_at_text" "exact ?_" item
  discard <| requireObjVal "todo item" "proof_state" item
  requireFieldAbsent "todo item" "runAtPosition" item
  requireFieldAbsent "todo item" "runAtText" item
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

private def checkCodeActionResolveNormalization : IO Unit := do
  let rawResult := Json.mkObj [
    ("snapshot", toJson "test-session/15"),
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
  checkRunAtNormalization
  checkSyncAndSaveNormalization
  checkTransportErrorNormalization
  checkTodoNormalization
  checkCodeActionResolveNormalization

end BeamTest.Broker.McpProjectionTest

def main := BeamTest.Broker.McpProjectionTest.main
