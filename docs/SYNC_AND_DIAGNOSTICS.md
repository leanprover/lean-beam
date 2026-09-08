# Sync And Diagnostics Contract

This is the canonical contract for Beam sync, refresh, save, progress, diagnostics, and readiness
reporting across the wrapper, internal broker transport, and MCP server.

Beam never applies source edits to `.lean` files on disk; the client applies source edits. The
commands below read saved source into Beam's LSP mirror or write Lean/Lake build artifacts; none is
a source-editing command.

## Command Model

`lean-beam update` is the cheap on-disk edit observation for a Lean file. It reads the current file,
opens or updates the broker's LSP mirror when needed, and returns the broker-owned document
`snapshot` immediately without waiting for diagnostics. Its `changed` flag means the broker sent
`didOpen` or `didChange` to the LSP session for this request; unchanged files keep the previous
document snapshot and return `changed: false`.

`lean-beam sync` is the diagnostics/readiness barrier for a Lean file. It opens or updates the
tracked file, waits for diagnostics for the current document snapshot, streams fresh request
diagnostics, and returns a machine-readable JSON verdict for that snapshot. Wrapper stdout uses
stable, agent-oriented field ordering after a broker operation completes. Selector, setup, or
transport failures can instead exit nonzero with human-facing stderr and no JSON, so automation
must check the exit status before parsing stdout. Clients that require structured live events and
failures should use MCP.

The returned `snapshot` is an opaque string identifying this file's source in one backend session.
Pass it unchanged to position, range, document-symbol, and code-action resolution requests for the
same workspace and file. `update` and `sync` preserve the token for unchanged tracked source.
Source changes, refresh, close/reopen, backend restart, and workspace reset or recreation produce
fresh tokens, even when the text is identical. Tokens from another file are also rejected.
Lean's numeric LSP document revisions remain internal; numeric `version` arguments are not accepted.

The broker checks the token before dispatch and verifies that the document is still current before
returning a document request's result. A stale token produces `contentModified` with
`error.data.reason = "snapshotMismatch"`, `expectedSnapshot`, and `currentSnapshot` when the file is
still tracked. A backend that exits while a request is pending can instead produce `workerExited`.
These checks concern the source tracked by the broker; they do not detect unsupported workspace
configuration drift or guarantee that imported artifacts are current.

After `contentModified`, read the current source and resolve the intended position, range, or code
action again. Obtain a fresh token from `update` or `sync` before retrying. Replacing the token alone
does not repair stale coordinates or actions. Treat tokens as opaque: do not construct, increment,
or compare their internal parts.

Example stale-snapshot response as printed by the wrapper on stdout:

```json
{
  "ok": false,
  "error": {
    "code": "contentModified",
    "message": "source snapshot changed for file:///workspace/Foo.lean; read the source and resolve the intended target again before retrying",
    "data": {
      "reason": "snapshotMismatch",
      "expectedSnapshot": "example-session/1",
      "currentSnapshot": "example-session/2",
      "uri": "file:///workspace/Foo.lean"
    }
  }
}
```

`lean-beam save` is `sync` plus a zero-build checkpoint for the synced Lake module. `lean-beam
close-save` is `save` plus closing the tracked file afterward. Both commands return the sync verdict
they established before checkpointing: `save` under `result.sync`, and `close-save` under
`result.saved.sync`. Document-error save failures include the blocking verdict under
`error.data.sync`.

Zero-build checkpointing supports structured Lake `leanOptions`, dynamic libraries, and plugins
already applied to the accepted file-worker snapshot. Strong `moreLeanArgs` are batch-only and fail
with `saveUnsupportedSetup` after the sync verdict is established.
Move shared `-D` settings from `moreLeanArgs` to `leanOptions`, or use `lake build` when the arguments
are intentionally batch-only. Save target resolution delegates to Lake's workspace loader for the
project's real `lakefile.lean` or `lakefile.toml`; the broker does not synthesize fallback Lake
configuration from `lakefile.lean` text and never batch-builds as part of `save`.

Beam assumes Lake workspace configuration remains unchanged for the lifetime of the running Lean
server. The server and existing file workers are not guaranteed to pick up edits to a lakefile,
manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic libraries. After any
such change, run `lean-beam --root ROOT stop` before the next command that uses the Lean server;
`lean-beam refresh` only reopens the file within the current server and is not sufficient. Beam does
not detect this configuration drift, so reusing a running session after such an edit is unsupported.

## Development Checkpoints And Batch Validation

`lean-beam save` writes a development checkpoint from the environment accepted by the Lean server.
A successful save means that the synced server snapshot passed Beam's readiness checks and was
written as a Lake module artifact. It does not mean that Lean batch elaboration was rerun, and it
does not certify that the resulting artifact is identical to one produced by `lake build`.

Server and batch elaboration coincide in almost all ordinary Lean code. Custom elaboration code can
still observe server mode or otherwise choose different behavior in the two contexts. Beam
intentionally accepts that exceptional distinction to make repeated one-module checkpoints much
cheaper during the edit and proof-development loop.

For ordinary local development, a successful Beam checkpoint is enough; do not routinely pay for a
clean local rebuild merely because Beam wrote an artifact. CI must independently run `lake build`
from a clean checkout or clean Lake build directory, without restoring Beam-produced module
artifacts into that job. Use the successful clean CI build as the final project-wide
batch-validation result.

If no successful clean CI result is available, or if server-sensitive elaboration is suspected,
discard the development checkpoints and perform one clean local batch build:

```bash
lean-beam --root ROOT stop
lake clean
lake build
```

This sequence is not a required step after every Beam checkpoint; it is the local fallback when no
successful clean CI result is available. A clean CI build remains the preferred
project-wide batch-validation authority; `saveReady` and successful Beam checkpointing report
acceptance of the current server snapshot.

## Reporting Surfaces

Progress, status, streamed diagnostics, and current results are separate reporting concepts.
Their transport types differ by surface.

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; internal broker `fileProgress` events; CLI progress text. |
| Status | Best-effort notice that a no-token MCP request is doing setup or remains pending. | MCP `notifications/message` with logger `beam.status`. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; internal broker `diagnostic` events; CLI stderr diagnostics. |
| Current result | Stable synced-state verdict for one document snapshot. | Final internal broker response or wrapper stdout `diagnostics`, `readiness`, and `fileProgress` fields; MCP spells the progress field `document_progress`. |

Wrapper stderr is the human-facing surface. Machine consumers of an owned wrapper session should
check exit status, then parse final stdout JSON when present. Use MCP for structured live events and
failures.

### Internal Broker Stream

The wrapper and daemon communicate through a private broker stream. It carries live progress and
diagnostics before one terminal response, but its framing and envelopes are implementation details,
not an installed command-line interface or a supported machine protocol. Maintainers keep its exact
ordering and correlation contract in the broker stream tests and
[development guidance](DEVELOPMENT.md#internal-broker-stream-contract).

The selected root chooses a workspace runtime; it is not a filesystem authorization boundary.
Relative paths resolve below that root, while absolute paths may identify dependency sources. Beam
can also execute Lean metaprogramming with IO, so callers that require filesystem isolation must
sandbox the owner process itself.

The wrapper's final stdout object may echo a caller-supplied `BEAM_REQUEST_ID` as a presentation
convenience; internally generated cancellation IDs remain hidden. This decoration is not part of
the semantic broker response.

## MCP Diagnostics

The MCP server advertises logging and forwards incremental Lean diagnostics as structured
`notifications/message` log events. Modern callers opt in for each request with
`_meta["io.modelcontextprotocol/logLevel"]`; legacy callers set the connection-wide level with
`logging/setLevel`. [MCP.md](MCP.md#progress-and-diagnostic-logs) defines the exact behavior for
both protocol eras. Events include path, URI, range, severity, message data, and
`completion_blocking=true` when a diagnostic is known to block file completion. They are
request-scoped observations; save-blocking evidence is attached to the final sync/save verdict.
A diagnostic includes `snapshot` when its backend notification names a positive document revision;
unversioned notifications omit it. Reply diagnostic items carry the barrier snapshot.

MCP clients that cannot conveniently collect interleaved notifications can call `lean_sync` or
`lean_refresh` with `diagnostics_in_result: true` to replay diagnostics in the final structured
result. By default replay and streaming use an error-only diagnostic filter. Final replay
intentionally duplicates any matching diagnostics already consumed live. For synced-file requests,
`diagnostic_scope: "all"` widens streamed and replayed diagnostic output to warnings, information,
and hints.

Lean marks some editor-only messages as silent, including its decorative `Goals accomplished!`
message. Beam removes silent diagnostics and speculative-execution messages at reception time. They
do not appear in diagnostic streams, final diagnostic items or counts, `lean_todo`, or `runAt`
messages. This rule is independent of `diagnostic_scope`: `"all"` means all user-facing severities,
not Lean's private editor chatter.

Lean currently publishes Lake `setup-file` build lines as information diagnostics. Beam recognizes
these observations best-effort and, at the MCP boundary, projects them separately from ordinary
diagnostics. Depending on the call's progress and logging metadata, MCP projects setup observations
as `beam.status` or throttled `notifications/progress`; [MCP.md](MCP.md#display-control-matrix)
defines the exact combinations. `runAt` does not stream ordinary file diagnostics by default.

`diagnostic_scope` is an output severity filter, not a request for a partial diagnostic state.
`diagnostics.counts` still summarizes the complete user-facing current diagnostic state.
When a first sync on a fresh or dependency-heavy Lake workspace is slow, clients should keep a
progress token attached. Clients that also need warning and information detail should independently
enable diagnostic logging and/or request `diagnostic_scope: "all"` plus
`diagnostics_in_result: true`.
Successful `lake setup-file` status diagnostics are transient Lean observations. MCP projects them
through live `beam.status` or tokened progress, and they usually do not appear in final
`diagnostics_in_result` replay after Lean clears setup progress. The internal broker stream still
carries Lean's temporary information-diagnostic envelope, which the wrapper may render on stderr.
Until Lean exposes a first-class setup/build status signal, the separation is an MCP projection
rather than an end-to-end typed distinction.

## Progress

MCP clients can pass `_meta.progressToken` on `tools/call` requests to receive
`notifications/progress` for setup and execution phases. Beam also reports throttled Lean
file-progress observations when Lean publishes them. Without a token, eligible calls use a
best-effort delayed `beam.status` notice. The operation matrix, delay, and logging-policy rules are
defined in [MCP.md](MCP.md#display-control-matrix).

Broker `fileProgress` and MCP `document_progress` fields contain compact Lean processing-range observations.
They always report `updates` and `done`; when Lean publishes range-bearing progress, they may also
report `rangeStartLine` and/or `rangeEndLine`; MCP spells these `range_start_line` and
`range_end_line`. The range end is the upper line bound reported by
Lean's progress ranges, not the source file's line count; diagnostics may legitimately refer to
lines beyond it. The final response contains the latest observation available when that response is
constructed, so it may be newer than the last live broker event or throttled MCP notification. An
operation can also reuse a previously observed value without emitting live file progress; `updates`
is not a count of work performed by the current request. Use these fields for coarse UI progress
only. Final machine decisions should use the readiness and diagnostic result fields. MCP includes
final `document_progress` only for `lean_sync`, `lean_refresh`, `lean_save`, and
`lean_close_save`; it is not inherited by `runAt` or unrelated tools.

For `sync`, `refresh`, `save`, and `close-save`, completed Lean file progress is one input to the
diagnostics-complete barrier. For non-barrier calls, file progress may be partial because the
request can return before the whole file reaches `done = true`.

## Readiness

Successful sync responses expose one flat result for the current document snapshot. MCP uses
snake_case field names; broker and CLI JSON use the corresponding camelCase names. The
machine-facing MCP readiness fields are:

- `readiness.save_ready`
- `readiness.reason`
- `readiness.blocking_error_count`
- `readiness.blocking_diagnostics`
- `readiness.blocking_messages`

`diagnostics.counts.*` reports user-facing Lean-published diagnostic severities. It answers "what
did Lean report?", while readiness answers "can this synced snapshot be checkpointed?". The backend
readiness API is authoritative for `saveReady`; diagnostic severity summaries are evidence and
counts, not a separate broker-side veto.

`blocking_error_count` is intentionally not named `error_count`: it counts save-blocking evidence,
including a blocking command message when Lean did not attach a diagnostic. It can therefore differ
from `diagnostics.counts.error`. Warning counts are reported once, under `diagnostics.counts.warning`.

Lean-side readiness applies the frontend artifact gate to the current synced snapshot: current
save-blocking frontend errors block save. This verdict answers whether Beam may checkpoint that
server snapshot; it is not a batch-equivalence verdict. Diagnostic streams, diagnostic summaries,
and message history are observations; clients should not reconstruct save readiness from them.

## Current Result

Each sync result describes only the current synced document snapshot. It does not carry deltas
against previous responses. Clients that need comparisons should retain the previous response they
care about and compare it explicitly.

- `path` and `snapshot`: the synced document described by the result
- `diagnostics.counts`: current user-facing diagnostic counts by severity and total
- `diagnostics.items`, when requested: diagnostics selected by `diagnostic_scope`
- `readiness`: the current save-readiness verdict and blocking evidence

Successful broker and wrapper saves repeat the synced document's top-level `path` and `snapshot`, add
the checkpoint fields `module`, `sourceHash`, `olean`, `ilean`, `c`, and `trace`, and nest the
canonical sync result under `sync`. Optional backend artifacts use `oleanServer`, `oleanPrivate`,
`ir`, and `bc`. Close-save wraps the same save result as
`{ "closed": true, "saved": <save-result> }`. MCP uses snake_case for the multiword artifact fields;
see the complete [`lean_save` result example](MCP.md#stable-result-shapes).

## Failures And Recovery

If Lean cannot reach a completed diagnostics barrier for the synced snapshot, `lean-beam sync` fails
instead of reporting partial success. `lean-beam save` and `lean-beam close-save` refuse to proceed
past that incomplete barrier.

Sync failures may include `error.data.staleDirectDeps`, `error.data.saveDeps`,
`error.data.recoveryPlan`, and `error.data.completionBlockingDiagnostics`. For now, recovery hints
are based on direct imports returned by Beam's diagnostics barrier request from Lean's accepted
header snapshot. Beam combines those imports with broker sync/save history and reports a stale direct
dependency when the dependency's observed source
change or saved checkpoint is newer than the target file's last successful sync boundary. It sets
`needsSave=true` when the latest saved checkpoint is older than the latest observed source change.
The intended direction is to get structured stale-dependency metadata from Lean's native
stale-dependency signal instead of reconstructing it in Beam. `completionBlockingDiagnostics`
entries carry `completionBlocking=true` when they explain why the file could not reach a
diagnostics-complete barrier.

For Lake workspaces, Beam starts the Lean server with Lake's workspace environment so Lean's own
import graph can detect stale open importers. When `sync` observes a real source change for an open
Lean file, Beam sends `textDocument/didChange` followed by `textDocument/didSave`; Lean may then
publish its native "Imports are out of date" diagnostic on open dependents, and Beam reports that
diagnostic as `syncBarrierIncomplete`. Beam does not currently implement Lean's dynamic
`workspace/didChangeWatchedFiles` watcher registration, so external source changes that never pass
through `sync` are not treated as a complete file-watcher surface.
