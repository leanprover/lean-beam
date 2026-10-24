# ULC-0011 Creation-time POSIX directory permissions

- Status: open
- Priority: low
- Origin: Lean filesystem; slice of #262 contract B
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: related: https://github.com/leanprover/lean4/issues/13638
- PR: none linked

## Problem and smallest upstream change

`mkdir` with restrictive permissions establishes privacy before another creator
can observe the directory. A later chmod cannot close the initial exposure.
Provide creation-time POSIX mode selection, subject to umask, in a leaf-only
operation. Existing entries must not be repaired as a side effect.

## Evidence and acceptance

The #262 experiment observed mode0775 during a 16-round/eight-creator race;
creating mode0700 directly removed that interval. Transfer the reduced
[system-contract fixture](../../../../tests/test-system-contracts.py): permissive
umask, concurrent creation, unchanged existing paths, missing parents, wrong-kind
entries, links and actual I/O failures. This card records existing evidence,
not a fresh test result.

## Beam workaround and removal

Replace the POSIX creation branch of `lean_beam_create_private_dir` once the
supported SDKs supply it. Non-following observation and Windows DACL semantics
remain in [ULC-0008](../ULC-0008-private-directory-contract/README.md).
This slice alone does not delete `control_dir.c` or prove Windows privacy.

## Next action

Prepare a focused slice of the filesystem proposal; avoid a generic ACL API or
Beam-specific layout policy. Apply the
[support-window migration rule](../../README.md#migration-and-ownership).
