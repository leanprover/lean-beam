/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Todo
import Beam.Snapshot
import Beam.Workspace.Protocol

open Lean

namespace Beam.Broker

abbrev WorkspaceId := Beam.Workspace.WorkspaceId

/-- Identity of one wrapper-owned daemon generation. -/
structure DaemonIdentity where
  daemonId : String
  configHash : String
  deriving BEq, Repr, FromJson, ToJson

def serverHelloSchemaVersion : Nat :=
  1

/-- Identity greeting emitted by a wrapper daemon before it accepts one request connection. -/
structure ServerHello where
  schemaVersion : Nat
  identity : DaemonIdentity
  deriving Repr, FromJson, ToJson

def ServerHello.current (identity : DaemonIdentity) : ServerHello := {
  schemaVersion := serverHelloSchemaVersion
  identity
}

def ServerHello.decode
    (expectedIdentity : DaemonIdentity)
    (msg : String) : Except String Unit := do
  let json ←
    match Json.parse msg with
    | .ok json => pure json
    | .error err => throw s!"invalid Beam daemon greeting json: {err}"
  let hello ←
    match fromJson? (α := ServerHello) json with
    | .ok hello => pure hello
    | .error err => throw s!"invalid Beam daemon greeting payload: {err}"
  unless hello.schemaVersion == serverHelloSchemaVersion do
    throw s!"unsupported Beam daemon greeting schema {hello.schemaVersion}"
  unless hello.identity == expectedIdentity do
    throw "Beam daemon greeting identity does not match the selected session"

instance : Repr Lsp.DiagnosticSeverity where
  reprPrec severity _ :=
    match severity with
    | .error => "error"
    | .warning => "warning"
    | .information => "information"
    | .hint => "hint"

inductive Op where
  | ensure
  | openDocs
  | cancel
  | updateFile
  | syncFile
  | refreshFile
  | close
  | runAt
  | hover
  | signatureHelp
  | definition
  | references
  | documentSymbols
  | workspaceSymbols
  | codeActionResolve
  | saveOlean
  | goals
  | todo
  | runWith
  | release
  | initWorkspace
  | listWorkspaces
  | dropWorkspace
  | stats
  | shutdown
  deriving Inhabited, BEq, Repr

def Op.all : Array Op := #[
  .ensure, .openDocs, .cancel, .updateFile, .syncFile, .refreshFile, .close, .runAt,
  .hover, .signatureHelp, .definition, .references, .documentSymbols, .workspaceSymbols,
  .codeActionResolve, .saveOlean, .goals, .todo, .runWith, .release, .initWorkspace,
  .listWorkspaces, .dropWorkspace, .stats, .shutdown
]

def Op.key : Op → String
  | .ensure => "ensure"
  | .openDocs => "open_docs"
  | .cancel => "cancel"
  | .updateFile => "update_file"
  | .syncFile => "sync_file"
  | .refreshFile => "refresh_file"
  | .close => "close"
  | .runAt => "run_at"
  | .hover => "hover"
  | .signatureHelp => "signature_help"
  | .definition => "definition"
  | .references => "references"
  | .documentSymbols => "document_symbols"
  | .workspaceSymbols => "workspace_symbols"
  | .codeActionResolve => "code_action_resolve"
  | .saveOlean => "save_olean"
  | .goals => "goals"
  | .todo => "todo"
  | .runWith => "run_with"
  | .release => "release"
  | .initWorkspace => "init_workspace"
  | .listWorkspaces => "list_workspaces"
  | .dropWorkspace => "drop_workspace"
  | .stats => "stats"
  | .shutdown => "shutdown"

instance : ToJson Op where
  toJson op := toJson op.key

instance : FromJson Op where
  fromJson?
    | .str "ensure" => .ok .ensure
    | .str "open_docs" => .ok .openDocs
    | .str "cancel" => .ok .cancel
    | .str "update_file" => .ok .updateFile
    | .str "sync_file" => .ok .syncFile
    | .str "refresh_file" => .ok .refreshFile
    | .str "close" => .ok .close
    | .str "run_at" => .ok .runAt
    | .str "hover" => .ok .hover
    | .str "signature_help" => .ok .signatureHelp
    | .str "definition" => .ok .definition
    | .str "references" => .ok .references
    | .str "document_symbols" => .ok .documentSymbols
    | .str "workspace_symbols" => .ok .workspaceSymbols
    | .str "code_action_resolve" => .ok .codeActionResolve
    | .str "save_olean" => .ok .saveOlean
    | .str "goals" => .ok .goals
    | .str "todo" => .ok .todo
    | .str "run_with" => .ok .runWith
    | .str "release" => .ok .release
    | .str "init_workspace" => .ok .initWorkspace
    | .str "list_workspaces" => .ok .listWorkspaces
    | .str "drop_workspace" => .ok .dropWorkspace
    | .str "stats" => .ok .stats
    | .str "shutdown" => .ok .shutdown
    | j => .error s!"expected Beam daemon op, got {j.compress}"

inductive Backend where
  | lean
  | rocq
  deriving Inhabited, BEq, Repr, Ord

instance : ToJson Backend where
  toJson
    | .lean => "lean"
    | .rocq => "rocq"

instance : FromJson Backend where
  fromJson?
    | .str "lean" => .ok .lean
    | .str "rocq" => .ok .rocq
    | j => .error s!"expected backend 'lean' or 'rocq', got {j.compress}"

inductive GoalMode where
  | before
  | after
  deriving Inhabited, BEq, Repr

def GoalMode.key : GoalMode → String
  | .before => "before"
  | .after => "after"

instance : ToJson GoalMode where
  toJson mode := toJson mode.key

instance : FromJson GoalMode where
  fromJson?
    | .str "before" => .ok .before
    | .str "after" => .ok .after
    | j => .error s!"expected goal mode 'before' or 'after', got {j.compress}"

inductive GoalPpFormat where
  | box
  | pp
  | str
  deriving Inhabited, BEq, Repr

def GoalPpFormat.key : GoalPpFormat → String
  | .box => "Box"
  | .pp => "Pp"
  | .str => "Str"

instance : ToJson GoalPpFormat where
  toJson format := toJson format.key

instance : FromJson GoalPpFormat where
  fromJson?
    | .str "Box" => .ok .box
    | .str "Pp" => .ok .pp
    | .str "Str" => .ok .str
    | j => .error s!"expected pp format 'Box', 'Pp', or 'Str', got {j.compress}"

structure Handle where
  workspaceId : WorkspaceId
  backend : Backend
  epoch : Nat
  session : String
  raw : Json
  deriving Inhabited, FromJson, ToJson

/-- Select which user-facing Lean diagnostic severities a request may display. -/
inductive DiagnosticScope where
  | errors
  | all
  deriving Inhabited, BEq, Repr

def DiagnosticScope.key : DiagnosticScope → String
  | .errors => "errors"
  | .all => "all"

instance : ToJson DiagnosticScope where
  toJson scope := toJson scope.key

instance : FromJson DiagnosticScope where
  fromJson?
    | .str "errors" => .ok .errors
    | .str "all" => .ok .all
    | json => .error s!"expected diagnostic scope 'errors' or 'all', got {json.compress}"

/-!
Broker requests keep routing and correlation in one small envelope. Operation-specific data lives in
`RequestPayload`, so a typed request cannot carry fields owned by another operation. The JSON codec
below deliberately keeps the wire shape flat.
-/

structure RequestBackend where
  backend : Backend := .lean

structure RequestFile extends RequestBackend where
  path : String

structure RequestSnapshotFile extends RequestFile where
  snapshot : SnapshotRef

structure RequestPosition extends RequestSnapshotFile where
  line : Nat
  character : Nat

structure SyncFileRequest extends RequestFile where
  diagnosticScope? : Option DiagnosticScope := none
  diagnosticsInResult? : Option Bool := none

structure CloseRequest extends RequestFile where
  diagnosticScope? : Option DiagnosticScope := none
  saveArtifacts? : Option Bool := none

structure RunAtRequest extends RequestPosition where
  text : String
  storeHandle? : Option Bool := none

structure ReferencesRequest extends RequestPosition where
  includeDeclaration? : Option Bool := none

structure WorkspaceSymbolsRequest extends RequestBackend where
  query : String

structure CodeActionResolveRequest extends RequestSnapshotFile where
  codeAction : Lsp.CodeAction

structure SaveOleanRequest extends RequestFile where
  diagnosticScope? : Option DiagnosticScope := none

structure GoalsRequest extends RequestPosition where
  text? : Option String := none
  mode? : Option GoalMode := none
  compact? : Option Bool := none
  ppFormat? : Option GoalPpFormat := none

structure TodoRequest extends RequestPosition where
  endLine : Nat
  endCharacter : Nat
  kinds? : Option (Array Beam.LSP.Todo.TodoKind) := none
  suggest? : Option Beam.LSP.Todo.TodoSuggestMode := none

structure RunWithRequest where
  path : String
  text : String
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  handle : Handle

structure ReleaseRequest where
  path : String
  handle : Handle

structure InitLeanBackendConfig where
  command : String
  plugin : String

structure InitWorkspaceRequest where
  workspaceMode? : Option Beam.Workspace.InitMode := none
  root : String
  lean? : Option InitLeanBackendConfig := none
  rocqCmd? : Option String := none

/-- The fields owned by exactly one broker operation. -/
inductive RequestPayload where
  | ensure (request : RequestBackend)
  | openDocs
  | cancel (cancelRequestId : String)
  | updateFile (request : RequestFile)
  | syncFile (request : SyncFileRequest)
  | refreshFile (request : SyncFileRequest)
  | close (request : CloseRequest)
  | runAt (request : RunAtRequest)
  | hover (request : RequestPosition)
  | signatureHelp (request : RequestPosition)
  | definition (request : RequestPosition)
  | references (request : ReferencesRequest)
  | documentSymbols (request : RequestSnapshotFile)
  | workspaceSymbols (request : WorkspaceSymbolsRequest)
  | codeActionResolve (request : CodeActionResolveRequest)
  | saveOlean (request : SaveOleanRequest)
  | goals (request : GoalsRequest)
  | todo (request : TodoRequest)
  | runWith (request : RunWithRequest)
  | release (request : ReleaseRequest)
  | initWorkspace (request : InitWorkspaceRequest)
  | listWorkspaces
  | dropWorkspace
  | stats
  | shutdown

structure Request where
  payload : RequestPayload
  workspaceId? : Option WorkspaceId := none
  clientRequestId? : Option String := none
  daemonCapability? : Option String := none

def RequestPayload.op : RequestPayload → Op
  | .ensure _ => .ensure
  | .openDocs => .openDocs
  | .cancel _ => .cancel
  | .updateFile _ => .updateFile
  | .syncFile _ => .syncFile
  | .refreshFile _ => .refreshFile
  | .close _ => .close
  | .runAt _ => .runAt
  | .hover _ => .hover
  | .signatureHelp _ => .signatureHelp
  | .definition _ => .definition
  | .references _ => .references
  | .documentSymbols _ => .documentSymbols
  | .workspaceSymbols _ => .workspaceSymbols
  | .codeActionResolve _ => .codeActionResolve
  | .saveOlean _ => .saveOlean
  | .goals _ => .goals
  | .todo _ => .todo
  | .runWith _ => .runWith
  | .release _ => .release
  | .initWorkspace _ => .initWorkspace
  | .listWorkspaces => .listWorkspaces
  | .dropWorkspace => .dropWorkspace
  | .stats => .stats
  | .shutdown => .shutdown

def Request.op (request : Request) : Op :=
  request.payload.op

def Request.ensure
    (backend : Backend := .lean) : Request :=
  { payload := .ensure { backend } }

def Request.openDocs : Request :=
  { payload := .openDocs }

def Request.cancel (cancelRequestId : String) : Request :=
  { payload := .cancel cancelRequestId }

def Request.listWorkspaces : Request :=
  { payload := .listWorkspaces }

def Request.dropWorkspace : Request :=
  { payload := .dropWorkspace }

def Request.stats : Request :=
  { payload := .stats }

def Request.shutdown : Request :=
  { payload := .shutdown }

inductive WorkspaceScope where
  | none
  | optional
  | required
  deriving BEq, Repr

/-- Describe whether a broker operation is process-wide or resolves one workspace. -/
def Op.workspaceScope : Op → WorkspaceScope
  | .listWorkspaces | .shutdown => .none
  | .openDocs | .stats => .optional
  | .cancel
  | .ensure | .updateFile | .syncFile | .refreshFile | .close | .runAt | .hover
  | .signatureHelp | .definition | .references | .documentSymbols | .workspaceSymbols
  | .codeActionResolve | .saveOlean | .goals | .todo | .runWith | .release
  | .initWorkspace | .dropWorkspace => .required

/-- Whether an operation participates in active-request tracking and exact cancellation. -/
def Op.tracksActiveRequest : Op → Bool
  | .cancel | .shutdown => false
  | .ensure | .openDocs | .updateFile | .syncFile | .refreshFile | .close | .runAt | .hover
  | .signatureHelp | .definition | .references | .documentSymbols | .workspaceSymbols
  | .codeActionResolve | .saveOlean | .goals | .todo | .runWith | .release | .initWorkspace
  | .listWorkspaces | .dropWorkspace | .stats => true

private def Op.requestFields (op : Op) : Array String :=
  #["clientRequestId", "daemonCapability"] ++
  (match op.workspaceScope with
  | .none => #[]
  | .optional | .required => #["workspaceId"]) ++
  match op with
  | .ensure | .openDocs | .stats => #[]
  | .cancel => #["cancelRequestId"]
  | .updateFile => #["path"]
  | .syncFile | .refreshFile =>
      #["path", "diagnosticScope", "diagnosticsInResult"]
  | .close => #["path", "diagnosticScope", "saveArtifacts"]
  | .runAt =>
      #["path", "snapshot", "line", "character", "text", "storeHandle"]
  | .hover | .signatureHelp | .definition =>
      #["path", "snapshot", "line", "character"]
  | .references =>
      #["path", "snapshot", "line", "character", "includeDeclaration"]
  | .documentSymbols => #["path", "snapshot"]
  | .workspaceSymbols => #["query"]
  | .codeActionResolve => #["path", "snapshot", "codeAction"]
  | .saveOlean => #["path", "diagnosticScope"]
  | .goals =>
      #[
        "path", "snapshot", "line", "character", "text", "mode", "compact",
        "ppFormat"
      ]
  | .todo =>
      #[
        "path", "snapshot", "line", "character", "endLine", "endCharacter", "kinds",
        "suggest"
      ]
  | .runWith =>
      #["path", "text", "storeHandle", "linear", "handle"]
  | .release => #["path", "handle"]
  | .initWorkspace =>
      #["workspaceMode", "root", "leanCmd", "leanPlugin", "rocqCmd"]
  | .dropWorkspace => #[]
  | .listWorkspaces | .shutdown => #[]

private def Op.acceptsBackendField : Op → Bool
  | .ensure | .updateFile | .syncFile | .refreshFile | .close | .runAt | .hover
  | .signatureHelp | .definition | .references | .documentSymbols | .workspaceSymbols
  | .codeActionResolve | .saveOlean | .goals | .todo => true
  | .runWith | .release
  | .openDocs | .cancel | .initWorkspace | .listWorkspaces | .dropWorkspace | .stats
  | .shutdown => false

private def optionalJsonField [ToJson α] (name : String) : Option α → List (String × Json)
  | some value => [(name, toJson value)]
  | none => []

private def RequestFile.jsonFields (request : RequestFile) : List (String × Json) :=
  [("path", toJson request.path)]

private def RequestSnapshotFile.jsonFields
    (request : RequestSnapshotFile) : List (String × Json) :=
  request.toRequestFile.jsonFields ++ [("snapshot", toJson request.snapshot)]

private def RequestPosition.jsonFields (request : RequestPosition) : List (String × Json) :=
  request.toRequestSnapshotFile.jsonFields ++ [
    ("line", toJson request.line),
    ("character", toJson request.character)
  ]

private def RequestPayload.jsonFields : RequestPayload → List (String × Json)
  | .ensure _ => []
  | .openDocs => []
  | .cancel cancelRequestId => [("cancelRequestId", toJson cancelRequestId)]
  | .updateFile request => request.jsonFields
  | .syncFile request | .refreshFile request =>
      request.toRequestFile.jsonFields ++
      optionalJsonField "diagnosticScope" request.diagnosticScope? ++
      optionalJsonField "diagnosticsInResult" request.diagnosticsInResult?
  | .close request =>
      request.toRequestFile.jsonFields ++
      optionalJsonField "diagnosticScope" request.diagnosticScope? ++
      optionalJsonField "saveArtifacts" request.saveArtifacts?
  | .runAt request =>
      request.toRequestPosition.jsonFields ++
      [("text", toJson request.text)] ++
      optionalJsonField "storeHandle" request.storeHandle?
  | .hover request | .signatureHelp request | .definition request =>
      request.jsonFields
  | .references request =>
      request.toRequestPosition.jsonFields ++
      optionalJsonField "includeDeclaration" request.includeDeclaration?
  | .documentSymbols request => request.jsonFields
  | .workspaceSymbols request =>
      [("query", toJson request.query)]
  | .codeActionResolve request =>
      request.toRequestSnapshotFile.jsonFields ++ [("codeAction", toJson request.codeAction)]
  | .saveOlean request =>
      request.toRequestFile.jsonFields ++
      optionalJsonField "diagnosticScope" request.diagnosticScope?
  | .goals request =>
      request.toRequestPosition.jsonFields ++
      optionalJsonField "text" request.text? ++
      optionalJsonField "mode" request.mode? ++
      optionalJsonField "compact" request.compact? ++
      optionalJsonField "ppFormat" request.ppFormat?
  | .todo request =>
      request.toRequestPosition.jsonFields ++ [
        ("endLine", toJson request.endLine),
        ("endCharacter", toJson request.endCharacter)
      ] ++
      optionalJsonField "kinds" request.kinds? ++
      optionalJsonField "suggest" request.suggest?
  | .runWith request =>
      [("path", toJson request.path), ("text", toJson request.text)] ++
      optionalJsonField "storeHandle" request.storeHandle? ++
      optionalJsonField "linear" request.linear? ++
      [("handle", toJson request.handle)]
  | .release request =>
      [("path", toJson request.path), ("handle", toJson request.handle)]
  | .initWorkspace request =>
      optionalJsonField "workspaceMode" request.workspaceMode? ++
      [("root", toJson request.root)] ++
      (match request.lean? with
      | some lean => [
          ("leanCmd", toJson lean.command),
          ("leanPlugin", toJson lean.plugin)
        ]
      | none => []) ++
      optionalJsonField "rocqCmd" request.rocqCmd?
  | .stats | .listWorkspaces | .dropWorkspace | .shutdown => []

def RequestPayload.backend? : RequestPayload → Option Backend
  | .ensure request => some request.backend
  | .updateFile request => some request.backend
  | .syncFile request | .refreshFile request => some request.backend
  | .close request => some request.backend
  | .runAt request => some request.backend
  | .hover request | .signatureHelp request | .definition request => some request.backend
  | .references request => some request.backend
  | .documentSymbols request => some request.backend
  | .workspaceSymbols request => some request.backend
  | .codeActionResolve request => some request.backend
  | .saveOlean request => some request.backend
  | .goals request => some request.backend
  | .todo request => some request.backend
  | .runWith request => some request.handle.backend
  | .release request => some request.handle.backend
  | .openDocs | .cancel _ | .initWorkspace _ | .listWorkspaces | .dropWorkspace
  | .stats | .shutdown => none

def Request.handle? (request : Request) : Option Handle :=
  match request.payload with
  | .runWith value => some value.handle
  | .release value => some value.handle
  | _ => none

instance : ToJson Request where
  toJson req := Json.mkObj <|
    [("op", toJson req.op)] ++
    (if req.op.acceptsBackendField then
      optionalJsonField "backend" req.payload.backend?
    else
      []) ++
    optionalJsonField "workspaceId" req.workspaceId? ++
    optionalJsonField "clientRequestId" req.clientRequestId? ++
    optionalJsonField "daemonCapability" req.daemonCapability? ++
    req.payload.jsonFields

private def requireRequestJsonFields (op : Op) : Json → Except String Unit
  | .obj fields =>
      let backendFields := if op.acceptsBackendField then #["backend"] else #[]
      let allowed := #["op"] ++ backendFields ++ op.requestFields
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"broker op '{op.key}' accepts no undeclared or unrelated fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"broker request must be an object, got {other.compress}"

/-- Validate the few routing invariants that remain in the common request envelope. -/
def Request.validateFields (req : Request) : Except String Unit := do
  if req.op.workspaceScope == .none && req.workspaceId?.isSome then
    throw s!"broker op '{req.op.key}' accepts no unrelated field 'workspaceId'"
  if let some workspaceId := req.workspaceId? then
    if let some handle := req.handle? then
      if workspaceId != handle.workspaceId then
        throw s!"request workspace '{workspaceId}' does not match handle workspace '{handle.workspaceId}'"

private def optionalField? [FromJson α] (j : Json) (field : String) : Except String (Option α) := do
  match j.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

private def requiredField [FromJson α] (j : Json) (field : String) : Except String α := do
  let value ←
    match j.getObjVal? field with
    | .ok value => pure value
    | .error _ => throw s!"missing '{field}'"
  match fromJson? value with
  | .ok decoded => pure decoded
  | .error err => throw s!"invalid '{field}': {err}"

private def decodeRequestFile
    (j : Json)
    (backend : Backend) : Except String RequestFile := do
  pure {
    backend
    path := ← requiredField j "path"
  }

private def decodeRequestSnapshotFile
    (j : Json)
    (backend : Backend) : Except String RequestSnapshotFile := do
  let target ← decodeRequestFile j backend
  pure {
    toRequestFile := target
    snapshot := ← requiredField j "snapshot"
  }

private def decodeRequestPosition
    (j : Json)
    (backend : Backend) : Except String RequestPosition := do
  let target ← decodeRequestSnapshotFile j backend
  pure {
    toRequestSnapshotFile := target
    line := ← requiredField j "line"
    character := ← requiredField j "character"
  }

instance : FromJson Request where
  fromJson? j := do
    let op ← j.getObjValAs? Op "op"
    requireRequestJsonFields op j
    let backend? ← optionalField? (α := Backend) j "backend"
    let backend := backend?.getD .lean
    let payload ←
      match op with
      | .ensure => pure <| .ensure { backend }
      | .openDocs => pure .openDocs
      | .cancel => pure <| .cancel (← requiredField j "cancelRequestId")
      | .updateFile => .updateFile <$> decodeRequestFile j backend
      | .syncFile | .refreshFile => do
          let target ← decodeRequestFile j backend
          let request : SyncFileRequest := {
            toRequestFile := target
            diagnosticScope? := ← optionalField? (α := DiagnosticScope) j "diagnosticScope"
            diagnosticsInResult? := ← optionalField? (α := Bool) j "diagnosticsInResult"
          }
          pure <| if op == .syncFile then .syncFile request else .refreshFile request
      | .close => do
          let target ← decodeRequestFile j backend
          pure <| .close {
            toRequestFile := target
            diagnosticScope? := ← optionalField? (α := DiagnosticScope) j "diagnosticScope"
            saveArtifacts? := ← optionalField? (α := Bool) j "saveArtifacts"
          }
      | .runAt => do
          let target ← decodeRequestPosition j backend
          pure <| .runAt {
            toRequestPosition := target
            text := ← requiredField j "text"
            storeHandle? := ← optionalField? (α := Bool) j "storeHandle"
          }
      | .hover | .signatureHelp | .definition => do
          let target ← decodeRequestPosition j backend
          pure <|
            if op == .hover then .hover target
            else if op == .signatureHelp then .signatureHelp target
            else .definition target
      | .references => do
          let target ← decodeRequestPosition j backend
          pure <| .references {
            toRequestPosition := target
            includeDeclaration? := ← optionalField? (α := Bool) j "includeDeclaration"
          }
      | .documentSymbols => .documentSymbols <$> decodeRequestSnapshotFile j backend
      | .workspaceSymbols =>
          pure <| .workspaceSymbols {
            backend
            query := ← requiredField j "query"
          }
      | .codeActionResolve => do
          let target ← decodeRequestSnapshotFile j backend
          pure <| .codeActionResolve {
            toRequestSnapshotFile := target
            codeAction := ← requiredField j "codeAction"
          }
      | .saveOlean => do
          let target ← decodeRequestFile j backend
          pure <| .saveOlean {
            toRequestFile := target
            diagnosticScope? := ← optionalField? (α := DiagnosticScope) j "diagnosticScope"
          }
      | .goals => do
          let target ← decodeRequestPosition j backend
          pure <| .goals {
            toRequestPosition := target
            text? := ← optionalField? (α := String) j "text"
            mode? := ← optionalField? (α := GoalMode) j "mode"
            compact? := ← optionalField? (α := Bool) j "compact"
            ppFormat? := ← optionalField? (α := GoalPpFormat) j "ppFormat"
          }
      | .todo => do
          let target ← decodeRequestPosition j backend
          pure <| .todo {
            toRequestPosition := target
            endLine := ← requiredField j "endLine"
            endCharacter := ← requiredField j "endCharacter"
            kinds? := ← optionalField? (α := Array Beam.LSP.Todo.TodoKind) j "kinds"
            suggest? := ← optionalField? (α := Beam.LSP.Todo.TodoSuggestMode) j "suggest"
          }
      | .runWith => do
          let handle ← requiredField j "handle"
          pure <| .runWith {
            path := ← requiredField j "path"
            text := ← requiredField j "text"
            storeHandle? := ← optionalField? (α := Bool) j "storeHandle"
            linear? := ← optionalField? (α := Bool) j "linear"
            handle
          }
      | .release => do
          let handle ← requiredField j "handle"
          pure <| .release {
            path := ← requiredField j "path"
            handle
          }
      | .initWorkspace =>
          let leanCmd? ← optionalField? (α := String) j "leanCmd"
          let leanPlugin? ← optionalField? (α := String) j "leanPlugin"
          let lean? ←
            match leanCmd?, leanPlugin? with
            | none, none => pure none
            | some command, some plugin => pure <| some { command, plugin }
            | some _, none => throw "'leanCmd' requires 'leanPlugin'"
            | none, some _ => throw "'leanPlugin' requires 'leanCmd'"
          pure <| .initWorkspace {
            workspaceMode? := ← optionalField? (α := Beam.Workspace.InitMode) j "workspaceMode"
            root := ← requiredField j "root"
            lean?
            rocqCmd? := ← optionalField? (α := String) j "rocqCmd"
          }
      | .listWorkspaces => pure .listWorkspaces
      | .dropWorkspace => pure .dropWorkspace
      | .stats => pure .stats
      | .shutdown => pure .shutdown
    let request : Request := {
      payload
      workspaceId? := ← optionalField? (α := WorkspaceId) j "workspaceId"
      clientRequestId? := ← optionalField? (α := String) j "clientRequestId"
      daemonCapability? := ← optionalField? (α := String) j "daemonCapability"
    }
    request.validateFields
    pure request

structure Error where
  code : String
  message : String := ""
  data? : Option Json := none
  deriving Inhabited, FromJson, ToJson

structure SyncFileProgress where
  updates : Nat := 0
  done : Bool := true
  /-- Earliest one-based line in Lean's current processing ranges, when any range is active. -/
  rangeStartLine? : Option Nat := none
  /-- One-based upper line bound from Lean's processing ranges; not the source file line count. -/
  rangeEndLine? : Option Nat := none
  deriving FromJson, ToJson, BEq, Repr

namespace SyncFileProgress

def rangeText? (progress : SyncFileProgress) : Option String :=
  match progress.rangeStartLine?, progress.rangeEndLine? with
  | some startLine, some endLine => some s!"range={startLine}..{endLine}"
  | some startLine, none => some s!"rangeStartLine={startLine}"
  | none, some endLine => some s!"rangeEndLine={endLine}"
  | none, none => none

def displayDetails (progress : SyncFileProgress) (includeDoneTrue : Bool := true) : String :=
  let rangePrefix :=
    match progress.rangeText? with
    | some text => text ++ " "
    | none => ""
  let doneSuffix :=
    if progress.done then
      if includeDoneTrue then
        " done=true"
      else
        ""
    else
      " done=false"
  s!"{rangePrefix}updates={progress.updates}{doneSuffix}"

end SyncFileProgress

private def requireOnlyJsonFields
    (label : String)
    (allowed : Array String) : Json → Except String Unit
  | .obj fields =>
      let unexpected := fields.foldl (init := #[]) fun unexpected field _ =>
        if allowed.contains field then unexpected else unexpected.push field
      unless unexpected.isEmpty do
        throw s!"{label} accepts no undeclared fields: {String.intercalate ", " unexpected.toList}"
  | other => throw s!"{label} must be an object, got {other.compress}"

structure SyncDiagnosticCounts where
  error : Nat := 0
  warning : Nat := 0
  information : Nat := 0
  hint : Nat := 0
  unknown : Nat := 0
  deriving Inhabited, BEq, Repr

def SyncDiagnosticCounts.total (counts : SyncDiagnosticCounts) : Nat :=
  counts.error + counts.warning + counts.information + counts.hint + counts.unknown

instance : ToJson SyncDiagnosticCounts where
  toJson counts := Json.mkObj [
    ("error", toJson counts.error),
    ("warning", toJson counts.warning),
    ("information", toJson counts.information),
    ("hint", toJson counts.hint),
    ("unknown", toJson counts.unknown),
    ("total", toJson counts.total)
  ]

instance : FromJson SyncDiagnosticCounts where
  fromJson? json := do
    requireOnlyJsonFields "sync diagnostic counts"
      #["error", "warning", "information", "hint", "unknown", "total"] json
    let errorCount ← json.getObjValAs? Nat "error"
    let warning ← json.getObjValAs? Nat "warning"
    let information ← json.getObjValAs? Nat "information"
    let hint ← json.getObjValAs? Nat "hint"
    let unknown ← json.getObjValAs? Nat "unknown"
    let total ← json.getObjValAs? Nat "total"
    let severityTotal := errorCount + warning + information + hint + unknown
    unless total == severityTotal do
      throw s!"sync diagnostic count total {total} does not match severity sum {severityTotal}"
    pure {
      error := errorCount
      warning
      information
      hint
      unknown
    }

structure SyncBlockingDiagnostic where
  range : Lsp.Range
  severity? : Option Lsp.DiagnosticSeverity := some .error
  message : String
  saveBlocking : Bool := false
  completionBlocking : Bool := false
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncBlockingDiagnostic where
  fromJson? json := do
    requireOnlyJsonFields "sync blocking diagnostic"
      #["range", "severity", "message", "saveBlocking", "completionBlocking"] json
    let range ← json.getObjValAs? Lsp.Range "range"
    let severity? ← optionalField? (α := Lsp.DiagnosticSeverity) json "severity"
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      range
      severity?
      message
      saveBlocking := saveBlocking?.getD false
      completionBlocking := completionBlocking?.getD false
    }

structure SyncBlockingCommandMessage where
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncBlockingCommandMessage where
  fromJson? json := do
    requireOnlyJsonFields "sync blocking message"
      #["message", "saveBlocking", "completionBlocking"] json
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      message
      saveBlocking := saveBlocking?.getD true
      completionBlocking := completionBlocking?.getD false
    }

structure SyncResultReadiness where
  saveReady : Bool := true
  reason : String := "ok"
  /-- Number of save-blocking errors, including command messages that have no diagnostic. -/
  blockingErrorCount : Nat := 0
  blockingDiagnostics : Array SyncBlockingDiagnostic := #[]
  blockingMessages : Array SyncBlockingCommandMessage := #[]
  deriving Inhabited, ToJson, BEq, Repr

instance : FromJson SyncResultReadiness where
  fromJson? json := do
    requireOnlyJsonFields "sync readiness"
      #["saveReady", "reason", "blockingErrorCount", "blockingDiagnostics", "blockingMessages"]
      json
    let saveReady ← json.getObjValAs? Bool "saveReady"
    let reason ← json.getObjValAs? String "reason"
    let blockingErrorCount ← json.getObjValAs? Nat "blockingErrorCount"
    let blockingDiagnostics ←
      json.getObjValAs? (Array SyncBlockingDiagnostic) "blockingDiagnostics"
    let blockingMessages ←
      json.getObjValAs? (Array SyncBlockingCommandMessage) "blockingMessages"
    pure {
      saveReady
      reason
      blockingErrorCount
      blockingDiagnostics
      blockingMessages
    }

structure StreamDiagnostic where
  path : String
  uri : String
  snapshot? : Option SnapshotRef := none
  severity? : Option Lsp.DiagnosticSeverity := none
  range : Lsp.Range
  message : String
  saveBlocking? : Option Bool := none
  completionBlocking : Bool := false
  deriving Inhabited, ToJson

instance : FromJson StreamDiagnostic where
  fromJson? json := do
    requireOnlyJsonFields "stream diagnostic"
      #[
        "path", "uri", "snapshot", "severity", "range", "message", "saveBlocking",
        "completionBlocking"
      ] json
    let path ← json.getObjValAs? String "path"
    let uri ← json.getObjValAs? String "uri"
    let snapshot? ← optionalField? (α := SnapshotRef) json "snapshot"
    let severity? ← optionalField? (α := Lsp.DiagnosticSeverity) json "severity"
    let range ← json.getObjValAs? Lsp.Range "range"
    let message ← json.getObjValAs? String "message"
    let saveBlocking? ← optionalField? (α := Bool) json "saveBlocking"
    let completionBlocking? ← optionalField? (α := Bool) json "completionBlocking"
    pure {
      path
      uri
      snapshot?
      severity?
      range
      message
      saveBlocking?
      completionBlocking := completionBlocking?.getD false
    }

structure SyncResultDiagnostics where
  counts : SyncDiagnosticCounts := {}
  items? : Option (Array StreamDiagnostic) := none
  deriving Inhabited

instance : ToJson SyncResultDiagnostics where
  toJson diagnostics :=
    Json.mkObj <|
      [("counts", toJson diagnostics.counts)] ++
      match diagnostics.items? with
      | some items => [("items", toJson items)]
      | none => []

instance : FromJson SyncResultDiagnostics where
  fromJson? json := do
    requireOnlyJsonFields "sync diagnostics" #["counts", "items"] json
    let counts ← json.getObjValAs? SyncDiagnosticCounts "counts"
    let items? ← optionalField? (α := Array StreamDiagnostic) json "items"
    pure { counts, items? }

structure SyncFileResult where
  path : String
  snapshot : SnapshotRef
  diagnostics : SyncResultDiagnostics := {}
  readiness : SyncResultReadiness := {}

structure UpdateFileResult where
  snapshot : SnapshotRef
  changed : Bool := false
  deriving FromJson, ToJson, BEq, Repr

structure CancelResult where
  cancelled : Bool
  deriving FromJson, ToJson

structure CodeActionResolveResult where
  snapshot : SnapshotRef
  codeAction : Lsp.CodeAction
  deriving FromJson, ToJson

instance : ToJson SyncFileResult where
  toJson result :=
    Json.mkObj <|
      [
        ("path", toJson result.path),
        ("snapshot", toJson result.snapshot),
        ("diagnostics", toJson result.diagnostics),
        ("readiness", toJson result.readiness)
      ]

instance : FromJson SyncFileResult where
  fromJson? json := do
    requireOnlyJsonFields "sync result" #["path", "snapshot", "diagnostics", "readiness"] json
    let path ← json.getObjValAs? String "path"
    let snapshot ← json.getObjValAs? SnapshotRef "snapshot"
    let diagnostics ← json.getObjValAs? SyncResultDiagnostics "diagnostics"
    let readiness ← json.getObjValAs? SyncResultReadiness "readiness"
    pure {
      path
      snapshot
      diagnostics
      readiness
    }

/-- Stable broker result for a successfully published Lean checkpoint. -/
structure SaveOleanResult where
  module : String
  sourceHash : String
  olean : String
  ilean : String
  c : String
  trace : String
  oleanServer? : Option String := none
  oleanPrivate? : Option String := none
  ir? : Option String := none
  bc? : Option String := none
  sync : SyncFileResult

def SaveOleanResult.path (result : SaveOleanResult) : String :=
  result.sync.path

def SaveOleanResult.snapshot (result : SaveOleanResult) : SnapshotRef :=
  result.sync.snapshot

instance : ToJson SaveOleanResult where
  toJson result :=
    Json.mkObj <|
      [
        ("path", toJson result.path),
        ("module", toJson result.module),
        ("snapshot", toJson result.snapshot),
        ("sourceHash", toJson result.sourceHash),
        ("olean", toJson result.olean),
        ("ilean", toJson result.ilean),
        ("c", toJson result.c),
        ("trace", toJson result.trace)
      ] ++
      (match result.oleanServer? with
      | some path => [("oleanServer", toJson path)]
      | none => []) ++
      (match result.oleanPrivate? with
      | some path => [("oleanPrivate", toJson path)]
      | none => []) ++
      (match result.ir? with
      | some path => [("ir", toJson path)]
      | none => []) ++
      (match result.bc? with
      | some path => [("bc", toJson path)]
      | none => []) ++
      [("sync", toJson result.sync)]

instance : FromJson SaveOleanResult where
  fromJson? json := do
    requireOnlyJsonFields "save result" #[
      "path", "module", "snapshot", "sourceHash", "olean", "ilean", "c", "trace",
      "oleanServer", "oleanPrivate", "ir", "bc", "sync"
    ] json
    let path ← json.getObjValAs? String "path"
    let module ← json.getObjValAs? String "module"
    let snapshot ← json.getObjValAs? SnapshotRef "snapshot"
    let sourceHash ← json.getObjValAs? String "sourceHash"
    let olean ← json.getObjValAs? String "olean"
    let ilean ← json.getObjValAs? String "ilean"
    let c ← json.getObjValAs? String "c"
    let trace ← json.getObjValAs? String "trace"
    let oleanServer? ← optionalField? (α := String) json "oleanServer"
    let oleanPrivate? ← optionalField? (α := String) json "oleanPrivate"
    let ir? ← optionalField? (α := String) json "ir"
    let bc? ← optionalField? (α := String) json "bc"
    let sync ← json.getObjValAs? SyncFileResult "sync"
    unless path == sync.path do
      throw s!"save result path '{path}' does not match sync path '{sync.path}'"
    unless snapshot == sync.snapshot do
      throw s!"save result snapshot {snapshot} does not match sync snapshot {sync.snapshot}"
    pure {
      module
      sourceHash
      olean
      ilean
      c
      trace
      oleanServer?
      oleanPrivate?
      ir?
      bc?
      sync
    }

/-- Stable broker result for an artifact save followed by closing the mirrored document. -/
structure CloseSaveResult where
  saved : SaveOleanResult

def CloseSaveResult.closed (_ : CloseSaveResult) : Bool :=
  true

instance : ToJson CloseSaveResult where
  toJson result := Json.mkObj [
    ("closed", toJson result.closed),
    ("saved", toJson result.saved)
  ]

instance : FromJson CloseSaveResult where
  fromJson? json := do
    requireOnlyJsonFields "close-save result" #["closed", "saved"] json
    let closed ← json.getObjValAs? Bool "closed"
    let saved ← json.getObjValAs? SaveOleanResult "saved"
    unless closed do
      throw "close-save result requires 'closed' to be true"
    pure { saved }

/-- A broker failure together with observations collected before the request failed. -/
structure ResponseFailure where
  error : Error
  fileProgress? : Option SyncFileProgress := none
  deriving Inhabited

/-- A successful broker payload or a typed broker failure. -/
inductive Response where
  | successResult (result : Json) (fileProgress? : Option SyncFileProgress)
  | errorResult (failure : ResponseFailure)
  deriving Inhabited

def Response.ok : Response → Bool
  | .successResult .. => true
  | .errorResult .. => false

def Response.result? : Response → Option Json
  | .successResult result .. => some result
  | .errorResult .. => none

def Response.error? : Response → Option Error
  | .successResult .. => none
  | .errorResult failure => some failure.error

def Response.fileProgress? : Response → Option SyncFileProgress
  | .successResult _ fileProgress? => fileProgress?
  | .errorResult failure => failure.fileProgress?

instance : ToJson Response where
  toJson resp :=
    let payloadFields :=
      match resp with
      | .successResult result _ => [("ok", toJson true), ("result", result)]
      | .errorResult failure => [("ok", toJson false), ("error", toJson failure.error)]
    Json.mkObj <| payloadFields ++
      (match resp.fileProgress? with
      | some progress => [("fileProgress", toJson progress)]
      | none => [])

instance : FromJson Response where
  fromJson? j := do
    requireOnlyJsonFields "Beam daemon response"
      #["ok", "result", "error", "fileProgress"] j
    let result? ← optionalField? (α := Json) j "result"
    let error? ← optionalField? (α := Error) j "error"
    let fileProgress? ← optionalField? (α := SyncFileProgress) j "fileProgress"
    let ok ← j.getObjValAs? Bool "ok"
    if ok then
      match result?, error? with
      | some result, none => pure <| .successResult result fileProgress?
      | _, some _ => throw "invalid Beam daemon response: ok=true must not include 'error'"
      | none, none => throw "invalid Beam daemon response: ok=true must include 'result'"
    else
      match result?, error? with
      | none, some error => pure <| .errorResult { error, fileProgress? }
      | some _, _ => throw "invalid Beam daemon response: ok=false must not include 'result'"
      | none, none => throw "invalid Beam daemon response: ok=false must include 'error'"

def syncBarrierIncompleteCode : String :=
  "syncBarrierIncomplete"

def saveTraceStaleCode : String :=
  "saveTraceStale"

def saveUnsupportedSetupCode : String :=
  "saveUnsupportedSetup"

def saveTargetNotModuleCode : String :=
  "saveTargetNotModule"

private inductive StreamKind where
  | response
  | fileProgress
  | diagnostic

private def StreamKind.key : StreamKind → String
  | .response => "response"
  | .fileProgress => "fileProgress"
  | .diagnostic => "diagnostic"

private instance : ToJson StreamKind where
  toJson kind := toJson kind.key

private instance : FromJson StreamKind where
  fromJson?
    | .str "response" => .ok .response
    | .str "fileProgress" => .ok .fileProgress
    | .str "diagnostic" => .ok .diagnostic
    | j => .error s!"expected Beam daemon stream kind, got {j.compress}"

/-- One decoded broker stream event with exactly the payload selected by its wire `kind`. -/
inductive StreamMessage where
  | response (clientRequestId? : Option String) (response : Response)
  | fileProgress (clientRequestId? : Option String) (progress : SyncFileProgress)
  | diagnostic (clientRequestId? : Option String) (diagnostic : StreamDiagnostic)
  deriving Inhabited

def StreamMessage.clientRequestId? : StreamMessage → Option String
  | .response clientRequestId? _
  | .fileProgress clientRequestId? _
  | .diagnostic clientRequestId? _ => clientRequestId?

instance : ToJson StreamMessage where
  toJson
    | .response clientRequestId? resp =>
        Json.mkObj <| [
          ("kind", toJson StreamKind.response),
          ("payload", toJson resp)
        ] ++ optionalJsonField "clientRequestId" clientRequestId?
    | .fileProgress clientRequestId? progress =>
        Json.mkObj <| [
          ("kind", toJson StreamKind.fileProgress),
          ("payload", toJson progress)
        ] ++ optionalJsonField "clientRequestId" clientRequestId?
    | .diagnostic clientRequestId? streamDiagnostic =>
        Json.mkObj <| [
          ("kind", toJson StreamKind.diagnostic),
          ("payload", toJson streamDiagnostic)
        ] ++ optionalJsonField "clientRequestId" clientRequestId?

private def decodeStreamPayload [FromJson α]
    (kind : StreamKind)
    (payload : Json) : Except String α :=
  (fromJson? payload).mapError fun err =>
    s!"invalid Beam {kind.key} stream payload: {err}"

instance : FromJson StreamMessage where
  fromJson? json := do
    requireOnlyJsonFields "Beam stream message"
      #["kind", "payload", "clientRequestId"] json
    let kind ← json.getObjValAs? StreamKind "kind"
    let payload ← json.getObjVal? "payload"
    let clientRequestId? ← optionalField? (α := String) json "clientRequestId"
    match kind with
    | .response =>
        pure <| .response clientRequestId? (← decodeStreamPayload kind payload)
    | .fileProgress =>
        pure <| .fileProgress clientRequestId? (← decodeStreamPayload kind payload)
    | .diagnostic =>
        pure <| .diagnostic clientRequestId? (← decodeStreamPayload kind payload)

def Response.success (result : Json) : Response :=
  .successResult result none

def ResponseFailure.toResponse (failure : ResponseFailure) : Response :=
  .errorResult failure

def Response.withFileProgress
    (resp : Response)
    (fileProgress : SyncFileProgress) : Response :=
  match resp with
  | .successResult result _ =>
      .successResult result (some fileProgress)
  | .errorResult failure =>
      .errorResult { failure with fileProgress? := some fileProgress }

def Response.withOptionalFileProgress
    (resp : Response)
    (fileProgress? : Option SyncFileProgress) : Response :=
  match fileProgress? with
  | some fileProgress => resp.withFileProgress fileProgress
  | none => resp

def ResponseFailure.withOptionalFileProgress
    (failure : ResponseFailure)
    (fileProgress? : Option SyncFileProgress) : ResponseFailure :=
  match fileProgress? with
  | some fileProgress => { failure with fileProgress? := some fileProgress }
  | none => failure

def Request.resolvedWorkspaceId? (req : Request) : Option WorkspaceId :=
  match req.handle?, req.workspaceId? with
  | some handle, _ => some handle.workspaceId
  | none, some workspaceId => some workspaceId
  | none, none => none

def Request.requireWorkspaceId (req : Request) : Except String WorkspaceId := do
  let some workspaceId := req.resolvedWorkspaceId?
    | throw "workspaceId is required"
  unless Beam.Workspace.validWorkspaceId workspaceId do
    throw "workspaceId must be non-empty"
  pure workspaceId

end Beam.Broker
