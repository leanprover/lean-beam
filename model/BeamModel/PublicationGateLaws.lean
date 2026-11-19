/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Beam.Broker.PublicationGate

/-! Laws over the production gate, not a second representation of its decisions. -/
namespace BeamModel.PublicationGate

open Beam.Broker.PublicationGate

theorem busy_rejects_claim (state : State α) (workspace : String) (completion : α)
    (h : state.current?.isSome = true) : state.claim workspace completion = none := by
  simp [State.claim, h]

/-- Successful acquisition installs exactly its returned claim and advances the runtime counter. -/
theorem claim_installs (state next : State α) (workspace : String) (completion : α)
    (claim : Claim α) (h : state.claim workspace completion = some (next, claim)) :
    next.current? = some claim ∧ claim.token = state.nextToken ∧
      next.nextToken = state.nextToken + 1 ∧ claim.workspaceId = workspace ∧
      claim.completion = completion := by
  unfold State.claim at h
  split at h
  · simp at h
  · cases h
    simp

theorem claim_requires_available (state next : State α) (workspace : String) (completion : α)
    (claim : Claim α) (h : state.claim workspace completion = some (next, claim)) :
    state.current? = none := by
  cases hc : state.current? with
  | none => rfl
  | some current => simp [State.claim, hc] at h

def Valid (state : State α) : Prop :=
  ∀ claim, state.current? = some claim → claim.token < state.nextToken

theorem empty_valid : Valid (State.empty : State α) := by simp [Valid, State.empty]

theorem claim_valid (state next : State α) (workspace : String) (completion : α)
    (claim : Claim α) (h : state.claim workspace completion = some (next, claim)) :
    Valid next := by
  obtain ⟨hc, ht, hn, _, _⟩ := claim_installs state next workspace completion claim h
  intro other ho
  have he : other = claim := by simpa [hc] using ho.symm
  subst other
  simp [ht, hn]

theorem release_foreign (state : State α) (claim : Claim α) (token : Nat)
    (h : state.current? = some claim) (hne : claim.token ≠ token) :
    state.release token = state := by
  simp [State.release, h, hne]

theorem release_own (state : State α) (claim : Claim α)
    (h : state.current? = some claim) :
    (state.release claim.token).current? = none := by
  simp [State.release, h]

theorem release_idempotent (state : State α) (token : Nat) :
    (state.release token).release token = state.release token := by
  unfold State.release
  split <;> simp_all

theorem release_preserves_counter (state : State α) (token : Nat) :
    (state.release token).nextToken = state.nextToken := by
  unfold State.release
  split <;> rfl

theorem release_valid (state : State α) (token : Nat) (hv : Valid state) :
    Valid (state.release token) := by
  unfold State.release
  split
  · simp [Valid]
  · exact hv

/-- A token from an earlier allocation cannot release a newly acquired claim. -/
theorem old_release_after_claim (state next : State α) (workspace : String) (completion : α)
    (claim : Claim α) (old : Nat) (hold : old < state.nextToken)
    (h : state.claim workspace completion = some (next, claim)) :
    next.release old = next := by
  obtain ⟨hc, ht, _⟩ := claim_installs state next workspace completion claim h
  apply release_foreign next claim old hc
  omega

theorem own_workspace_waits (state : State α) (claim : Claim α)
    (h : state.current? = some claim) :
    state.waitFor? (some claim.workspaceId) = some claim.completion := by
  simp [State.waitFor?, h]

theorem runtime_waits (state : State α) (claim : Claim α)
    (h : state.current? = some claim) : state.waitFor? none = some claim.completion := by
  simp [State.waitFor?, h]

theorem other_workspace_does_not_wait (state : State α) (claim : Claim α) (workspace : String)
    (h : state.current? = some claim) (hne : workspace ≠ claim.workspaceId) :
    state.waitFor? (some workspace) = none := by
  simp [State.waitFor?, h, hne]

theorem released_does_not_wait (state : State α) (claim : Claim α) (workspace? : Option String)
    (h : state.current? = some claim) :
    (state.release claim.token).waitFor? workspace? = none := by
  simp [State.waitFor?, release_own state claim h]

end BeamModel.PublicationGate
