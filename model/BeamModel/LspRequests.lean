/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std

/-! A safety projection of LSP 3.17 request lifetimes, in one direction of one connection.
IDs are interned atoms, not a restriction of LSP's integer/string wire IDs. Initialization,
method semantics, byte delivery, faults, and eventual response obligations are outside this slice.
See docs/CLOSE_SAVE_MODEL.md, "LSP clause provenance". -/
namespace BeamModel.LspRequests

abbrev Id := Nat

structure State where
  /-- Request IDs still owed a response in this direction of the protocol connection. -/
  outstanding : List Id := []
  deriving BEq, DecidableEq, Repr

inductive Event where
  | request (id : Id)
  | response (id : Id)
  | cancel (id : Id)
  | notification
  deriving BEq, DecidableEq, Repr

/-- `none` rejects a trace at this abstraction boundary. Response payloads, including success,
error, and null success, are erased. A cancellation notification is not a terminal response. -/
def step (s : State) : Event → Option State
  | .request id =>
      if id ∈ s.outstanding then none
      else some { outstanding := s.outstanding ++ [id] }
  | .response id =>
      if id ∈ s.outstanding then some { outstanding := s.outstanding.filter (· != id) }
      else none
  | .cancel _ | .notification => some s

def run : State → List Event → Option State
  | s, [] => some s
  | s, event :: rest => (step s event).bind (fun next => run next rest)

theorem cancellation_preserves_obligation (s : State) (id : Id) :
    step s (.cancel id) = some s := rfl

theorem notification_preserves_obligations (s : State) :
    step s .notification = some s := rfl

theorem unmatched_response_rejected (s : State) (id : Id) (h : id ∉ s.outstanding) :
    step s (.response id) = none := by simp [step, h]

theorem duplicate_registration_rejected (s : State) (id : Id) (h : id ∈ s.outstanding) :
    step s (.request id) = none := by simp [step, h]

theorem response_consumes_obligation (s next : State) (id : Id)
    (h : step s (.response id) = some next) : id ∉ next.outstanding := by
  simp only [step] at h
  split at h
  · cases h
    simp
  · contradiction

theorem duplicate_response_rejected (s next : State) (id : Id)
    (h : step s (.response id) = some next) : step next (.response id) = none :=
  unmatched_response_rejected next id (response_consumes_obligation s next id h)

/-- Finite-prefix safety: every accepted step preserves uniqueness of outstanding IDs. -/
theorem step_preserves_unique (s next : State) (event : Event)
    (unique : s.outstanding.Nodup) (h : step s event = some next) :
    next.outstanding.Nodup := by
  cases event with
  | request id =>
    simp only [step] at h
    split at h
    · contradiction
    · cases h
      simp_all [List.nodup_append]
      intro a ha he
      subst a
      contradiction
  | response id =>
    simp only [step] at h
    split at h
    · cases h
      exact unique.filter _
    · contradiction
  | cancel id => cases h; exact unique
  | notification => cases h; exact unique

theorem run_preserves_unique (s next : State) (events : List Event)
    (unique : s.outstanding.Nodup) (h : run s events = some next) :
    next.outstanding.Nodup := by
  induction events generalizing s with
  | nil => cases h; exact unique
  | cons event rest ih =>
    cases hs : step s event with
    | none => simp [run, hs] at h
    | some middle =>
      apply ih middle (step_preserves_unique s middle event unique hs)
      simpa [run, hs] using h

end BeamModel.LspRequests
