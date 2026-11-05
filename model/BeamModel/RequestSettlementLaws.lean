/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.RequestSettlement

namespace BeamModel.RequestSettlement

theorem initial_valid : Valid {} := by simp [Valid]

theorem resolve_preserves_result (s : State) (role : Role) (outcome : Outcome)
    (h : s.result = some outcome) : (resolve s role).result = some outcome := by
  simp only [resolve]
  split <;> simp_all

theorem step_preserves_result (s : State) (event : Event) (outcome : Outcome)
    (h : s.result = some outcome) : (step s event).result = some outcome := by
  cases event <;> simp only [step]
  all_goals first | exact h | exact resolve_preserves_result _ _ _ h | skip
  all_goals split <;> simp_all
  all_goals split <;> simp_all

theorem run_preserves_result (s : State) (events : List Event) (outcome : Outcome)
    (h : s.result = some outcome) : (run s events).result = some outcome := by
  induction events generalizing s with
  | nil => exact h
  | cons event rest ih => exact ih _ (step_preserves_result _ _ _ h)

theorem resolve_valid (s : State) (role : Role) (h : Valid s) : Valid (resolve s role) := by
  unfold resolve
  split
  · exact h
  · rcases h with ⟨hp, hr, hw⟩
    simp only [Valid]
    cases s.result <;> simp_all

theorem step_valid (s : State) (event : Event) (h : Valid s) : Valid (step s event) := by
  cases event with
  | resolve role => exact resolve_valid _ _ h
  | cancel => exact h
  | peerCrash => exact h
  | register =>
    simp only [step]
    split
    · exact h
    · split <;> simp_all [Valid, HasCustodian]
  | reply payload =>
    simp only [step]
    split
    · simp_all [Valid, HasCustodian]
    · exact h
  | close cause =>
    cases hp : s.pending <;> simp_all [step, Valid, HasCustodian]
  | writeSucceeded =>
    simp only [step]
    split
    · simp_all [Valid, HasCustodian]
      intro _
      rcases h.2 with hp | hc | hr <;> simp_all
    · exact h
  | writeFailed =>
    simp only [step]
    split
    · simp_all [Valid, HasCustodian]
    · exact h
  | chooseWriteFailure fallback =>
    simp only [step]
    split
    · simp_all [Valid, HasCustodian]
    · exact h

theorem run_valid (s : State) (events : List Event) (h : Valid s) : Valid (run s events) := by
  induction events generalizing s with
  | nil => exact h
  | cons event rest ih => exact ih _ (step_valid _ _ h)

theorem step_preserves_first_failure (s : State) (event : Event) (cause : Nat)
    (h : s.channelFailure = some cause) :
    (step s event).channelFailure = some cause := by
  cases event <;> simp only [step]
  all_goals first | exact h | skip
  all_goals try simp [resolve, h]
  all_goals split <;> simp_all
  all_goals split <;> simp_all

theorem run_preserves_first_failure (s : State) (events : List Event) (cause : Nat)
    (h : s.channelFailure = some cause) :
    (run s events).channelFailure = some cause := by
  induction events generalizing s with
  | nil => exact h
  | cons event rest ih => exact ih _ (step_preserves_first_failure _ _ _ h)

theorem close_preserves_detached_claims (s : State) (cause : Nat) (h : s.pending = false) :
    (step s (.close cause)).claims = s.claims := by simp [step, h]

theorem resolve_without_claim_inert (s : State) (role : Role)
    (h : s.claims.find? (fun claim => claim.1 == role) = none) :
    step s (.resolve role) = s := by simp [step, resolve, h]

theorem cancel_preserves_responsibility (s : State) : step s .cancel = s := rfl

theorem unobserved_crash_preserves_responsibility (s : State) : step s .peerCrash = s := rfl

/-- Safety, not eventual settlement: every reachable unresolved registration retains a custodian. -/
theorem unresolved_has_custodian (events : List Event)
    (registered : (run {} events).registered = true)
    (unresolved : (run {} events).result = none) : HasCustodian (run {} events) := by
  have h := (run_valid {} events initial_valid).2.1 registered
  exact h.resolve_left (by simp [unresolved])

theorem closed_has_no_pending (s : State) (cause : Nat) (valid : Valid s)
    (h : s.channelFailure = some cause) : s.pending = false := by
  cases hp : s.pending
  · rfl
  · have := valid.1 hp
    simp [h] at this

end BeamModel.RequestSettlement
