# Feedback Reports

`lean-beam feedback-report` (MCP: `beam_feedback_report`) returns a pasteable bug report card to the
caller. Beam never uploads or submits it.

## Input

Pass a JSON object with `--stdin` or `--input <path>`; free-form notes are not accepted.

- Required string fields: `title`, `summary`, `reproduction`, `expected`, `actual`.
- Optional triage: `kind` (`bug`, `ux`, `perf`, `docs`, `question`) and `severity` (`low`,
  `medium`, `high`, `critical`).
- `--bundle none|dir|zip` optionally writes a local evidence bundle.

```bash
printf '%s\n' '{"title":"...","summary":"...","reproduction":"...","expected":"...","actual":"...","kind":"bug"}' \
  | lean-beam feedback-report --stdin
```

## Before Sharing

A non-confidential report can include caller narrative, request and response payloads, local paths,
Beam stats, open-file data, daemon logs and incidents, and bundle evidence. Review all of it before
posting.

## Confidential Workspaces

Set `"confidential": true` for a non-public workspace. This forces HOME-path redaction and omits
automatically collected project debug context, request and response payloads, evidence, and the
echoed MCP workspace descriptor. Requested bundles still return operational paths locally.

Confidential reports keep other caller-authored narrative without scanning it for secrets. Review
those fields before sharing through an authorized private channel, and never post the report
publicly.
