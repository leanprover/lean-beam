/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.DocumentAdmission

/-! Laws of the pure component used by the broker, rather than of its abstract specification. -/

namespace BeamModel.Admission

open Beam.Broker.DocumentAdmission

theorem closing_rejects_admission (state : State) (uri : String)
    (h : state.isClosing uri = true) : state.admit uri = .error .closing := by
  simp [State.admit, h]

theorem release_idempotent (state : State) (permit : Permit) :
    (state.release permit).release permit = state.release permit := by
  simp [State.release, List.filter_filter]

theorem release_preserves_other_entry (state : State) (permit other : Permit) (phase : Phase)
    (h : other ≠ permit) :
    (other, phase) ∈ (state.release permit).entries ↔ (other, phase) ∈ state.entries := by
  simp [State.release, h]

theorem release_removes_own_entry (state : State) (permit : Permit) (phase : Phase) :
    (permit, phase) ∉ (state.release permit).entries := by
  simp [State.release]

theorem reserve_blocks_admission (state next : State) (permit : Permit)
    (h : state.reserve permit = .ok next) :
    next.admit permit.uri = .error .closing := by
  unfold State.reserve at h
  split at h
  · simp at h
  · cases hc : state.check permit with
    | error _ => simp [hc] at h
    | ok _ =>
      simp [hc] at h
      subst next
      simp [State.admit, State.isClosing]

/-- Allocation cannot reuse a capability still retained by a live or revoked scope. -/
def Valid (state : State) : Prop :=
  ∀ entry ∈ state.entries, entry.1.id < state.nextId

theorem empty_valid : Valid State.empty := by simp [Valid, State.empty]

theorem admission_is_fresh (state next : State) (uri : String) (permit : Permit)
    (hv : Valid state) (h : state.admit uri = .ok (next, permit)) :
    Valid next ∧ ∀ phase, (permit, phase) ∉ state.entries := by
  unfold State.admit at h
  split at h
  · simp at h
  · cases h
    constructor
    · intro entry he
      simp only [List.mem_cons] at he
      rcases he with rfl | he
      · simp
      · exact Nat.lt_trans (hv entry he) (Nat.lt_succ_self _)
    · intro phase he
      have := hv _ he
      exact (Nat.lt_irrefl _ this)

theorem release_valid (state : State) (permit : Permit) (hv : Valid state) :
    Valid (state.release permit) := by
  intro entry he
  exact hv entry (List.mem_filter.mp he).1

theorem retire_valid (state : State) (hv : Valid state) : Valid state.retire := by
  intro entry he
  obtain ⟨old, ho, rfl⟩ := List.mem_map.mp he
  exact hv old ho

theorem fence_valid (state : State) (permit : Permit) (hv : Valid state) :
    Valid (state.fence permit) := by
  intro entry he
  obtain ⟨old, ho, rfl⟩ := List.mem_map.mp he
  exact hv old ho

private theorem checked_member (state : State) (permit : Permit)
    (h : state.check permit = .ok ()) : ∃ phase, (permit, phase) ∈ state.entries := by
  unfold State.check at h
  cases he : state.entries.find? (fun entry => entry.1 == permit) with
  | none => simp [he] at h
  | some entry =>
    have hp := List.find?_some he
    have hm := List.mem_of_find?_eq_some he
    have hp : entry.1 = permit := by simpa using hp
    exact ⟨entry.2, hp ▸ hm⟩

theorem reserve_valid (state next : State) (permit : Permit) (hv : Valid state)
    (h : state.reserve permit = .ok next) : Valid next := by
  unfold State.reserve at h
  split at h
  · simp at h
  · cases hc : state.check permit with
    | error _ => simp [hc] at h
    | ok value =>
      cases value
      obtain ⟨phase, hp⟩ := checked_member state permit hc
      simp [hc] at h
      subst next
      intro entry he
      simp only [List.mem_cons] at he
      rcases he with rfl | he
      · exact hv (permit, phase) hp
      · exact fence_valid state permit hv entry (List.mem_filter.mp he).1

end BeamModel.Admission
