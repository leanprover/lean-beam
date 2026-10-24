# ULC-0007 Non-following Windows leaf metadata

- Status: open
- Priority: high
- Origin: Lean filesystem; #262 contract A
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: related: https://github.com/leanprover/lean4/issues/13638
- PR: none linked

## Problem and smallest upstream change

`FilePath.symlinkMetadata` promises non-following metadata, but the inspected
Windows implementation delegates to following metadata. Observe the leaf
itself, including directory junctions/reparse points, and preserve actual
absence separately from I/O failure. Beam/Elan path-selection policy does not
belong in this primitive.

## Evidence

Lean `a946636`: [API contract](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Init/System/IO.lean#L1151-L1156)
and [Windows implementation](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/runtime/io.cpp#L1159-L1177).
Consumer cases are in [system contracts](../../../../tests/test-system-contracts.py)
and [their Lean assertions](../../../../tests/lean/BeamTest/SystemContractTest.lean).
#262 supplies the workaround; this card does not claim a new test run.

## Acceptance and scope

Cover files/directories, symlinks, mount-point/junction and other reparse tags,
dangling links/junctions, invalid names, non-directory ancestors where the OS
distinguishes them, and genuine access denial. Never turn observation errors
into Boolean false/absence. The Windows invalid-name fixture is not evidence
for `ERROR_ACCESS_DENIED`; privileged CI share-lock/ACL attempts did not
establish that mapping. A suitably restricted account is still needed.

## Beam workaround and removal

Replace `lean_beam_path_is_link` and its binding once every admitted SDK has
the required semantics. Keep foreign-component admission tests. Remove Windows
absence compensation only after proving it redundant.
[Private-directory APIs](../ULC-0008-private-directory-contract/README.md) are
separate: this fix alone does not delete `control_dir.c`.

## Next action

Prepare the reduced Windows bug report/patch, linked to the broader filesystem
discussion. Record the first complete providing version and apply the
[migration rule](../../README.md#migration-and-ownership).
