# BUC-0002 Tactic-position term ascription failure

- Status: resolved
- Priority: high
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

`have htest := (Nat.succ : Nat)` in a speculative tactic request once produced
only `internal exception #5` instead of the ordinary Lean type error.
Preserve the earlier decision to close this report: semantic failure should
return the type mismatch and must not create a successor handle.

## Evidence

The July 7 review reported a passing `checkRunAtHandleTermAscriptionFailure`
regression in [the handle API tests](../../../../tests/lean/BeamTest/LSP/Handle/Api.lean).
This is historical validation, not a new execution result. Reopen only with a
current reduced failure; do not add a separate error-handling abstraction.

## Current workaround and removal target

No additional workaround is proposed. Keep the semantic-failure regression.
