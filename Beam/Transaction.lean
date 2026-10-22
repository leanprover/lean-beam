/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Init.System.IO

namespace Beam.Transaction

/-- An unsuccessful recovery action, identified by its index in the supplied plan. -/
structure ActionFailure (ε : Type) where
  actionIndex : Nat
  error : ε

/-- Cleanup after commit cannot undo a committed result. Failed rollback preserves the original
failure alongside every recovery failure; neither outcome discards errors from the other phase. -/
inductive Outcome (ε α : Type) where
  | committed (value : α) (cleanupFailures : Array (ActionFailure ε))
  | aborted (error : ε) (rollbackFailures : Array (ActionFailure ε))

private def recover (actions : Array (EIO ε Unit)) : BaseIO (Array (ActionFailure ε)) := do
  let mut failures := #[]
  for (action, index) in actions.toList.zipIdx.reverse do
    match ← action.toBaseIO with
    | .ok () => pure ()
    | .error error => failures := failures.push { actionIndex := index, error }
  pure failures

/-- Run an operation with a prepared recovery plan. On failure, attempt every rollback action in
reverse order. On success, attempt every cleanup action in reverse order instead.

Rollback must be valid even when the operation failed before changing anything, or after changing
only part of its state. Callers establish ownership and prepare the necessary beforeimages before
entering this scope. Acquisition can itself use a transaction with its own recovery plan.

There is deliberately no unconditional cleanup after rollback: a failed recovery may need to retain
its resources. The helper neither provides concurrent isolation nor recovers from process death. -/
def run (action : EIO ε α)
    (rollback : Array (EIO ε Unit) := #[])
    (cleanup : Array (EIO ε Unit) := #[]) : BaseIO (Outcome ε α) := do
  match ← action.toBaseIO with
  | .ok value => return .committed value (← recover cleanup)
  | .error error => return .aborted error (← recover rollback)

end Beam.Transaction
