# BUC-0004 runAt diagnostic origin mapping

- Status: candidate
- Priority: high
- Origin: downstream LIRIS feedback
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

A multiline speculative snippet can return a rendered `<runAt>` location that
callers must map back to their submitted text. The July report requested a
structured snippet range rather than manual reconstruction.

Preserve this as a bounded result improvement. Reuse source positions already
owned by the parser/message path where possible. Keep the public request small;
hashes, insertion metadata, excerpts, and extra mode flags are not prerequisites.

## Evidence and next action

The July 7 review reproduced a parser failure rendered as
`<runAt>:2:9: expected end of input`. It has not been rerun for this import.
The earlier implementation experiment remains a prototype, not current behavior.
Check parser and elaborator messages in both command and tactic positions,
Unicode/position conventions, multiline offsets, and messages from real files.
Do not attribute every diagnostic to the speculative buffer.

Related [Beam #100](https://github.com/leanprover/lean-beam/issues/100)
concerns adjacent snippet ergonomics; this card only owns origin mapping.

## Current workaround and removal target

Retain the exact submitted snippet when interpreting rendered positions.
A correct range projection should remove caller-side synthetic-line arithmetic.
