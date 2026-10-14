/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.CodeActions
import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Lean.Elab.Term
import Lean.Util.Sorry
import Beam.LSP.Lib.Diagnostics
import Beam.LSP.Lib.Goal
import Beam.LSP.Lib.Request

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
Agent-oriented todo inspection over a Lean document range.

This family owns `$/lean/todo`, including todo item wire types and optional runAt text
suggestions. It shares goal rendering with `RunAt`/`Goals` and worker diagnostics with
`Save`.
-/
namespace Beam.LSP.Todo

/-- JSON-RPC method name for agent-oriented todo inspection over a document range. -/
def method : String := "$/lean/todo"

/-- Kinds of agent-actionable todo items reported by `$/lean/todo`. -/
inductive TodoKind where
  | sorry
  | hole
  | diagnostic
  | codeAction
  | incompleteProof
  deriving BEq, Repr

def TodoKind.key : TodoKind → String
  | .sorry => "sorry"
  | .hole => "hole"
  | .diagnostic => "diagnostic"
  | .codeAction => "code_action"
  | .incompleteProof => "incomplete_proof"

def TodoKind.all : Array TodoKind :=
  #[.sorry, .hole, .diagnostic, .codeAction, .incompleteProof]

def TodoKind.allKeys : Array String :=
  TodoKind.all.map TodoKind.key

instance : ToJson TodoKind where
  toJson kind := toJson kind.key

instance : FromJson TodoKind where
  fromJson?
    | .str "sorry" => .ok .sorry
    | .str "hole" => .ok .hole
    | .str "diagnostic" => .ok .diagnostic
    | .str "code_action" => .ok .codeAction
    | .str "incomplete_proof" => .ok .incompleteProof
    | j => .error s!"expected todo kind, got {j.compress}"

/-- Suggestion budget for `$/lean/todo`. -/
inductive TodoSuggestMode where
  | none
  | basic
  deriving BEq, Repr

def TodoSuggestMode.key : TodoSuggestMode → String
  | .none => "none"
  | .basic => "basic"

def TodoSuggestMode.all : Array TodoSuggestMode :=
  #[.none, .basic]

def TodoSuggestMode.allKeys : Array String :=
  TodoSuggestMode.all.map TodoSuggestMode.key

instance : ToJson TodoSuggestMode where
  toJson mode := toJson mode.key

instance : FromJson TodoSuggestMode where
  fromJson?
    | .str "none" => .ok .none
    | .str "basic" => .ok .basic
    | j => .error s!"expected todo suggest mode 'none' or 'basic', got {j.compress}"

/-- Request payload for agent-oriented todo inspection over a document range. -/
structure TodoParams where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  range : Lean.Lsp.Range
  kinds? : Option (Array TodoKind) := none
  suggest? : Option TodoSuggestMode := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource TodoParams where
  fileSource p := p.textDocument.uri

/-- One normalized agent-facing todo item. -/
structure TodoItem where
  kind : TodoKind
  range : Lean.Lsp.Range
  runAtPosition : Lean.Lsp.Position
  runAtText? : Option String := none
  message? : Option String := none
  severity? : Option Lean.Lsp.DiagnosticSeverity := none
  diagnostic? : Option Lean.Lsp.Diagnostic := none
  codeAction? : Option Lean.Lsp.CodeAction := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

/-- Typed success payload for `$/lean/todo`. -/
structure TodoResult where
  version : Nat
  range : Lean.Lsp.Range
  items : Array TodoItem := #[]
  deriving FromJson, ToJson

private def positionLE (a b : Lsp.Position) : Bool :=
  a.line < b.line || (a.line == b.line && a.character <= b.character)

private def positionLT (a b : Lsp.Position) : Bool :=
  a.line < b.line || (a.line == b.line && a.character < b.character)

private def samePosition (a b : Lsp.Position) : Bool :=
  a.line == b.line && a.character == b.character

private def rangeOverlaps (a b : Lsp.Range) : Bool :=
  positionLT a.start b.«end» && positionLT b.start a.«end»

private def rangeIsEmpty (range : Lsp.Range) : Bool :=
  samePosition range.start range.«end»

private def positionInRangeClosed (position : Lsp.Position) (range : Lsp.Range) : Bool :=
  positionLE range.start position && positionLE position range.«end»

/--
Todo queries use half-open range overlap for non-empty ranges. Empty query ranges are cursor-style
point queries, and match todo items whose range contains the point, including the item's end
position. Including the end makes the point query compose with items whose `runAtPosition` is just
after the syntax that produced the todo, such as incomplete proof tactic ranges.
-/
private def rangeMatchesQuery (item requested : Lsp.Range) : Bool :=
  if rangeIsEmpty requested then
    positionInRangeClosed requested.start item
  else
    rangeOverlaps item requested

private def rawLE (a b : String.Pos.Raw) : Bool :=
  a.byteIdx <= b.byteIdx

private def rawLT (a b : String.Pos.Raw) : Bool :=
  a.byteIdx < b.byteIdx

private def syntaxRangeIsEmpty (range : Syntax.Range) : Bool :=
  range.start.byteIdx == range.stop.byteIdx

private def rawInSyntaxRangeClosed (position : String.Pos.Raw) (range : Syntax.Range) : Bool :=
  rawLE range.start position && rawLE position range.stop

private def syntaxRangeOverlaps (a b : Syntax.Range) : Bool :=
  rawLT a.start b.stop && rawLT b.start a.stop

private def syntaxRangeMatchesQuery (item requested : Syntax.Range) : Bool :=
  if syntaxRangeIsEmpty requested then
    rawInSyntaxRangeClosed requested.start item
  else
    syntaxRangeOverlaps item requested

private def lspRangeToSyntaxRange (text : FileMap) (range : Lsp.Range) : Syntax.Range :=
  {
    start := text.lspPosToUtf8Pos range.start
    stop := text.lspPosToUtf8Pos range.«end»
  }

private def validateRange (range : Lsp.Range) : RequestM Unit := do
  validatePosition range.start
  validatePosition range.«end»
  unless positionLE range.start range.«end» do
    throw <| RequestError.invalidParams s!"range start {range.start} is after end {range.«end»}"

private def wantsKind (kinds? : Option (Array TodoKind)) (kind : TodoKind) : Bool :=
  match kinds? with
  | none => true
  | some kinds => kinds.isEmpty || kinds.contains kind

private def shouldSuggestBasic (mode? : Option TodoSuggestMode) : Bool :=
  mode?.getD .basic == .basic

private def todoItemLt (a b : TodoItem) : Bool :=
  if positionLT a.range.start b.range.start then
    true
  else if positionLT b.range.start a.range.start then
    false
  else if positionLT a.range.«end» b.range.«end» then
    true
  else if positionLT b.range.«end» a.range.«end» then
    false
  else
    a.kind.key < b.kind.key

private def mkSimpleItem
    (kind : TodoKind)
    (range : Lsp.Range)
    (message? : Option String := none)
    (severity? : Option Lsp.DiagnosticSeverity := none)
    (runAtText? : Option String := none) : TodoItem :=
  {
    kind
    range
    runAtPosition := range.start
    runAtText?
    message?
    severity?
  }

private def isIdentBoundaryChar (c : Char) : Bool :=
  c.isAlphanum || c == '_' || c == '\'' || c == '.'

private def startsWithAt (source token : String) (pos : String.Pos.Raw) : Bool :=
  String.Pos.Raw.substrEq source pos token 0 token.utf8ByteSize

private def rangeTextEq (source text : String) (range : Syntax.Range) : Bool :=
  range.stop.byteIdx == range.start.byteIdx + text.utf8ByteSize &&
    startsWithAt source text range.start

-- Structural proof markers can carry unsolved goals after them, but agents should act at the
-- tactic that left the goals open, not at the enclosing `by` or branch bullet.
private def isStructuralProofMarker (source : String) (range : Syntax.Range) : Bool :=
  rangeTextEq source "by" range || rangeTextEq source "·" range

private def tokenHasIdentifierBoundaries
    (source : String)
    (startPos : String.Pos.Raw)
    (endPos : String.Pos.Raw) : Bool :=
  let beforeOk :=
    startPos.byteIdx == 0 ||
      !isIdentBoundaryChar ((startPos.prev source).get source)
  let afterOk :=
    endPos.atEnd source ||
      !isIdentBoundaryChar (endPos.get source)
  beforeOk && afterOk

private def remainingBlockCommentDepth? (depth : Nat) : Option Nat :=
  if depth <= 1 then none else some (depth - 1)

private partial def advancePastLineComment (source : String) (pos : String.Pos.Raw) :
    String.Pos.Raw :=
  if pos.atEnd source then
    pos
  else
    let next := pos.next source
    if pos.get source == '\n' then
      next
    else
      advancePastLineComment source next

private partial def advancePastBlockComment
    (source : String)
    (pos : String.Pos.Raw)
    (depth : Nat) : String.Pos.Raw :=
  if pos.atEnd source then
    pos
  else if startsWithAt source "/-" pos then
    advancePastBlockComment source (pos + "/-") (depth + 1)
  else if startsWithAt source "-/" pos then
    let next := pos + "-/"
    match remainingBlockCommentDepth? depth with
    | none => next
    | some depth => advancePastBlockComment source next depth
  else
    advancePastBlockComment source (pos.next source) depth

private partial def advancePastStringLiteral (source : String) (pos : String.Pos.Raw) :
    String.Pos.Raw :=
  if pos.atEnd source then
    pos
  else
    let c := pos.get source
    let next := pos.next source
    if c == '\\' then
      if next.atEnd source then next else advancePastStringLiteral source (next.next source)
    else if c == '"' then
      next
    else
      advancePastStringLiteral source next

private partial def advancePastQuotedIdentifier (source : String) (pos : String.Pos.Raw) :
    String.Pos.Raw :=
  if pos.atEnd source then
    pos
  else
    let next := pos.next source
    if pos.get source == '»' then
      next
    else
      advancePastQuotedIdentifier source next

/-
Sorry detection deliberately combines three overlapping signals:

* A lightweight source scan keeps working when later commands fail to elaborate. It skips comments,
  strings, and quoted identifiers, but it is still only a lexical fallback.
* A syntax-tree walk records actual `Parser.Term.sorry` nodes from Lean's parser.
* An info-tree pass records terms Lean elaborated as user-written non-synthetic sorries.

The final simplification pass deduplicates the usual overlap. Keeping the signals separate gives
agents useful todos even for partially broken files while retaining parser/elaborator confirmation
when Lean gets that far.
-/
private partial def collectSourceTokenSorries
    (text : FileMap)
    (requestedRange : Syntax.Range)
    (requestedLspRange : Lsp.Range)
    (pos : String.Pos.Raw := 0)
    (items : Array TodoItem := #[]) : Array TodoItem :=
  let source := text.source
  if pos.atEnd source then
    items
  else
    let token := "sorry"
    if startsWithAt source "--" pos then
      collectSourceTokenSorries text requestedRange requestedLspRange
        (advancePastLineComment source (pos + "--")) items
    else if startsWithAt source "/-" pos then
      collectSourceTokenSorries text requestedRange requestedLspRange
        (advancePastBlockComment source (pos + "/-") 1) items
    else if pos.get source == '"' then
      collectSourceTokenSorries text requestedRange requestedLspRange
        (advancePastStringLiteral source (pos.next source)) items
    else if pos.get source == '«' then
      collectSourceTokenSorries text requestedRange requestedLspRange
        (advancePastQuotedIdentifier source (pos.next source)) items
    else
      let endPos := pos + token
      let range : Syntax.Range := { start := pos, stop := endPos }
      let lspRange := range.toLspRange text
      let items :=
        if startsWithAt source token pos &&
            tokenHasIdentifierBoundaries source pos endPos &&
            (syntaxRangeMatchesQuery range requestedRange ||
              rangeMatchesQuery lspRange requestedLspRange)
        then
          items.push <| mkSimpleItem
            .sorry
            lspRange
            (message? := some "syntactic sorry")
        else
          items
      collectSourceTokenSorries text requestedRange requestedLspRange (pos.next source) items

private def sameRange (a b : Lsp.Range) : Bool :=
  a.start == b.start && a.«end» == b.«end»

private def sameTodoLocation (a b : TodoItem) : Bool :=
  a.kind == b.kind && sameRange a.range b.range

private def includesRange (outer inner : Lsp.Range) : Bool :=
  positionLE outer.start inner.start && positionLE inner.«end» outer.«end»

private def strictlyIncludesRange (outer inner : Lsp.Range) : Bool :=
  includesRange outer inner && !sameRange outer inner

private def isCoveredIncompleteProofItem (items : Array TodoItem) (item : TodoItem) : Bool :=
  item.kind == .incompleteProof && items.any fun other =>
    other.kind == .incompleteProof &&
      strictlyIncludesRange item.range other.range &&
      item.runAtPosition == other.runAtPosition

private def dedupeTodoItems (items : Array TodoItem) : Array TodoItem :=
  items.foldl (init := #[]) fun acc item =>
    if acc.any (sameTodoLocation item) then acc else acc.push item

private def simplifyTodoItems (items : Array TodoItem) : Array TodoItem :=
  let items := dedupeTodoItems items
  items.filter fun item => !isCoveredIncompleteProofItem items item

private partial def collectSyntaxSorries
    (text : FileMap)
    (requestedRange : Syntax.Range)
    (requestedLspRange : Lsp.Range)
    (stx : Syntax)
    (items : Array TodoItem) : Array TodoItem :=
  let items :=
    match stx.getRange? (canonicalOnly := false) with
    | some range =>
        let lspRange := range.toLspRange text
        if stx.isOfKind ``Lean.Parser.Term.sorry &&
            (syntaxRangeMatchesQuery range requestedRange ||
              rangeMatchesQuery lspRange requestedLspRange)
        then
          items.push <| mkSimpleItem
            .sorry
            lspRange
            (message? := some "syntactic sorry")
        else
          items
    | none => items
  Id.run do
    let mut items := items
    for i in [:stx.getNumArgs] do
      items := collectSyntaxSorries text requestedRange requestedLspRange stx[i] items
    return items

private structure SnapshotTodoConfig where
  text : FileMap
  requestedRange : Syntax.Range
  requestedLspRange : Lsp.Range
  kinds? : Option (Array TodoKind)
  suggestBasic : Bool

private def wantsSnapshotInfoTree (config : SnapshotTodoConfig) : Bool :=
  wantsKind config.kinds? .sorry ||
    wantsKind config.kinds? .hole ||
    wantsKind config.kinds? .incompleteProof

private def collectTermInfoItems
    (config : SnapshotTodoConfig)
    (info : TermInfo)
    (items : Array TodoItem) : Array TodoItem := Id.run do
  let mut items := items
  if wantsKind config.kinds? .hole &&
      [``Lean.Elab.Term.elabHole, ``Lean.Elab.Term.elabSyntheticHole].contains info.elaborator then
    if let some range := info.stx.getRange? (canonicalOnly := true) then
      let lspRange := range.toLspRange config.text
      if syntaxRangeMatchesQuery range config.requestedRange ||
          rangeMatchesQuery lspRange config.requestedLspRange then
        items := items.push <| mkSimpleItem .hole lspRange (message? := some "term hole")
  if wantsKind config.kinds? .sorry && info.expr.isNonSyntheticSorry then
    if let some range := info.stx.getRange? (canonicalOnly := true) then
      let lspRange := range.toLspRange config.text
      if syntaxRangeMatchesQuery range config.requestedRange ||
          rangeMatchesQuery lspRange config.requestedLspRange then
        items := items.push <| mkSimpleItem .sorry lspRange (message? := some "syntactic sorry")
  return items

private def collectIncompleteProofInfoItem
    (config : SnapshotTodoConfig)
    (ctx : ContextInfo)
    (tacticInfo : TacticInfo)
    (items : Array TodoItem) : RequestM (Array TodoItem) := do
  unless wantsKind config.kinds? .incompleteProof do
    return items
  unless !tacticInfo.goalsAfter.isEmpty do
    return items
  let some range := tacticInfo.stx.getRange? (canonicalOnly := true)
    | return items
  if isStructuralProofMarker config.text.source range then
    return items
  let lspRange := range.toLspRange config.text
  unless syntaxRangeMatchesQuery range config.requestedRange ||
      rangeMatchesQuery lspRange config.requestedLspRange do
    return items
  let proofState ← proofStateOfGoals tacticInfo.goalsAfter { ctx with mctx := tacticInfo.mctxAfter }
  return items.push {
    kind := .incompleteProof
    range := lspRange
    runAtPosition := lspRange.«end»
    runAtText? := if config.suggestBasic then some "exact ?_" else none
    message? := some "incomplete proof"
    proofState? := some proofState
  }

private def collectSnapshotInfoTreeItems
    (config : SnapshotTodoConfig)
    (snap : Snapshots.Snapshot)
    (items : Array TodoItem) : RequestM (Array TodoItem) := do
  if !wantsSnapshotInfoTree config then
    return items
  snap.infoTree.foldInfoM (init := items) fun ctx info items => do
    match info with
    | .ofTermInfo info =>
        return collectTermInfoItems config info items
    | .ofTacticInfo tacticInfo =>
        collectIncompleteProofInfoItem config ctx tacticInfo items
    | _ =>
        return items

private def collectSnapshotItems
    (text : FileMap)
    (requestedRange : Syntax.Range)
    (requestedLspRange : Lsp.Range)
    (snaps : Array Snapshots.Snapshot)
    (kinds? : Option (Array TodoKind))
    (suggestBasic : Bool)
    (items : Array TodoItem := #[]) : RequestM (Array TodoItem) := do
  let config : SnapshotTodoConfig := { text, requestedRange, requestedLspRange, kinds?, suggestBasic }
  if !wantsSnapshotInfoTree config then
    return items
  let mut items := items
  for snap in snaps do
    if wantsKind kinds? .sorry then
      items := collectSyntaxSorries text requestedRange requestedLspRange snap.stx items
    items ← collectSnapshotInfoTreeItems config snap items
  pure items

private def collectDiagnosticItems
    (requestedRange : Lsp.Range)
    (diagnostics : Array Widget.InteractiveDiagnostic) : Array TodoItem :=
  diagnostics.foldl (init := #[]) fun items diagnostic => Id.run do
    unless Beam.LSP.Lib.isUserVisibleDiagnostic diagnostic do
      return items
    let plain := Widget.InteractiveDiagnostic.toDiagnostic diagnostic
    unless rangeMatchesQuery diagnostic.fullRange requestedRange do
      return items
    items.push {
      kind := .diagnostic
      range := diagnostic.fullRange
      runAtPosition := diagnostic.fullRange.start
      message? := some plain.message
      severity? := plain.severity?
      diagnostic? := some plain
    }

private def firstOverlappingEditRange?
    (requestedRange : Lsp.Range)
    (edits : Lsp.TextEditBatch) : Option Lsp.Range :=
  edits.foldl (init := none) fun range? edit =>
    match range? with
    | some range => some range
    | none =>
        if rangeMatchesQuery edit.range requestedRange then
          some edit.range
        else
          none

private def firstOverlappingDocumentChangeRange?
    (requestedRange : Lsp.Range)
    (changes : Array Lsp.DocumentChange) : Option Lsp.Range :=
  changes.foldl (init := none) fun range? change =>
    match range? with
    | some range => some range
    | none =>
        match change with
        | .edit edit => firstOverlappingEditRange? requestedRange edit.edits
        | _ => none

private def firstOverlappingWorkspaceEditRange?
    (requestedRange : Lsp.Range)
    (edit : Lsp.WorkspaceEdit) : Option Lsp.Range :=
  match edit.documentChanges? with
  | some changes =>
      firstOverlappingDocumentChangeRange? requestedRange changes
  | none =>
      match edit.changes? with
      | some changes =>
          changes.toArray.foldl (init := none) fun range? (_, edits) =>
            match range? with
            | some range => some range
            | none => firstOverlappingEditRange? requestedRange edits
      | none => none

private def codeActionRange (requestedRange : Lsp.Range) (action : Lsp.CodeAction) : Lsp.Range :=
  let diagnosticRange? := do
    let diagnostics ← action.diagnostics?
    let diagnostic ← diagnostics[0]?
    pure diagnostic.range
  let editRange? := action.edit?.bind (firstOverlappingWorkspaceEditRange? requestedRange)
  diagnosticRange?.getD <| editRange?.getD requestedRange

private def collectCodeActionItems
    (requestedRange : Lsp.Range)
    (actions : Array Lsp.CodeAction) : Array TodoItem :=
  actions.foldl (init := #[]) fun items action => Id.run do
    let range := codeActionRange requestedRange action
    items.push {
      kind := .codeAction
      range
      runAtPosition := range.start
      message? := some action.title
      severity? := none
      codeAction? := some action
    }

private def collectDocumentItems
    (doc : FileWorker.EditableDocument)
    (snaps : Array Snapshots.Snapshot)
    (requestedRange : Syntax.Range)
    (requestedLspRange : Lsp.Range)
    (kinds? : Option (Array TodoKind))
    (suggestBasic : Bool) : RequestM (Array TodoItem) := do
  let text := doc.meta.text
  let mut items := #[]
  if wantsKind kinds? .sorry then
    items := collectSourceTokenSorries text requestedRange requestedLspRange 0 items
  items ← collectSnapshotItems text requestedRange requestedLspRange snaps kinds? suggestBasic items
  pure items

private def todoResult
    (doc : FileWorker.EditableDocument)
    (p : TodoParams)
    (snaps : Array Snapshots.Snapshot)
    (codeActions : Array Lsp.CodeAction) : RequestM TodoResult := do
  let requestedSyntaxRange := lspRangeToSyntaxRange doc.meta.text p.range
  let suggestBasic := shouldSuggestBasic p.suggest?
  let mut items ← collectDocumentItems doc snaps requestedSyntaxRange p.range p.kinds? suggestBasic
  if wantsKind p.kinds? .diagnostic then
    let diagnostics ← collectCurrentDiagnostics doc
    items := items ++ collectDiagnosticItems p.range diagnostics
  if wantsKind p.kinds? .codeAction then
    items := items ++ collectCodeActionItems p.range codeActions
  items := simplifyTodoItems items
  pure {
    version := doc.meta.version
    range := p.range
    items := items.qsort todoItemLt
  }

def handleTodo (p : TodoParams) : RequestM (RequestTask TodoResult) := do
  requireDocumentVersion p.textDocument
  validateRange p.range
  checkRequestCancelled
  let doc ← RequestM.readDoc
  let barrier := doc.reporter.bindCheap (fun _ => doc.cmdSnaps.waitAll)
  RequestM.bindTaskCheap barrier fun (snaps, _) => do
    checkRequestCancelled
    let codeActionTask ←
      if wantsKind p.kinds? .codeAction then
        let diagnostics ← collectCurrentDiagnostics doc
        let plainDiagnostics :=
          diagnostics.filterMap fun diagnostic =>
            if rangeMatchesQuery diagnostic.fullRange p.range then
              some <| Widget.InteractiveDiagnostic.toDiagnostic diagnostic
            else
              none
        let params : Lsp.CodeActionParams := {
          textDocument := { uri := p.textDocument.uri }
          range := p.range
          context := { diagnostics := plainDiagnostics }
        }
        Lean.Server.handleCodeAction params
      else
        pure <| RequestTask.pure #[]
    RequestM.bindRequestTaskCostly codeActionTask fun codeActions => do
      checkRequestCancelled
      return RequestTask.pure (← todoResult doc p snaps.toArray codeActions)

end Beam.LSP.Todo
