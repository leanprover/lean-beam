# BUC-0005 Todo result filtering

- Status: candidate
- Priority: high
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-27
- Backlog owner: Beam integration coordinator
- Implementer: tracked in Beam #377
- Issue: none linked
- PR: https://github.com/leanprover/lean-beam/pull/377 (0.2.0)

## Problem and decision

The older card mixed todo noise, progress reporting, and readiness. Narrow it
to whether broad `lean_todo` includes intermediate proof states that callers
mistake for unfinished saved declarations. A readiness mode or new diagnostic
taxonomy is not yet justified.

Progress/readiness semantics stay in
[Sync and Diagnostics](../../../SYNC_AND_DIAGNOSTICS.md).
Setup-file tagging belongs to
[ULC-0003](../ULC-0003-structured-setup-file-progress/README.md).

## Evidence and next action

The original large-proof trace has not been retested. The current Beam proposal,
[#377](https://github.com/leanprover/lean-beam/pull/377), addresses noise from
completed proofs, sibling goals, and the relationship between worklist items and
`runAt` positions. Its revised implementation is under review for 0.2.0; this
card does not certify the final head or claim that the original trace passed.
Keep readiness and checkpoint acceptance separate from this worklist API.

## Current workaround and removal target

Use sync/save readiness for checkpoint acceptance; use todo for targeted proof
inspection. No local shim deletion is established by the historical report.
