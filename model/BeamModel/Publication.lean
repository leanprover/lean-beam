/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std

/-! One private publication attempt. Distinct attempts have disjoint candidate paths, an external
allocation assumption. `current` abstracts successful broker identity/basis validation. Canonical
commit is atomic here; filesystem crashes, rollback, sidecars, and other processes are unmodeled. -/
namespace BeamModel.Publication

inductive Phase where
  | preparing | ready | committed | abandoned
  deriving BEq, DecidableEq, Repr

structure State where
  /-- Authority phase of this private publication attempt. -/
  phase : Phase := .preparing
  /-- Abstract result of validating the captured owner and accepted source basis. -/
  current : Bool := true
  /-- Successful private worker completion has been accepted. -/
  workerDone : Bool := false
  /-- Successful trace preparation has made this attempt ready. -/
  traceDone : Bool := false
  /-- Proof counter of isolated writes, which can continue after abandonment. -/
  privateWrites : Nat := 0
  /-- Proof counter of atomic abstract promotions, not filesystem operation count. -/
  canonicalCommits : Nat := 0
  deriving BEq, DecidableEq, Repr

inductive Action where
  | privateWrite | workerComplete | traceComplete | promote | abandon | ownerLost
  deriving BEq, DecidableEq, Repr

def step (state : State) : Action → State
  | .privateWrite => { state with privateWrites := state.privateWrites + 1 }
  | .workerComplete =>
      if state.phase = .preparing ∧ state.current then { state with workerDone := true }
      else state
  | .traceComplete =>
      if state.phase = .preparing ∧ state.current ∧ state.workerDone then
        { state with phase := .ready, traceDone := true }
      else state
  | .promote =>
      if state.phase = .ready ∧ state.current then
        { state with phase := .committed, canonicalCommits := state.canonicalCommits + 1 }
      else state
  | .abandon =>
      if state.phase = .committed then state else { state with phase := .abandoned }
  | .ownerLost =>
      { state with
        current := false
        phase := if state.phase = .committed then .committed else .abandoned }

def run (state : State) : List Action → State
  | [] => state
  | action :: rest => run (step state action) rest

end BeamModel.Publication
