# ULC-0010 Non-consuming child exit observation

- Status: open
- Priority: medium
- Origin: Lean subprocesses; slice of #262 contract C
- Last reviewed: 2026-10-24
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: related: https://github.com/leanprover/lean4/issues/14438
- PR: none linked

## Problem and smallest upstream change

POSIX `Child.tryWait` consumes exit status, releasing the identity that a caller
may still need for owned group cleanup. Provide non-consuming exit observation
or an equivalent retained-identity operation, followed by exactly one final wait.

## Evidence and acceptance

Lean `a946636` [Windows observation](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/runtime/process.cpp#L91-L124)
already retains a process handle; the
[POSIX path](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/runtime/process.cpp#L354-L399) uses consuming `waitpid`.
Test running, exited-but-unreaped, repeated observation, one final collection,
and detected external loss of ownership. Preserve real OS failures separately
from a still-running result. No fresh runtime test is claimed by this import.

## Beam workaround and removal

At Beam `c716816dbd3ab392279978b5a930536cd4d3df59`,
[`ProcessJob.poll`](https://github.com/leanprover/lean-beam/blob/c716816dbd3ab392279978b5a930536cd4d3df59/Beam/ProcessJob.lean#L31-L36)
already uses `Child.tryWait` on Windows. That Beam migration is complete; do not
propose reopening a process by PID or another Windows polling adapter.
POSIX still needs the non-consuming native observation. Replace only that
binding when the complete retained-identity contract is available across the
admitted targets.
Windows jobs, parent loss, group signalling and scoped teardown remain under
[ULC-0009](../ULC-0009-owned-subprocess-lifetime/README.md); this slice does not
delete `process_job.c` or establish the complete owned-lifetime contract.

## Next action

Propose the focused observation contract in the existing subprocess discussion.
Record its first providing version and use the
[migration rule](../../README.md#migration-and-ownership).
