/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std

/-! An observation-level specification, not an implementation proof or an LSP interpreter.
A key includes its backend incarnation. Physical peer failure and broker observation are separate.
`settle` transfers responsibility for resolving a promise; it does not assert resolution happened. -/
namespace BeamModel.BackendProtocol

structure Key where
  incarnation : Nat
  request : Nat
  deriving BEq, ReflBEq, LawfulBEq, DecidableEq, Repr

inductive Outcome where
  | response | channelFailure
  deriving BEq, DecidableEq, Repr

inductive Effect where
  | settle (key : Key) (outcome : Outcome)
  deriving BEq, DecidableEq, Repr

structure State where
  incarnation : Nat
  accepting : Bool := true
  pending : List Key := []
  deriving BEq, DecidableEq, Repr

inductive Event where
  | register (key : Key)
  | reply (key : Key)
  | cancel (key : Key)
  | peerCrash
  | closeChannel
  deriving BEq, DecidableEq, Repr

/-- FIFO input and server execution belong to a later peer model. This core records only local
admission, response correlation, and transfer of settlement responsibility. Registration is before
send; a registered request need not have reached the peer. No transition infers producer settlement. -/
def step (s : State) : Event → State × List Effect
  | .register key =>
      if s.accepting && key.incarnation == s.incarnation && !(s.pending.contains key) then
        ({ s with pending := s.pending ++ [key] }, [])
      else (s, [])
  | .reply key =>
      if key.incarnation == s.incarnation && s.pending.contains key then
        ({ s with pending := s.pending.filter (· != key) }, [.settle key .response])
      else (s, [])
  | .cancel _ => (s, [])
  | .peerCrash => (s, [])
  | .closeChannel =>
      ({ s with accepting := false, pending := [] },
        s.pending.map (fun key => .settle key .channelFailure))

theorem cancel_does_not_settle (s : State) (key : Key) :
    step s (.cancel key) = (s, []) := rfl

theorem crash_is_not_observation (s : State) : step s .peerCrash = (s, []) := rfl

theorem closed_rejects_registration (s : State) (key : Key) :
    step (step s .closeChannel).1 (.register key) = ((step s .closeChannel).1, []) := by
  simp [step]

theorem close_is_idempotent (s : State) :
    step (step s .closeChannel).1 .closeChannel = ((step s .closeChannel).1, []) := by
  simp [step]

theorem closed_ignores_reply (s : State) (key : Key) :
    step (step s .closeChannel).1 (.reply key) = ((step s .closeChannel).1, []) := by
  simp [step]

theorem foreign_reply_ignored (s : State) (key : Key)
    (h : key.incarnation ≠ s.incarnation) : step s (.reply key) = (s, []) := by
  simp [step, h]

-- A silent crashed peer can leave work pending. This is permitted, not a liveness theorem.
example : (step { incarnation := 7, pending := [⟨7, 1⟩] } .peerCrash).1.pending =
    [⟨7, 1⟩] := rfl

-- Reply order need not follow registration order.
example : (step { incarnation := 7, pending := [⟨7, 1⟩, ⟨7, 2⟩] }
    (.reply ⟨7, 2⟩)).1.pending = [⟨7, 1⟩] := by decide

end BeamModel.BackendProtocol
