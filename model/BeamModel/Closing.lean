/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std

/-!
Executable proposal for one broker-owned document slot, not the implemented wire protocol.
Source numbers represent exact text. Atomic transitions abstract broker critical sections;
file reads and checkpoint publication occur outside them. See docs/CLOSE_SAVE_MODEL.md.
-/

namespace BeamModel.Closing

structure Document where
  basis : Nat
  source : Nat
  deriving DecidableEq, BEq, Repr

/-- Captured before a filesystem read; remains meaningful when the document is absent. -/
structure ReadPermit where
  owner : Nat
  fence : Nat
  deriving DecidableEq, BEq, Repr

/-- Private ownership of one close attempt, distinct even for unchanged document text. -/
structure Lease extends ReadPermit where
  document : Document
  deriving DecidableEq, BEq, Repr

inductive Lifecycle where
  | open (document : Option Document)
  | closing (lease : Lease)
  deriving DecidableEq, BEq, Repr

structure State where
  owner : Nat := 1
  fence : Nat := 0
  nextBasis : Nat := 1
  lifecycle : Lifecycle := .open none
  /-- External commit observations, retained independently of document lifetime. -/
  committed : List Lease := []
  deriving DecidableEq, BEq, Repr

inductive Failure where
  | closing
  | staleRead
  | staleLease
  | notCommitted
  deriving DecidableEq, BEq, Repr

def State.permit (state : State) : ReadPermit :=
  ⟨state.owner, state.fence⟩

def beginRead (state : State) : Except Failure ReadPermit :=
  match state.lifecycle with
  | .closing _ => .error .closing
  | .open _ => .ok state.permit

/-- This helper is used only after read admission, with an open lifecycle. -/
def acceptSource (state : State) (document : Option Document) (source : Nat) :
    State × Document :=
  match document with
  | some doc =>
    if doc.source = source then (state, doc) else fresh
  | none => fresh
where
  fresh :=
    let doc := { basis := state.nextBasis, source }
    ({ state with nextBasis := state.nextBasis + 1, lifecycle := .open (some doc) }, doc)

def acceptRead (state : State) (permit : ReadPermit) (source : Nat) :
    State × Except Failure Document :=
  match state.lifecycle with
  | .closing _ => (state, .error .closing)
  | .open doc =>
    if permit = state.permit then
      let (state, doc) := acceptSource state doc source
      (state, .ok doc)
    else (state, .error .staleRead)

/-- Source acceptance and exclusive reservation are one transition. -/
def reserve (state : State) (permit : ReadPermit) (source : Nat) :
    State × Except Failure Lease :=
  match acceptRead state permit source with
  | (next, .error error) => (next, .error error)
  | (next, .ok doc) =>
    let lease : Lease := { owner := next.owner, fence := next.fence + 1, document := doc }
    ({ next with fence := lease.fence, lifecycle := .closing lease }, .ok lease)

/-- Destructor for the scope: never restores a captured State, and never recreates an owner. -/
def release (state : State) (lease : Lease) : State :=
  if state.lifecycle = .closing lease then
    { state with lifecycle := .open (some lease.document) }
  else state

/--
An environment event: a dispatched publication has committed. This can arrive after teardown.
It is not permission to publish, nor a claim about cross-process artifact coherence.
-/
def observeCommit (state : State) (lease : Lease) : State :=
  { state with committed := lease :: state.committed }

def saved (state : State) (lease : Lease) : Bool :=
  state.committed.contains lease

/-- Abstract successful close delivery and local removal; uncertain delivery is outside this model. -/
def finish (state : State) (lease : Lease) : State × Except Failure Unit :=
  if state.lifecycle = .closing lease then
    if saved state lease then
      ({ state with lifecycle := .open none }, .ok ())
    else (state, .error .notCommitted)
  else (state, .error .staleLease)

/-- Ordinary close respects an exclusive close attempt and also fences delayed source reads. -/
def close (state : State) : State × Except Failure Unit :=
  match state.lifecycle with
  | .closing _ => (state, .error .closing)
  | .open _ =>
    ({ state with fence := state.fence + 1, lifecycle := .open none }, .ok ())

/--
Owner loss and recreation may reuse local counters, but not owner identity. This abstracts
workspace/backend replacement; it is not a proposal for a public generation allocator.
-/
def replace (state : State) : State :=
  { owner := state.owner + 1, committed := state.committed }

inductive Action where
  | accept (permit : ReadPermit) (source : Nat)
  | reserve (permit : ReadPermit) (source : Nat)
  | release (lease : Lease)
  | committed (lease : Lease)
  | finish (lease : Lease)
  | close
  | replace
  deriving DecidableEq, BEq, Repr

inductive Outcome where
  | accepted (doc : Document)
  | reserved (lease : Lease)
  | rejected (error : Failure)
  | done
  deriving DecidableEq, BEq, Repr

def step (state : State) : Action → State × Outcome
  | .accept permit source =>
    let (next, result) := acceptRead state permit source
    (next, match result with | .ok doc => .accepted doc | .error e => .rejected e)
  | .reserve permit source =>
    let (next, result) := reserve state permit source
    (next, match result with | .ok lease => .reserved lease | .error e => .rejected e)
  | .release lease => (release state lease, .done)
  | .committed lease => (observeCommit state lease, .done)
  | .finish lease =>
    let (next, result) := finish state lease
    (next, match result with | .ok _ => .done | .error e => .rejected e)
  | .close =>
    let (next, result) := close state
    (next, match result with | .ok _ => .done | .error e => .rejected e)
  | .replace => (replace state, .done)

def run (state : State) : List Action → State
  | [] => state
  | action :: rest => run (step state action).1 rest

end BeamModel.Closing
