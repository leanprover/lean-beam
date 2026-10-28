/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.BackendProtocol
import BeamModel.RequestSettlementLaws

/-! Partial correspondence between two abstract models, not production refinement.
One allocated request is embedded in the earlier store-observation model. Resolution and failure
selection are invisible there. Writer detachment has no event in that earlier model: do not infer a
complete simulation from these individual commuting laws. -/
namespace BeamModel.RequestSettlement

/-- The request's incarnation is external and fixed throughout this local lifecycle. -/
def observation (s : State) (key : BackendProtocol.Key) : BackendProtocol.State := {
  incarnation := key.incarnation
  accepting := s.channelFailure.isNone
  pending := if s.pending then [key] else []
}

theorem reply_observation (s : State) (key : BackendProtocol.Key) (outcome : Outcome) :
    observation (step s (.reply outcome)) key =
      (BackendProtocol.step (observation s key) (.reply key)).1 := by
  cases hp : s.pending <;> simp [step, observation, BackendProtocol.step, hp]

theorem close_observation (s : State) (key : BackendProtocol.Key) (cause : Nat) :
    observation (step s (.close cause)) key =
      (BackendProtocol.step (observation s key) .closeChannel).1 := by
  simp [step, observation, BackendProtocol.step]

theorem resolution_is_observation_stutter (s : State) (key : BackendProtocol.Key) (role : Role) :
    observation (step s (.resolve role)) key = observation s key := by
  simp only [step, resolve]
  split <;> rfl

theorem write_failure_selection_is_observation_stutter
    (s : State) (key : BackendProtocol.Key) (cause : Nat) :
    observation (step s (.chooseWriteFailure cause)) key = observation s key := by
  simp only [step]
  split <;> rfl

theorem reply_claim_matches_observation (s : State) (key : BackendProtocol.Key)
    (outcome : Outcome) (h : s.pending = true) :
    (BackendProtocol.step (observation s key) (.reply key)).2 =
      [.settle key .response] ∧
    (step s (.reply outcome)).claims = (.reader, outcome) :: s.claims := by
  simp [step, observation, BackendProtocol.step, h]

theorem close_claim_matches_observation (s : State) (key : BackendProtocol.Key)
    (cause : Nat) (h : s.pending = true) :
    (BackendProtocol.step (observation s key) .closeChannel).2 =
      [.settle key .channelFailure] ∧
    (step s (.close cause)).claims =
      (.closer, .failure (s.channelFailure.getD cause)) :: s.claims := by
  simp [step, observation, BackendProtocol.step, h]

end BeamModel.RequestSettlement
