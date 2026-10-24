# ULC-0009 Complete owned subprocess lifetime

- Status: candidate
- Priority: high
- Origin: Lean subprocesses; #262 contract C
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: related: https://github.com/leanprover/lean4/issues/14438
- PR: none linked

## Problem and contract

Project-loading helpers can block, fail, or leave descendants. Async waiting
alone does not replace ownership through cancellation, timeout, parent loss,
termination, and final collection.

Required behavior, allowing an equivalent upstream design:

- Retain process identity through observation and group/job cleanup; perform
  termination before final collection and never signal a recycled PID.
- On Windows, establish job ownership before allowing project code to execute.
  Early-start failure must still own leader termination and collection.
- Define cancellation/deadline, parent-loss, and exception-safe closure behavior.
- Make detected ownership loss permanent; reject observation through an escaped
  capability after closure before touching the old PID.

This cleans up ordinary owned helpers under explicit assumptions. It does not
contain privileged code or descendants that deliberately escape a POSIX group.
Beam's `Scope` is not linear: callers must not independently wait/kill its raw child.

## Evidence and acceptance

Keep [Lake-helper fixture cases](../../../../tests/lean/BeamTest/Broker/LakeHelperClientFixture.lean)
for retained exit, external reaping, exceptional cleanup, and escaped observation.
Preserve end-to-end cancellation, timeout, parent-loss and workspace-instance
tests after primitives move upstream. These are #262 evidence/acceptance targets,
not a new test execution claim.

Carry the Darwin `EPERM` case upstream with a reduced reproduction, affected
SDK/kernel versions, and the unreaped-leader assumption. Accepting that error
requires a complete kernel snapshot showing every remaining member exiting or
zombie; failed/truncated observation must preserve the signalling error.
This does not resolve the separate macOS sync-liveness investigation.

## Beam workaround and removal

Only a complete equivalent lifetime contract across admitted SDKs permits
deleting `process_job.c`, its bindings, object target and unnecessary platform
headers/build setup, then simplifying the Lean adapter.
[ULC-0010](../ULC-0010-nonconsuming-child-exit/README.md) removes only a poll
binding. Windows already has retained-handle `Child.tryWait`; adopting it is
a separately testable local reduction, not a new required abstraction.

## Next action

Agree the lifetime boundary with Lean maintainers using the existing subprocess
discussion. Do not add another portability strategy or claim async wait alone
retires this shim. Apply the [migration rule](../../README.md#migration-and-ownership).
