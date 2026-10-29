# Feedback Report Cards

`lean-beam feedback-report` and MCP `beam_feedback_report` produce a structured Beam report card
for bug reports and project feedback. Both entry points return the report to their caller and may
write a local bundle; Beam itself does not upload or submit feedback. The surrounding MCP client may
retain or transmit returned tool output under its own data policy; Beam does not control that client.
Sharing through [GitHub issues](https://github.com/leanprover/lean-beam/issues),
[Lean Zulip](https://leanprover.zulipchat.com), or another channel is a separate action.

The output is JSON with a pasteable Markdown `markdown` field, structured `metadata`, non-fatal
collection warnings, and optional evidence bundle paths. The CLI includes the collected Beam debug
context by default; MCP output is compact by default and includes that context only when requested.

Every non-confidential card warns that it may contain caller-authored narrative, request/response
payloads, local paths, Beam stats, open-file data, daemon logs or incidents, and bundle evidence.
Review those categories before posting the report publicly.

## CLI

```bash
lean-beam --root /path/to/project feedback-report --stdin
lean-beam --root /path/to/project feedback-report --input report.json --bundle dir
lean-beam --root /path/to/project feedback-report --input report.json --bundle zip --output-dir /tmp/beam-report
```

Input JSON:

```json
{
  "title": "Short report title",
  "summary": "What went wrong.",
  "kind": "bug",
  "severity": "high",
  "reproduction": "Concrete commands or steps.",
  "expected": "Expected behavior.",
  "actual": "Observed behavior.",
  "tags": ["daemon", "startup"],
  "request": {"op": "runAt"},
  "response": {"ok": false},
  "bundle": "none",
  "confidential": false
}
```

Required fields are `title`, `summary`, `reproduction`, `expected`, and `actual`. Optional
`kind` values are `bug`, `ux`, `perf`, `docs`, and `question`. Optional `severity` values are
`low`, `medium`, `high`, and `critical`. Optional `bundle` values are `none`, `dir`, and `zip`; the
default is `none`. Redaction is enabled by default. When the reporting process has a nonempty
`HOME`, it replaces that path with `~` in report text and JSON string values. It does not rewrite
JSON object keys. Non-confidential MCP results also retain the absolute workspace descriptor
described below. Review the whole output before sharing; pass `--no-redact` or `"redact": false`
only when it can safely contain local paths.

Set `"confidential": true` for feedback from a non-public workspace. Confidential mode:

- marks the Markdown and metadata as confidential and says not to post the report publicly
- forces home-path redaction and cannot be combined with `"redact": false` or `--no-redact`
- does not collect project-derived daemon, stats, open-file, incident, or log context
- skips CLI project-root discovery unless a requested bundle needs the default project-relative
  output directory
- clears the active project root and client request id from metadata; MCP also omits its echoed
  workspace descriptor
- omits request/response payloads and caller-supplied evidence from the rendered report and bundle
  contents
- retains only the Beam name and version; MCP reports additionally retain the MCP protocol version
  and whether the MCP runtime was active

The caller-authored `title`, `summary`, `reproduction`, `expected`, `actual`, `impact`, `workaround`,
and tags are retained except for current-`HOME` path substitution so the report remains useful.
Confidential mode cannot identify arbitrary source code or secrets in those fields. Review that
narrative before sharing the report through an authorized private channel, and never post a
confidential report publicly.

Free-form notes are not accepted directly. Wrap notes in the required JSON object fields above;
`lean-beam feedback-report --help` prints the accepted input shape. Unknown fields are rejected so
that a misspelled privacy option cannot silently fall back to non-confidential output.
The optional `request` and `response` fields must be JSON objects.

Evidence entries, when present, must have a simple `name` and exactly one source: inline `content`
or a local `path`. File evidence is accepted only from the known project root, Beam control
directory, or the bundle directory being written.

Redaction is intentionally narrow and best-effort. It is meant to keep ordinary home-directory
paths out of report cards, not to scrub arbitrary secrets, access tokens, private repository names,
or sensitive source snippets. Review non-confidential output before sharing it publicly;
confidential reports must never be posted publicly.

When a project root is available, the CLI includes Beam identity, live daemon stats, open files,
daemon registry status, startup log tail, and recent daemon incident records.

## MCP

Call `beam_feedback_report` with the same required fields plus an explicit local workspace
descriptor. Beam validates that local target even when confidential mode omits project context:

```json
{
  "workspace": {"root": "/absolute/path/to/project"},
  "title": "Short report title",
  "summary": "What went wrong.",
  "reproduction": "Concrete commands or steps.",
  "expected": "Expected behavior.",
  "actual": "Observed behavior.",
  "confidential": true
}
```

MCP returns compact report-card JSON in
`structuredContent`: `markdown`, `metadata`, `collection_warnings`, and any bundle paths. The
default Markdown includes a short Beam runtime summary instead of the full collected debug JSON,
including the full source commit, runtime payload, and stale-runtime or invalid-install identity
when available. Pass `include_collected: true` to include the full collected Beam debug context
inline and render the full debug-context section in Markdown. Non-confidential results echo the
resolved `workspace` descriptor, including its absolute, unredacted root even with `redact: true`.
Confidential results omit that descriptor;
`include_collected: true` returns only the restricted runtime identity and cannot restore omitted
project context.

MCP does not start a Lean runtime just to collect feedback. In non-confidential mode it includes
daemon registry and recent daemon incident context for the described workspace. When a runtime is
active, it also includes in-process stats and open-file data scoped to that canonical root; it does
not include the broker's process-wide workspace map or another workspace's root, sessions, metrics,
or document mirror. MCP always validates its explicit project root. If the CLI cannot infer a root,
pass `--output-dir` when requesting a bundle.

## Output

The top-level JSON object contains:

- `markdown`: pasteable report card
- `metadata`: schema, title, kind, severity, timestamp, known project root, tags, bundle mode,
  confidentiality, and client request id; the project root and request id are null for confidential
  reports
- `collected`: for non-confidential reports, Beam identity, stats, open files, and daemon context;
  always present in CLI output and in MCP output only when `include_collected: true`. For
  confidential reports, when present, it contains only the restricted runtime identity
- `collection_warnings`: non-fatal context collection and bundle-packaging failures
- `bundle_dir` and `zip_path`: present only when a bundle is requested and written

When redaction is disabled with `"redact": false`, CLI and MCP results return `bundle_dir` and
`zip_path` as local machine paths. With the default redaction setting, paths under `HOME` are
rendered with `~`.

Evidence bundles contain `card.md`, `metadata.json`, `collected.json`, `report.json`, and an
`evidence/` directory when caller-supplied evidence is present.
Confidential bundles omit the `evidence/` directory and local `bundle_dir` / `zip_path` fields from
their internal `report.json`. The local CLI or MCP result still returns those operational paths so
the caller can find the bundle.

Sequential bundle writes choose distinct paths instead of overwriting an existing bundle. Path
selection and directory creation are not atomic across concurrent writers, so callers should
serialize reports that could resolve to the same derived or explicit output base.
