# ULC-0016 Retain the import artifacts used by a header snapshot

- Status: candidate
- Priority: high
- Origin: Beam checkpoint review / Lean file worker / Lake
- Last reviewed: 2026-10-24
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: Beam follow-up: https://github.com/leanprover/lean-beam/issues/370
- PR: related Beam workaround: https://github.com/leanprover/lean-beam/pull/368
- First complete providing version: unknown
- Beam migration: not started

## Problem and decision

A checkpoint must describe the imports its worker actually elaborated against.
Looking up dependency traces only when saving can instead describe newer
artifacts produced after the worker loaded its imports. An unchanged module name
does not establish artifact identity.

Explore retaining the import artifacts supplied to header processing with the
accepted header snapshot, then exposing that basis to the request owner. The
contract must identify loaded inputs, not resolve the current filesystem again.
The representation, retention cost, and handling of non-content-addressed
artifacts still need design; a pathname alone must not be assumed immutable.

## Evidence and acceptance

Source inspected at Lean 4.36.0-rc1 revision
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:
[`FileWorker`](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/FileWorker.lean#L433-L445)
passes `ModuleSetup.importArts` into header processing. This is a useful origin
for retained evidence; it is not yet an agreed snapshot API.

[Beam #368](https://github.com/leanprover/lean-beam/pull/368) proposes an early
trace-capture workaround and save-time comparison. It is pending work, not
support shipped by this card. The source inspected for that proposal was
`5860df2e219d904ac6712a166e5f664f6ccf205f`; no new end-to-end reproduction is
claimed here.

Acceptance for the upstream contract:

- Retain the basis of the accepted header and return it for that same snapshot.
- Rebuilding an import after header loading must not change the reported basis.
- A replacement or failed header must not inherit a previous header's evidence.
- Define missing, replaced, mutable and content-addressed artifact behavior;
  unavailable evidence must not silently authorize a checkpoint.
- Preserve request cancellation, document identity and worker lifetime ownership.
- Demonstrate that save refuses changed imports while an unchanged checkpoint
  remains usable by the target Lake build.

These are acceptance requirements, not completed upstream tests. Search related
Lean/Lake work and agree ownership before selecting an API.

## Beam workaround and removal

If #368 lands, a complete upstream replacement could remove its early
`$/beam/importBasis` capture requests after open/change and the corresponding
worker-side capture state. Keep the save-time comparison, snapshot checks and
publication guarantees. Removal requires the contract on all admitted targets.

Dependency watching in [Beam #370](https://github.com/leanprover/lean-beam/issues/370)
is an independent feedback improvement; dropped or coalesced events cannot
replace save-time evidence. Structured stale-dependency diagnostics remain
[ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md), and Lake
save-plan APIs remain [ULC-0014](../ULC-0014-shared-lake-tooling-helper/README.md).

## Next action

The coordinator should confirm an upstream design owner and reduce one
header-load/import-rebuild/save sequence before proposing a snapshot field or
request. Record the first complete providing version and the actual Beam
deletion under the [migration rule](../../README.md#migration-and-ownership).
