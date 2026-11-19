/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std

/-! Pure claim decisions used under the broker state lock. The payload is opaque: production
stores a completion promise, but these transitions neither wait for nor resolve it. -/
namespace Beam.Broker.PublicationGate

structure Claim (α : Type) where
  private mk ::
  token : Nat
  workspaceId : String
  completion : α

/-- One runtime's publication gate. Allocation remains monotone across workspace replacement. -/
structure State (α : Type) where
  private mk ::
  nextToken : Nat
  current? : Option (Claim α)

def State.empty : State α := ⟨1, none⟩

/-- The caller must validate document ownership, basis and cancellation in the same protected
transition. A successful claim authorizes entering the separately checked publication plan. -/
def State.claim (state : State α) (workspaceId : String) (completion : α) :
    Option (State α × Claim α) :=
  if state.current?.isSome then none else
    let claim : Claim α := ⟨state.nextToken, workspaceId, completion⟩
    some (⟨state.nextToken + 1, some claim⟩, claim)

/-- Stale cleanup cannot release a later claim. This does not resolve the completion payload. -/
def State.release (state : State α) (token : Nat) : State α :=
  if state.current?.any (·.token == token) then { state with current? := none } else state

/-- `none` selects runtime-wide changes; a named workspace waits only for its own publication. -/
def State.waitFor? (state : State α) (workspaceId? : Option String) : Option α := do
  let claim ← state.current?
  if workspaceId?.all (· == claim.workspaceId) then some claim.completion else none

end Beam.Broker.PublicationGate
