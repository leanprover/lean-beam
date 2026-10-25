# ULC-0008 Private directory creation and observation

- Status: candidate
- Priority: high
- Origin: Lean filesystem; #262 contract B
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: related: https://github.com/leanprover/lean4/issues/13638
- PR: none linked

## Problem and contract

Per-user capability-bearing control directories must be private at creation.
Creating a default directory and later changing permissions exposes a race.
Existing entries also require non-following observation without permission
repair or deletion after pathname ownership may have changed.

Required behavior, allowing an equivalent upstream design:

- Establish the access policy in the leaf-creation operation; do not recreate
  missing parents. Parent creation is a separate caller choice.
- Preserve absence, wrong kind, rejected policy, and actual OS failure distinctly.
- Inspect the exact existing leaf without following links or mutating its policy.
- Provide a meaningful Windows security contract instead of synthetic POSIX bits.

## Evidence and design boundary

The #262 investigation ran 16 rounds with eight concurrent creators and observed
a mode-0775 interval before chmod. Creation-time mode0700 removes that POSIX
interval; [ULC-0011](../ULC-0011-creation-time-posix-permissions/README.md) owns
that independently landable slice. It does not solve Windows privacy.

Beam currently accepts a narrow Windows DACL: current-user ownership and
effective full owner allow, with additional grants only for SYSTEM/Administrators.
Deny, object, and callback entries are rejected. This is Beam's consumer policy,
not a proposed general ACL engine. Agree creation and typed inspection primitives
with Lean maintainers before marking this full contract ready for implementation.

## Acceptance

Preserve [system-contract cases](../../../../tests/test-system-contracts.py)
for permissive umasks/concurrent creation, unchanged existing private/nonprivate
paths, files, links, dangling targets, real I/O errors, broad grants and owner deny.
Actual access-denial mapping still needs a restricted Windows account;
invalid-name errors cover a different category. No fresh test run is claimed here.

## Beam workaround and removal

Replace `lean_beam_create_private_dir` and `lean_beam_observe_private_dir`,
including token/SID/DACL plumbing. Once
[ULC-0007](../ULC-0007-nonfollowing-leaf-metadata/README.md) is also complete,
delete `control_dir.c`, its object target and unused ACL linkage/header setup.
Keep application admission policy and regression tests.

## Next action

Discuss Windows creation/inspection ownership under the existing filesystem
proposal. Record the first complete providing version and follow the
[migration rule](../../README.md#migration-and-ownership).
