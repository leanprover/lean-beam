/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std

/-! One allocated request's local settlement lifecycle. Channel closure is projected onto this
request; other requests, wire delivery, and remote producer settlement are not represented.
Payloads and typed failure data are abstract atoms. `resolve` models the documented first-wins
promise primitive, not a theorem about Lean's runtime. See docs/CLOSE_SAVE_MODEL.md. -/
namespace BeamModel.RequestSettlement

inductive Outcome where
  | response (payload : Nat)
  | failure (cause : Nat)
  deriving BEq, DecidableEq, Repr

inductive Role where
  | reader | closer | writer | rejectedRegistration
  deriving BEq, DecidableEq, Repr

inductive Writer where
  | idle | inFlight | detached | done
  deriving BEq, DecidableEq, Repr

structure State where
  registered : Bool := false
  pending : Bool := false
  writer : Writer := .idle
  channelFailure : Option Nat := none
  claims : List (Role × Outcome) := []
  result : Option Outcome := none
  deriving BEq, DecidableEq, Repr

inductive Event where
  | register
  | reply (outcome : Outcome)
  | close (cause : Nat)
  | writeSucceeded
  | writeFailed
  | chooseWriteFailure (fallback : Nat)
  | resolve (role : Role)
  | cancel
  | peerCrash
  deriving BEq, DecidableEq, Repr

/-- A claim records the handler responsible for attempting resolution outside the map lock.
The primitive resolution itself is atomic in this model. An invocation can be redundant. -/
def resolve (s : State) (role : Role) : State :=
  match s.claims.find? (fun claim => claim.1 == role) with
  | none => s
  | some claim =>
      { s with claims := s.claims.filter (fun claim => claim.1 != role)
               result := s.result.or (some claim.2) }

def step (s : State) : Event → State
  | .register =>
      if s.registered then s else
      match s.channelFailure with
      | none => { s with registered := true, pending := true, writer := .inFlight }
      | some cause =>
          { s with registered := true
                   claims := (.rejectedRegistration, .failure cause) :: s.claims }
  | .reply outcome =>
      if s.pending then
        { s with pending := false, claims := (.reader, outcome) :: s.claims }
      else s
  | .close cause =>
      let retained := s.channelFailure.getD cause
      { s with channelFailure := some retained, pending := false
               claims := if s.pending then (.closer, .failure retained) :: s.claims else s.claims }
  | .writeSucceeded =>
      if s.writer = .inFlight then { s with writer := .done } else s
  | .writeFailed =>
      if s.writer = .inFlight then { s with writer := .detached, pending := false } else s
  | .chooseWriteFailure fallback =>
      if s.writer = .detached then
        { s with writer := .done
                 claims := (.writer, .failure (s.channelFailure.getD fallback)) :: s.claims }
      else s
  | .resolve role => resolve s role
  | .cancel | .peerCrash => s

def run : State → List Event → State
  | s, [] => s
  | s, event :: rest => run (step s event) rest

/-- No progress promise: a responsible actor may remain delayed indefinitely. -/
def HasCustodian (s : State) : Prop :=
  s.pending = true ∨ s.writer = .inFlight ∨ s.writer = .detached ∨ s.claims ≠ []

/-- A tracked request is either still in the map, in the writer's send/failure interval, owned
by a handler with a settlement claim, or already resolved. This is proof bookkeeping. -/
def Valid (s : State) : Prop :=
  (s.pending = true → s.channelFailure = none) ∧
  (s.registered = true → s.result ≠ none ∨ HasCustodian s) ∧
  (s.writer = .inFlight → s.pending = true ∨ s.claims ≠ [] ∨ s.result ≠ none)

end BeamModel.RequestSettlement
