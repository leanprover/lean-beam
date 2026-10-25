# ULC-0002 Backend readiness primitive

- Status: deferred
- Priority: medium
- Origin: Lean server
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

Beam's private checkpoint-readiness helper knows about diagnostics, final
command state, and snapshot completion. A shared Lean helper might reduce
duplication, but the old proposal has not established a reusable upstream API.

Park the broad readiness umbrella. The stale URI improvement in
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md) can proceed
independently using diagnostic metadata. It does not require a new readiness
service. [ULC-0005](../ULC-0005-pure-frontend-readiness-report/README.md) remains
folded into this design question.

## Evidence and next action

Existing Beam behavior is documented under
[broker/server boundaries](../../../DEVELOPMENT.md#broker-server-boundaries).
It shows a consumer, not agreement that Lean should expose Beam's policy.
Resume only with another concrete consumer or a small independently useful
helper and a clear before/after deletion.

## Current workaround and removal target

Retain the typed backend readiness verdict and its tests. Progress and broker
diagnostic counts do not replace that authority. No helper deletion is promised.
