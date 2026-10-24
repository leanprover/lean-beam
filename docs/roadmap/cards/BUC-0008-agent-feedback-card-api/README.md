# BUC-0008 Feedback report capture

- Status: resolved
- Priority: medium
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

Agents needed to capture a useful bug report while request parameters and
diagnostics were available. The report-capture slice is implemented; its
current entry points are `lean-beam feedback-report` and MCP
`beam_feedback_report`, documented in [Feedback Report Cards](../../../FEEDBACK.md).

Generating a report does not submit it. Keep repository card-directory writing
separate from the core report API; the backlog in this directory is a
maintainer workflow, not a new runtime feature.

## Evidence

The July review reported feedback/projection/protocol coverage. Command names
in that report have since changed; use current help and the feedback guide.
No test rerun is claimed by this import.

## Current workaround and removal target

Review and manually transfer the returned Markdown/evidence into the intended
tracker. No automatic issue submission or directory-writer implementation is
proposed by this resolved card.
