# BUC-0005 Todo result filtering

- Status: deferred
- Priority: medium
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

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

The original large-proof trace has not been retested. Produce a completed
theorem with noisy broad todo output and compare narrow ranges/kinds. Decide
whether documentation or a small filter fixes the concrete confusion before
expanding the public API.

## Current workaround and removal target

Use sync/save readiness for checkpoint acceptance; use todo for targeted proof
inspection. No local shim deletion is established by the historical report.
