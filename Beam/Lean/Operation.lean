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

private def operationDescription : Operation → String
  | .runAt => "Speculatively test one Lean command or tactic block at a file position without retaining follow-up state. Supplied text remains speculative and is not persisted as source. To keep the result, first edit and save the Lean file with the client's normal file-edit tool; only then call the sync operation."
  | .runAtHandle => "Speculatively test one Lean command or tactic block at a file position. A successful result may include next_handle for follow-up execution. Supplied text remains speculative and is not persisted as source. To keep the result, first edit and save the Lean file with the client's normal file-edit tool; only then call the sync operation."
  | .hover => "Inspect Lean hover information at a file position."
  | .signatureHelp => "Inspect Lean signature help at a file position."
  | .definition => "Find Lean definitions for the symbol at a file position."
  | .references => "Find Lean references for the symbol at a file position."
  | .documentSymbols => "List Lean document symbols for one synced file."
  | .workspaceSymbols => "Search Lean workspace symbols by query string."
  | .goals => "Inspect Lean goals before or after a file position."
  | .todo => "Inspect agent-actionable Lean todo items in a file range."
  | .codeActionResolve => "Resolve and return a Lean code action payload from the todo result. If it contains an LSP WorkspaceEdit, the client must apply it."
  | .runWith => "Speculatively continue from a stored handle without consuming the parent handle. The continuation remains speculative and is not persisted as source. To keep the result, first edit and save the Lean file so it contains the complete accepted source; only then call the sync operation."
  | .runWithLinear => "Speculatively continue from a stored handle and consume that handle on success or failure. The continuation remains speculative and is not persisted as source. To keep the result, first edit and save the Lean file so it contains the complete accepted source; only then call the sync operation."
  | .release => "Release a stored Lean follow-up handle."
  | .update => "Read the current on-disk Lean source into the broker's LSP mirror and return its document snapshot without waiting for diagnostics."
  | .sync => "Read the current on-disk Lean source into the broker's LSP mirror, wait for diagnostics and readiness, and return its document snapshot. This never applies or recovers speculative text."
  | .refresh => "Close the tracked LSP document, reread the current on-disk Lean source, and wait for fresh diagnostics."
  | .save => "Read and synchronize the current on-disk Lean source, then write Lean/Lake build artifacts as a zero-build development checkpoint when possible."
  | .closeSave => "Read and synchronize the current on-disk Lean source, write the same Lean/Lake build artifacts when possible, and close the tracked LSP document."
  | .close => "Close the tracked LSP document."

def sourceFileInvariant : String :=
  "Beam never applies source edits to `.lean` files on disk; the client applies source edits."

private def executesSuppliedLeanText : Operation → Bool
  | .runAt | .runAtHandle | .runWith | .runWithLinear => true
  | _ => false

private def speculativeIoCaveat : String :=
  "Speculative execution isolates Beam's source and document state, but it is not an OS sandbox; Lean commands and project metaprogramming may perform IO."

def Operation.behaviorDescription (operation : Operation) : String :=
  String.intercalate " " <|
    [operationDescription operation] ++
      (if executesSuppliedLeanText operation then [speculativeIoCaveat] else [])

def Operation.description (operation : Operation) : String :=
  String.intercalate " " [operation.behaviorDescription, sourceFileInvariant]

private def pathField : String × Json :=
  ("path", Beam.JsonSchema.string "Lean file path, relative to the server root unless absolute.")

private def snapshotField : String × Json :=
  ("snapshot", Beam.JsonSchema.string "Opaque snapshot token returned by update or sync for this file. After contentModified, read the source and resolve the target again before retrying with a fresh token.")

private def lineField : String × Json :=
  ("line", Beam.JsonSchema.natural "Zero-based LSP line.")

private def characterField : String × Json :=
  ("character", Beam.JsonSchema.natural "Zero-based UTF-16 LSP character.")

private def rangeStartLineField : String × Json :=
  ("start_line", Beam.JsonSchema.natural "Zero-based LSP start line.")

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
    "Raw Lean LSP CodeAction payload returned by the todo operation. The action must include its data field so Lean can resolve it against this document snapshot.")

private def positionFields : List (String × Json) :=
  [pathField, snapshotField, lineField, characterField]

private def rangeFields : List (String × Json) :=
  [
    pathField,
    snapshotField,
    rangeStartLineField,
    rangeStartCharacterField,
    rangeEndLineField,
    rangeEndCharacterField
  ]

private def documentFields : List (String × Json) :=
  [pathField, snapshotField]

open Beam.JsonSchema in
def Operation.inputSchema : Operation → Json
  | .runAt | .runAtHandle =>
      inputObject (positionFields ++ [runAtTextField]) #["path", "snapshot", "line", "character", "text"]
  | .hover | .signatureHelp | .definition =>
      inputObject positionFields #["path", "snapshot", "line", "character"]
  | .references =>
      inputObject (positionFields ++ [includeDeclarationField]) #["path", "snapshot", "line", "character"]
  | .documentSymbols =>
      inputObject documentFields #["path", "snapshot"]
  | .workspaceSymbols =>
      inputObject [workspaceSymbolQueryField] #["query"]
  | .goals =>
      inputObject (positionFields ++ [goalsModeField]) #["path", "snapshot", "line", "character", "mode"]
  | .todo =>
      inputObject (rangeFields ++ [kindsField, suggestField])
        #["path", "snapshot", "start_line", "start_character", "end_line", "end_character"]
  | .codeActionResolve =>
      inputObject (documentFields ++ [codeActionField]) #["path", "snapshot", "code_action"]
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
      inputObject [pathField] #["path"]

/-- Reject fields outside the closed schema owned by one Lean operation. -/
def Operation.validateInputFields (operation : Operation) (input : Json) : Except String Unit :=
  Beam.JsonSchema.validateInputFields operation.key operation.inputSchema input

/-- A file and the opaque source token obtained from update or sync. -/
structure DocumentInput where
  path : String
  snapshot : SnapshotRef
  deriving FromJson, ToJson

/-- A source-bound position in zero-based LSP line/character units. -/
structure PositionInput extends DocumentInput where
  line : Nat
  character : Nat
  deriving FromJson, ToJson

/-- Input for position-based Lean execution. -/
structure RunAtInput extends PositionInput where
  text : String
  deriving FromJson, ToJson

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

/-- Input for Lean reference queries. -/
structure ReferencesInput extends PositionInput where
  includeDeclaration? : Option Bool := none

instance : ToJson ReferencesInput where
  toJson input :=
    let json := toJson input.toPositionInput
    match input.includeDeclaration? with
    | some includeDeclaration => json.setObjVal! "include_declaration" (toJson includeDeclaration)
    | none => json

instance : FromJson ReferencesInput where
  fromJson? j := do
    let toPositionInput ← fromJson? j
    let includeDeclaration? ← optionalField? (α := Bool) j "include_declaration"
    pure { toPositionInput, includeDeclaration? }

/-- Input for workspace-wide Lean symbol queries. -/
structure WorkspaceSymbolsInput where
  query : String
  deriving FromJson, ToJson

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
structure GoalsInput extends PositionInput where
  mode : GoalsMode
  deriving FromJson, ToJson

/-- Input for range-based Lean todo inspection operations. -/
structure TodoInput extends DocumentInput where
  startLine : Nat
  startCharacter : Nat
  endLine : Nat
  endCharacter : Nat
  kinds? : Option (Array Beam.LSP.Todo.TodoKind) := none
  suggest? : Option Beam.LSP.Todo.TodoSuggestMode := none

instance : ToJson TodoInput where
  toJson input :=
    Json.mkObj <|
      [ ("path", toJson input.path)
      , ("snapshot", toJson input.snapshot)
      , ("start_line", toJson input.startLine)
      , ("start_character", toJson input.startCharacter)
      , ("end_line", toJson input.endLine)
      , ("end_character", toJson input.endCharacter)
      ] ++
      (match input.kinds? with
      | some kinds => [("kinds", toJson kinds)]
      | none => []) ++
      (match input.suggest? with
      | some suggest => [("suggest", toJson suggest)]
      | none => [])

instance : FromJson TodoInput where
  fromJson? j := do
    let toDocumentInput ← fromJson? j
    let startLine ← j.getObjValAs? Nat "start_line"
    let startCharacter ← j.getObjValAs? Nat "start_character"
    let endLine ← j.getObjValAs? Nat "end_line"
    let endCharacter ← j.getObjValAs? Nat "end_character"
    let kinds? ← optionalField? (α := Array Beam.LSP.Todo.TodoKind) j "kinds"
    let suggest? ← optionalField? (α := Beam.LSP.Todo.TodoSuggestMode) j "suggest"
    pure { toDocumentInput, startLine, startCharacter, endLine, endCharacter, kinds?, suggest? }

/-- Input for resolving a Lean code action returned by the todo operation. -/
structure CodeActionResolveInput extends DocumentInput where
  codeAction : Lean.Lsp.CodeAction

instance : ToJson CodeActionResolveInput where
  toJson input :=
    (toJson input.toDocumentInput).setObjVal! "code_action" (toJson input.codeAction)

instance : FromJson CodeActionResolveInput where
  fromJson? j := do
    let toDocumentInput ← fromJson? j
    let codeAction ← j.getObjValAs? Lean.Lsp.CodeAction "code_action"
    pure { toDocumentInput, codeAction }

/-- Input for handle-based Lean execution. -/
structure RunWithInput where
  path : String
  handle : Beam.Broker.Handle
  text : String
  deriving FromJson, ToJson

/-- Input for explicit handle release. -/
structure ReleaseInput where
  path : String
  handle : Beam.Broker.Handle
  deriving FromJson, ToJson

/-- Input for path-scoped operations without extra flags. -/
structure PathInput where
  path : String
  deriving FromJson, ToJson

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
    let path ← j.getObjValAs? String "path"
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
    let path ← j.getObjValAs? String "path"
    let diagnosticScope? ← optionalField? (α := Beam.Broker.DiagnosticScope) j "diagnostic_scope"
    pure { path, diagnosticScope? }

private def DocumentInput.toRequestSnapshotFile (input : DocumentInput) :
    Beam.Broker.RequestSnapshotFile := {
  path := input.path
  snapshot := input.snapshot
}

private def PositionInput.toRequestPosition (input : PositionInput) : Beam.Broker.RequestPosition := {
  toRequestSnapshotFile := input.toDocumentInput.toRequestSnapshotFile
  line := input.line
  character := input.character
}

def RunAtInput.toBrokerRequest
    (input : RunAtInput)
    (storeHandle : Bool := false) : Beam.Broker.Request := {
  payload := .runAt {
    toRequestPosition := input.toPositionInput.toRequestPosition
    text := input.text
    storeHandle? := if storeHandle then some true else none
  }
}

def PositionInput.toHoverBrokerRequest (input : PositionInput) : Beam.Broker.Request := {
  payload := .hover input.toRequestPosition
}

def PositionInput.toSignatureHelpBrokerRequest (input : PositionInput) :
    Beam.Broker.Request := {
  payload := .signatureHelp input.toRequestPosition
}

def PositionInput.toDefinitionBrokerRequest (input : PositionInput) : Beam.Broker.Request := {
  payload := .definition input.toRequestPosition
}

def ReferencesInput.toBrokerRequest (input : ReferencesInput) : Beam.Broker.Request := {
  payload := .references {
    toRequestPosition := input.toPositionInput.toRequestPosition
    includeDeclaration? := input.includeDeclaration?
  }
}

def DocumentInput.toDocumentSymbolsBrokerRequest (input : DocumentInput) :
    Beam.Broker.Request := {
  payload := .documentSymbols input.toRequestSnapshotFile
}

def WorkspaceSymbolsInput.toBrokerRequest (input : WorkspaceSymbolsInput) :
    Beam.Broker.Request := {
  payload := .workspaceSymbols { query := input.query }
}

def PositionInput.toGoalsBrokerRequest
    (input : PositionInput)
    (mode : Beam.Broker.GoalMode) : Beam.Broker.Request := {
  payload := .goals {
    toRequestPosition := input.toRequestPosition
    mode? := some mode
  }
}

def GoalsInput.toBrokerRequest (input : GoalsInput) : Beam.Broker.Request := {
  payload := .goals {
    toRequestPosition := input.toPositionInput.toRequestPosition
    mode? := some input.mode.toBrokerMode
  }
}

def TodoInput.toBrokerRequest (input : TodoInput) : Beam.Broker.Request := {
  payload := .todo {
    toRequestSnapshotFile := input.toDocumentInput.toRequestSnapshotFile
    line := input.startLine
    character := input.startCharacter
    endLine := input.endLine
    endCharacter := input.endCharacter
    kinds? := input.kinds?
    suggest? := input.suggest?
  }
}

def CodeActionResolveInput.toBrokerRequest
    (input : CodeActionResolveInput) : Beam.Broker.Request := {
  payload := .codeActionResolve {
    toRequestSnapshotFile := input.toDocumentInput.toRequestSnapshotFile
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
      pure <| (← fromJson? (α := DocumentInput) input).toDocumentSymbolsBrokerRequest
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
