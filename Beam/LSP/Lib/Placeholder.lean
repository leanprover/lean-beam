/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Beam.LSP.Lib.Goal

open Lean
open Lean.Elab
open Lean.Meta
open Lean.Server
open Lean.Server.RequestM

/-
Unfilled term placeholders: a `sorry`, `_`, or `?x` term that Lean left open when it finished the
enclosing command.

`RunAt` runs speculative tactics against a fresh goal standing for such a placeholder. A hole that
elaboration filled, or whose goal a later tactic handled, is not open, so `RunAt` keeps its tactic or
command basis there.

A `sorry` tactic is not a term placeholder: Lean records it as a tactic, and `runAt` already runs
tactic text against its goal.
-/
namespace Beam.LSP.Lib

inductive PlaceholderKind where
  /-- A user-written `sorry` term. -/
  | sorry
  /-- A `_` or `?x` term hole. -/
  | hole
  deriving BEq

structure Placeholder where
  kind : PlaceholderKind
  /-- Context of the enclosing command; its metavariable context is the command's final one. -/
  ctx : ContextInfo
  info : TermInfo
  range : Syntax.Range

private def placeholderKind? (info : TermInfo) : Option PlaceholderKind :=
  if info.stx.isOfKind ``Lean.Parser.Term.sorry && info.expr.isNonSyntheticSorry then
    some .sorry
  else if [`Lean.Elab.Term.elabHole, `Lean.Elab.Term.elabSyntheticHole].contains info.elaborator then
    some .hole
  else
    none

/-- A tactic in the info tree with its source range. -/
structure TacticNode where
  ctx : ContextInfo
  info : TacticInfo
  range : Syntax.Range

def collectTacticNodes (tree : InfoTree) : Array TacticNode :=
  tree.foldInfo (init := #[]) fun ctx info nodes =>
    match info with
    | .ofTacticInfo info =>
        match info.stx.getRange? (canonicalOnly := true) with
        | some range => nodes.push { ctx, info, range }
        | none => nodes
    | _ => nodes

/--
A tactic starting at or after `after` handled `goal` when it ran on the goal, or when it assigned
the goal, for example by unification, to something other than an admitted synthetic `sorry`.
Enclosing tactics start earlier, so the goals that a branch bullet or `by` admits stay unhandled.
-/
def goalHandledAfter (nodes : Array TacticNode) (after : String.Pos.Raw) (goal : MVarId) : Bool :=
  nodes.any fun node =>
    after ≤ node.range.start &&
      (node.info.goalsBefore.contains goal ||
        node.info.mctxAfter.dAssignment.contains goal ||
        match node.info.mctxAfter.eAssignment.find? goal with
        | some value => !(instantiateMVarsCore node.info.mctxAfter value).1.isSyntheticSorry
        | none => false)

/-- The metavariable Lean created for a hole. -/
def Placeholder.mvarId? (p : Placeholder) : Option MVarId :=
  match p.kind with
  | .sorry => none
  | .hole =>
      let head := p.info.expr.getAppFn
      if head.isMVar then some head.mvarId! else none

/--
A `sorry` is always open. A hole is open unless Lean filled it, for example by unification, or a
later tactic handled the goal it became, as a `sorry` tactic after `refine ⟨k, ?_⟩` does. The term's
own context predates later tactics, so both are checked. An admitted synthetic `sorry` leaves a hole
open, as does a delayed assignment that is still pending.
-/
private def Placeholder.isOpen (p : Placeholder) (tactics : Array TacticNode) : Bool :=
  match p.kind with
  | .sorry => true
  | .hole =>
      let value := (instantiateMVarsCore p.ctx.mctx p.info.expr).1
      (value.getAppFn.isMVar || value.isSyntheticSorry) &&
        !(p.mvarId?.any (goalHandledAfter tactics p.range.stop))

/-- Open placeholders written in the source, in info-tree order, at most one per source range. -/
def collectPlaceholders (tree : InfoTree) : Array Placeholder :=
  let tactics := collectTacticNodes tree
  tree.foldInfo (init := #[]) fun ctx info placeholders =>
    match info with
    | .ofTermInfo info => Id.run do
        let some kind := placeholderKind? info | return placeholders
        let some range := info.stx.getRange? (canonicalOnly := true) | return placeholders
        let p := { kind, ctx, info, range }
        if !p.isOpen tactics || placeholders.any (·.range == range) then
          return placeholders
        return placeholders.push p
    | _ => placeholders

/-- The innermost open placeholder whose source range contains `pos`, including its end. -/
def placeholderAt? (placeholders : Array Placeholder) (pos : String.Pos.Raw) :
    Option Placeholder :=
  placeholders.foldl (init := none) fun best? p =>
    if p.range.start ≤ pos && pos ≤ p.range.stop then
      match best? with
      | some best =>
          if p.range.stop.byteIdx - p.range.start.byteIdx <
              best.range.stop.byteIdx - best.range.start.byteIdx then some p else best?
      | none => some p
    else
      best?

private def localInstancesOf (lctx : LocalContext) : MetaM LocalInstances :=
  withLCtx lctx {} do
    lctx.foldlM (init := #[]) fun insts decl => do
      if decl.isImplementationDetail then
        return insts
      match ← isClass? decl.type with
      | some className => return insts.push { className, fvar := decl.toExpr }
      | none => return insts

/--
A fresh goal standing for the placeholder: its expected type in its local context. A hole may be
assigned to an admitted `sorry`, so it cannot serve as a goal itself.
-/
def Placeholder.mkGoal (p : Placeholder) : MetaM MVarId := do
  let type ← instantiateMVars (← withLCtx p.info.lctx {} (inferType p.info.expr))
  let userName :=
    match p.mvarId? with
    | some mvarId => (p.ctx.mctx.findDecl? mvarId).map (·.userName) |>.getD Name.anonymous
    | none => Name.anonymous
  let goal ← mkFreshExprMVarAt p.info.lctx (← localInstancesOf p.info.lctx) type
    (kind := .syntheticOpaque) (userName := userName)
  return goal.mvarId!

def Placeholder.proofState (p : Placeholder) : RequestM ProofState :=
  p.ctx.runMetaM {} do proofStateOfGoalList [← p.mkGoal]

-- Lean 4.35 moved parsed-command lookup from the server API to the language API.
-- Select the public API while elaborating this definition; there is no runtime fallback.
def findParsedCommandAt (doc : FileWorker.EditableDocument) (pos : String.Pos.Raw) :
    ServerTask (Option Language.Lean.CommandParsedSnapshot) := by
  first
  | exact (Language.Lean.findCmdParsedSnap doc.initSnap doc.meta.text pos).asServerTask
  | exact Lean.Server.RequestM.findCmdParsedSnap doc pos

private partial def hasPlaceholderSyntaxAt (stx : Syntax) (pos : String.Pos.Raw) : Bool :=
  match stx.getRange? (canonicalOnly := true) with
  | some range =>
      range.start ≤ pos && pos ≤ range.stop &&
        ([``Lean.Parser.Term.sorry, ``Lean.Parser.Term.hole, ``Lean.Parser.Term.syntheticHole].any
            stx.isOfKind ||
          stx.getArgs.any (hasPlaceholderSyntaxAt · pos))
  | none => stx.getArgs.any (hasPlaceholderSyntaxAt · pos)

/--
The open placeholder at `position`, if any. Only positions on placeholder syntax wait for the
enclosing command to finish: whether a hole stays open is known only then.
-/
def findPlaceholderAt (position : Lean.Lsp.Position) :
    RequestM (RequestTask (Option Placeholder)) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.bindTaskCostly (findParsedCommandAt doc pos) fun
    | some parsed =>
        if hasPlaceholderSyntaxAt parsed.stx pos then
          RequestM.withWaitFindSnap doc (fun snap => snap.endPos >= pos)
            (notFoundX := pure none)
            (x := fun snap => pure <| placeholderAt? (collectPlaceholders snap.infoTree) pos)
        else
          pure <| .pure none
    | none => pure <| .pure none

end Beam.LSP.Lib
