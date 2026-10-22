/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.Publication

namespace BeamModel.Publication

theorem late_completions_inert (state : State) (h : state.phase = .abandoned) :
    step state .workerComplete = state ∧ step state .traceComplete = state := by
  simp [step, h]

theorem abandoned_step (state : State) (action : Action) (h : state.phase = .abandoned) :
    (step state action).phase = .abandoned ∧
      (step state action).canonicalCommits = state.canonicalCommits := by
  cases action <;> simp [step, h]

/-- An old private writer may continue, but no later completion/action restores publication authority. -/
theorem abandoned_run (state : State) (actions : List Action) (h : state.phase = .abandoned) :
    (run state actions).phase = .abandoned ∧
      (run state actions).canonicalCommits = state.canonicalCommits := by
  induction actions generalizing state with
  | nil => exact ⟨h, rfl⟩
  | cons action rest ih =>
      have hs := abandoned_step state action h
      have hr := ih (step state action) hs.1
      exact ⟨hr.1, hr.2.trans hs.2⟩

theorem not_ready_cannot_publish (state : State) (h : state.phase ≠ .ready) :
    step state .promote = state := by simp [step, h]

theorem stale_owner_cannot_publish (state : State) (h : state.current = false) :
    step state .promote = state := by simp [step, h]

theorem trace_requires_worker_completion (state : State) (h : state.workerDone = false) :
    step state .traceComplete = state := by simp [step, h]

theorem abandon_preserves_commit_receipt (state : State) :
    (step state .abandon).canonicalCommits = state.canonicalCommits := by
  simp only [step]
  split <;> rfl

/-- Reachable ready/committed states have both acknowledgements, and each attempt commits once. -/
def State.Valid (state : State) : Prop :=
  ((state.phase = .ready ∨ state.phase = .committed) →
    state.workerDone = true ∧ state.traceDone = true) ∧
  state.canonicalCommits = (if state.phase = .committed then 1 else 0)

theorem initial_valid : State.Valid {} := by simp [State.Valid]

theorem step_valid (state : State) (action : Action) (h : state.Valid) :
    (step state action).Valid := by
  cases action <;> cases hp : state.phase <;> cases hc : state.current <;>
    cases hw : state.workerDone <;> cases ht : state.traceDone <;>
    simp_all [State.Valid, step]

theorem run_valid (state : State) (actions : List Action) (h : state.Valid) :
    (run state actions).Valid := by
  induction actions generalizing state with
  | nil => exact h
  | cons action rest ih => exact ih _ (step_valid state action h)

theorem valid_commit_bound (state : State) (h : state.Valid) :
    state.canonicalCommits ≤ 1 := by
  have hc := h.2
  split at hc <;> omega

end BeamModel.Publication
