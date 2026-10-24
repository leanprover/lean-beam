# BUC-0001 Stale import dependency reporting

- Status: candidate
- Priority: high
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

The original report concerned a stale-import diagnostic with empty dependency
hints. Beam can derive `staleDirectDeps`, `saveDeps`, and a recovery plan for
observed direct dependencies, but missing hints must not imply a usable importer.
Reproduce the empty-hint case on a supported toolchain before choosing an
additional response field. Earlier example field names were proposals, not API.

The upstream part is [ULC-0001](../ULC-0001-structured-stale-dependency-metadata/README.md).
Prefer its authoritative stale URI over another inference mechanism.

## Evidence and next action

The July 2026 review reported partial reproduction; the exact downstream trace
has not been rerun for this card import. Existing coverage is in
[wrapper diagnostics](../../../../tests/test-beam-wrapper-diagnostics.sh)
and [broker protocol tests](../../../../tests/lean/BeamTest/Broker/ProtocolTest.lean).
These files are evidence locations, not a claim of a fresh test run.

Check the unknown-dependency case and preserve the distinction between
unavailable hints and no detected staleness. Do not invent a dependency URI.
Keep recovery behavior aligned with
[sync/save failures](../../../SYNC_AND_DIAGNOSTICS.md#failures-and-recovery).

## Current workaround

Explicitly sync/save edited dependencies and refresh the importer. If the
dependency cannot be identified safely, retain the diagnostic and recommend
the documented build/restart recovery. A checkpoint is not batch-build evidence.
