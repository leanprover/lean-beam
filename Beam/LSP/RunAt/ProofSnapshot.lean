/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

/-
Execution snapshots for the `$/lean/runAt` and `$/lean/runWith` family.

This is deliberately local to `Beam.LSP.RunAt`: other LSP families may inspect goals, but they do
not retain executable proof states for continuation.
-/
namespace Beam.LSP.RunAt

structure ProofSnapshot where
  coreState : Core.State
  coreContext : Core.Context
  metaState : Meta.State
  metaContext : Meta.Context
  termState : Elab.Term.State
  termContext : Elab.Term.Context
  tacticState : Elab.Tactic.State
  tacticContext : Elab.Tactic.Context

namespace ProofSnapshot

open Elab
open Elab.Tactic

def withCancelToken (p : ProofSnapshot) (cancelTk? : Option IO.CancelToken) : ProofSnapshot :=
  { p with coreContext := { p.coreContext with cancelTk? } }

def runCoreM (p : ProofSnapshot) (t : CoreM α) : IO (α × ProofSnapshot) := do
  let (a, coreState) ← (Core.CoreM.toIO · p.coreContext p.coreState) do
    t
  return (a, { p with coreState })

def runMetaM (p : ProofSnapshot) (t : MetaM α) : IO (α × ProofSnapshot) := do
  let ((a, metaState), p') ←
    p.runCoreM (Meta.MetaM.run (ctx := p.metaContext) (s := p.metaState) do t)
  return (a, { p' with metaState })

def runTermElabM (p : ProofSnapshot) (t : TermElabM α) : IO (α × ProofSnapshot) := do
  let ((a, termState), p') ←
    p.runMetaM (Term.TermElabM.run (ctx := p.termContext) (s := p.termState) do
      -- Setting `declName?` in the reader context is not enough: Lean's auxiliary
      -- declaration generator is stateful and must be scoped to this declaration too.
      -- The caller owns synthesis so its diagnostics and exceptions share the tactic's
      -- saved-state boundary.
      match p.termContext.declName? with
      | some declName => Term.withDeclName declName t
      | none => t)
  return (a, { p' with termState })

def runTacticM (p : ProofSnapshot) (t : TacticM α) : IO (α × ProofSnapshot) := do
  let ((a, tacticState), p') ← p.runTermElabM (t p.tacticContext |>.run p.tacticState)
  return (a, { p' with tacticState })

def create (ctx : Elab.ContextInfo) (goals : List MVarId) (levelNames : List Name := []) :
    IO ProofSnapshot := do
  ctx.runMetaM {} do
    -- InfoTree contexts do not save the term elaborator's universe scope. Start with the
    -- command and declaration-header scopes, then collect parameters from goals and hypotheses.
    let mut levels : CollectLevelParams.State := {}
    for name in levelNames.reverse do
      levels := CollectLevelParams.visitLevel (.param name) levels
    for goal in goals do
      let decl ← goal.getDecl
      for localDecl in decl.lctx do
        levels := collectLevelParams levels (← instantiateMVars localDecl.type)
        if let some value := localDecl.value? then
          levels := collectLevelParams levels (← instantiateMVars value)
      levels := collectLevelParams levels (← instantiateMVars decl.type)
    pure {
      coreState := ← getThe Core.State
      coreContext := ← readThe Core.Context
      metaState := ← getThe Meta.State
      metaContext := ← readThe Meta.Context
      termState := { levelNames := levels.params.toList.reverse }
      -- Tactic info contexts may omit `parentDecl?`; the environment's async prefix still
      -- identifies the enclosing declaration whose scope admits auxiliary declarations.
      termContext := { declName? := ctx.parentDecl? <|> ctx.env.asyncPrefix? }
      tacticState := { goals }
      -- Editor-style tactic recovery is useful for collecting later diagnostics, but an isolated
      -- runAt probe should report the direct tactic failure. With recovery enabled, term
      -- elaboration errors can become synthetic sorries and later surface only as `abortTactic`.
      tacticContext := { elaborator := .anonymous, recover := false }
    }

end ProofSnapshot
end Beam.LSP.RunAt
