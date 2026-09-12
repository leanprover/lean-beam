/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Server
import Beam.Mcp.Stdio
import BeamTest.Broker.JsonAssert
import BeamTest.Broker.TestUtil
import BeamTest.TestHarness

open Lean
open BeamTest.Broker.JsonAssert
open BeamTest.Broker.TestUtil

namespace BeamTest.Broker.McpProtocolTest

private def checkJsonHelpers : IO Unit := do
  require "strip LF" (Beam.Mcp.Stdio.stripLineEnding "json\n" == "json")
  require "strip CRLF" (Beam.Mcp.Stdio.stripLineEnding "json\r\n" == "json")
  require "strip CR" (Beam.Mcp.Stdio.stripLineEnding "json\r" == "json")
  require "leave interior CR" (Beam.Mcp.Stdio.stripLineEnding "j\rson" == "j\rson")

  let withField := Json.mkObj [("name", toJson "fixture")]
  let decodedName ← expectOk "optional string field" <|
    Beam.Mcp.optionalField? (α := String) withField "name"
  require "optional string field decoded" (decodedName == some "fixture")

  let missingName ← expectOk "missing optional string field" <|
    Beam.Mcp.optionalField? (α := String) withField "missing"
  require "missing optional string field decodes as none" missingName.isNone

  discard <| expectOk "closed object fields" <|
    Beam.Mcp.requireOnlyFields "fixture" #["name"] withField
  match Beam.Mcp.requireOnlyFields "fixture" #["name"] <|
      Json.mkObj [("name", toJson "fixture"), ("extra", toJson true)] with
  | .ok _ => throw <| IO.userError "closed object accepted an undeclared field"
  | .error err =>
      require "closed object error identifies its undeclared field"
        (err.contains "undeclared fields" && err.contains "extra")

  match Beam.Mcp.optionalField? (α := String) (Json.mkObj [("name", toJson (1 : Nat))]) "name" with
  | .ok value =>
      throw <| IO.userError s!"invalid optional field decoded unexpectedly: {repr value}"
  | .error err =>
      require "invalid optional field names the field" (err.contains "name")

private def checkIncoming : IO Unit := do
  let reqJson := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", toJson (1 : Nat)),
    ("method", toJson "tools/list")
  ]
  match ← expectOk "decode request" <| Beam.Mcp.Incoming.fromJson? reqJson with
  | .request req =>
      require "decoded request method" (req.method == "tools/list")
  | .notification _ =>
      throw <| IO.userError "request decoded as notification"

  let notificationJson := Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/initialized")
  ]
  match ← expectOk "decode notification" <| Beam.Mcp.Incoming.fromJson? notificationJson with
  | .notification notification =>
      require "decoded notification method" (notification.method == "notifications/initialized")
  | .request _ =>
      throw <| IO.userError "notification decoded as request"

  match Beam.Mcp.Incoming.fromJson? <| Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", Json.null),
    ("method", toJson "tools/list")
  ] with
  | .ok _ =>
      throw <| IO.userError "null request id decoded successfully"
  | .error _ =>
      pure ()

  match Beam.Mcp.Incoming.fromJson? <| Json.mkObj [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson "unsolicited-response"),
      ("result", Json.mkObj [("ok", toJson true)])
    ] with
  | .ok _ => throw <| IO.userError "unsolicited client response decoded successfully"
  | .error err =>
      require "client response rejection explains the accepted message kinds"
        (err.contains "request or notification")

  let stringId ← expectOk "decode string request id" <|
    Beam.Mcp.RequestId.fromJson? (toJson "1")
  let numberId ← expectOk "decode numeric request id" <|
    Beam.Mcp.RequestId.fromJson? (toJson (1 : Nat))
  let wholeDecimalId ← expectOk "decode integral decimal request id" <|
    Beam.Mcp.RequestId.fromJson? (Json.num { mantissa := 10, exponent := 1 })
  let zeroId ← expectOk "decode zero request id with a large decimal exponent" <|
    Beam.Mcp.RequestId.fromJson? (Json.num { mantissa := 0, exponent := 100000 })
  require "string and numeric request ids are distinct" (stringId != numberId)
  require "integral numeric request ids are canonical" (wholeDecimalId == numberId)
  require "integral numeric request ids retain their wire spelling"
    (wholeDecimalId.json == Json.num { mantissa := 10, exponent := 1 })
  require "zero request ids are canonical" (zeroId == (← expectOk "decode plain zero request id" <|
    Beam.Mcp.RequestId.fromJson? (toJson (0 : Nat))))
  let envelopeId? := Beam.Mcp.RequestId.fromEnvelope? <| Json.mkObj [
    ("id", Json.num { mantissa := 10, exponent := 1 }),
    ("unexpected", toJson true)
  ]
  require "request ids can be recovered from otherwise invalid envelopes"
    (envelopeId?.map Beam.Mcp.RequestId.json ==
      some (Json.num { mantissa := 10, exponent := 1 }))
  require "invalid envelope request ids are not recovered"
    ((Beam.Mcp.RequestId.fromEnvelope? <| Json.mkObj [("id", Json.null)]).isNone)
  require "missing envelope request ids are not recovered"
    ((Beam.Mcp.RequestId.fromEnvelope? <| Json.mkObj [("jsonrpc", toJson "2.0")]).isNone)
  let keyed :=
    ({} : Std.TreeMap Beam.Mcp.RequestId String)
      |>.insert stringId "string"
      |>.insert numberId "number"
      |>.insert wholeDecimalId "canonical number"
  require "request id map preserves string key" (keyed.get? stringId == some "string")
  require "request id map canonicalizes equivalent numeric keys"
    (keyed.get? numberId == some "canonical number")

  match Beam.Mcp.RequestId.fromJson? (Json.num { mantissa := 15, exponent := 1 }) with
  | .ok id =>
      throw <| IO.userError s!"fractional request id decoded unexpectedly: {id.json.compress}"
  | .error err =>
      require "fractional request id error should require an integer" (err.contains "integer")

  let cancelled ← expectOk "decode cancellation params" <|
    Beam.Mcp.parseCancelledParams <| some <| Json.mkObj [
      ("requestId", toJson "slow-request"),
      ("reason", toJson "client no longer needs the result"),
      ("_meta", Json.mkObj [("traceId", toJson "cancel-trace")])
    ]
  require "cancellation request id" (cancelled.requestId == .string "slow-request")
  require "cancellation reason" (cancelled.reason? == some "client no longer needs the result")

  for invalidResponse in #[
      Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("id", toJson "invalid-response")
      ],
      Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("id", toJson "invalid-response"),
        ("result", Json.mkObj []),
        ("error", Json.mkObj [])
      ]
    ] do
    match Beam.Mcp.Incoming.fromJson? invalidResponse with
    | .ok _ => throw <| IO.userError s!"invalid response decoded: {invalidResponse.compress}"
    | .error _ => pure ()

  for (label, ambiguous) in #[
      ("request with response result", Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("id", toJson "mixed-request"),
        ("method", toJson "tools/list"),
        ("result", Json.mkObj [])
      ]),
      ("notification with response error", Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("method", toJson "notifications/initialized"),
        ("error", Json.mkObj [])
      ]),
      ("response with request method", Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("id", toJson "mixed-response"),
        ("method", toJson "tools/list"),
        ("result", Json.mkObj [])
      ]),
      ("request with undeclared envelope field", Json.mkObj [
        ("jsonrpc", toJson "2.0"),
        ("id", toJson "extra-request"),
        ("method", toJson "tools/list"),
        ("unexpected", toJson true)
      ])
    ] do
    match Beam.Mcp.Incoming.fromJson? ambiguous with
    | .ok _ => throw <| IO.userError s!"{label} decoded unexpectedly: {ambiguous.compress}"
    | .error err =>
        require s!"{label} should report a closed JSON-RPC envelope"
          (err.contains "undeclared fields")

  match Beam.Mcp.parseCancelledParams <| some <| Json.mkObj [
      ("requestId", toJson "slow-request"),
      ("workspace", Json.mkObj [])
    ] with
  | .ok _ => throw <| IO.userError "cancellation params accepted an unrelated workspace"
  | .error err => require "cancellation rejects undeclared fields" (err.contains "workspace")

private def checkVersionIdentityJson : IO Unit := do
  let current := Beam.Version.Identity.asJson {
    name := "identity-fixture"
    runtimeCurrent? := some true
  }
  requireJsonBool "runtime identity json" "runtime_current" true current
  let source := Beam.Version.Identity.asJson { name := "source-fixture" }
  requireFieldAbsent "source identity json" "runtime_current" source
  let invalid := Beam.Version.Identity.asJson {
    name := "invalid-installed-fixture"
    runtimeError? := some "invalid install manifest"
  }
  requireJsonString "invalid runtime identity json" "runtime_error" "invalid install manifest" invalid

private def requireJsonArray (label : String) : Json → IO (Array Json)
  | Json.arr values => pure values
  | other => throw <| IO.userError s!"{label} is not an array: {other.compress}"

private def requireTool (tools : Array Json) (name : String) : IO Json := do
  let some tool := tools.find? fun tool =>
      (tool.getObjValAs? String "name").toOption == some name
    | throw <| IO.userError s!"tools/list does not expose {name}: {tools}"
  pure tool

private def requireToolDescription (tools : Array Json) (name : String) : IO String := do
  let tool ← requireTool tools name
  IO.ofExcept <| tool.getObjValAs? String "description"

private def readOnlyToolNames : Array String := #[
  "beam_version",
  "beam_stats",
  "lean_run_at",
  "lean_hover",
  "lean_signature_help",
  "lean_definition",
  "lean_references",
  "lean_document_symbols",
  "lean_workspace_symbols",
  "lean_goals",
  "lean_todo",
  "lean_code_action_resolve"
]

private def additiveToolNames : Array String := #[
  "lean_run_at_handle",
  "lean_run_with"
]

private def idempotentToolNames : Array String := #[
  "lean_drop_workspace",
  "lean_close"
]

private def expectedToolAnnotations? (name : String) : Option Json :=
  if readOnlyToolNames.contains name then
    some <| Json.mkObj [("readOnlyHint", toJson true)]
  else if additiveToolNames.contains name then
    some <| Json.mkObj [("destructiveHint", toJson false)]
  else if idempotentToolNames.contains name then
    some <| Json.mkObj [("idempotentHint", toJson true)]
  else
    none

private def requireUniqueStrings (label : String) (values : Array String) : IO Unit := do
  let unique := values.foldl (init := #[]) fun seen value =>
    if seen.contains value then seen else seen.push value
  require s!"{label} contains duplicate values: {values}" (unique.size == values.size)

private def checkToolAnnotationMatrix (tools : Array Json) : IO Unit := do
  requireUniqueStrings "MCP effect annotation categories"
    (readOnlyToolNames ++ additiveToolNames ++ idempotentToolNames)
  for names in #[readOnlyToolNames, additiveToolNames, idempotentToolNames] do
    for name in names do
      discard <| requireTool tools name
  for tool in tools do
    let name ← IO.ofExcept <| tool.getObjValAs? String "name"
    match expectedToolAnnotations? name with
    | some expected =>
      let annotations ← requireObjVal s!"{name} tool" "annotations" tool
      require s!"{name} should advertise exactly its non-default MCP annotations"
        (annotations == expected)
    | none =>
      requireFieldAbsent s!"{name} tool" "annotations" tool

private def requireClosedInputSchema (label : String) (tool : Json) : IO Json := do
  let schema ← requireObjVal label "inputSchema" tool
  requireJsonString label "$schema" Beam.JsonSchema.dialect schema
  requireJsonBool label "additionalProperties" false schema
  pure schema

private def objectFieldNames (label : String) : Json → IO (Array String)
  | .obj fields => pure <| fields.foldl (init := #[]) fun names field _ => names.push field
  | other => throw <| IO.userError s!"{label} is not an object: {other.compress}"

private def checkToolInputParameterUniqueness (tools : Array Json) : IO Unit := do
  let forbiddenAliases := #[
    "root", "workspace_id", "workspaceId", "includeDeclaration", "startLine",
    "startCharacter", "endLine", "endCharacter", "codeAction", "diagnosticScope",
    "diagnosticsInResult", "full_diagnostics", "include_diagnostics"
  ]
  for tool in tools do
    let name ← IO.ofExcept <| tool.getObjValAs? String "name"
    let schema ← requireClosedInputSchema s!"{name} input schema" tool
    let properties ← requireObjVal s!"{name} input schema" "properties" schema
    let propertyNames ← objectFieldNames s!"{name} input properties" properties
    let required ← IO.ofExcept <| schema.getObjValAs? (Array String) "required"
    requireUniqueStrings s!"{name} required parameters" required
    for field in required do
      require s!"{name} requires undeclared parameter '{field}'" (propertyNames.contains field)
    for alias in forbiddenAliases do
      require s!"{name} exposes ambiguous or obsolete top-level parameter '{alias}'"
        (!propertyNames.contains alias)
    let workspaceBound := name == "beam_feedback_report" || name == "lean_drop_workspace" ||
      name.startsWith "lean_"
    require s!"{name} workspace selector requirement is inconsistent"
      (required.contains "workspace" == workspaceBound)
    let handleBound := name == "lean_run_with" || name == "lean_run_with_linear" ||
      name == "lean_release"
    require s!"{name} handle parameter ownership is inconsistent"
      (propertyNames.contains "handle" == handleBound)

private def requireSchemaRequiredFields
    (label : String)
    (expected : Array String)
    (schema : Json) : IO Unit := do
  let required ← requireObjVal label "required" schema
  require s!"{label} required fields" (required == toJson expected)

private def checkToolDescriptionContracts (tools : Array Json) : IO Unit := do
  let sourceFileInvariant :=
    "Beam never applies source edits to `.lean` files on disk; the client applies source edits."
  for operation in Beam.Lean.Operation.all do
    let toolName := s!"lean_{operation.key}"
    let description ← requireToolDescription tools toolName
    require s!"{toolName} description should end with the source-file invariant"
      (description.endsWith sourceFileInvariant)
  for toolName in #["lean_run_at", "lean_run_at_handle", "lean_run_with", "lean_run_with_linear"] do
    let description ← requireToolDescription tools toolName
    require s!"{toolName} description should explain speculative file behavior"
      (description.contains "not persisted as source" &&
        description.contains "first edit and save the Lean file" &&
        description.contains "only then call lean_sync")
    require s!"{toolName} description should state the speculative IO boundary"
      (description.contains "not an OS sandbox" && description.contains "may perform IO")
  let runAtHandleDescription ← requireToolDescription tools "lean_run_at_handle"
  require "lean_run_at_handle description should not promise a handle unconditionally"
    (runAtHandleDescription.contains "successful result may include next_handle")
  let syncDescription ← requireToolDescription tools "lean_sync"
  require "lean_sync description should distinguish saved source from speculative probes"
    (syncDescription.contains "Read the current on-disk Lean source" &&
      syncDescription.contains "never applies or recovers speculative text")
  for toolName in #["lean_update", "lean_refresh"] do
    let description ← requireToolDescription tools toolName
    require s!"{toolName} description should state that it reads source from disk"
      (description.contains "current on-disk Lean source")
  for toolName in #["lean_save", "lean_close_save"] do
    let description ← requireToolDescription tools toolName
    require s!"{toolName} description should distinguish build artifacts from source"
      (description.contains "Lean/Lake build artifacts")
  let resolveDescription ← requireToolDescription tools "lean_code_action_resolve"
  require "lean_code_action_resolve description should leave edits to the client"
    (resolveDescription.contains "LSP WorkspaceEdit" &&
      resolveDescription.contains "client must apply it")
  let feedbackReportDescription ← requireToolDescription tools "beam_feedback_report"
  require "beam_feedback_report description should state the no-upload contract"
    (feedbackReportDescription.startsWith "Beam does not upload or submit feedback.")
  require "beam_feedback_report description should advertise live-status tuning"
    (feedbackReportDescription.contains "_meta.progressToken" &&
      feedbackReportDescription.contains "one status log")

private def checkToolsListShape : IO Unit := do
  let result := Beam.Mcp.toolsListResult
  let tools ← requireObjVal "tools/list result" "tools" result
  let tools ← requireJsonArray "tools/list tools" tools
  require "tools/list is non-empty" (!tools.isEmpty)
  checkToolInputParameterUniqueness tools
  checkToolAnnotationMatrix tools
  require "tools/list must not expose obsolete tool beam_feedback"
    (!(tools.any fun tool =>
      (tool.getObjValAs? String "name").toOption == some "beam_feedback"))

  let schemaCases : Array (String × Array String) := #[
    ("beam_version", #[]),
    ("beam_stats", #[]),
    ("beam_feedback_report", Beam.Feedback.requiredInputFields.push "workspace"),
    ("lean_drop_workspace", #["workspace"]),
    ("lean_run_at", #["path", "version", "line", "character", "text", "workspace"]),
    ("lean_run_at_handle", #["path", "version", "line", "character", "text", "workspace"]),
    ("lean_hover", #["path", "version", "line", "character", "workspace"]),
    ("lean_signature_help", #["path", "version", "line", "character", "workspace"]),
    ("lean_definition", #["path", "version", "line", "character", "workspace"]),
    ("lean_references", #["path", "version", "line", "character", "workspace"]),
    ("lean_document_symbols", #["path", "version", "workspace"]),
    ("lean_workspace_symbols", #["query", "workspace"]),
    ("lean_goals", #["path", "version", "line", "character", "mode", "workspace"]),
    ("lean_todo", #["path", "version", "start_line", "start_character", "end_line", "end_character", "workspace"]),
    ("lean_code_action_resolve", #["path", "version", "code_action", "workspace"]),
    ("lean_run_with", #["path", "handle", "text", "workspace"]),
    ("lean_run_with_linear", #["path", "handle", "text", "workspace"]),
    ("lean_release", #["path", "handle", "workspace"]),
    ("lean_update", #["path", "workspace"]),
    ("lean_sync", #["path", "workspace"]),
    ("lean_refresh", #["path", "workspace"]),
    ("lean_save", #["path", "workspace"]),
    ("lean_close_save", #["path", "workspace"]),
    ("lean_close", #["path", "workspace"])
  ]
  require "tools/list should expose only cache management and curated Lean tools"
    (tools.size == schemaCases.size)
  for (toolName, requiredFields) in schemaCases do
    let tool ← requireTool tools toolName
    let schema ← requireClosedInputSchema s!"{toolName} input schema" tool
    requireSchemaRequiredFields s!"{toolName} input schema" requiredFields schema
  checkToolDescriptionContracts tools
  let syncTool ← requireTool tools "lean_sync"
  let syncSchema ← requireClosedInputSchema "lean_sync input schema" syncTool
  let syncProperties ← requireObjVal "lean_sync input schema" "properties" syncSchema
  let workspaceSchema ← requireObjVal "lean_sync input schema" "workspace" syncProperties
  let workspaceProperties ← requireObjVal "workspace descriptor schema" "properties" workspaceSchema
  requireFieldPresent "workspace descriptor schema" "root" workspaceProperties
  requireFieldPresent "lean_sync input schema" "diagnostic_scope" syncProperties
  requireFieldPresent "lean_sync input schema" "diagnostics_in_result" syncProperties
  let diagnosticScopeSchema ← requireObjVal "lean_sync input schema" "diagnostic_scope" syncProperties
  let diagnosticScopeEnum ← requireObjVal "lean_sync diagnostic_scope schema" "enum"
    diagnosticScopeSchema
  require "lean_sync diagnostic_scope enum should expose errors/all"
    (diagnosticScopeEnum == toJson (#[("errors" : String), "all"] : Array String))
  let referencesTool ← requireTool tools "lean_references"
  let referencesSchema ← requireClosedInputSchema "lean_references input schema" referencesTool
  let referencesProperties ← requireObjVal "lean_references input schema" "properties" referencesSchema
  requireFieldPresent "lean_references input schema" "include_declaration" referencesProperties
  let refreshTool ← requireTool tools "lean_refresh"
  let refreshSchema ← requireClosedInputSchema "lean_refresh input schema" refreshTool
  let refreshProperties ← requireObjVal "lean_refresh input schema" "properties" refreshSchema
  requireFieldPresent "lean_refresh input schema" "diagnostic_scope" refreshProperties
  requireFieldPresent "lean_refresh input schema" "diagnostics_in_result" refreshProperties
  let saveTool ← requireTool tools "lean_save"
  let saveSchema ← requireClosedInputSchema "lean_save input schema" saveTool
  let saveProperties ← requireObjVal "lean_save input schema" "properties" saveSchema
  requireFieldPresent "lean_save input schema" "diagnostic_scope" saveProperties
  requireFieldAbsent "lean_save input schema" "diagnostics_in_result" saveProperties
  let closeSaveTool ← requireTool tools "lean_close_save"
  let closeSaveSchema ← requireClosedInputSchema "lean_close_save input schema" closeSaveTool
  let closeSaveProperties ← requireObjVal "lean_close_save input schema" "properties" closeSaveSchema
  requireFieldPresent "lean_close_save input schema" "diagnostic_scope" closeSaveProperties
  requireFieldAbsent "lean_close_save input schema" "diagnostics_in_result" closeSaveProperties
  let feedbackTool ← requireTool tools "beam_feedback_report"
  let feedbackSchema ← requireClosedInputSchema "beam_feedback_report input schema" feedbackTool
  let feedbackProperties ← requireObjVal "beam_feedback_report input schema" "properties" feedbackSchema
  let bundleSchema ← requireObjVal "beam_feedback_report input schema" "bundle" feedbackProperties
  let bundleEnum ← requireObjVal "beam_feedback_report bundle schema" "enum" bundleSchema
  require "beam_feedback_report bundle enum should expose none/dir/zip"
    (bundleEnum == toJson (#["none", "dir", "zip"] : Array String))
  requireFieldPresent "beam_feedback_report input schema" "kind" feedbackProperties
  requireFieldPresent "beam_feedback_report input schema" "severity" feedbackProperties
  requireFieldPresent "beam_feedback_report input schema" "confidential" feedbackProperties
  requireFieldPresent "beam_feedback_report input schema" "include_collected" feedbackProperties

  let rawExposed := tools.any fun tool =>
    (tool.getObjValAs? String "name").toOption == some Beam.LSP.RunAt.method ||
      (tool.getObjValAs? String "name").toOption == some "lean_request_at"
  require "tools/list must not expose raw LSP/request-at tools" (!rawExposed)

private def checkWorkspaceDescriptor : IO Unit := do
  let root := "/workspace"
  let json := Json.mkObj [
    ("workspace", Json.mkObj [("root", toJson root)])
  ]
  let descriptor ← expectOk "decode workspace descriptor" <|
    Beam.Workspace.decodeDescriptorField json
  require "workspace descriptor preserves the explicit root" (descriptor.root == root)
  require "workspace descriptor derives a deterministic private cache key"
    (descriptor.cacheKey == "local:/workspace")
  require "workspace descriptor JSON is typed and round-trips"
    ((fromJson? (α := Beam.Workspace.Descriptor) (toJson descriptor)).toOption == some descriptor)
  match Beam.Workspace.decodeDescriptorField (Json.mkObj []) with
  | .ok _ => throw <| IO.userError "missing workspace descriptor decoded unexpectedly"
  | .error err => require "missing descriptor error names workspace" (err.contains "workspace")
  match Beam.Workspace.decodeDescriptorField <| Json.mkObj [
      ("workspace", Json.mkObj [("root", toJson (3 : Nat))])
    ] with
  | .ok _ => throw <| IO.userError "non-string workspace root decoded unexpectedly"
  | .error err => require "invalid descriptor error names workspace" (err.contains "workspace")
  match Beam.Workspace.decodeDescriptorField <| Json.mkObj [
      ("workspace", Json.mkObj [
        ("root", toJson root),
        ("workspace_id", toJson "legacy")
      ])
    ] with
  | .ok _ => throw <| IO.userError "workspace descriptor accepted an obsolete selector field"
  | .error err =>
      require "closed descriptor error should reject obsolete selector fields"
        (err.contains "accepts only the 'root' field")

private def expectWorkspaceRootError
    (label rootText expectedMessage : String) : IO Unit := do
  match ← Beam.Lean.Workspace.resolveRoot rootText with
  | .ok root =>
      throw <| IO.userError s!"{label}: invalid workspace root resolved as {root}"
  | .error err =>
      require s!"{label}: workspace error should contain '{expectedMessage}'"
        (err.message.contains expectedMessage)

private def checkWorkspaceRootValidation : IO Unit := do
  let fixtureRoot :=
    System.FilePath.mk s!"/tmp/lean-beam-workspace-root-validation-{← IO.monoNanosNow}"
  let emptyRoot := fixtureRoot / "empty"
  let fileRoot := fixtureRoot / "not-a-directory"
  let missingRoot := fixtureRoot / "missing"
  try
    IO.FS.createDirAll emptyRoot
    IO.FS.writeFile fileRoot "not a workspace directory\n"
    expectWorkspaceRootError "relative workspace root" "relative/project" "absolute path"
    expectWorkspaceRootError "missing workspace root" missingRoot.toString "does not resolve"
    expectWorkspaceRootError "workspace root file" fileRoot.toString "not a directory"
    expectWorkspaceRootError "non-project workspace root" emptyRoot.toString
      "not a Lean/Lake project"

    let expectedRoot ← Beam.resolveExistingPath (← IO.currentDir)
    match ← Beam.Lean.Workspace.resolveRoot expectedRoot.toString with
    | .error err =>
        throw <| IO.userError s!"current Lean project root was rejected: {err.message}"
    | .ok root =>
        require "valid workspace root should retain its canonical spelling" (root == expectedRoot)
  finally
    try
      if ← fixtureRoot.pathExists then
        IO.FS.removeDirAll fixtureRoot
    catch _ =>
      pure ()

private def checkRuntimeSetupErrors : IO Unit := do
  let missingRoot := System.FilePath.mk s!"/tmp/lean-beam-missing-mcp-root-{← IO.monoNanosNow}"
  match ← Beam.Mcp.Runtime.mkBrokerConfig {} missingRoot with
  | .ok _ =>
      throw <| IO.userError "missing MCP root resolved unexpectedly"
  | .error err =>
      require "missing MCP root should be an invalidRequest error" (err.code == -32600)
      require "missing MCP root setup error should name the setup boundary"
        (err.message.startsWith s!"{Beam.Mcp.runtimeSetupErrorPrefix}:")
      require "missing MCP root setup error should mention project root"
        (err.message.contains "project root does not resolve")

  let root := System.FilePath.mk s!"/tmp/lean-beam-mcp-runtime-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    match ← Beam.Mcp.Runtime.mkBrokerConfig {} root with
    | .ok _ =>
        throw <| IO.userError "MCP runtime resolved without runtime flags or beam-cli"
    | .error err =>
        require "missing MCP runtime should be an invalidRequest error" (err.code == -32600)
        require "missing MCP runtime setup error should explain usable setup paths"
          (err.message.contains Beam.Mcp.runtimeSetupGuidance)
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

  let projectRoot ← Beam.resolveExistingPath (← IO.currentDir)
  let plugin ← BeamTest.TestHarness.pluginPath
  match ← Beam.Mcp.Runtime.mkBrokerConfig {
      leanCmd? := some "lean"
      leanPlugin? := some plugin.toString
    } projectRoot with
  | .error err =>
      throw <| IO.userError s!"explicit MCP runtime setup failed: {err.message}"
  | .ok config =>
      require "explicit MCP runtime should infer its sibling target Lake helper"
        (config.lean?.bind (·.lakeHelper?)).isSome

  for (label, options) in #[
      ("Lean command only", ({ beamCli? := some "unused", leanCmd? := some "lean" } : Beam.Mcp.Runtime.Options)),
      ("Lean plugin only", ({ beamCli? := some "unused", leanPlugin? := some plugin.toString } : Beam.Mcp.Runtime.Options)),
      ("beam-cli with explicit runtime", ({
        beamCli? := some "unused"
        leanCmd? := some "lean"
        leanPlugin? := some plugin.toString
      } : Beam.Mcp.Runtime.Options))
    ] do
    match ← Beam.Mcp.Runtime.mkBrokerConfig options projectRoot with
    | .ok _ =>
        throw <| IO.userError s!"{label} MCP runtime setup succeeded unexpectedly"
    | .error err =>
        require s!"{label} should be an invalidRequest error" (err.code == -32600)
        require s!"{label} should reject mixed or partial runtime sources"
          (err.message.contains "choose exactly one Lean runtime source")

  let isolatedPluginDir :=
    System.FilePath.mk s!"/tmp/lean-beam-mcp-plugin-without-helper-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll isolatedPluginDir
    let isolatedPlugin := isolatedPluginDir / plugin.fileName.getD "beam-lsp-plugin"
    IO.FS.writeFile isolatedPlugin "not loaded by this setup check\n"
    match ← Beam.Mcp.Runtime.mkBrokerConfig {
        leanCmd? := some "lean"
        leanPlugin? := some isolatedPlugin.toString
      } projectRoot with
    | .ok _ =>
        throw <| IO.userError "helperless explicit MCP runtime setup succeeded unexpectedly"
    | .error err =>
        require "helperless explicit MCP runtime should be an invalidRequest error" (err.code == -32600)
        require "helperless explicit MCP runtime should name the target Lake helper"
          (err.message.contains "could not locate the target Lake helper")
  finally
    try
      if ← isolatedPluginDir.pathExists then
        IO.FS.removeDirAll isolatedPluginDir
    catch _ =>
      pure ()

private def expectResponse (label : String) (value : Option Json) : IO Json := do
  match value with
  | some json => pure json
  | none => throw <| IO.userError s!"{label}: expected JSON-RPC response"

private def rpcRequest (id : Nat) (method : String) (params? : Option Json := none) : Json :=
  Json.mkObj <|
    [
      ("jsonrpc", toJson "2.0"),
      ("id", toJson id),
      ("method", toJson method)
    ] ++
    match params? with
    | some params => [("params", params)]
    | none => []

private def rpcNotification (method : String) (params? : Option Json := none) : Json :=
  Json.mkObj <|
    [
      ("jsonrpc", toJson "2.0"),
      ("method", toJson method)
    ] ++
    match params? with
    | some params => [("params", params)]
    | none => []

private def withWorkspace (root : System.FilePath) (arguments : Json) : Json :=
  arguments.setObjVal! "workspace" (toJson <| Beam.Workspace.Descriptor.ofRoot root)

private def toolCallParams (name : String) (arguments : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("name", toJson name),
    ("arguments", arguments)
  ]

private def toolCallParamsWithProgress
    (name : String)
    (progressToken : Json)
    (arguments : Json := Json.mkObj []) : Json :=
  Json.mkObj [
    ("name", toJson name),
    ("arguments", arguments),
    ("_meta", Json.mkObj [
      ("progressToken", progressToken)
    ])
  ]

private def checkProgressProtocol : IO Unit := do
  let stringToken := Json.str "sync-token"
  let stringParams ← expectOk "decode string progressToken" <|
    Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" stringToken <|
        Json.mkObj [("path", toJson "Demo.lean")]
  require "string progressToken should decode" (stringParams.progressToken? == some stringToken)

  let numberToken := toJson (7 : Nat)
  let numberParams ← expectOk "decode numeric progressToken" <|
    Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" numberToken <|
        Json.mkObj [("path", toJson "Demo.lean")]
  require "numeric progressToken should decode" (numberParams.progressToken? == some numberToken)

  match Beam.Mcp.parseCallToolParams <| some <| Json.mkObj [
      ("name", toJson "lean_sync"),
      ("arguments", Json.mkObj [("path", toJson "Demo.lean")]),
      ("workspace", Json.mkObj [])
    ] with
  | .ok _ => throw <| IO.userError "tools/call accepted an undeclared outer workspace field"
  | .error err =>
      require "tools/call rejects undeclared outer fields"
        (err.contains "undeclared fields" && err.contains "workspace")

  match Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" (toJson true) <|
        Json.mkObj [("path", toJson "Demo.lean")] with
  | .ok params =>
      throw <| IO.userError s!"invalid progressToken decoded unexpectedly: {(toJson params.progressToken?).compress}"
  | .error err =>
      require "invalid progressToken error should name progressToken" (err.contains "progressToken")

  let decimalToken := Json.num { mantissa := 15, exponent := 1 }
  let decimalParams ← expectOk "decode decimal progressToken" <|
    Beam.Mcp.parseCallToolParams <| some <|
      toolCallParamsWithProgress "lean_sync" decimalToken <|
        Json.mkObj [("path", toJson "Demo.lean")]
  require "decimal progressToken is preserved" (decimalParams.progressToken? == some decimalToken)

  let notification := Beam.Mcp.progressNotification stringToken 3 (some "syncing") (some 8)
  requireJsonString "progress notification" "method" "notifications/progress" notification
  let params ← requireObjVal "progress notification" "params" notification
  requireJsonString "progress notification params" "progressToken" "sync-token" params
  requireJsonInt "progress notification params" "progress" 3 params
  requireJsonInt "progress notification params" "total" 8 params
  requireJsonString "progress notification params" "message" "syncing" params

  let setupDiagnostic : Beam.Broker.StreamDiagnostic := {
    path := "Demo.lean"
    uri := "file:///workspace/Demo.lean"
    severity? := some .information
    range := {
      start := { line := 0, character := 0 }
      «end» := { line := 1, character := 0 }
    }
    message := "✔ [1/2] Building Demo.Dependency (12s)\n"
  }
  let setupMessage ←
    match Beam.Mcp.Server.Internal.projectStreamDiagnostic
        (.leanOperation .sync) (some "Demo.lean") setupDiagnostic with
    | .setupStatus message => pure message
    | .diagnostic =>
        throw <| IO.userError "Lake setup diagnostic projected as an ordinary MCP diagnostic"
  require "setup status message is normalized and contextual"
    (setupMessage ==
      "lean_sync on Demo.lean: preparing Lean dependencies — ✔ [1/2] Building Demo.Dependency (12s)")
  require "ordinary information diagnostic stays diagnostic" <|
    Beam.Mcp.Server.Internal.projectStreamDiagnostic
      (.leanOperation .sync) (some "Demo.lean")
        { setupDiagnostic with message := "ordinary Lean information" } ==
        .diagnostic

  let statusRequestId ← expectOk "decode status request id" <|
    Beam.Mcp.RequestId.fromJson? (toJson (42 : Nat))
  let statusNotification := Beam.Mcp.toolStatusNotification {
    requestId := statusRequestId
    tool := "lean_sync"
    state := .preparingDependencies
    message := setupMessage
    path? := some "Demo.lean"
    progressHint? := some "Pass tools/call params._meta.progressToken."
  }
  requireJsonString "status notification" "method" "notifications/message" statusNotification
  let statusParams ← requireObjVal "status notification" "params" statusNotification
  requireJsonString "status notification params" "level" "notice" statusParams
  requireJsonString "status notification params" "logger" "beam.status" statusParams
  let statusData ← requireObjVal "status notification params" "data" statusParams
  requireJsonInt "status notification data" "requestId" 42 statusData
  requireJsonString "status notification data" "tool" "lean_sync" statusData
  requireJsonString "status notification data" "state" "preparing_dependencies" statusData
  requireJsonString "status notification data" "message"
    setupMessage statusData
  requireJsonString "status notification data" "path" "Demo.lean" statusData
  requireJsonString "status notification data" "progressHint"
    "Pass tools/call params._meta.progressToken." statusData

private def handleRpcRequest
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (label : String)
    (id : Nat)
    (method : String)
    (params? : Option Json := none) : IO Json := do
  expectResponse label =<<
    Beam.Mcp.Server.handleJson state opts (rpcRequest id method params?)

private def handleRpcRequestWithNotifications
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (notifications : Beam.Mcp.Server.NotificationSink)
    (label : String)
    (id : Nat)
    (method : String)
    (params? : Option Json := none) : IO Json := do
  expectResponse label =<<
    Beam.Mcp.Server.handleJson state opts (rpcRequest id method params?) notifications

private def modernMeta
    (version : String := Beam.Mcp.protocolVersion)
    (logLevel? : Option String := none) : Json :=
  Json.mkObj <| [
    ("io.modelcontextprotocol/protocolVersion", toJson version),
    ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
    ("io.modelcontextprotocol/clientInfo", Json.mkObj [
      ("name", toJson "beam-mcp-protocol-test"),
      ("version", toJson "0")
    ])
  ] ++ match logLevel? with
    | some level => [("io.modelcontextprotocol/logLevel", toJson level)]
    | none => []

private def modernParams
    (fields : List (String × Json) := [])
    (version : String := Beam.Mcp.protocolVersion)
    (logLevel? : Option String := none) : Json :=
  Json.mkObj <| fields ++ [("_meta", modernMeta version logLevel?)]

private def legacyInitializeParams
    (version : String := Beam.Mcp.legacyProtocolVersion) : Json :=
  Json.mkObj [
    ("protocolVersion", toJson version),
    ("capabilities", Json.mkObj []),
    ("clientInfo", Json.mkObj [
      ("name", toJson "beam-mcp-protocol-test"),
      ("version", toJson "0")
    ])
  ]

private def expectRpcErrorCode (label : String) (expected : Int) (resp : Json) : IO Json := do
  let err ← requireObjVal label "error" resp
  requireJsonInt label "code" expected err
  pure err

private def expectToolErrorCode (label expectedCode : String) (resp : Json) : IO Json := do
  let result ← requireObjVal s!"{label} response" "result" resp
  requireJsonBool s!"{label} result" "isError" true result
  let structured ← requireObjVal s!"{label} result" "structuredContent" result
  requireJsonString s!"{label} structured error" "code" expectedCode structured
  pure structured

private def requireRuntimeActiveResult
    (label : String)
    (expected : Bool)
    (response : Json) : IO Unit := do
  let result ← requireObjVal s!"{label} response" "result" response
  requireJsonBool s!"{label} result" "isError" false result
  let structured ← requireObjVal s!"{label} result" "structuredContent" result
  requireJsonBool s!"{label} structured" "runtime_active" expected structured

private def requireLegacyRuntimeActive
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (label : String)
    (id : Nat)
    (expected : Bool)
    (notifications : Beam.Mcp.Server.NotificationSink := {}) : IO Unit := do
  let response ← handleRpcRequestWithNotifications state opts notifications label id "tools/call" <|
    some <| toolCallParams "beam_version"
  requireRuntimeActiveResult label expected response

private def requireModernRuntimeActive
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (label : String)
    (id : Nat)
    (expected : Bool) : IO Unit := do
  let response ← handleRpcRequest state opts label id "tools/call" <| some <| modernParams [
    ("name", toJson "beam_version"),
    ("arguments", Json.mkObj [])
  ]
  requireRuntimeActiveResult label expected response

private def legacyStatsWorkspaces
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (notifications : Beam.Mcp.Server.NotificationSink)
    (label : String)
    (id : Nat) : IO Json := do
  let response ← handleRpcRequestWithNotifications state opts notifications label id "tools/call" <|
    some <| toolCallParams "beam_stats"
  let result ← requireObjVal s!"{label} response" "result" response
  requireJsonBool s!"{label} result" "isError" false result
  let structured ← requireObjVal s!"{label} result" "structuredContent" result
  requireObjVal s!"{label} structured" "workspaces" structured

private def requireModernResultEnvelope (label : String) (result : Json) : IO Unit := do
  requireJsonString label "resultType" "complete" result
  let resultMeta ← requireObjVal label "_meta" result
  let serverInfo ← requireObjVal label "io.modelcontextprotocol/serverInfo" resultMeta
  requireJsonString label "name" Beam.Mcp.serverName serverInfo

private def requireConfidentialFeedbackResult
    (label secret : String)
    (result : Json) : IO Unit := do
  requireJsonBool s!"{label} result" "isError" false result
  let structured ← requireObjVal s!"{label} result" "structuredContent" result
  require s!"{label} omits caller payloads" (!structured.compress.contains secret)
  requireFieldAbsent s!"{label} structured" "workspace" structured
  let markdown ← IO.ofExcept <| structured.getObjValAs? String "markdown"
  require s!"{label} carries a visible warning"
    (markdown.contains "do not post this report publicly")
  let metadata ← requireObjVal s!"{label} structured" "metadata" structured
  requireJsonBool s!"{label} metadata" "confidential" true metadata
  requireJsonNull s!"{label} metadata" "active_root" metadata
  let collected ← requireObjVal s!"{label} structured" "collected" structured
  let identity ← requireObjVal s!"{label} collected" "identity" collected
  requireJsonString s!"{label} identity" "name" Beam.Version.mcpServerName identity
  requireJsonString s!"{label} identity" "version" Beam.Version.projectVersion identity
  requireJsonString s!"{label} identity" "mcp_protocol"
    Beam.Version.mcpProtocolVersion identity
  requireJsonBool s!"{label} identity" "runtime_active" false identity
  requireFieldAbsent s!"{label} identity" "beam_home" identity
  requireFieldAbsent s!"{label} identity" "source_commit" identity
  requireFieldAbsent s!"{label} identity" "active_root" identity
  requireFieldAbsent s!"{label} collected" "daemon" collected
  requireFieldAbsent s!"{label} collected" "openFiles" collected

private def checkModernProtocol : IO Unit := do
  let root ← IO.currentDir
  let state ← Beam.Mcp.Server.ServerState.create
  let opts : Beam.Mcp.Server.Options := {}

  let discoverResp ← handleRpcRequest state opts "server/discover" 100 "server/discover" <|
    some modernParams
  let discover ← requireObjVal "server/discover response" "result" discoverResp
  requireModernResultEnvelope "server/discover result" discover
  requireJsonInt "server/discover result" "ttlMs" (Int.ofNat Beam.Mcp.publicCacheTtlMs) discover
  requireJsonString "server/discover result" "cacheScope" "public" discover
  let supportedJson ← requireObjVal "server/discover result" "supportedVersions" discover
  let supported ← requireJsonArray "server/discover supportedVersions" supportedJson
  require "server/discover advertises exactly the modern per-request protocol revisions"
    (supported == #[toJson Beam.Mcp.protocolVersion])
  let discoverCapabilities ← requireObjVal "server/discover result" "capabilities" discover
  discard <| requireObjVal "server/discover capabilities" "logging" discoverCapabilities
  let discoverTools ← requireObjVal "server/discover capabilities" "tools" discoverCapabilities
  requireJsonBool "server/discover tools capability" "listChanged" false discoverTools
  match ← state.protocolState with
  | .undecided => pure ()
  | other => throw <| IO.userError s!"server/discover selected a protocol family: {repr other}"
  let listResp ← handleRpcRequest state opts "modern tools/list" 101 "tools/list" <|
    some modernParams
  let listResult ← requireObjVal "modern tools/list response" "result" listResp
  requireModernResultEnvelope "modern tools/list result" listResult
  requireJsonInt "modern tools/list result" "ttlMs" (Int.ofNat Beam.Mcp.publicCacheTtlMs) listResult
  requireJsonString "modern tools/list result" "cacheScope" "public" listResult
  let modernToolsJson ← requireObjVal "modern tools/list result" "tools" listResult
  let modernTools ← requireJsonArray "modern tools/list result tools" modernToolsJson
  let hasModernTool (name : String) : Bool :=
    modernTools.any fun tool => (tool.getObjValAs? String "name").toOption == some name
  require "modern tools/list exposes beam_feedback_report" (hasModernTool "beam_feedback_report")
  require "modern tools/list omits obsolete beam_feedback" (!hasModernTool "beam_feedback")
  match ← state.protocolState with
  | .modern => pure ()
  | other => throw <| IO.userError s!"modern tools/list did not select modern protocol state: {repr other}"

  let callResp ← handleRpcRequest state opts "modern beam_version" 102 "tools/call" <|
    some <| modernParams [
      ("name", toJson "beam_version"),
      ("arguments", Json.mkObj [])
    ]
  let callResult ← requireObjVal "modern beam_version response" "result" callResp
  requireModernResultEnvelope "modern beam_version result" callResult
  requireJsonBool "modern beam_version result" "isError" false callResult

  let confidentialSecret := "PRIVATE_MODERN_MCP_CODE_b136"
  let feedbackResp ← handleRpcRequest state opts "modern confidential beam_feedback_report" 1021
    "tools/call" <| some <| modernParams [
      ("name", toJson "beam_feedback_report"),
      ("arguments", withWorkspace root <| Json.mkObj [
        ("title", toJson "Modern MCP confidential feedback fixture"),
        ("summary", toJson "Feedback report from a private workspace."),
        ("reproduction", toJson "Call beam_feedback_report through stateless MCP."),
        ("expected", toJson "A confidential report card is returned."),
        ("actual", toJson "A confidential report card is returned."),
        ("request", Json.mkObj [("source", toJson confidentialSecret)]),
        ("confidential", toJson true),
        ("include_collected", toJson true)
      ])
    ]
  let feedbackResult ← requireObjVal "modern confidential beam_feedback_report response" "result"
    feedbackResp
  requireModernResultEnvelope "modern confidential beam_feedback_report result" feedbackResult
  requireConfidentialFeedbackResult "modern confidential beam_feedback_report" confidentialSecret
    feedbackResult
  requireModernRuntimeActive state opts
    "modern beam_feedback_report should not create a broker runtime" 1022 false

  let preservedMetaResult := Beam.Mcp.modernResult <| Json.mkObj [
    ("_meta", Json.mkObj [("example.test/value", toJson "preserved")])
  ]
  let preservedMeta ← requireObjVal "modern result" "_meta" preservedMetaResult
  requireJsonString "modern result metadata" "example.test/value" "preserved" preservedMeta

  let missingMetaResp ← handleRpcRequest state opts "server/discover missing metadata" 103
    "server/discover" <| some <| Json.mkObj []
  discard <| expectRpcErrorCode "server/discover missing metadata" (-32602) missingMetaResp

  let modernInitializeResp ← handleRpcRequest state opts "modern initialize is removed" 1031
    "initialize" <| some modernParams
  discard <| expectRpcErrorCode "modern initialize is removed" (-32601) modernInitializeResp

  let missingCapabilitiesResp ← handleRpcRequest state opts "modern missing capabilities" 104
    "tools/list" <| some <| Json.mkObj [
      ("_meta", Json.mkObj [
        ("io.modelcontextprotocol/protocolVersion", toJson Beam.Mcp.protocolVersion)
      ])
    ]
  discard <| expectRpcErrorCode "modern missing capabilities" (-32602) missingCapabilitiesResp

  let unsupportedResp ← handleRpcRequest state opts "unsupported modern version" 105
    "tools/list" <| some <| modernParams (version := "1900-01-01")
  let unsupported ← expectRpcErrorCode "unsupported modern version" (-32022) unsupportedResp
  let unsupportedData ← requireObjVal "unsupported modern version" "data" unsupported
  requireJsonString "unsupported modern version" "requested" "1900-01-01" unsupportedData
  let unsupportedVersionsJson ← requireObjVal "unsupported modern version" "supported" unsupportedData
  let unsupportedVersions ← requireJsonArray "unsupported modern version supported" unsupportedVersionsJson
  require "unsupported modern version lists exactly the per-request revisions"
    (unsupportedVersions == #[toJson Beam.Mcp.protocolVersion])

  let invalidLogLevelResp ← handleRpcRequest state opts "invalid modern log level" 112
    "tools/list" <| some <| modernParams (logLevel? := some "verbose")
  discard <| expectRpcErrorCode "invalid modern log level" (-32602) invalidLogLevelResp

  let invalidClientInfoResp ← handleRpcRequest state opts "invalid modern client info" 113
    "tools/list" <| some <| Json.mkObj [
      ("_meta", Json.mkObj [
        ("io.modelcontextprotocol/protocolVersion", toJson Beam.Mcp.protocolVersion),
        ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
        ("io.modelcontextprotocol/clientInfo", Json.mkObj [
          ("name", toJson "beam-mcp-protocol-test")
        ])
      ])
    ]
  discard <| expectRpcErrorCode "invalid modern client info" (-32602) invalidClientInfoResp

  let invalidCapabilitiesResp ← handleRpcRequest state opts "invalid modern capabilities" 114
    "tools/list" <| some <| Json.mkObj [
      ("_meta", Json.mkObj [
        ("io.modelcontextprotocol/protocolVersion", toJson Beam.Mcp.protocolVersion),
        ("io.modelcontextprotocol/clientCapabilities", Json.arr #[toJson "not-an-object"])
      ])
    ]
  discard <| expectRpcErrorCode "invalid modern capabilities" (-32602) invalidCapabilitiesResp

  let semanticErrorResp ← handleRpcRequest state opts "modern known-tool input error" 115
    "tools/call" <| some <| modernParams [
      ("name", toJson "lean_sync"),
      ("arguments", Json.mkObj [])
    ]
  discard <| expectToolErrorCode "modern known-tool input error" "invalidInput" semanticErrorResp
  let semanticErrorResult ← requireObjVal "modern known-tool input error response" "result"
    semanticErrorResp
  requireModernResultEnvelope "modern known-tool input error result" semanticErrorResult

  let requestStateResp ← handleRpcRequest state opts "unsupported requestState" 116
    "tools/call" <| some <| modernParams [
      ("name", toJson "beam_version"),
      ("requestState", Json.mkObj [])
    ]
  let requestStateError ← expectRpcErrorCode "unsupported requestState" (-32602) requestStateResp
  let requestStateMessage ← expectOk "unsupported requestState message" <|
    requestStateError.getObjValAs? String "message"
  require "unsupported requestState explains the missing MRTR origin"
    (requestStateMessage.contains "input_required")

  let inputResponsesResp ← handleRpcRequest state opts "unsupported inputResponses" 117
    "tools/call" <| some <| modernParams [
      ("name", toJson "beam_version"),
      ("inputResponses", Json.arr #[])
    ]
  let inputResponsesError ←
    expectRpcErrorCode "unsupported inputResponses" (-32602) inputResponsesResp
  let inputResponsesMessage ← expectOk "unsupported inputResponses message" <|
    inputResponsesError.getObjValAs? String "message"
  require "unsupported inputResponses explains the missing MRTR origin"
    (inputResponsesMessage.contains "input_required")

  let modernLoggingResp ← handleRpcRequest state opts "modern logging/setLevel" 106
    "logging/setLevel" <| some <| modernParams [("level", toJson "error")]
  discard <| expectRpcErrorCode "modern logging/setLevel" (-32601) modernLoggingResp

  let modernPingResp ← handleRpcRequest state opts "modern ping" 107 "ping" <|
    some modernParams
  discard <| expectRpcErrorCode "modern ping" (-32601) modernPingResp

  let unknownNotificationResp? ←
    Beam.Mcp.Server.handleJson state opts (rpcNotification "notifications/example-unknown")
  require "unknown notification should not produce a response" unknownNotificationResp?.isNone

  let initResp ← handleRpcRequest state opts "legacy initialize after modern requests" 108
    "initialize" <| some legacyInitializeParams
  discard <| expectRpcErrorCode "legacy initialize after modern requests" (-32600) initResp
  let unmarkedListResp ← handleRpcRequest state opts "unmarked tools/list after modern requests" 109
    "tools/list"
  let unmarkedListError ←
    expectRpcErrorCode "unmarked tools/list after modern requests" (-32602) unmarkedListResp
  let unmarkedListMessage ← expectOk "unmarked tools/list message" <|
    unmarkedListError.getObjValAs? String "message"
  require "unmarked modern request names the missing metadata"
    (unmarkedListMessage.contains "protocolVersion" &&
      unmarkedListMessage.contains "clientCapabilities")
  let modernListAgainResp ← handleRpcRequest state opts "modern tools/list after rejected legacy traffic" 110
    "tools/list" <| some modernParams
  let modernListAgain ← requireObjVal "modern tools/list after rejected legacy traffic" "result"
    modernListAgainResp
  requireModernResultEnvelope "modern tools/list after rejected legacy traffic" modernListAgain

private def checkServerBasics : IO Unit := do
  let root ← IO.currentDir
  let state ← Beam.Mcp.Server.ServerState.create
  let opts : Beam.Mcp.Server.Options := {}

  let preInitResp ← handleRpcRequest state opts "pre-initialize tools/list rejection" 0 "tools/list"
  discard <| expectRpcErrorCode "pre-initialize tools/list response" (-32600) preInitResp

  let missingInitParams ← handleRpcRequest state opts "missing initialize params" 1000 "initialize"
  discard <| expectRpcErrorCode "missing initialize params" (-32602) missingInitParams
  match ← state.protocolState with
  | .undecided => pure ()
  | other => throw <| IO.userError s!"invalid initialize selected a protocol family: {repr other}"

  let missingClientInfo ← handleRpcRequest state opts "missing initialize clientInfo" 1001
    "initialize" <| some <| Json.mkObj [
      ("protocolVersion", toJson Beam.Mcp.legacyProtocolVersion),
      ("capabilities", Json.mkObj [])
    ]
  discard <| expectRpcErrorCode "missing initialize clientInfo" (-32602) missingClientInfo

  let invalidCapabilities ← handleRpcRequest state opts "invalid initialize capabilities" 1002
    "initialize" <| some <| (legacyInitializeParams.setObjVal! "capabilities" (Json.arr #[]))
  discard <| expectRpcErrorCode "invalid initialize capabilities" (-32602) invalidCapabilities

  let invalidClientInfo ← handleRpcRequest state opts "invalid initialize clientInfo" 1003
    "initialize" <| some <| (legacyInitializeParams.setObjVal! "clientInfo" <| Json.mkObj [
      ("name", toJson "beam-mcp-protocol-test")
    ])
  discard <| expectRpcErrorCode "invalid initialize clientInfo" (-32602) invalidClientInfo

  let undeclaredInitField ← handleRpcRequest state opts "undeclared initialize field" 1004
    "initialize" <| some <| (legacyInitializeParams.setObjVal! "workspace" (Json.mkObj []))
  discard <| expectRpcErrorCode "undeclared initialize field" (-32602) undeclaredInitField

  let initResp ← handleRpcRequest state opts "initialize" 1 "initialize" <| some <|
    legacyInitializeParams
  let initResult ← requireObjVal "initialize response" "result" initResp
  requireJsonString "initialize result" "protocolVersion" Beam.Mcp.legacyProtocolVersion initResult
  let serverInfo ← requireObjVal "initialize result" "serverInfo" initResult
  requireJsonString "initialize serverInfo" "name" Beam.Mcp.serverName serverInfo
  requireJsonString "initialize serverInfo" "version" Beam.Mcp.serverVersion serverInfo
  let capabilities ← requireObjVal "initialize result" "capabilities" initResult
  discard <| requireObjVal "initialize capabilities" "logging" capabilities
  let toolsCapability ← requireObjVal "initialize capabilities" "tools" capabilities
  requireJsonBool "initialize tools capability" "listChanged" false toolsCapability
  match ← state.protocolState with
  | .legacy legacy =>
      require "initialize should await notifications/initialized"
        (legacy.phase == .awaitingInitialized)
  | other => throw <| IO.userError s!"initialize did not select legacy protocol state: {repr other}"

  let setLogLevelResp ← handleRpcRequest state opts "set log level" 12 "logging/setLevel" <| some <|
    Json.mkObj [
      ("level", toJson "warning"),
      ("_meta", Json.mkObj [("traceId", toJson "logging-trace")])
    ]
  discard <| requireObjVal "set log level response" "result" setLogLevelResp
  match ← state.protocolState with
  | .legacy legacy =>
      require "set log level should update legacy protocol state" (legacy.logLevel == .warning)
  | other => throw <| IO.userError s!"logging request left legacy protocol state: {repr other}"

  let badLogLevelResp ← handleRpcRequest state opts "bad log level" 13 "logging/setLevel" <| some <|
    Json.mkObj [
      ("level", toJson "verbose")
    ]
  discard <| expectRpcErrorCode "bad log level response" (-32602) badLogLevelResp

  let preReadyResp ← handleRpcRequest state opts "pre-ready tools/list rejection" 11 "tools/list"
  discard <| expectRpcErrorCode "pre-ready tools/list response" (-32600) preReadyResp

  let initializedResp? ←
    Beam.Mcp.Server.handleJson state opts (rpcNotification "notifications/initialized")
  require "initialized notification should not produce a response" initializedResp?.isNone
  match ← state.protocolState with
  | .legacy legacy =>
      require "initialized notification should make the legacy protocol ready"
        (legacy.phase == .ready)
  | other => throw <| IO.userError s!"initialized notification left legacy protocol state: {repr other}"

  let modernAfterLegacy ← handleRpcRequest state opts "modern tools/list after legacy initialize" 1100
    "tools/list" <| some modernParams
  discard <| expectRpcErrorCode "modern tools/list after legacy initialize" (-32600) modernAfterLegacy

  let listResp ← handleRpcRequest state opts "tools/list" 2 "tools/list"
  let listResult ← requireObjVal "tools/list response" "result" listResp
  discard <| requireObjVal "tools/list response" "tools" listResult

  let versionResp ← handleRpcRequest state opts "beam version" 21 "tools/call" <|
    some <| toolCallParams "beam_version"
  let versionResult ← requireObjVal "beam version response" "result" versionResp
  requireJsonBool "beam version result" "isError" false versionResult
  let versionStructured ← requireObjVal "beam version result" "structuredContent" versionResult
  requireJsonString "beam version structured" "name" Beam.Mcp.serverName versionStructured
  requireJsonString "beam version structured" "version" Beam.Mcp.serverVersion versionStructured
  requireJsonString "beam version structured" "mcp_protocol" Beam.Mcp.protocolVersion versionStructured
  requireJsonBool "beam version structured" "runtime_active" false versionStructured

  let statsResp ← handleRpcRequest state opts "beam stats without runtime" 20 "tools/call" <|
    some <| toolCallParams "beam_stats"
  let statsResult ← requireObjVal "beam stats without runtime response" "result" statsResp
  requireJsonBool "beam stats without runtime result" "isError" false statsResult
  let statsStructured ← requireObjVal
    "beam stats without runtime result" "structuredContent" statsResult
  let uptimeMs ← IO.ofExcept <| statsStructured.getObjValAs? Nat "uptimeMs"
  require "beam stats without runtime should report zero uptime" (uptimeMs == 0)
  let emptyWorkspaces ← requireObjVal
    "beam stats without runtime structured result" "workspaces" statsStructured
  require "beam stats without runtime should return an empty workspace object"
    (emptyWorkspaces == Json.mkObj [])

  let feedbackResp ← handleRpcRequest state opts "beam feedback" 22 "tools/call" <|
    some <| toolCallParams "beam_feedback_report" <|
      withWorkspace root <| Json.mkObj [
        ("title", toJson "MCP feedback fixture"),
        ("kind", toJson "bug"),
        ("severity", toJson "medium"),
        ("summary", toJson "Feedback report from protocol test."),
        ("reproduction", toJson "Call beam_feedback_report through tools/call."),
        ("expected", toJson "A structured report card is returned."),
        ("actual", toJson "A structured report card is returned.")
      ]
  let feedbackResult ← requireObjVal "beam feedback response" "result" feedbackResp
  requireJsonBool "beam feedback result" "isError" false feedbackResult
  let feedbackStructured ← requireObjVal "beam feedback result" "structuredContent" feedbackResult
  let feedbackMarkdown ← IO.ofExcept <| feedbackStructured.getObjValAs? String "markdown"
  require "beam feedback markdown contains title" (feedbackMarkdown.contains "# MCP feedback fixture")
  require "beam feedback markdown warns before public posting"
    (feedbackMarkdown.contains "Review before posting publicly")
  require "beam feedback markdown states that feedback is not submitted automatically"
    (feedbackMarkdown.contains "Beam does not submit feedback automatically")
  require "beam feedback compact markdown contains runtime summary"
    (feedbackMarkdown.contains "## Beam Runtime")
  require "beam feedback compact markdown omits full debug context"
    (!feedbackMarkdown.contains "## Beam Debug Context")
  let feedbackMetadata ← requireObjVal "beam feedback structured" "metadata" feedbackStructured
  requireJsonString "beam feedback metadata" "kind" "bug" feedbackMetadata
  requireJsonString "beam feedback metadata" "severity" "medium" feedbackMetadata
  requireFieldPresent "beam feedback compact structured" "workspace" feedbackStructured
  requireFieldAbsent "beam feedback compact structured" "collected" feedbackStructured
  requireFieldPresent "beam feedback compact structured" "collection_warnings" feedbackStructured

  let feedbackFullResp ← handleRpcRequest state opts "beam feedback include_collected" 23 "tools/call" <|
    some <| toolCallParams "beam_feedback_report" <|
      withWorkspace root <| Json.mkObj [
        ("title", toJson "MCP feedback fixture full"),
        ("kind", toJson "bug"),
        ("severity", toJson "medium"),
        ("summary", toJson "Feedback report from protocol test."),
        ("reproduction", toJson "Call beam_feedback_report through tools/call."),
        ("expected", toJson "A structured report card is returned."),
        ("actual", toJson "A structured report card is returned."),
        ("include_collected", toJson true)
      ]
  let feedbackFullResult ← requireObjVal "beam feedback include_collected response" "result" feedbackFullResp
  requireJsonBool "beam feedback include_collected result" "isError" false feedbackFullResult
  let feedbackFullStructured ← requireObjVal "beam feedback include_collected result" "structuredContent" feedbackFullResult
  let feedbackFullMarkdown ← IO.ofExcept <| feedbackFullStructured.getObjValAs? String "markdown"
  require "beam feedback include_collected markdown contains full debug context"
    (feedbackFullMarkdown.contains "## Beam Debug Context")
  let feedbackCollected ← requireObjVal "beam feedback include_collected structured" "collected" feedbackFullStructured
  discard <| requireObjVal "beam feedback collected" "identity" feedbackCollected
  discard <| requireObjVal "beam feedback collected" "daemon" feedbackCollected

  let confidentialSecret := "PRIVATE_MCP_CODE_91bc"
  let feedbackConfidentialResp ←
    handleRpcRequest state opts "beam feedback confidential" 25 "tools/call" <|
      some <| toolCallParams "beam_feedback_report" <|
        withWorkspace root <| Json.mkObj [
          ("title", toJson "MCP confidential feedback fixture"),
          ("summary", toJson "Feedback report from a private workspace."),
          ("reproduction", toJson "Call beam_feedback_report through tools/call."),
          ("expected", toJson "A confidential report card is returned."),
          ("actual", toJson "A confidential report card is returned."),
          ("request", Json.mkObj [("source", toJson confidentialSecret)]),
          ("confidential", toJson true),
          ("include_collected", toJson true)
        ]
  let feedbackConfidentialResult ←
    requireObjVal "beam feedback confidential response" "result" feedbackConfidentialResp
  requireConfidentialFeedbackResult "beam feedback confidential" confidentialSecret
    feedbackConfidentialResult

  requireLegacyRuntimeActive state opts
    "beam_feedback_report should not create a broker runtime" 26 false

  let uncachedDropResp ← handleRpcRequest state opts "drop uncached workspace" 24 "tools/call" <|
    some <| toolCallParams "lean_drop_workspace" <| withWorkspace root (Json.mkObj [])
  let uncachedDropResult ← requireObjVal "drop uncached workspace response" "result" uncachedDropResp
  requireJsonBool "drop uncached workspace result" "isError" false uncachedDropResult
  let uncachedDropStructured ←
    requireObjVal "drop uncached workspace result" "structuredContent" uncachedDropResult
  let uncachedDropWorkspace ←
    requireObjVal "drop uncached workspace structured result" "workspace" uncachedDropStructured
  let canonicalRoot ← Beam.resolveExistingPath root
  requireJsonString "drop uncached workspace descriptor" "root" canonicalRoot.toString
    uncachedDropWorkspace
  requireJsonBool "drop uncached workspace structured result" "dropped" false uncachedDropStructured
  requireJsonBool "drop uncached workspace structured result" "invalidated_handles" false
    uncachedDropStructured
  requireJsonString "drop uncached workspace structured result" "reason" "notFound"
    uncachedDropStructured
  requireLegacyRuntimeActive state opts
    "dropping an uncached workspace should not create a broker runtime" 27 false

  let rawToolResp ← handleRpcRequest state opts "raw tool rejection" 3 "tools/call" <|
    some <| toolCallParams Beam.LSP.RunAt.method
  discard <| expectRpcErrorCode "raw tool response" (-32602) rawToolResp

  let badArgsResp ← handleRpcRequest state opts "bad args rejection" 4 "tools/call" <|
    some <| toolCallParams "lean_run_at" <|
      Json.mkObj [
          ("path", toJson "Demo.lean"),
          ("line", toJson (0 : Nat)),
          ("character", toJson (0 : Nat))
      ]
  discard <| expectToolErrorCode "bad args" "invalidInput" badArgsResp

  let obsoleteSelectorResp ← handleRpcRequest state opts "obsolete workspace selector rejection" 31
      "tools/call" <| some <| toolCallParams "lean_drop_workspace" <| Json.mkObj [
        ("workspace", toJson <| Beam.Workspace.Descriptor.ofRoot root),
        ("workspace_id", toJson "legacy")
      ]
  let obsoleteSelector ← expectToolErrorCode "obsolete workspace selector" "invalidInput"
    obsoleteSelectorResp
  let obsoleteSelectorMessage ← IO.ofExcept <| obsoleteSelector.getObjValAs? String "message"
  require "obsolete workspace selector error should identify an undeclared field"
    (obsoleteSelectorMessage.contains "workspace_id" &&
      obsoleteSelectorMessage.contains "undeclared input fields")

  for obsoleteField in #["full_diagnostics", "include_diagnostics"] do
    let response ← handleRpcRequest state opts s!"obsolete {obsoleteField} rejection" 35
      "tools/call" <| some <| toolCallParams "lean_sync" <|
        withWorkspace root <| Json.mkObj [
          ("path", toJson "Demo.lean"),
          (obsoleteField, toJson true)
        ]
    let err ← expectToolErrorCode s!"obsolete {obsoleteField}" "invalidInput" response
    let message ← IO.ofExcept <| err.getObjValAs? String "message"
    require s!"obsolete MCP field error should identify {obsoleteField}"
      (message.contains obsoleteField && message.contains "undeclared input fields")

  let booleanScopeResp ← handleRpcRequest state opts "boolean diagnostic_scope rejection" 36
    "tools/call" <| some <| toolCallParams "lean_sync" <|
      withWorkspace root <| Json.mkObj [
        ("path", toJson "Demo.lean"),
        ("diagnostic_scope", toJson true)
      ]
  let booleanScope ← expectToolErrorCode "boolean diagnostic_scope" "invalidInput" booleanScopeResp
  let booleanScopeMessage ← IO.ofExcept <| booleanScope.getObjValAs? String "message"
  require "boolean diagnostic_scope error should name accepted values"
    (booleanScopeMessage.contains "errors" && booleanScopeMessage.contains "all")

  let misspelledConfidentialResp ←
    handleRpcRequest state opts "misspelled confidential feedback field rejection" 34
      "tools/call" <| some <| toolCallParams "beam_feedback_report" <|
        withWorkspace root <| Json.mkObj [
          ("title", toJson "Misspelled confidential feedback field"),
          ("summary", toJson "Reject a misspelled privacy control."),
          ("reproduction", toJson "Pass confidental instead of confidential."),
          ("expected", toJson "A typed invalidInput error."),
          ("actual", toJson "Regression coverage."),
          ("confidental", toJson true)
        ]
  let misspelledConfidential ← expectToolErrorCode "misspelled confidential feedback field"
    "invalidInput" misspelledConfidentialResp
  let misspelledConfidentialMessage ← IO.ofExcept <|
    misspelledConfidential.getObjValAs? String "message"
  require "misspelled confidential feedback field should fail closed"
    (misspelledConfidentialMessage.contains "confidental" &&
      misspelledConfidentialMessage.contains "undeclared input fields")

  let nestedExtraResp ← handleRpcRequest state opts "nested feedback field rejection" 33
      "tools/call" <| some <| toolCallParams "beam_feedback_report" <|
        withWorkspace root <| Json.mkObj [
          ("title", toJson "Nested feedback field"),
          ("summary", toJson "Reject nested fields omitted from the schema."),
          ("reproduction", toJson "Pass an undeclared evidence field."),
          ("expected", toJson "A typed invalidInput error."),
          ("actual", toJson "Regression coverage."),
          ("evidence", Json.arr #[Json.mkObj [
            ("name", toJson "trace.json"),
            ("content", Json.mkObj []),
            ("workspace_id", toJson "legacy")
          ]])
        ]
  let nestedExtra ← expectToolErrorCode "nested feedback field" "invalidInput" nestedExtraResp
  let nestedExtraMessage ← IO.ofExcept <| nestedExtra.getObjValAs? String "message"
  require "nested feedback error should identify the undeclared field"
    (nestedExtraMessage.contains "workspace_id" && nestedExtraMessage.contains "undeclared fields")

  let relativeWorkspaceResp ← handleRpcRequest state opts "relative workspace rejection" 32
      "tools/call" <| some <| toolCallParams "lean_run_at" <| Json.mkObj [
        ("path", toJson "Demo.lean"),
        ("version", toJson (0 : Nat)),
        ("line", toJson (0 : Nat)),
        ("character", toJson (0 : Nat)),
        ("text", toJson "rfl"),
        ("workspace", toJson ({ root := "relative/project" } : Beam.Workspace.Descriptor))
      ]
  let relativeWorkspace ← expectToolErrorCode "relative workspace" "invalidInput"
    relativeWorkspaceResp
  let relativeMessage ← IO.ofExcept <| relativeWorkspace.getObjValAs? String "message"
  require "relative workspace error should require an absolute root"
    (relativeMessage.contains "absolute")

private def diagnosticLogNotifications (notifications : Array Json) : Array Json :=
  notifications.filter fun notification =>
    (notification.getObjValAs? String "method").toOption == some "notifications/message" &&
      ((notification.getObjVal? "params").toOption.bind fun params =>
        (params.getObjValAs? String "logger").toOption) == some "lean.diagnostic"

private def requireDiagnosticLog
    (notifications : Array Json)
    (level severity path : String) : IO Json := do
  let logs := diagnosticLogNotifications notifications
  let some notification := logs.find? fun notification =>
      match notification.getObjVal? "params" with
      | .error _ => false
      | .ok params =>
          (params.getObjValAs? String "level").toOption == some level &&
          match params.getObjVal? "data" with
          | .error _ => false
          | .ok data =>
              (data.getObjValAs? String "severity").toOption == some severity &&
                (data.getObjValAs? String "path").toOption == some path
    | throw <| IO.userError
        s!"expected {level}/{severity} diagnostic log for {path}, got {(toJson notifications).compress}"
  pure notification

private def expectNoDiagnosticLogs (label : String) (notifications : Array Json) : IO Unit := do
  let logs := diagnosticLogNotifications notifications
  unless logs.isEmpty do
    throw <| IO.userError s!"expected no {label} diagnostic logs, got {(toJson logs).compress}"

private def expectNoDiagnosticLog
    (label : String)
    (notifications : Array Json)
    (severity path : String) : IO Unit := do
  let logs := diagnosticLogNotifications notifications
  let found := logs.any fun notification =>
    match notification.getObjVal? "params" with
    | .error _ => false
    | .ok params =>
        match params.getObjVal? "data" with
        | .error _ => false
        | .ok data =>
            (data.getObjValAs? String "severity").toOption == some severity &&
              (data.getObjValAs? String "path").toOption == some path
  if found then
    throw <| IO.userError
      s!"expected no {label} {severity} diagnostic log for {path}, got {(toJson logs).compress}"

private def requireDiagnosticsArray (label : String) (structured : Json) : IO (Array Json) := do
  let diagnosticsJson ← requireObjVal label "diagnostics" structured
  let itemsJson ← requireObjVal label "items" diagnosticsJson
  match itemsJson with
  | Json.arr diagnostics => pure diagnostics
  | other =>
      throw <| IO.userError s!"expected {label} diagnostics.items array, got {other.compress}"

private def requireNoDiagnosticSeverity
    (label : String)
    (diagnostics : Array Json)
    (severity : String) : IO Unit := do
  if diagnostics.any (fun diagnostic =>
      (diagnostic.getObjValAs? String "severity").toOption == some severity) then
    throw <| IO.userError
      s!"expected {label} to omit {severity} diagnostics, got {(toJson diagnostics).compress}"

private def requireDiagnosticSeverityForPath
    (label : String)
    (diagnostics : Array Json)
    (severity path : String) : IO Unit := do
  unless diagnostics.any (fun diagnostic =>
      (diagnostic.getObjValAs? String "path").toOption == some path &&
        (diagnostic.getObjValAs? String "severity").toOption == some severity) do
    throw <| IO.userError
      s!"expected {label} {severity} diagnostic for {path}, got {(toJson diagnostics).compress}"

private def mcpOptionsWithPlugin : IO Beam.Mcp.Server.Options := do
  pure {
    leanCmd? := some "lean"
    leanPlugin? := some (← BeamTest.TestHarness.pluginPath).toString
  }

private def initMcpSession
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (notifications : Beam.Mcp.Server.NotificationSink) : IO Unit := do
  let _ ← handleRpcRequestWithNotifications state opts notifications "initialize" 1 "initialize" <| some <|
    legacyInitializeParams
  let initializedResp? ←
    Beam.Mcp.Server.handleJson state opts (rpcNotification "notifications/initialized") notifications
  require "initialized notification should not produce a response" initializedResp?.isNone

private def callLeanSync
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (notifications : Beam.Mcp.Server.NotificationSink)
    (root : System.FilePath)
    (id : Nat)
    (path : String)
    (diagnosticScope : Beam.Broker.DiagnosticScope := .all)
    (diagnosticsInResult : Bool := false) : IO Json := do
  let arguments := withWorkspace root <| Json.mkObj <|
    [
      ("path", toJson path),
      ("diagnostic_scope", toJson diagnosticScope)
    ] ++
    if diagnosticsInResult then
      [("diagnostics_in_result", toJson true)]
    else
      []
  handleRpcRequestWithNotifications state opts notifications s!"lean_sync {path}" id "tools/call" <|
    some <| toolCallParams "lean_sync" arguments

private def checkIdempotentLifecycleTools : IO Unit := do
  let root ← mkTempProjectRoot "lean-beam-mcp-idempotent-lifecycle"
  let state ← Beam.Mcp.Server.ServerState.create
  try
    copySaveProjectFixture root
    let opts ← mcpOptionsWithPlugin
    let notifications : Beam.Mcp.Server.NotificationSink := {
      send := fun _ => pure ()
    }
    initMcpSession state opts notifications

    let syncResp ← callLeanSync state opts notifications root 2 "SaveSmoke/B.lean"
    let syncResult ← requireObjVal "lifecycle lean_sync response" "result" syncResp
    requireJsonBool "lifecycle lean_sync result" "isError" false syncResult
    let canonicalRoot ← Beam.resolveExistingPath root
    let workspaceId := (Beam.Workspace.Descriptor.ofRoot canonicalRoot).cacheKey
    let workspaces ← legacyStatsWorkspaces state opts notifications
      "lifecycle stats after sync" 3
    let workspaceStats ← requireObjVal
      "lifecycle stats after sync workspaces" workspaceId workspaces
    requireJsonString "lifecycle stats workspace" "root" canonicalRoot.toString workspaceStats

    for (id, label) in #[(4, "first"), (5, "repeated")] do
      let closeResp ← handleRpcRequestWithNotifications state opts notifications
        s!"{label} lean close" id "tools/call" <| some <| toolCallParams "lean_close" <|
          withWorkspace root <| Json.mkObj [
            ("path", toJson "SaveSmoke/B.lean")
          ]
      let closeResult ← requireObjVal s!"{label} lean_close response" "result" closeResp
      requireJsonBool s!"{label} lean_close result" "isError" false closeResult
      let closeStructured ←
        requireObjVal s!"{label} lean_close result" "structuredContent" closeResult
      requireJsonBool s!"{label} lean_close structured result" "closed" true closeStructured

    let firstDropResp ← handleRpcRequestWithNotifications state opts notifications
      "first lean drop workspace" 6 "tools/call" <|
        some <| toolCallParams "lean_drop_workspace" <| withWorkspace root (Json.mkObj [])
    let firstDropResult ← requireObjVal "first lean_drop_workspace response" "result" firstDropResp
    requireJsonBool "first lean_drop_workspace result" "isError" false firstDropResult
    let firstDropStructured ←
      requireObjVal "first lean_drop_workspace result" "structuredContent" firstDropResult
    requireJsonBool "first lean_drop_workspace structured result" "dropped" true firstDropStructured
    requireJsonBool "first lean_drop_workspace structured result" "invalidated_handles" true
      firstDropStructured
    let workspaces ← legacyStatsWorkspaces state opts notifications
      "lifecycle stats after drop" 7
    requireFieldAbsent "lifecycle stats after drop workspaces" workspaceId workspaces

    let repeatedDropResp ← handleRpcRequestWithNotifications state opts notifications
      "repeated lean drop workspace" 8 "tools/call" <|
        some <| toolCallParams "lean_drop_workspace" <| withWorkspace root (Json.mkObj [])
    let repeatedDropResult ←
      requireObjVal "repeated lean_drop_workspace response" "result" repeatedDropResp
    requireJsonBool "repeated lean_drop_workspace result" "isError" false repeatedDropResult
    let repeatedDropStructured ←
      requireObjVal "repeated lean_drop_workspace result" "structuredContent" repeatedDropResult
    requireJsonBool "repeated lean_drop_workspace structured result" "dropped" false
      repeatedDropStructured
    requireJsonBool "repeated lean_drop_workspace structured result" "invalidated_handles" false
      repeatedDropStructured
    requireJsonString "repeated lean_drop_workspace structured result" "reason" "notFound"
      repeatedDropStructured

    state.closeRuntime
    requireLegacyRuntimeActive state opts
      "MCP runtime close should clear ServerState ownership" 9 false notifications
    state.closeRuntime
  finally
    state.closeRuntime
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDiagnosticLogForwarding : IO Unit := do
  let root ← mkTempProjectRoot "lean-beam-mcp-diagnostic-log"
  let state ← Beam.Mcp.Server.ServerState.create
  try
    copySaveProjectFixture root
    let expectedRoot ← Beam.resolveExistingPath root
    let opts ← mcpOptionsWithPlugin
    let notificationsRef ← IO.mkRef #[]
    let notifications : Beam.Mcp.Server.NotificationSink := {
      send := fun notification =>
        notificationsRef.modify fun seen => seen.push notification
    }
    initMcpSession state opts notifications

    writeSaveWarningFile root "-- mcp diagnostic log default"
    let defaultSyncResp ← callLeanSync state opts notifications root 2 "SaveSmoke/B.lean"
      (diagnosticScope := .errors)
      (diagnosticsInResult := true)
    let defaultSyncResult ← requireObjVal "default lean_sync response" "result" defaultSyncResp
    requireJsonBool "default lean_sync result" "isError" false defaultSyncResult
    let defaultStructured ←
      requireObjVal "default lean_sync result" "structuredContent" defaultSyncResult
    let defaultDiagnostics ←
      requireDiagnosticsArray "default lean_sync structured result" defaultStructured
    requireNoDiagnosticSeverity "default lean_sync diagnostics_in_result" defaultDiagnostics "warning"
    expectNoDiagnosticLog
      "default lean_sync with diagnostic_scope=errors"
      (← notificationsRef.get)
      "warning"
      "SaveSmoke/B.lean"

    notificationsRef.set #[]
    writeSaveWarningFile root "-- mcp diagnostic log full"
    let syncResp ← callLeanSync state opts notifications root 3 "SaveSmoke/B.lean"
      (diagnosticScope := .all)
      (diagnosticsInResult := true)
    let syncResult ← requireObjVal "lean_sync response" "result" syncResp
    requireJsonBool "lean_sync result" "isError" false syncResult
    let syncStructured ← requireObjVal "lean_sync result" "structuredContent" syncResult
    let replyDiagnostics ← requireDiagnosticsArray "lean_sync structured result" syncStructured
    if replyDiagnostics.isEmpty then
      throw <| IO.userError
        s!"expected lean_sync diagnostics_in_result to replay diagnostics, got {syncStructured.compress}"
    requireDiagnosticSeverityForPath
      "lean_sync diagnostics_in_result"
      replyDiagnostics
      "warning"
      "SaveSmoke/B.lean"
    let warningLog ← requireDiagnosticLog (← notificationsRef.get) "warning" "warning" "SaveSmoke/B.lean"
    let params ← requireObjVal "warning log notification" "params" warningLog
    let data ← requireObjVal "warning log params" "data" params
    discard <| requireObjVal "warning log data" "range" data
    discard <| requireObjVal "warning log data" "uri" data
    discard <| requireObjVal "warning log data" "version" data
    requireJsonBool "warning log data" "completion_blocking" false data
    requireFieldAbsent "warning log data" "save_blocking" data
    let message ← IO.ofExcept <| data.getObjValAs? String "message"
    require "warning log should preserve diagnostic message" (!message.isEmpty)

    let _ ← handleRpcRequestWithNotifications state opts notifications "set error log level" 4
      "logging/setLevel" <| some <| Json.mkObj [
        ("level", toJson "error")
      ]
    notificationsRef.set #[]
    writeSaveWarningFile root "-- mcp warning suppressed"
    let suppressedResp ← callLeanSync state opts notifications root 5 "SaveSmoke/B.lean"
    let suppressedResult ← requireObjVal "suppressed lean_sync response" "result" suppressedResp
    requireJsonBool "suppressed lean_sync result" "isError" false suppressedResult
    let suppressedStructured ← requireObjVal "suppressed lean_sync result" "structuredContent" suppressedResult
    let suppressedDiagnostics ←
      requireObjVal "suppressed lean_sync result" "diagnostics" suppressedStructured
    requireFieldAbsent "suppressed lean_sync diagnostics" "items" suppressedDiagnostics
    expectNoDiagnosticLogs "warning-only after error log level" (← notificationsRef.get)

    let statsResp ← handleRpcRequestWithNotifications state opts notifications "beam stats" 40
      "tools/call" <| some <| toolCallParams "beam_stats"
    let statsResult ← requireObjVal "beam stats response" "result" statsResp
    requireJsonBool "beam stats result" "isError" false statsResult
    let statsStructured ← requireObjVal "beam stats result" "structuredContent" statsResult
    let workspaces ← requireObjVal "beam stats structured" "workspaces" statsStructured
    let workspaceKey := (Beam.Workspace.Descriptor.ofRoot expectedRoot).cacheKey
    let workspaceStats ← requireObjVal "beam stats workspaces" workspaceKey workspaces
    requireJsonString "beam stats workspace" "root" expectedRoot.toString workspaceStats
    discard <| requireObjVal "beam stats workspace" "sessions" workspaceStats
    let byBackend ← requireObjVal "beam stats workspace" "byBackend" workspaceStats
    let leanMetrics ← requireObjVal "beam stats byBackend" "lean" byBackend
    let ops ← requireObjVal "beam stats lean metrics" "ops" leanMetrics
    let syncStats ← requireObjVal "beam stats lean ops" "sync_file" ops
    let syncCount ← IO.ofExcept <| syncStats.getObjValAs? Nat "count"
    require "beam stats should include prior sync_file calls" (syncCount >= 1)

    let refreshResp ← handleRpcRequestWithNotifications state opts notifications "lean refresh" 41
      "tools/call" <| some <| toolCallParams "lean_refresh" <|
        withWorkspace root <| Json.mkObj [
          ("path", toJson "SaveSmoke/B.lean"),
          ("diagnostics_in_result", toJson true)
        ]
    let refreshResult ← requireObjVal "lean_refresh response" "result" refreshResp
    requireJsonBool "lean_refresh result" "isError" false refreshResult
    let refreshStructured ← requireObjVal "lean_refresh result" "structuredContent" refreshResult
    discard <| IO.ofExcept <| refreshStructured.getObjValAs? Nat "version"
    discard <| requireObjVal "lean_refresh structured result" "readiness" refreshStructured
    let refreshDiagnostics ← requireObjVal "lean_refresh structured result" "diagnostics" refreshStructured
    discard <| requireObjVal "lean_refresh diagnostics" "counts" refreshDiagnostics
    let refreshWorkspace ← requireObjVal "lean_refresh structured result" "workspace" refreshStructured
    requireJsonString "lean_refresh workspace" "root" expectedRoot.toString refreshWorkspace

    let closeSaveResp ← handleRpcRequestWithNotifications state opts notifications "lean close-save" 42
      "tools/call" <| some <| toolCallParams "lean_close_save" <|
        withWorkspace root <| Json.mkObj [
          ("path", toJson "SaveSmoke/B.lean")
        ]
    let closeSaveResult ← requireObjVal "lean_close_save response" "result" closeSaveResp
    requireJsonBool "lean_close_save result" "isError" false closeSaveResult
    let closeSaveStructured ← requireObjVal "lean_close_save result" "structuredContent" closeSaveResult
    requireJsonBool "lean_close_save structured result" "closed" true closeSaveStructured
    let saved ← requireObjVal "lean_close_save structured result" "saved" closeSaveStructured
    discard <| IO.ofExcept <| saved.getObjValAs? Nat "version"
    discard <| requireObjVal "lean_close_save saved result" "sync" saved
    let closeSaveWorkspace ←
      requireObjVal "lean_close_save structured result" "workspace" closeSaveStructured
    requireJsonString "lean_close_save workspace" "root" expectedRoot.toString closeSaveWorkspace

    notificationsRef.set #[]
    IO.FS.writeFile (root / "SaveSmoke" / "B.lean") "def bVal : Nat := \"broken\"\n"
    let errorResp ← callLeanSync state opts notifications root 6 "SaveSmoke/B.lean"
    let errorResult ← requireObjVal "error lean_sync response" "result" errorResp
    requireJsonBool "error lean_sync result" "isError" false errorResult
    let errorLog ← requireDiagnosticLog (← notificationsRef.get) "error" "error" "SaveSmoke/B.lean"
    let errorParams ← requireObjVal "error log notification" "params" errorLog
    let errorData ← requireObjVal "error log params" "data" errorParams
    requireJsonBool "error log data" "completion_blocking" false errorData
    requireFieldAbsent "error log data" "save_blocking" errorData
  finally
    state.closeRuntime
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

def main : IO Unit := do
  checkJsonHelpers
  checkVersionIdentityJson
  checkIncoming
  checkToolsListShape
  checkWorkspaceDescriptor
  checkWorkspaceRootValidation
  checkProgressProtocol
  checkRuntimeSetupErrors
  checkModernProtocol
  checkServerBasics
  checkIdempotentLifecycleTools
  checkDiagnosticLogForwarding

end BeamTest.Broker.McpProtocolTest

def main := BeamTest.Broker.McpProtocolTest.main
