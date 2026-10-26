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
import Beam.LSP.Lib.Placeholder
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
  /-- The whole document when omitted. -/
  range? : Option Lean.Lsp.Range := none
  kinds? : Option (Array TodoKind) := none
  suggest? : Option TodoSuggestMode := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource TodoParams where
  fileSource p := p.textDocument.uri

/-- One normalized agent-facing todo item. -/
structure TodoItem where
  kind : TodoKind
  range : Lean.Lsp.Range
  /--
  Where `runAt` starts from this item's `proofState`, when it has one. It is absent when no source
  position selects that state, for example the goals left after a branch bullet.
  -/
  runAtPosition? : Option Lean.Lsp.Position := none
  runAtText? : Option String := none
  message? : Option String := none
  severity? : Option Lean.Lsp.DiagnosticSeverity := none
  codeAction? : Option Lean.Lsp.CodeAction := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

/-- Typed success payload for `$/lean/todo`. -/
structure TodoResult where
  version : Nat
  /-- The requested range, or the whole document. -/
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
position. Including the end makes the point query compose with items whose `runAtPosition?` is just
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
    runAtPosition? := some range.start
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
* An info-tree pass records `sorry` tactics and the `sorry` terms Lean left as open placeholders,
  with the goal that `runAt` sees at the item's position.

The final simplification pass merges the usual overlap into the most informative item. Keeping the
signals separate gives agents useful todos even for partially broken files while retaining
parser/elaborator confirmation and goals when Lean gets that far.
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
      item.runAtPosition? == other.runAtPosition?

/-- Keep one item per location, with the goal and suggestion of whichever signal found them. -/
private def dedupeTodoItems (items : Array TodoItem) : Array TodoItem :=
  items.foldl (init := #[]) fun acc item =>
    match acc.findIdx? (sameTodoLocation item) with
    | some i =>
        acc.modify i fun kept => { kept with
          proofState? := kept.proofState? <|> item.proofState?
          runAtText? := kept.runAtText? <|> item.runAtText? }
    | none => acc.push item

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

private def tacticRangeWidth (range : Syntax.Range) : Nat :=
  range.stop.byteIdx - range.start.byteIdx

/--
Maps each goal to the index of the last tactic leaving it open, preferring the narrowest tactic when
several end at the same position. Nested tactics such as a rewrite rule and its enclosing `rw` share
goals.
-/
private def lastTacticsLeaving (source : String) (nodes : Array TacticNode) :
    Std.HashMap MVarId (Nat × TacticNode) := Id.run do
  let mut last : Std.HashMap MVarId (Nat × TacticNode) := {}
  for (node, i) in nodes.zipIdx do
    if isStructuralProofMarker source node.range then
      continue
    for goal in node.info.goalsAfter do
      let replaces :=
        match last[goal]? with
        | none => true
        | some (_, other) =>
            rawLT other.range.stop node.range.stop ||
              (node.range.stop == other.range.stop &&
                tacticRangeWidth node.range < tacticRangeWidth other.range)
      if replaces then
        last := last.insert goal (i, node)
  return last

/--
The metavariable context after the outermost tactic containing `node` ran. It holds every
assignment of `node`'s proof block, including steps without a source range of their own such as the
`assumption` that `rwa` runs, and it precedes Lean admitting the goals the block left open.
Tactics are collected in info-tree order, so among equally wide candidates the first is the
outermost.
-/
private def blockFinalMCtx (nodes : Array TacticNode) (node : TacticNode) : MetavarContext :=
  let contains (other : TacticNode) :=
    other.range.start ≤ node.range.start && node.range.stop ≤ other.range.stop
  let root := nodes.foldl (init := node) fun root other =>
    if contains other && tacticRangeWidth root.range < tacticRangeWidth other.range then other
    else root
  let root := (nodes.find? fun other =>
    contains other && tacticRangeWidth other.range == tacticRangeWidth root.range).getD root
  root.info.mctxAfter

/-- A goal is left open when nothing assigned it, or only Lean's error recovery admitted it. -/
private def goalLeftOpen (mctx : MetavarContext) (goal : MVarId) : Bool :=
  !mctx.dAssignment.contains goal &&
    match mctx.eAssignment.find? goal with
    | some value => (instantiateMVarsCore mctx value).1.isSyntheticSorry
    | none => true

/--
Reports goals that remain open at the end of their proof block. A goal left by one tactic and
solved or worked on later in the block is ordinary proof progress, not an incomplete proof, so each
unsolved goal is attributed only to the last tactic that left it open. Goals left at the same range share one
item, also when a tactic ran once per goal there, as under `<;>` or `all_goals`.
-/
private def collectIncompleteProofItems
    (config : SnapshotTodoConfig)
    (nodes : Array TacticNode)
    (items : Array TodoItem) : RequestM (Array TodoItem × Array MVarId) := do
  unless wantsKind config.kinds? .incompleteProof do
    return (items, #[])
  -- Per source range, the tactics (by info-tree index) that left open goals there.
  let mut unsolved : Std.HashMap (Nat × Nat) (Array (Nat × TacticNode × Array MVarId)) := {}
  for (goal, i, node) in lastTacticsLeaving config.text.source nodes do
    -- Both checks are needed: the final context sees steps without a source range, such as the
    -- `assumption` in `rwa`, and a later tactic that worked on the goal shows that error recovery
    -- admitted it only because that later work failed, as when a bullet stops early.
    if goalLeftOpen (blockFinalMCtx nodes node) goal && !goalHandledAfter nodes node.range.stop goal then
      let key := (node.range.start.byteIdx, node.range.stop.byteIdx)
      let runs := unsolved[key]?.getD #[]
      let runs := match runs.findIdx? (·.1 == i) with
        | some j => runs.modify j fun (i, node, goals) => (i, node, goals.push goal)
        | none => runs.push (i, node, #[goal])
      unsolved := unsolved.insert key runs
  let mut items := items
  let mut reported := #[]
  for (_, runs) in unsolved.toArray do
    let runs := runs.qsort (·.1 < ·.1)
    let some (_, first, _) := runs[0]?
      | continue
    let lspRange := first.range.toLspRange config.text
    unless syntaxRangeMatchesQuery first.range config.requestedRange ||
        rangeMatchesQuery lspRange config.requestedLspRange do
      continue
    -- Each run of the tactic renders its own goals in the context it left them in.
    let mut goals := #[]
    for (_, node, leftOpen) in runs do
      let left := node.info.goalsAfter.filter leftOpen.contains
      reported := reported ++ left.toArray
      let state ← proofStateOfGoals left { node.ctx with mctx := node.info.mctxAfter }
      goals := goals ++ state.goals
    items := items.push {
      kind := .incompleteProof
      range := lspRange
      runAtPosition? := some lspRange.«end»
      runAtText? := if config.suggestBasic then some "exact ?_" else none
      message? := some "incomplete proof"
      proofState? := some { goals }
    }
  return (items, reported)

/-- A `sorry` tactic closes the main goal; `runAt` at its start runs against that goal. -/
private def collectTacticSorryItems
    (config : SnapshotTodoConfig)
    (nodes : Array TacticNode)
    (items : Array TodoItem) : RequestM (Array TodoItem) := do
  unless wantsKind config.kinds? .sorry do
    return items
  let mut items := items
  for node in nodes do
    unless node.info.stx.isOfKind `Lean.Parser.Tactic.tacticSorry do
      continue
    let some goal := node.info.goalsBefore.head?
      | continue
    let lspRange := node.range.toLspRange config.text
    unless syntaxRangeMatchesQuery node.range config.requestedRange ||
        rangeMatchesQuery lspRange config.requestedLspRange do
      continue
    let proofState ← proofStateOfGoals [goal] { node.ctx with mctx := node.info.mctxBefore }
    items := items.push { mkSimpleItem .sorry lspRange (message? := some "syntactic sorry") with
      proofState? := some proofState }
  return items

/--
Open `sorry` terms and holes, with the goal that `runAt` elaborates a term against at the item's
position. A hole that a tactic left as an open goal, as in `refine ⟨?_, ?_⟩`, is reported once,
where that goal stays open.
-/
private def collectPlaceholderItems
    (config : SnapshotTodoConfig)
    (tree : InfoTree)
    (openGoals : Array MVarId)
    (items : Array TodoItem) : RequestM (Array TodoItem × Array MVarId) := do
  let mut items := items
  let mut holes := #[]
  for placeholder in collectPlaceholders tree do
    let (kind, message) :=
      match placeholder.kind with
      | .sorry => (TodoKind.sorry, "syntactic sorry")
      | .hole => (TodoKind.hole, "term hole")
    unless wantsKind config.kinds? kind do
      continue
    if placeholder.mvarId?.any openGoals.contains then
      continue
    let lspRange := placeholder.range.toLspRange config.text
    unless syntaxRangeMatchesQuery placeholder.range config.requestedRange ||
        rangeMatchesQuery lspRange config.requestedLspRange do
      continue
    items := items.push { mkSimpleItem kind lspRange (message? := some message) with
      proofState? := some (← placeholder.proofState) }
    if let some mvarId := placeholder.mvarId? then
      holes := holes.push mvarId
  return (items, holes)

/-- Items from one command's info tree, and the goals and holes they report. -/
private def collectSnapshotInfoTreeItems
    (config : SnapshotTodoConfig)
    (snap : Snapshots.Snapshot)
    (items : Array TodoItem) : RequestM (Array TodoItem × Array MVarId) := do
  if !wantsSnapshotInfoTree config then
    return (items, #[])
  let nodes := collectTacticNodes snap.infoTree
  let (items, openGoals) ← collectIncompleteProofItems config nodes items
  let items ← collectTacticSorryItems config nodes items
  let (items, holes) ← collectPlaceholderItems config snap.infoTree openGoals items
  return (items, openGoals ++ holes)

private def collectSnapshotItems
    (text : FileMap)
    (requestedRange : Syntax.Range)
    (requestedLspRange : Lsp.Range)
    (snaps : Array Snapshots.Snapshot)
    (kinds? : Option (Array TodoKind))
    (suggestBasic : Bool)
    (items : Array TodoItem := #[]) : RequestM (Array TodoItem × Std.HashSet MVarId) := do
  let config : SnapshotTodoConfig := { text, requestedRange, requestedLspRange, kinds?, suggestBasic }
  if !wantsSnapshotInfoTree config then
    return (items, {})
  let mut items := items
  let mut reported : Std.HashSet MVarId := {}
  for snap in snaps do
    if wantsKind kinds? .sorry then
      items := collectSyntaxSorries text requestedRange requestedLspRange snap.stx items
    let (snapItems, goals) ← collectSnapshotInfoTreeItems config snap items
    items := snapItems
    reported := reported.insertMany goals
  pure (items, reported)

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
      runAtPosition? := some diagnostic.fullRange.start
      message? := some plain.message
      severity? := plain.severity?
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
      runAtPosition? := some range.start
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
    (suggestBasic : Bool) : RequestM (Array TodoItem × Std.HashSet MVarId) := do
  let text := doc.meta.text
  let mut items := #[]
  if wantsKind kinds? .sorry then
    items := collectSourceTokenSorries text requestedRange requestedLspRange 0 items
  collectSnapshotItems text requestedRange requestedLspRange snaps kinds? suggestBasic items

private partial def messageGoals : MessageData → Array MVarId
  | .ofGoal goal => #[goal]
  | .compose a b => messageGoals a ++ messageGoals b
  | .nest _ d | .group d | .tagged _ d | .withContext _ d | .withNamingContext _ d => messageGoals d
  | _ => #[]

private def diagnosticSeverity : MessageSeverity → Lsp.DiagnosticSeverity
  | .information => .information
  | .warning => .warning
  | .error => .error

/-- Index of the command snapshot containing `pos`. -/
private def commandIndex? (snaps : Array Snapshots.Snapshot) (pos : String.Pos.Raw) : Option Nat :=
  snaps.findIdx? (pos < ·.endPos)

/--
Whether a Lean message only restates an obligation that a structured item already reports: the
unsolved goals of a tactic block or the placeholder Lean could not synthesize, when every goal it
names is reported, or a declaration's `sorry` warning, when the declaration's `sorry` is reported.
Diagnostics that explain a failure, such as a tactic error, are never subsumed.
-/
private def isSubsumedMessage
    (text : FileMap)
    (snaps : Array Snapshots.Snapshot)
    (reportedGoals : Std.HashSet MVarId)
    (sorryCommands : Array Nat)
    (msg : Message) : Bool :=
  if msg.data.hasTag (fun tag => tag == `Tactic.unsolvedGoals || tag == `Elab.synthPlaceholder) then
    let goals := messageGoals msg.data
    !goals.isEmpty && goals.all reportedGoals.contains
  else if msg.data.hasTag (· == `hasSorry) then
    (commandIndex? snaps (text.ofPosition msg.pos)).any sorryCommands.contains
  else
    false

private def messageKey (text : FileMap) (msg : Message) : Lsp.Range × Lsp.DiagnosticSeverity :=
  ({ start := text.leanPosToLspPos msg.pos
     «end» := text.leanPosToLspPos (msg.endPos.getD msg.pos) }, diagnosticSeverity msg.severity)

/--
Diagnostic keys to drop. Published diagnostics no longer carry Lean's message tags, so they are
matched to the document's messages by full range and severity; a key that also belongs to an
unsubsumed message is kept.
-/
private def subsumedDiagnosticKeys
    (doc : FileWorker.EditableDocument)
    (snaps : Array Snapshots.Snapshot)
    (items : Array TodoItem)
    (reportedGoals : Std.HashSet MVarId) : Array (Lsp.Range × Lsp.DiagnosticSeverity) := Id.run do
  let text := doc.meta.text
  let sorryCommands := items.filterMap fun item =>
    if item.kind == .sorry then commandIndex? snaps (text.lspPosToUtf8Pos item.range.start) else none
  let messages := (Language.toSnapshotTree doc.initSnap).getAll.foldl (init := #[])
    fun acc snap => acc ++ snap.diagnostics.msgLog.toList.toArray
  let mut subsumed := #[]
  let mut kept := #[]
  for msg in messages do
    let key := messageKey text msg
    if isSubsumedMessage text snaps reportedGoals sorryCommands msg then
      subsumed := subsumed.push key
    else
      kept := kept.push key
  return subsumed.filter (!kept.contains ·)

/-- The innermost non-structural tactic containing `pos` that received goals. -/
private def innermostTacticAt?
    (text : FileMap)
    (snaps : Array Snapshots.Snapshot)
    (pos : String.Pos.Raw) : Option TacticNode := do
  let snap ← (commandIndex? snaps pos).bind (snaps[·]?)
  (collectTacticNodes snap.infoTree).foldl (init := none) fun best? node =>
    if node.range.start ≤ pos && pos ≤ node.range.stop &&
        !node.info.goalsBefore.isEmpty && !isStructuralProofMarker text.source node.range then
      match best? with
      | some best =>
          if tacticRangeWidth node.range < tacticRangeWidth best.range then some node else best?
      | none => some node
    else
      best?

/--
An error inside a tactic proof is actionable where its innermost tactic starts: `runAt` there runs a
replacement against the goals that tactic received.
-/
private def attachFailedTacticGoal
    (text : FileMap)
    (snaps : Array Snapshots.Snapshot)
    (item : TodoItem) : RequestM TodoItem := do
  unless item.severity? == some .error do
    return item
  let some tactic := innermostTacticAt? text snaps (text.lspPosToUtf8Pos item.range.start)
    | return item
  let proofState ←
    proofStateOfGoals tactic.info.goalsBefore { tactic.ctx with mctx := tactic.info.mctxBefore }
  return { item with
    runAtPosition? := some (tactic.range.toLspRange text).start
    proofState? := some proofState }

/--
Ranges of the tactics that failed with an error, whether that error is reported as a diagnostic or
subsumed by the item it restates. Unsolved-goals errors name goals a block left open rather than a
failing tactic, so they are excluded.
-/
private def failedTacticRanges
    (doc : FileWorker.EditableDocument)
    (snaps : Array Snapshots.Snapshot) : Array Lsp.Range :=
  let text := doc.meta.text
  (Language.toSnapshotTree doc.initSnap).getAll.foldl (init := #[]) fun acc snap =>
    snap.diagnostics.msgLog.toList.foldl (init := acc) fun acc msg =>
      if msg.severity != .error || msg.data.hasTag (· == `Tactic.unsolvedGoals) then
        acc
      else
        match innermostTacticAt? text snaps (text.ofPosition msg.pos) with
        | some tactic => acc.push (tactic.range.toLspRange text)
        | none => acc

private def todoResult
    (doc : FileWorker.EditableDocument)
    (p : TodoParams)
    (range : Lsp.Range)
    (snaps : Array Snapshots.Snapshot)
    (codeActions : Array Lsp.CodeAction) : RequestM TodoResult := do
  let requestedSyntaxRange := lspRangeToSyntaxRange doc.meta.text range
  let suggestBasic := shouldSuggestBasic p.suggest?
  let (items, reportedGoals) ←
    collectDocumentItems doc snaps requestedSyntaxRange range p.kinds? suggestBasic
  let mut items := simplifyTodoItems items
  if wantsKind p.kinds? .diagnostic then
    let diagnostics ← collectCurrentDiagnostics doc
    let subsumed := subsumedDiagnosticKeys doc snaps items reportedGoals
    for item in collectDiagnosticItems range diagnostics do
      if subsumed.contains (item.range, item.severity?.getD .error) then
        continue
      items := items.push (← attachFailedTacticGoal doc.meta.text snaps item)
    -- The error, or the item that subsumes it, explains why its tactic left the goal open.
    let failedTactics := failedTacticRanges doc snaps
    items := items.filter fun item =>
      !(item.kind == .incompleteProof && failedTactics.contains item.range)
  if wantsKind p.kinds? .codeAction then
    items := items ++ collectCodeActionItems range codeActions
  pure {
    version := doc.meta.version
    range
    items := items.qsort todoItemLt
  }

private def documentRange (text : FileMap) : Lsp.Range :=
  { start := { line := 0, character := 0 }, «end» := text.utf8PosToLspPos text.source.rawEndPos }

/--
Range of the command snapshot where Lean runs code-action providers for `range`: the first snapshot
ending at or after the range end.
-/
private def codeActionCommandRange?
    (text : FileMap) (snaps : Array Snapshots.Snapshot) (range : Lsp.Range) : Option Lsp.Range := do
  let stop := text.lspPosToUtf8Pos range.«end»
  let i ← snaps.findIdx? (·.endPos ≥ stop)
  let snap ← snaps[i]?
  let start := (if i == 0 then none else snaps[i - 1]?).map (·.endPos) |>.getD 0
  pure { start := text.utf8PosToLspPos start, «end» := text.utf8PosToLspPos snap.endPos }

/--
The proof state `runAt` starts from at `position`, selected as `handleRunAt` does: an open placeholder
there first, then the tactic state Lean selects at the position.
-/
private def runAtProofStateAt (position : Lsp.Position) :
    RequestM (RequestTask (Option ProofState)) := do
  let placeholderTask ← findPlaceholderAt position
  RequestM.bindRequestTaskCostly placeholderTask fun
    | some placeholder => return .pure (some (← placeholder.proofState))
    | none => do
        let basisTask ← findProofBasisAt position
        RequestM.bindRequestTaskCostly basisTask fun
          | some basis => return .pure (some (← basisProofState basis))
          | none => return .pure none

/--
An item keeps its `runAtPosition?` only when `runAt` there starts from the item's proof state. Goals
that no source position selects, such as those left after a branch bullet, keep their proof state
without a position.
-/
private partial def keepSelectableRunAtPositions (items : List TodoItem) (acc : Array TodoItem) :
    RequestM (RequestTask (Array TodoItem)) := do
  match items with
  | [] => return .pure acc
  | item :: rest =>
      match item.runAtPosition?, item.proofState? with
      | some position, some expected =>
          let stateTask ← runAtProofStateAt position
          RequestM.bindRequestTaskCostly stateTask fun state? => do
            let selectable := state?.any fun state => toJson state == toJson expected
            let item := if selectable then item else { item with runAtPosition? := none }
            keepSelectableRunAtPositions rest (acc.push item)
      | _, _ => keepSelectableRunAtPositions rest (acc.push item)

def handleTodo (p : TodoParams) : RequestM (RequestTask TodoResult) := do
  requireDocumentVersion p.textDocument
  -- Lean runs code-action providers on the one command at the range end, so a whole-document
  -- request cannot enumerate them.
  let p ← match p.range? with
    | some range => do
        validateRange range
        pure p
    | none =>
        if p.kinds?.any (·.contains .codeAction) then
          throw <| RequestError.invalidParams
            "code_action items need a range: Lean runs code-action providers on the command at the range end"
        let kinds := (p.kinds?.filter (!·.isEmpty)).getD TodoKind.all
        pure { p with kinds? := some (kinds.filter (· != .codeAction)) }
  checkRequestCancelled
  let doc ← RequestM.readDoc
  let range := p.range?.getD (documentRange doc.meta.text)
  let barrier := doc.reporter.bindCheap (fun _ => doc.cmdSnaps.waitAll)
  RequestM.bindTaskCheap barrier fun (snaps, _) => do
    checkRequestCancelled
    let codeActionTask ←
      if wantsKind p.kinds? .codeAction then
        let diagnostics ← collectCurrentDiagnostics doc
        -- Lean copies the forwarded diagnostics into every action's resolve data. Diagnostics that
        -- start in other commands cannot apply to that snapshot's providers, so forward only its own.
        let commandRange? := codeActionCommandRange? doc.meta.text snaps.toArray range
        let plainDiagnostics :=
          diagnostics.filterMap fun diagnostic =>
            let inCommand := commandRange?.any fun command =>
              positionLE command.start diagnostic.fullRange.start &&
                positionLT diagnostic.fullRange.start command.«end»
            if inCommand && rangeMatchesQuery diagnostic.fullRange range then
              some <| Widget.InteractiveDiagnostic.toDiagnostic diagnostic
            else
              none
        let params : Lsp.CodeActionParams := {
          textDocument := { uri := p.textDocument.uri }
          range
          context := { diagnostics := plainDiagnostics }
        }
        Lean.Server.handleCodeAction params
      else
        pure <| RequestTask.pure #[]
    RequestM.bindRequestTaskCostly codeActionTask fun codeActions => do
      checkRequestCancelled
      let result ← todoResult doc p range snaps.toArray codeActions
      let itemsTask ← keepSelectableRunAtPositions result.items.toList #[]
      RequestM.bindRequestTaskCostly itemsTask fun items => return .pure { result with items }

end Beam.LSP.Todo
