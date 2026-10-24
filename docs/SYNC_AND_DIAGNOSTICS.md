# Sync And Diagnostics Contract

This is the canonical contract for Beam sync, refresh, save, progress, diagnostics, and readiness
reporting across the wrapper, internal broker transport, and MCP server.

Beam never applies source edits to `.lean` files on disk; the client applies source edits. The
commands below read saved source into Beam's LSP mirror or write Lean/Lake build artifacts; none is
a source-editing command.

All requests follow Beam's current [soft cancellation policy](STATUS.md#soft-cancellation).
Cancellation may wait for active work to settle and does not undo committed effects.

## Command Model

`lean-beam update` is the cheap on-disk edit observation for a Lean file. It reads the current file,
opens or updates the broker's LSP mirror when needed, and returns the broker-owned document
`version` immediately without waiting for diagnostics. Its `changed` flag means the broker sent
`didOpen` or `didChange` to the LSP session for this request; unchanged files keep the previous
document version and return `changed: false`.

`lean-beam sync` is the diagnostics/readiness barrier for a Lean file. It opens or updates the
tracked file, waits for diagnostics for the current document version, streams fresh request
diagnostics, and returns a machine-readable JSON verdict for that version. Wrapper stdout uses
stable, agent-oriented field ordering after a broker operation completes. Selector, setup, or
transport failures can instead exit nonzero with human-facing stderr and no JSON, so automation
must check the exit status before parsing stdout. Clients that require structured live events and
failures should use MCP.

`lean-beam refresh` refreshes a tracked document from saved source and waits for diagnostics. It
validates the path and reads the source before closing and reopening the document, so a rejected
path or failed source read leaves the existing document open. If a newer source read was accepted
while the refresh was reading, the refresh uses that newer snapshot without closing it. Refresh is
therefore not equivalent to issuing `close` followed by `sync` as separate commands.

Plain `close` performs cleanup without reading source contents and remains available after the
source path disappears or becomes an unsupported kind. It does not open a new document or start a
Lean backend. Its `closed` result is `true` when it removes a tracked document, and `false` for an
unknown or already closed document. Both outcomes invalidate earlier source-read admissions for
that identity; a fresh request may intentionally reopen it.

The returned document `version` is the snapshot token for broker, MCP, and wrapper callers.
Position- or range-bound operations reject missing or stale versions; clients can obtain the
version from `lean-beam update`, the internal broker `update_file` operation, or MCP `lean_update`.
`lean-beam sync`, the internal broker `sync_file` operation, and MCP `lean_sync` also return the
current version when the caller needs the diagnostics/readiness barrier.

Each captured source snapshot carries three internal hash representations for two text identities:
the saved source text and the document text accepted by Lean after CRLF line endings become LF.

| Representation | Input and consumer |
| --- | --- |
| `rawSourceHash` | Hash of the unnormalized saved source; controls document versions, disk freshness and checkpoint invalidation. |
| `documentHash` | Hash of Lean's normalized document; checks that diagnostics and saved artifacts belong to the accepted document version and text. |
| `lakeTraceHash` | `Lake.Hash.ofText` of the saved source; supplies the normalized source hash Lake expects in build traces. |

The document and Lake hashes share normalized input, but Lake applies its own hash mixing. They
are different representations rather than independent content identities. Beam keeps the result
of Lake's supported `Hash.ofText` operation instead of duplicating its hashing recipe or making
the LSP worker depend on Lake's hash representation.

`DocumentState.FileSnapshot.ofText` computes all three values from one captured source text. Both
the file snapshot and tracked document state require an explicit document hash; it cannot default
to the raw source hash, since those values differ when CRLF normalization changes the text. An
accepted snapshot carries these values together through sync and save, including when concurrent
file reads finish out of order.

For an LF-to-CRLF edit, the raw source hash changes, the document version advances, and the previous
checkpoint is invalidated. The normalized document and Lake source trace identities stay the same.
Sync and save preserve the source file's saved bytes, and a valid saved artifact family can still
be replayed by Lake without recompilation.

When the broker rejects a position- or range-bound request because the supplied version is stale,
the failure uses `contentModified` and includes `error.data.reason = "documentVersionMismatch"`.
The same payload reports `expectedVersion`, the currently accepted `acceptedVersion`, and
`currentVersion` when the broker can name the current tracked document version.

The message distinguishes the requested version from the accepted version. It mentions a source
change on disk only when the request observed one relative to the tracked source.
Position queries use zero-based LSP lines and UTF-16 character units. Positions beyond the accepted
document's line or character bounds return `invalidParams`; valid end-of-line and end-of-file
positions remain valid. A valid hover query with no hover information still returns `null`.

Example stale-version semantic response as printed by the wrapper on stdout:

```json
{
  "ok": false,
  "error": {
    "code": "contentModified",
    "message": "document version mismatch for file:///workspace/Foo.lean: requested version 1, accepted version 2",
    "data": {
      "reason": "documentVersionMismatch",
      "expectedVersion": 1,
      "acceptedVersion": 2,
      "currentVersion": 2,
      "uri": "file:///workspace/Foo.lean"
    }
  }
}
```

`lean-beam save` is `sync` plus a zero-build checkpoint for the synced Lake module. `lean-beam
close-save` reserves that document, checkpoints it, and closes it. Both commands return the sync verdict
they established before checkpointing: `save` under `result.sync`, and `close-save` under
`result.saved.sync`. Document-error save failures include the blocking verdict under
`error.data.sync`.

For MCP, save completion and response delivery are separate. A busy rejection (`-32024`) means the
request did not execute. An output-limit error (`-32023`) can follow a committed save or completed
close; it does not roll back those effects. A missing or cancelled response also does not establish
that a save did not commit. Pending output holds no document permit, broker request handle, or
publication authority after execution and cleanup finish, and does not delay a workspace drop or
later broker work. A stdout write attempt is not client acknowledgement. See the
[MCP transport contract](MCP_TRANSPORT_CONTRACT.md) for output limits and cancellation cutoffs.

Close-save reserves the canonical document when its source snapshot is accepted, before waiting
for diagnostics or preparing the checkpoint. During preparation, competing document
operations return `contentModified` with `error.data.reason = "documentClosing"`. This includes
update, sync, refresh, save, close, and semantic or continuation requests that implicitly sync.
Coordinate with the close-save caller before retrying these rejected operations.
An operation accepted before reservation can affect the snapshot selected by close-save.

Requests admitted before reservation but still awaiting source acceptance cannot resume after
closure or failure cleanup: they return `documentClosing` while the reservation exists, or
`documentAdmissionExpired` afterward, under the same `contentModified` code. Start a new request
after coordinating with the owner. A fresh request may intentionally reopen a closed file.
Already-dispatched semantic work may finish under its existing document and backend guards.
Other documents remain admissible during preparation. Within one process, saves serialize their
sync/readiness work, private artifact and trace preparation, canonical publication, and private-file
cleanup across workspaces. Final close follows outside that serialization. Cancellation can wait
for the active private phase to finish or for an earlier save to release the serialization.

Preparation uses isolated private files, leaving the canonical checkpoint unchanged on failure.
After preparation, Beam rechecks the accepted document and cancellation before starting canonical
publication. That final cancellation check is the cutoff: later cancellation cannot revoke the
publication attempt. Same-workspace document changes and owner teardown wait for publication to
settle. Unrelated workspace work, read-only state access, and cancellation remain reachable; the
wait has no fixed filesystem-I/O bound.
This coordination is local to one broker: it does not lock source files on disk or coordinate
independent Beam or Lake writers.

Failure or cancellation before publication releases the reservation and preserves a healthy
backend, its documents, and continuation handles. During private serialization or trace preparation,
Beam records caller cancellation and waits for the phase to finish before reporting it. Settled
private outputs can then be removed without changing the checkpoint. An unacknowledged attempt may
retain private files but cannot publish later. Backend loss or uncertain artifact-request or
final-close delivery can retire the captured backend; subsequent work must reacquire its documents
and handles. Abandoned preparation files may be removed manually only after all potential Beam and
helper writers have stopped. Preserve backups from reported publication/recovery failures until
they have been investigated and recovery is complete.
Cancellation after publication begins does not undo a committed checkpoint. Implementation and
recovery boundaries are documented in the [close-save model](CLOSE_SAVE_MODEL.md#publication-implementation).

After a checkpoint succeeds, finalization still checks the exact accepted document. An ordinary
`save` may return its historical checkpoint result after a concurrent change without marking the
replacement checkpointed. Close-save retains a defensive `savedDocumentChanged` refusal if its
document comparison fails: `error.data.saved` contains the committed checkpoint,
`error.data.closed = false`, and `currentVersion` identifies a tracked replacement when present.
The replacement and its handles remain intact. That receipt means the checkpoint succeeded;
synchronize and save again if the new text needs a checkpoint.

Other finalization failures after the artifacts and Lake trace have committed retain their
original error code and message, add the checkpoint under `error.data.saved`, and preserve any
original error data under `error.data.originalData`. They do not assert `closed = false` when
notification delivery may have failed. CLI and MCP pass this error data through with the broker field
names, including `sourceHash` inside `saved`; successful CLI and MCP save results use snake_case.

Preserving this receipt in the broker does not guarantee that an MCP client receives it.
Cancellation or transport failure can prevent delivery; the
[MCP transport contract](MCP_TRANSPORT_CONTRACT.md)
also permits an output-limit error after execution. A missing receipt does not establish that the
checkpoint failed. There is no receipt journal or recovery protocol.

Zero-build checkpointing writes artifacts from the accepted Lean server state without rerunning
batch compilation. It supports structured Lake `leanOptions`, dynamic libraries, and plugins
already applied to that state. A module with effective `moreLeanArgs`, including arguments
inherited from its package or library, is unsupported for this operation: Lake applies these
arguments to batch compilation, so the server snapshot does not establish that they were applied.
The configuration can still be valid for `lake build`.

Beam returns `saveUnsupportedSetup` after establishing the sync verdict and resolving the module,
before Lake dependency-trace preparation. This rejection preserves the sync verdict under
`error.data.sync` and leaves prior artifacts and the Lake trace unchanged. A rejected `close-save`
also leaves the document open. Move shared `-D` settings from `moreLeanArgs` to `leanOptions`, or use
`lake build` when the arguments are intentionally batch-only.

Save target resolution delegates to Lake's workspace loader for the
project's real `lakefile.lean` or `lakefile.toml`; the broker does not synthesize fallback Lake
configuration from `lakefile.lean` text and never batch-builds as part of `save`.

Before replacing checkpoint artifacts, Beam invalidates Lake's cached hashes for the outputs it
writes so later incremental builds recheck their dependents. If publication fails, Beam attempts
to restore the previous artifacts; successful recovery leaves the final trace absent. Failed recovery
reports both errors and retains the backups needed for recovery. These steps do not make the artifact
family atomically visible or recover from process death.

A snapshot with `compiler.postponeCompile` enabled, or with declarations still waiting for deferred
compilation, is not a complete checkpoint. Its sync result has `readiness.save_ready: false` and
`readiness.reason: "deferredCompilation"`, even when elaboration has no errors. `save` and
`close-save` reject it with `saveUnsupportedSetup` before changing artifacts or the Lake trace;
use `lake build` for this compilation pipeline. This also applies to declaration-scoped
`set_option compiler.postponeCompile true in`, whose option resets before the end of the file.

### Project Configuration Changes

Beam assumes Lake workspace configuration remains unchanged for the lifetime of the running Lean
server. The server and existing file workers are not guaranteed to pick up edits to a lakefile,
manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic libraries. After any
such change, run `lean-beam --root ROOT stop` before the next command that uses the Lean server;
use the original installation and the same session-directory selection. For MCP, drop and recreate
the workspace, restarting the MCP server when changing its installation. `lean-beam refresh` only
reopens the file within the current server and is not sufficient.

Beam does recheck runtime admission: a changed project selector or installation can reject reuse.
This is not general configuration-change detection or live reload. If only the selector changed,
restoring the retained runtime can restore admission; other configuration edits still require a
fresh server. See [toolchain-change recovery](SETUP.md#changing-the-project-toolchain).

## Worker Errors And Document Recovery

After Beam observes an explicit worker failure, ordinary use of that document returns the recorded
error without sending another request to Lean:

- Use `sync` to reopen the file from saved source and wait for diagnostics/readiness.
- Use `update` to submit the reopen without waiting for that result. Successful update is not a
  worker-health or readiness barrier.
- A fresh `save` or `close-save` performs the same recovery during its initial synchronization,
  before preparing artifacts or taking a new close-save reservation. Normal save serialization and
  document admission still apply; an existing close-save owner cannot be bypassed.

When Lean explicitly replies with `workerExited` or `workerCrashed`, Beam records the first error
only for the session and accepted document revision that owned the request. Caller cancellation
can change the returned error to `requestCancelled`; it does not erase the observed worker failure.
Late replies cannot mark a replacement document or session as failed. This also applies when an
ordinary source update was accepted before the error was recorded: the newer revision requires
its own explicit error before Beam marks it as failed, even if it used the same worker.

Recovery does not automatically resubmit the failed request or its speculative `runAt` text.
Reopening elaborates saved source again, so source-level `#eval` or elaborator effects can run again;
it does not provide exactly-once execution. Other documents and their handles keep their existing
session. Handles from the replaced worker become invalid. Recovery of unchanged source preserves
its document version and checkpoint association, but establishes a new internal accepted revision.
An actual source edit advances the version, invalidates the checkpoint, and notifies importing
workers that their dependency is stale,
just like an ordinary source update. An update that reopens the worker returns `changed: true`.

The internal broker's `open_docs` entry includes `workerError` while the failure is recorded and
omits obsolete `fileProgress`. Its `checkpointed` field still describes the saved source/artifacts,
not the health of the current worker. Worker recovery does not rewrite checkpoint artifacts.

Worker failures retain their existing `workerExited` / `workerCrashed` code. Where the observing
boundary knows the recovery, `error.data.recovery` distinguishes:

| `kind` | Meaning and next step |
| --- | --- |
| `newHelper` | The target Lake helper exited without a response. A new request creates a fresh helper; inspect save state before deciding whether to repeat a save. |
| `newBackend` | The Lean backend exited and its exit was confirmed. A new request starts a fresh backend. This does not establish completion of the failed request. |
| `restartWorkspace` | Backend exit was not confirmed. Drop the MCP workspace or stop and restart its owning wrapper session before issuing new work. |
| `sync` | An explicit file-worker failure was returned. The recovery object includes its `uri`; synchronize that file with CLI `sync` or MCP `lean_sync`, subject to the admission limits below. |

Original backend error data is preserved in `error.data.originalData` when recovery metadata is
attached. A helper response or trace-write receipt describes that helper phase; it does not by
itself prove that the broker published a checkpoint. Preserve any `saved` or `operationResponse`
receipt supplied with a later failure and inspect its phase. No recovery hint authorizes automatic
replay, establishes rollback, or erases a cleanup failure.

Recording one worker error does not supply replies for other already-dispatched requests. With an
older Lean watchdog, those requests may remain pending until Lean replies or a fresh sync/refresh
can acquire the document and close its old worker, releasing queued replies. Single-document
recovery requires admission: an unresolved close-save retains its closing owner, so `update`,
`sync`, `refresh`, plain `close`, and new saves are rejected with `documentClosing`. Observing a
worker error does not revoke that owner. Soft cancellation does not establish producer settlement
or release its reservation. If the owner cannot settle on an affected Lean version, recovery may
require restarting the owning workspace/session, with its existing cleanup and settlement rules;
single-document recovery cannot bypass the reservation. Reliable completion of queued requests
still requires the upstream routing correction.

This behavior requires an explicit worker-error response. Generic fatal file progress also occurs
for validly running workers with fatal elaboration diagnostics and is not evidence of worker exit.
Lean versions that leave later requests unanswered after an idle worker exit require an upstream
routing correction; Beam does not infer that failure from elapsed time or promise automatic
recovery before it receives an explicit error.

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
artifacts into that job. This provides batch-build evidence for the selected project targets,
not independent proof confirmation.

If no successful clean CI result is available, or if server-sensitive elaboration is suspected,
discard the development checkpoints and perform one clean local batch build:

```bash
lean-beam --root ROOT stop
lake clean
lake build
```

This sequence is not a required step after every Beam checkpoint; it is the local fallback when no
successful clean CI result is available. `save_ready` reports checkpoint eligibility; warnings such
as `sorry` may remain. A clean build does not independently establish the intended theorem or its
allowed axioms. See [trust and proof confirmation](../skills/lean-beam/references/trust-and-validation.md)
for supported ownership assumptions and the separate comparator workflow.

## Reporting Surfaces

Progress, status, streamed diagnostics, and current results are separate reporting concepts.
Their transport types differ by surface.

| Concept | Scope | Current surface |
| --- | --- | --- |
| Progress | Request-scoped operation movement, not diagnostics and not final readiness. | MCP `notifications/progress`; internal broker `fileProgress` events; CLI progress text. |
| Status | Best-effort notice that a no-token MCP request is doing setup or remains pending. | MCP `notifications/message` with logger `beam.status`. |
| Streamed diagnostics | Lean-published events observed while a request is pending. | MCP `notifications/message` with logger `lean.diagnostic`; internal broker `diagnostic` events; CLI stderr diagnostics. |
| Current result | Stable synced-state verdict for one document version. | CLI `result` and MCP `structuredContent` share `diagnostics`, `readiness`, and `document_progress`; the internal broker response remains private. |

Wrapper stderr is the human-facing surface. Machine consumers of an owned wrapper session should
check exit status, then parse final stdout JSON when present. Use MCP for structured live events and
failures.

### Internal Broker Stream

The wrapper and daemon communicate through a private broker stream. It carries live progress and
diagnostics before one terminal response, but its framing and envelopes are implementation details,
not an installed command-line interface or a supported machine protocol. Maintainers keep its exact
ordering and correlation contract in the broker stream tests and
[development guidance](DEVELOPMENT.md#internal-broker-stream-contract).

The selected root chooses a workspace runtime and bounds document admission. A path used to read or
open a document must resolve to an existing regular file inside its canonical root, with a canonical
filename ending in `.lean`. The suffix is case-sensitive, matching Lean module-name selection.
An alias named `Alias.txt` that resolves to `Main.lean` is accepted; `Alias.lean` resolving to
`notes.txt` is rejected. Beam checks the canonical target before reading contents or starting a
document worker. Missing paths, directories, cyclic or dangling symlinks, and unsupported source
kinds return `invalidParams`; permission and unexpected I/O failures retain `internalError`.
Missing source targets are reported as `does not exist`; unresolvable paths such as symlink cycles
are reported as `cannot be resolved`. Source bytes must be valid UTF-8; invalid encoding returns
`invalidParams` before starting a document worker and preserves any tracked document.
Opening uses strict filesystem resolution, so `missing/../Main.lean` cannot bypass a missing
intermediate directory. Empty files and malformed Lean syntax in valid UTF-8 remain source inputs:
Lean reports syntax and elaboration diagnostics normally. To open an external file, select a workspace
containing it. Normal Lean imports and navigation results remain available across that boundary. Lean
metaprogramming can perform IO, so callers requiring OS filesystem isolation must sandbox the owner
process itself.

The wrapper's final stdout object may echo a caller-supplied `BEAM_REQUEST_ID` as a presentation
convenience; internally generated cancellation IDs remain hidden. This decoration is not part of
the semantic broker response.

## MCP Diagnostics

The MCP server advertises logging and forwards incremental Lean diagnostics as structured
`notifications/message` log events. Modern callers opt in for each request with
`_meta["io.modelcontextprotocol/logLevel"]`; legacy callers set the connection-wide level with
`logging/setLevel`. [MCP.md](MCP.md#progress-and-diagnostic-logs) defines the exact behavior for
both protocol eras. Events include path, URI, version, range, severity, message data, and
`completion_blocking=true` when a diagnostic is known to block file completion. They are
request-scoped observations; save-blocking evidence is attached to the final sync/save verdict.

MCP clients that cannot conveniently collect interleaved notifications can call `lean_sync` or
`lean_refresh` with `diagnostics_in_result: true` to replay diagnostics in the final structured
result. By default replay and streaming use an error-only diagnostic filter. Final replay
intentionally duplicates any matching diagnostics already consumed live. For synced-file requests,
`diagnostic_scope: "all"` widens streamed and replayed diagnostic output to warnings, information,
and hints.

Beam omits Lean's silent messages, such as `Goals accomplished!`, from diagnostic streams, final
diagnostic items or counts, `lean_todo`, and `runAt` messages. This rule is independent of
`diagnostic_scope`: `"all"` does not reveal silent messages.

For `runAt` and handle continuations, silence controls presentation rather than success. A remaining
Lean message with error severity or a caught elaboration abort produces `success=false` and no
successor handle. If no visible error is available, Beam supplies a short failure explanation.
Beam uses the final messages after enclosing commands or tactics have handled expected errors,
including consuming them with `#guard_msgs` or downgrading them in Verso documentation examples.

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
lines beyond it. The operation result retains the latest observed counters and ranges available when
that response is constructed, so they may be newer than the last live broker event or throttled MCP
notification. An operation can also reuse a previously observed value without emitting live file
progress; `updates` is not a count of work performed by the current request. When observed,
`document_progress` appears on both CLI and MCP operation results, including operations such as
`runAt`. It may be partial and does not imply that the operation waited for the whole file to finish.
Use these fields for coarse UI progress only. Final machine decisions should use the readiness and
diagnostic result fields.

For `sync`, `refresh`, `save`, and `close-save`, the internal diagnostics barrier waits for Lean's
reporter and command snapshots, then reports `hasFatalSnapshot`: whether a snapshot contains a
fatal stop preventing further file processing. Ordinary elaboration errors do not set this flag;
they can finish processing while still blocking artifact save through `readiness.save_ready`.
The final progress `done` value is derived from the barrier's fatal-snapshot status and dependency
checks. A delayed busy progress notification cannot reject a completed barrier, and an observed
done notification cannot override a fatal snapshot or a stale-dependency veto. For non-barrier
calls, file progress may be partial because the request can return before the whole file reaches
`done = true`.

## Readiness

Successful sync responses expose one flat result for the current document version. CLI's `result`
and MCP's `structuredContent` use the same snake_case names for Beam-owned operation fields; MCP
also includes the explicit `workspace` descriptor. The CLI keeps its `ok`/`result` transport
envelope. The internal broker protocol is separate and may keep its own field names. Standard
Lean/LSP payloads embedded in a result retain their protocol-defined shape.

Known-empty collections are present as empty arrays. Optional fields are omitted when they were not
requested or do not apply; for example, `diagnostics.items` is absent unless diagnostic replay was
requested. CLI JSON is compact by default; `--pretty` changes whitespace only. MCP remains compact.
The machine-facing readiness fields are:

- `readiness.save_ready`
- `readiness.reason`
- `readiness.blocking_error_count`
- `readiness.blocking_diagnostics`
- `readiness.blocking_messages`

`diagnostics.counts.*` reports user-facing Lean-published diagnostic severities. It answers "what
did Lean report?", while readiness answers "can this synced version be checkpointed?". The backend
readiness API is authoritative for `save_ready`; diagnostic severity summaries are evidence and
counts, not a separate broker-side veto. The same `readiness` object and names appear in the CLI
operation result.

`blocking_error_count` is intentionally not named `error_count`: it counts save-blocking evidence,
including a blocking command message when Lean did not attach a diagnostic. It can therefore differ
from `diagnostics.counts.error`. Warning counts are reported once, under `diagnostics.counts.warning`.

Lean-side readiness applies the frontend artifact gate to the current synced snapshot: current
save-blocking frontend errors and deferred compilation block save. This verdict answers whether Beam may checkpoint that
server snapshot; it is not a batch-equivalence verdict. Diagnostic streams, diagnostic summaries,
and message history are observations; clients should not reconstruct save readiness from them.

## Current Result

Each sync result describes only the current synced document version. It does not carry deltas
against previous responses. Clients that need comparisons should retain the previous response they
care about and compare it explicitly.

- `path` and `version`: the synced document described by the result
- `diagnostics.counts`: current user-facing diagnostic counts by severity and total
- `diagnostics.items`, when requested: diagnostics selected by `diagnostic_scope`
- `readiness`: the current save-readiness verdict and blocking evidence

Successful CLI and MCP saves repeat the synced document's top-level `path` and `version`, add
the checkpoint fields `module`, `source_hash`, `olean`, `ilean`, `c`, and `trace`, and nest the
canonical sync result under `sync`. Module saves also include `olean_server`, `olean_private`, `ir`,
and `ir_sig`; LLVM-enabled builds additionally include `bc`. The `.ir.sig` file is published with
the module's `.olean` and `.ir` companions, and its hash is included in the Lake save trace.
Close-save wraps the same save result as
`{ "closed": true, "saved": <save-result> }`. MCP uses snake_case for the multiword artifact fields;
see the complete [`lean_save` result example](MCP.md#stable-result-shapes).

## Failures And Recovery

If Lean cannot reach a completed diagnostics barrier for the synced version, `lean-beam sync` fails
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
