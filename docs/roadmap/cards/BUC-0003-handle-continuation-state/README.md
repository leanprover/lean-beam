# BUC-0003 Handle continuation state

- Status: deferred
- Priority: medium
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

The historical proofmode report found goals without a handle and ambiguity
about focused versus sibling goals after continuation. It did not establish
that the continuation implementation was incorrect.

Defer a larger metadata surface. Handles remain extensions around
`runAt(pos, "lean text")`; first reproduce a concrete decision a caller cannot
make from the current response. The earlier collection of proposed focus and
goal-count fields is not an accepted API.

## Evidence and next action

The original downstream trace has not been retested. Compare a minimized
branch-closing example against
[handle API coverage](../../../../tests/lean/BeamTest/LSP/Handle/Api.lean),
including failed successors and release/invalidation, before proposing a field.

## Current workaround and removal target

Use small handle continuations and validate the saved theorem through normal
sync/save. No workaround deletion is identified until the ambiguity is reproduced.
