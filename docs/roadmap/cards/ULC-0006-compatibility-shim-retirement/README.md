# ULC-0006 Compatibility shim retirement

- Status: deferred
- Priority: low
- Origin: Beam compatibility policy
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Decision

This is a support-window decision, not an upstream API request. The old list
of source identity, traces, C emission, and diagnostics shims is obsolete.
Current [compatibility guidance](../../../DEVELOPMENT.md#lean-compatibility-shims)
identifies `mkModuleOutputDescrsCompat`: Lake 4.33–4.35 requires `c`, while
4.36 and the pinned nightly use optional `c?`.

Revisit only when [Compatibility Policy](../../../COMPATIBILITY.md) changes the
admitted window. Delete the obsolete branch with the retired target; do not
recreate aliases or version negotiation. The live registries and developer
guide own the detailed list, avoiding a second drifting inventory here.

## Evidence and next action

Source inspection of the #262 baseline found the remaining Lake descriptor
boundary. No new upstream change or toolchain bump is proposed by this card.
Native API retirement is tracked separately in ULC-0007 through ULC-0011.
