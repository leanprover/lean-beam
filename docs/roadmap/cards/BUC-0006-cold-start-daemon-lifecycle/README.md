# BUC-0006 Cold-start failure evidence

- Status: resolved
- Priority: high
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: https://github.com/leanprover/lean-beam/issues/110
- PR: none linked

## Problem and decision

Cold imports and concurrent activity had produced opaque daemon closures and
timeouts. Preserve the completed failure-reporting slice: enriched closure
context and bounded incident records, implemented in
[Beam #194](https://github.com/leanprover/lean-beam/pull/194) and
[#195](https://github.com/leanprover/lean-beam/pull/195).

This closes the reporting work, not every liveness or performance problem.
New hangs require a separate reduced report; setup progress is
[ULC-0003](../ULC-0003-structured-setup-file-progress/README.md).

## Evidence

The August 14 review identified `BeamTest.Broker.CliDaemonTest` coverage for
closure context and incident retention. It did not reproduce the intermittent
failure. [Beam #110](https://github.com/leanprover/lean-beam/issues/110)
remains a historical evidence location; no fresh pass is claimed here.

## Current workaround and removal target

Use doctor and the incident paths it reports, then prepare a
[feedback report](../../../FEEDBACK.md) with `lean-beam feedback-report` or
MCP `beam_feedback_report`. No broad daemon orchestration redesign follows
from this resolved reporting card.
