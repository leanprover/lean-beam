/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import BeamModel.Closing

namespace BeamModel.Closing

theorem closing_rejects_read (state : State) (lease : Lease)
    (h : state.lifecycle = .closing lease) :
    beginRead state = .error .closing := by
  simp [beginRead, h]

theorem closing_rejects_acceptance (state : State) (lease : Lease)
    (permit : ReadPermit) (source : Nat) (h : state.lifecycle = .closing lease) :
    acceptRead state permit source = (state, .error .closing) ∧
      reserve state permit source = (state, .error .closing) ∧
      close state = (state, .error .closing) := by
  simp [acceptRead, reserve, close, h]

theorem foreign_release_unchanged (state : State) (lease : Lease)
    (h : state.lifecycle ≠ .closing lease) : release state lease = state := by
  simp [release, h]

theorem release_idempotent (state : State) (lease : Lease) :
    release (release state lease) lease = release state lease := by
  unfold release
  split <;> simp_all

theorem finish_requires_ownership (state next : State) (lease : Lease)
    (h : finish state lease = (next, .ok ())) :
    state.lifecycle = .closing lease ∧ saved state lease = true ∧
      next.lifecycle = .open none := by
  unfold finish at h
  split at h
  · split at h
    · cases h
      simp_all
    · simp at h
  · simp at h

theorem finalizer_after_success_is_inert (state next : State) (lease : Lease)
    (h : finish state lease = (next, .ok ())) :
    release next lease = next := by
  have hn := (finish_requires_ownership state next lease h).2.2
  simp [release, hn]

/-- A source read from before reservation stays invalid even after cleanup reopens the same basis. -/
theorem old_read_after_release (owner fence nextBasis source : Nat) (doc : Document)
    (receipts : List Lease) :
    let lease : Lease := { owner, fence := fence + 1, document := doc }
    let state : State := {
      owner, fence := fence + 1, nextBasis, lifecycle := .closing lease, committed := receipts }
    acceptRead (release state lease) ⟨owner, fence⟩ source =
      (release state lease, .error .staleRead) := by
  simp [release, acceptRead, State.permit]

/-- Retaining the fence in an absent slot prevents a delayed read from resurrecting it. -/
theorem old_read_after_close (owner fence nextBasis source : Nat) (receipts : List Lease) :
    let state : State := {
      owner, fence := fence + 1, nextBasis, lifecycle := .open none, committed := receipts }
    acceptRead state ⟨owner, fence⟩ source = (state, .error .staleRead) := by
  simp [acceptRead, State.permit]

theorem old_lease_after_replacement (state : State) (lease : Lease) :
    finish (replace state) lease = (replace state, .error .staleLease) ∧
      release (replace state) lease = replace state := by
  simp [finish, replace, release]

theorem old_read_after_replacement (state : State) (source : Nat) :
    acceptRead (replace state) state.permit source =
      (replace state, .error .staleRead) := by
  simp [acceptRead, replace, State.permit]

private theorem acceptance_preserves_permit (state : State) (permit : ReadPermit) (source : Nat) :
    (acceptRead state permit source).1.permit = state.permit := by
  unfold acceptRead
  split
  · rfl
  · split
    · simp only [acceptSource]
      split
      · split <;> rfl
      · rfl
    · rfl

/-- Every successful acquisition advances admission and installs exactly the returned owner. -/
theorem reservation_installs_fresh_lease (state next : State) (permit : ReadPermit)
    (source : Nat) (lease : Lease) (h : reserve state permit source = (next, .ok lease)) :
    next.lifecycle = .closing lease ∧ lease.owner = state.owner ∧
      lease.fence = state.fence + 1 ∧ next.permit = lease.toReadPermit := by
  have hp := acceptance_preserves_permit state permit source
  unfold reserve at h
  cases he : acceptRead state permit source with
  | mk accepted result =>
    rw [he] at h hp
    cases result with
    | error _ => simp at h
    | ok doc =>
      cases h
      have ho := congrArg ReadPermit.owner hp
      have hf := congrArg ReadPermit.fence hp
      simpa [State.permit] using And.intro ho hf

private theorem acceptance_preserves_receipts (state : State) (permit : ReadPermit) (source : Nat) :
    (acceptRead state permit source).1.committed = state.committed := by
  unfold acceptRead
  split
  · rfl
  · split
    · simp only [acceptSource]
      split
      · split <;> rfl
      · rfl
    · rfl

theorem step_preserves_commit (state : State) (action : Action) (lease : Lease)
    (h : lease ∈ state.committed) : lease ∈ (step state action).1.committed := by
  cases action with
  | accept permit source =>
    simpa only [step, acceptance_preserves_receipts] using h
  | reserve permit source =>
    have hc := acceptance_preserves_receipts state permit source
    simp only [step, reserve]
    cases he : acceptRead state permit source with
    | mk next result =>
      rw [he] at hc
      dsimp only at hc
      cases result <;> simpa [hc] using h
  | release lease =>
    simp only [step, release]
    split <;> exact h
  | committed lease => exact List.mem_cons_of_mem _ h
  | finish lease =>
    simp only [step, finish]
    split
    · split <;> exact h
    · exact h
  | close =>
    simp only [step, close]
    split <;> exact h
  | replace => exact h

/-- Every finite interleaving retains evidence of a committed checkpoint, even across owner loss. -/
theorem run_preserves_commit (state : State) (actions : List Action) (lease : Lease)
    (h : lease ∈ state.committed) : lease ∈ (run state actions).committed := by
  induction actions generalizing state with
  | nil => exact h
  | cons action rest ih => exact ih _ (step_preserves_commit state action lease h)

/-- Every installed lease belongs to this owner and this admission fence. -/
def State.Valid (state : State) : Prop :=
  match state.lifecycle with
  | .closing lease => lease.toReadPermit = state.permit
  | .open _ => True

theorem initial_valid : State.Valid {} := by trivial

private theorem acceptance_valid (state : State) (permit : ReadPermit) (source : Nat)
    (h : state.Valid) : (acceptRead state permit source).1.Valid := by
  unfold acceptRead
  split
  · exact h
  · split
    · simp only [acceptSource]
      split
      · split
        · exact h
        · trivial
      · trivial
    · exact h

theorem step_valid (state : State) (action : Action) (h : state.Valid) :
    (step state action).1.Valid := by
  cases action with
  | accept permit source => exact acceptance_valid state permit source h
  | reserve permit source =>
    have hv := acceptance_valid state permit source h
    simp only [step, reserve]
    cases he : acceptRead state permit source with
    | mk accepted result =>
      rw [he] at hv
      cases result with
      | error _ => exact hv
      | ok _ => rfl
  | release lease =>
    simp only [step, release]
    split
    · trivial
    · exact h
  | committed lease => exact h
  | finish lease =>
    simp only [step, finish]
    split
    · split
      · trivial
      · exact h
    · exact h
  | close =>
    simp only [step, close]
    split
    · exact h
    · trivial
  | replace => trivial

theorem run_valid (state : State) (actions : List Action) (h : state.Valid) :
    (run state actions).Valid := by
  induction actions generalizing state with
  | nil => exact h
  | cons action rest ih => exact ih _ (step_valid state action h)

end BeamModel.Closing
