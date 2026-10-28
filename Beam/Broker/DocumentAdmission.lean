/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Std

namespace Beam.Broker.DocumentAdmission

/-- A scoped capability, allocated before source reads or queued document work. -/
structure Permit where
  private mk ::
  id : Nat
  uri : String
  deriving BEq, ReflBEq, LawfulBEq, DecidableEq, Repr

inductive Phase where
  | reading
  | closing
  | revoked
  deriving BEq, ReflBEq, LawfulBEq, DecidableEq, Repr

inductive Conflict where
  | closing
  | stale
  deriving BEq, ReflBEq, LawfulBEq, DecidableEq, Repr

/--
One workspace's in-flight document admissions. Released requests leave no path tombstone.
The enclosing runtime/workspace lifetime owns these capabilities and all transitions.
-/
structure State where
  private mk ::
  /-- Next permit identifier in this workspace lifetime; allocation never reuses it. -/
  nextId : Nat
  /-- In-flight scopes, including revoked permits retained until their owners release them. -/
  entries : List (Permit × Phase)
  deriving Repr

def State.empty : State := ⟨1, []⟩

def State.isClosing (state : State) (uri : String) : Bool :=
  state.entries.any fun (permit, phase) => permit.uri == uri && phase == .closing

def State.admit (state : State) (uri : String) : Except Conflict (State × Permit) :=
  if state.isClosing uri then .error .closing else
    let permit : Permit := ⟨state.nextId, uri⟩
    .ok (⟨state.nextId + 1, (permit, .reading) :: state.entries⟩, permit)

def State.check (state : State) (permit : Permit) : Except Conflict Unit :=
  match state.entries.find? (fun entry => entry.1 == permit) with
  | some (_, .reading) => .ok ()
  | some (_, .closing) => .ok ()
  | _ => .error (if state.isClosing permit.uri then .closing else .stale)

/-- Invalidate older work without invalidating the operation performing the transition. -/
def State.fence (state : State) (permit : Permit) : State :=
  { state with entries := state.entries.map fun (other, phase) =>
      (other, if other.uri == permit.uri && other != permit then .revoked else phase) }

def State.reserve (state : State) (permit : Permit) : Except Conflict State :=
  if state.isClosing permit.uri then .error .closing else
    match state.check permit with
    | .error conflict => .error conflict
    | .ok () => .ok { state with entries :=
        (permit, .closing) :: (state.fence permit).entries.filter (fun entry => entry.1 != permit) }

/-- Scope exit removes only this admission, never restores an older document or owner. -/
def State.release (state : State) (permit : Permit) : State :=
  { state with entries := state.entries.filter fun entry => entry.1 != permit }

/-- Invalidate held reads after a first worker error, retaining an existing close owner. -/
def State.revokeReading (state : State) (uri : String) : State :=
  { state with entries := state.entries.map fun (permit, phase) =>
      (permit, if permit.uri == uri && phase == .reading then .revoked else phase) }

/-- Backend replacement revokes old work but keeps allocation monotone until workspace removal. -/
def State.retire (state : State) : State :=
  { state with entries := state.entries.map fun (permit, _) => (permit, .revoked) }

end Beam.Broker.DocumentAdmission
