/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.JsonSchema
import Beam.LSP.Todo

open Lean

namespace Beam.Lean

/--
Curated Lean operations that Beam exposes above the raw LSP layer.

CLI and MCP projections should map to these operations instead of constructing broker requests
independently or exposing raw LSP methods.
-/
inductive Operation where
  | runAt
  | runAtHandle
  | hover
  | signatureHelp
  | definition
  | references
  | documentSymbols
  | workspaceSymbols
  | goals
  | todo
  | codeActionResolve
  | runWith
  | runWithLinear
  | release
  | update
  | sync
  | refresh
  | save
  | closeSave
  | close
  deriving BEq, Repr

def Operation.all : Array Operation := #[
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

def Operation.key : Operation → String
  | .runAt => "run_at"
  | .runAtHandle => "run_at_handle"
  | .hover => "hover"
  | .signatureHelp => "signature_help"
  | .definition => "definition"
  | .references => "references"
  | .documentSymbols => "document_symbols"
  | .workspaceSymbols => "workspace_symbols"
  | .goals => "goals"
  | .todo => "todo"
  | .codeActionResolve => "code_action_resolve"
  | .runWith => "run_with"
  | .runWithLinear => "run_with_linear"
  | .release => "release"
  | .update => "update"
  | .sync => "sync"
  | .refresh => "refresh"
  | .save => "save"
  | .closeSave => "close_save"
  | .close => "close"

instance : ToJson Operation where
  toJson op := toJson op.key

private def operationDescription (syncOperation : String) : Operation → String
  | .runAt => s!"Speculatively run one Lean command or tactic block at a file position. The text is not persisted as source and no follow-up state is kept. To keep a result, first edit and save the Lean file yourself, then call {syncOperation}."
  | .runAtHandle => s!"Speculatively run one Lean command or tactic block at a file position. A successful result may include next_handle for exact follow-up execution. The text is not persisted as source. To keep a result, first edit and save the Lean file yourself, then call {syncOperation}."
  | .hover => "Inspect Lean hover information at a file position."
  | .signatureHelp => "Inspect Lean signature help at a file position."
  | .definition => "Find Lean definitions for the symbol at a file position."
  | .references => "Find Lean references for the symbol at a file position."
  | .documentSymbols => "List Lean document symbols for one synced file."
  | .workspaceSymbols => "Search Lean workspace symbols by query string."
  | .goals => "Inspect Lean goals before or after a file position."
  | .todo => "Inspect agent-actionable Lean todo items in a file, or in an optional range. Sorry, hole, and incomplete-proof items carry the goal that run_at sees at their run_at_position; run_at_position is omitted when no source position selects that goal. Code actions use one command snapshot selected by the range end; prefer a point inside the relevant syntax or a range within one command. An empty code-action result does not establish whole-range or whole-file completeness."
  | .codeActionResolve => "Resolve and return a Lean code action payload from the todo result. If it contains an LSP WorkspaceEdit, the client must apply it."
  | .runWith => s!"Speculatively continue from a stored handle without consuming it. The continuation is not persisted as source. To keep a result, first edit and save the Lean file so it contains the complete accepted source, then call {syncOperation}."
  | .runWithLinear => s!"Speculatively continue from a stored handle and consume it on success or failure. The continuation is not persisted as source. To keep a result, first edit and save the Lean file so it contains the complete accepted source, then call {syncOperation}."
  | .release => "Release a stored Lean follow-up handle."
  | .update => "Read the current on-disk Lean source into the broker's LSP mirror and return its document version without waiting for diagnostics."
  | .sync => "Read the current on-disk Lean source into the broker's LSP mirror, wait for diagnostics and readiness, and return its document version. This never applies or recovers speculative text."
  | .refresh => "Refresh the tracked document from the current on-disk Lean source and wait for fresh diagnostics."
  | .save => "Read and synchronize the current on-disk Lean source, then write Lean/Lake build artifacts as a zero-build development checkpoint when possible."
  | .closeSave => "Read and synchronize the current on-disk Lean source, write the same Lean/Lake build artifacts when possible, and close the tracked LSP document."
  | .close => "Close the tracked LSP document."

/-- Transport-wide rule; MCP states it once in its server instructions. -/
def sourceFileInvariant : String :=
  "Beam never applies source edits to `.lean` files on disk; the client applies source edits."

private def executesSuppliedLeanText : Operation → Bool
  | .runAt | .runAtHandle | .runWith | .runWithLinear => true
  | _ => false

private def speculativeCaveat : String :=
  "Tactic probes reject new local `let rec` definitions, even valid ones; save the enclosing declaration and sync instead. Probes are not an OS sandbox: Lean code may perform IO."

/-- Describe an operation, naming the transport's sync operation in the keep-a-result guidance. -/
def Operation.description (operation : Operation) (syncOperation : String := "the sync operation") :
    String :=
  String.intercalate " " <|
    [operationDescription syncOperation operation] ++
      (if executesSuppliedLeanText operation then [speculativeCaveat] else [])

private def pathField : String × Json :=
  ("path", Beam.JsonSchema.string
    "Absolute or relative path to a regular .lean source inside the workspace root.")

private def versionField : String × Json :=
  ("version", Beam.JsonSchema.natural "Document version returned by a successful update or sync operation for this file.")

private def lineField : String × Json :=
  ("line", Beam.JsonSchema.natural "Zero-based LSP line.")

private def characterField : String × Json :=
  ("character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP character.")

private def rangeStartLineField : String × Json :=
  ("start_line", Beam.JsonSchema.natural "Zero-based LSP start line. Pass all four range fields, or none for the whole file without code actions.")

private def rangeStartCharacterField : String × Json :=
  ("start_character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP start character.")

private def rangeEndLineField : String × Json :=
  ("end_line", Beam.JsonSchema.natural "Zero-based LSP end line.")

private def rangeEndCharacterField : String × Json :=
  ("end_character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP end character.")

private def runAtTextField : String × Json :=
  ("text", Beam.JsonSchema.string "One Lean command or tactic block to run at the selected position. Top-level command sequences are not accepted by one runAt call.")

private def continuationTextField : String × Json :=
  ("text", Beam.JsonSchema.string "One Lean continuation command or tactic block to run from the stored handle.")

private def handleField : String × Json :=
  ("handle", Beam.JsonSchema.object "Opaque broker-wrapped Lean handle from a previous tool result.")

private def releaseHandleField : String × Json :=
  ("handle", Beam.JsonSchema.object "Opaque broker-wrapped Lean handle to release.")

private def kindsField : String × Json :=
  ("kinds", Beam.JsonSchema.enumStringArray "Todo kinds to include. Omit or pass [] for all kinds."
    Beam.LSP.Todo.TodoKind.allKeys)

private def suggestField : String × Json :=
  ("suggest", Beam.JsonSchema.enumString "Suggestion mode for optional run_at_text hints."
    Beam.LSP.Todo.TodoSuggestMode.allKeys)

private def includeDeclarationField : String × Json :=
  ("include_declaration", Beam.JsonSchema.bool
    "When true, include the declaration location in reference results. Defaults to true.")

private def workspaceSymbolQueryField : String × Json :=
  ("query", Beam.JsonSchema.string "Workspace symbol search query.")

private def goalsModeField : String × Json :=
  ("mode", Beam.JsonSchema.enumString "Whether to inspect goals before or after the file position."
    #["before", "after"])

private def syncDiagnosticScopeField : String × Json :=
  ("diagnostic_scope", Beam.JsonSchema.enumString
    "Select user-facing diagnostic severities for live logging or final replay. Defaults to errors. This setting does not control Lake setup status or silent editor-only messages."
    #["errors", "all"])

private def saveDiagnosticScopeField : String × Json :=
  ("diagnostic_scope", Beam.JsonSchema.enumString
    "Select user-facing diagnostic severities for live logging. Defaults to errors. This setting does not control Lake setup status or silent editor-only messages."
    #["errors", "all"])

private def diagnosticsInResultField : String × Json :=
  ("diagnostics_in_result", Beam.JsonSchema.bool
    "When true, include selected current diagnostics in the final sync result; diagnostic_scope controls the severity filter.")

private def codeActionField : String × Json :=
  ("code_action", Beam.JsonSchema.object
    "Raw Lean LSP CodeAction payload returned by the todo operation. The action must include its data field so Lean can resolve it against this document version.")

private def positionFields : List (String × Json) :=
  [pathField, versionField, lineField, characterField]

private def rangeFields : List (String × Json) :=
  [
    pathField,
    versionField,
    rangeStartLineField,
    rangeStartCharacterField,
    rangeEndLineField,
    rangeEndCharacterField
  ]

private def documentFields : List (String × Json) :=
  [pathField, versionField]

open Beam.JsonSchema in
def Operation.inputSchema : Operation → Json
  | .runAt | .runAtHandle =>
      inputObject (positionFields ++ [runAtTextField]) #["path", "version", "line", "character", "text"]
  | .hover | .signatureHelp | .definition =>
      inputObject positionFields #["path", "version", "line", "character"]
  | .references =>
      inputObject (positionFields ++ [includeDeclarationField]) #["path", "version", "line", "character"]
  | .documentSymbols =>
      inputObject documentFields #["path", "version"]
  | .workspaceSymbols =>
      inputObject [workspaceSymbolQueryField] #["query"]
  | .goals =>
      inputObject (positionFields ++ [goalsModeField]) #["path", "version", "line", "character", "mode"]
  | .todo =>
      inputObject (rangeFields ++ [kindsField, suggestField])
        #["path", "version"]
  | .codeActionResolve =>
      inputObject (documentFields ++ [codeActionField]) #["path", "version", "code_action"]
  | .runWith | .runWithLinear =>
      inputObject [pathField, handleField, continuationTextField] #["path", "handle", "text"]
  | .release =>
      inputObject [pathField, releaseHandleField] #["path", "handle"]
  | .update =>
      inputObject [pathField] #["path"]
  | .sync | .refresh =>
      inputObject [pathField, syncDiagnosticScopeField, diagnosticsInResultField] #["path"]
  | .save | .closeSave =>
      inputObject [pathField, saveDiagnosticScopeField] #["path"]
  | .close =>
      inputObject [("path", string "Document path to close, including a deleted source.")] #["path"]

/-- Reject fields outside the closed schema owned by one Lean operation. -/
def Operation.validateInputFields (operation : Operation) (input : Json) : Except String Unit :=
  Beam.JsonSchema.validateInputFields operation.key operation.inputSchema input

private def inputValue (j : Json) (field expected : String) : Except String Json :=
  match j.getObjVal? field with
  | .ok value => .ok value
  | .error _ => .error s!"{field}: required value is missing ({expected})"

/-- Decode a public argument at its field boundary, without exposing Lean structure names. -/
private def inputField [FromJson α] (j : Json) (field expected : String) : Except String α := do
  let value ← inputValue j field expected
  (fromJson? value).mapError fun _ => s!"{field}: {expected}"

/-- Opaque handles retain their decoder's public reason as well as the expected source. -/
private def inputHandle (j : Json) : Except String Beam.Broker.Handle := do
  let value ← inputValue j "handle" "handle returned by Beam expected"
  (fromJson? value).mapError fun reason => s!"handle: handle returned by Beam expected; {reason}"

/-- Input for position-based Lean execution. Coordinates use LSP zero-based line/character units. -/
structure RunAtInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  text : String
  deriving ToJson

instance : FromJson RunAtInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      version := ← inputField j "version" "non-negative integer expected"
      line := ← inputField j "line" "non-negative integer expected"
      character := ← inputField j "character" "non-negative integer expected"
      text := ← inputField j "text" "string expected"
    }

/-- Input for position-based Lean inspection operations. -/
structure PositionInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  deriving ToJson

instance : FromJson PositionInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      version := ← inputField j "version" "non-negative integer expected"
      line := ← inputField j "line" "non-negative integer expected"
      character := ← inputField j "character" "non-negative integer expected"
    }

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

/-- Input for Lean reference queries. -/
structure ReferencesInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  includeDeclaration? : Option Bool := none

instance : ToJson ReferencesInput where
  toJson input :=
    Json.mkObj <|
      [ ("path", toJson input.path)
      , ("version", toJson input.version)
      , ("line", toJson input.line)
      , ("character", toJson input.character)
      ] ++
      match input.includeDeclaration? with
      | some includeDeclaration => [("include_declaration", toJson includeDeclaration)]
      | none => []

instance : FromJson ReferencesInput where
  fromJson? j := do
    let path ← inputField (α := String) j "path" "string expected"
    let version ← inputField (α := Nat) j "version" "non-negative integer expected"
    let line ← inputField (α := Nat) j "line" "non-negative integer expected"
    let character ← inputField (α := Nat) j "character" "non-negative integer expected"
    let includeDeclaration? ← optionalField? (α := Bool) j "include_declaration"
    pure { path, version, line, character, includeDeclaration? }

/-- Input for file-scoped Lean document symbol queries. -/
structure DocumentSymbolsInput where
  path : String
  version : Nat
  deriving ToJson

instance : FromJson DocumentSymbolsInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      version := ← inputField j "version" "non-negative integer expected"
    }

/-- Input for workspace-wide Lean symbol queries. -/
structure WorkspaceSymbolsInput where
  query : String
  deriving ToJson

instance : FromJson WorkspaceSymbolsInput where
  fromJson? j := do
    pure {
      query := ← inputField j "query" "string expected"
    }

inductive GoalsMode where
  | before
  | after
  deriving BEq, Repr

def GoalsMode.key : GoalsMode → String
  | .before => "before"
  | .after => "after"

def GoalsMode.toBrokerMode : GoalsMode → Beam.Broker.GoalMode
  | .before => .before
  | .after => .after

instance : ToJson GoalsMode where
  toJson mode := toJson mode.key

instance : FromJson GoalsMode where
  fromJson?
    | .str "before" => .ok .before
    | .str "after" => .ok .after
    | j => .error s!"expected goals mode 'before' or 'after', got {j.compress}"

/-- Input for read-only Lean goal inspection at a file position. -/
structure GoalsInput where
  path : String
  version : Nat
  line : Nat
  character : Nat
  mode : GoalsMode
  deriving ToJson

instance : FromJson GoalsInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      version := ← inputField j "version" "non-negative integer expected"
      line := ← inputField j "line" "non-negative integer expected"
      character := ← inputField j "character" "non-negative integer expected"
      mode := ← inputField j "mode" "'before' or 'after' expected"
    }

/-- Input for Lean todo inspection operations. -/
structure TodoInput where
  path : String
  version : Nat
  /-- The whole document when omitted. -/
  range? : Option Lean.Lsp.Range := none
  kinds? : Option (Array Beam.LSP.Todo.TodoKind) := none
  suggest? : Option Beam.LSP.Todo.TodoSuggestMode := none

instance : ToJson TodoInput where
  toJson input :=
    Json.mkObj <|
      [ ("path", toJson input.path)
      , ("version", toJson input.version)
      ] ++
      (match input.range? with
      | some range =>
          [ ("start_line", toJson range.start.line)
          , ("start_character", toJson range.start.character)
          , ("end_line", toJson range.«end».line)
          , ("end_character", toJson range.«end».character)
          ]
      | none => []) ++
      (match input.kinds? with
      | some kinds => [("kinds", toJson kinds)]
      | none => []) ++
      (match input.suggest? with
      | some suggest => [("suggest", toJson suggest)]
      | none => [])

instance : FromJson TodoInput where
  fromJson? j := do
    let path ← inputField (α := String) j "path" "string expected"
    let version ← inputField (α := Nat) j "version" "non-negative integer expected"
    let rangeFields := #["start_line", "start_character", "end_line", "end_character"]
    let range? ←
      if rangeFields.all (j.getObjVal? · |>.toOption |>.isNone) then
        pure none
      else
        let position (line character : String) : Except String Lean.Lsp.Position := do
          pure {
            line := ← inputField j line "non-negative integer expected with the other range fields"
            character := ← inputField j character
              "non-negative integer expected with the other range fields"
          }
        pure <| some {
          start := ← position "start_line" "start_character"
          «end» := ← position "end_line" "end_character"
        }
    let kinds? ← optionalField? (α := Array Beam.LSP.Todo.TodoKind) j "kinds"
    let suggest? ← optionalField? (α := Beam.LSP.Todo.TodoSuggestMode) j "suggest"
    pure { path, version, range?, kinds?, suggest? }

/-- Input for resolving a Lean code action returned by the todo operation. -/
structure CodeActionResolveInput where
  path : String
  version : Nat
  codeAction : Lean.Lsp.CodeAction

instance : ToJson CodeActionResolveInput where
  toJson input :=
    Json.mkObj [
      ("path", toJson input.path),
      ("version", toJson input.version),
      ("code_action", toJson input.codeAction)
    ]

instance : FromJson CodeActionResolveInput where
  fromJson? j := do
    let path ← inputField (α := String) j "path" "string expected"
    let version ← inputField (α := Nat) j "version" "non-negative integer expected"
    let codeAction ← inputField (α := Lean.Lsp.CodeAction) j "code_action" "code action returned by Beam expected"
    pure { path, version, codeAction }

/-- Input for handle-based Lean execution. -/
structure RunWithInput where
  path : String
  handle : Beam.Broker.Handle
  text : String
  deriving ToJson

instance : FromJson RunWithInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      handle := ← inputHandle j
      text := ← inputField j "text" "string expected"
    }

/-- Input for explicit handle release. -/
structure ReleaseInput where
  path : String
  handle : Beam.Broker.Handle
  deriving ToJson

instance : FromJson ReleaseInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
      handle := ← inputHandle j
    }

/-- Input for path-scoped operations without extra flags. -/
structure PathInput where
  path : String
  deriving ToJson

instance : FromJson PathInput where
  fromJson? j := do
    pure {
      path := ← inputField j "path" "string expected"
    }

/-- Input for sync/refresh operations with optional diagnostic scope and final replay control. -/
structure SyncInput where
  path : String
  diagnosticScope? : Option Beam.Broker.DiagnosticScope := none
  diagnosticsInResult? : Option Bool := none

instance : ToJson SyncInput where
  toJson input :=
    Json.mkObj <|
      [("path", toJson input.path)] ++
      (match input.diagnosticScope? with
      | some diagnosticScope => [("diagnostic_scope", toJson diagnosticScope)]
      | none => []) ++
      (match input.diagnosticsInResult? with
      | some diagnosticsInResult => [("diagnostics_in_result", toJson diagnosticsInResult)]
      | none => [])

instance : FromJson SyncInput where
  fromJson? j := do
    let path ← inputField (α := String) j "path" "string expected"
    let diagnosticScope? ← optionalField? (α := Beam.Broker.DiagnosticScope) j "diagnostic_scope"
    let diagnosticsInResult? ← optionalField? (α := Bool) j "diagnostics_in_result"
    pure { path, diagnosticScope?, diagnosticsInResult? }

/-- Input for save/close-save operations with optional live diagnostic scope. -/
structure SaveInput where
  path : String
  diagnosticScope? : Option Beam.Broker.DiagnosticScope := none

instance : ToJson SaveInput where
  toJson input :=
    Json.mkObj <|
      [("path", toJson input.path)] ++
      match input.diagnosticScope? with
      | some diagnosticScope => [("diagnostic_scope", toJson diagnosticScope)]
      | none => []

instance : FromJson SaveInput where
  fromJson? j := do
    let path ← inputField (α := String) j "path" "string expected"
    let diagnosticScope? ← optionalField? (α := Beam.Broker.DiagnosticScope) j "diagnostic_scope"
    pure { path, diagnosticScope? }

def RunAtInput.toBrokerRequest
    (input : RunAtInput)
    (storeHandle : Bool := false) : Beam.Broker.Request := {
  payload := .runAt {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
    text := input.text
    storeHandle? := if storeHandle then some true else none
  }
}

def PositionInput.toHoverBrokerRequest (input : PositionInput) : Beam.Broker.Request := {
  payload := .hover {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
  }
}

def PositionInput.toSignatureHelpBrokerRequest (input : PositionInput) :
    Beam.Broker.Request := {
  payload := .signatureHelp {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
  }
}

def PositionInput.toDefinitionBrokerRequest (input : PositionInput) : Beam.Broker.Request := {
  payload := .definition {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
  }
}

def ReferencesInput.toBrokerRequest (input : ReferencesInput) : Beam.Broker.Request := {
  payload := .references {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
    includeDeclaration? := input.includeDeclaration?
  }
}

def DocumentSymbolsInput.toBrokerRequest (input : DocumentSymbolsInput) :
    Beam.Broker.Request := {
  payload := .documentSymbols {
    path := input.path
    version := input.version
  }
}

def WorkspaceSymbolsInput.toBrokerRequest (input : WorkspaceSymbolsInput) :
    Beam.Broker.Request := {
  payload := .workspaceSymbols { query := input.query }
}

def PositionInput.toGoalsBrokerRequest
    (input : PositionInput)
    (mode : Beam.Broker.GoalMode) : Beam.Broker.Request := {
  payload := .goals {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
    mode? := some mode
  }
}

def GoalsInput.toBrokerRequest (input : GoalsInput) : Beam.Broker.Request := {
  payload := .goals {
    path := input.path
    version := input.version
    line := input.line
    character := input.character
    mode? := some input.mode.toBrokerMode
  }
}

def TodoInput.toBrokerRequest (input : TodoInput) : Beam.Broker.Request := {
  payload := .todo {
    path := input.path
    version := input.version
    range? := input.range?
    kinds? := input.kinds?
    suggest? := input.suggest?
  }
}

def CodeActionResolveInput.toBrokerRequest
    (input : CodeActionResolveInput) : Beam.Broker.Request := {
  payload := .codeActionResolve {
    path := input.path
    version := input.version
    codeAction := input.codeAction
  }
}

def RunWithInput.toBrokerRequest
    (input : RunWithInput)
    (linear : Bool := false) : Beam.Broker.Request := {
  payload := .runWith {
    path := input.path
    text := input.text
    storeHandle? := some true
    linear? := some linear
    handle := input.handle
  }
}

def ReleaseInput.toBrokerRequest (input : ReleaseInput) : Beam.Broker.Request := {
  payload := .release {
    path := input.path
    handle := input.handle
  }
}

def PathInput.toCloseBrokerRequest (input : PathInput) : Beam.Broker.Request := {
  payload := .close { path := input.path }
}

def PathInput.toUpdateBrokerRequest (input : PathInput) : Beam.Broker.Request := {
  payload := .updateFile { path := input.path }
}

def SyncInput.toSyncBrokerRequest (input : SyncInput) : Beam.Broker.Request := {
  payload := .syncFile {
    path := input.path
    diagnosticScope? := input.diagnosticScope?
    diagnosticsInResult? := input.diagnosticsInResult?
  }
}

def SyncInput.toRefreshBrokerRequest (input : SyncInput) : Beam.Broker.Request := {
  payload := .refreshFile {
    path := input.path
    diagnosticScope? := input.diagnosticScope?
    diagnosticsInResult? := input.diagnosticsInResult?
  }
}

def SaveInput.toSaveBrokerRequest (input : SaveInput) : Beam.Broker.Request := {
  payload := .saveOlean {
    path := input.path
    diagnosticScope? := input.diagnosticScope?
  }
}

def SaveInput.toCloseSaveBrokerRequest (input : SaveInput) : Beam.Broker.Request := {
  payload := .close {
    path := input.path
    saveArtifacts? := some true
    diagnosticScope? := input.diagnosticScope?
  }
}

def Operation.toBrokerRequest
    (op : Operation)
    (input : Json) : Except String Beam.Broker.Request := do
  op.validateInputFields input
  match op with
  | .runAt =>
      pure <| (← fromJson? (α := RunAtInput) input).toBrokerRequest
  | .runAtHandle =>
      pure <| (← fromJson? (α := RunAtInput) input).toBrokerRequest (storeHandle := true)
  | .hover =>
      pure <| (← fromJson? (α := PositionInput) input).toHoverBrokerRequest
  | .signatureHelp =>
      pure <| (← fromJson? (α := PositionInput) input).toSignatureHelpBrokerRequest
  | .definition =>
      pure <| (← fromJson? (α := PositionInput) input).toDefinitionBrokerRequest
  | .references =>
      pure <| (← fromJson? (α := ReferencesInput) input).toBrokerRequest
  | .documentSymbols =>
      pure <| (← fromJson? (α := DocumentSymbolsInput) input).toBrokerRequest
  | .workspaceSymbols =>
      pure <| (← fromJson? (α := WorkspaceSymbolsInput) input).toBrokerRequest
  | .goals =>
      pure <| (← fromJson? (α := GoalsInput) input).toBrokerRequest
  | .todo =>
      pure <| (← fromJson? (α := TodoInput) input).toBrokerRequest
  | .codeActionResolve =>
      pure <| (← fromJson? (α := CodeActionResolveInput) input).toBrokerRequest
  | .runWith =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest
  | .runWithLinear =>
      pure <| (← fromJson? (α := RunWithInput) input).toBrokerRequest (linear := true)
  | .release =>
      pure <| (← fromJson? (α := ReleaseInput) input).toBrokerRequest
  | .update =>
      pure <| (← fromJson? (α := PathInput) input).toUpdateBrokerRequest
  | .sync =>
      pure <| (← fromJson? (α := SyncInput) input).toSyncBrokerRequest
  | .refresh =>
      pure <| (← fromJson? (α := SyncInput) input).toRefreshBrokerRequest
  | .save =>
      pure <| (← fromJson? (α := SaveInput) input).toSaveBrokerRequest
  | .closeSave =>
      pure <| (← fromJson? (α := SaveInput) input).toCloseSaveBrokerRequest
  | .close =>
      pure <| (← fromJson? (α := PathInput) input).toCloseBrokerRequest

end Beam.Lean
