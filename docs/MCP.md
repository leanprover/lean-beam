# MCP

This is maintainer documentation for the experimental `lean-beam-mcp` server. User setup lives in
the [setup guide](SETUP.md#mcp-setup).

## Protocol And State Model

`lean-beam-mcp` is a stdio MCP server over the shared Beam broker runtime. It is not a raw Lean LSP
proxy and does not auto-expose editor-oriented LSP methods as agent tools.

The server prefers stateless
[MCP `2026-07-28`](https://modelcontextprotocol.io/specification/2026-07-28/). It also supports
initialization-based MCP `2025-11-25` while clients migrate. `server/discover` lists the modern
revisions that clients may send in per-request metadata; legacy clients continue to start with
`initialize`, so `2025-11-25` is not a discovery result.

One stdio transport uses one protocol family. `server/discover` is a neutral compatibility probe:
after discovery, a client may still choose either family. A successful legacy `initialize` selects
the legacy family, while the first supported operation carrying valid modern protocol metadata
selects the modern family. Once selected, requests from the other family return JSON-RPC `-32600`.
Modern request metadata remains request-local: it is validated independently and never retained for
a later request.

Modern clients do not initialize a session. Every request instead includes:

```json
{
  "_meta": {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {
      "name": "example-client",
      "version": "1.0"
    }
  }
}
```

The protocol version and client capabilities are required; client identity is optional. Each
successful modern result has `resultType: "complete"` and identifies the server in
`_meta["io.modelcontextprotocol/serverInfo"]`. `server/discover` and `tools/list` are public-cache
results with a one-hour TTL because their contents do not depend on a user, workspace, or prior
request. MCP `2026-07-28` deprecates Logging, so Beam writes operational logs to `stderr`. Discovery
still advertises `logging` for clients that need request-scoped, structured Lean diagnostics on the
MCP stream; those clients opt in on each request.

The application model is request-stateless in both protocol eras:

- every workspace-bound request includes an explicit workspace descriptor
- no request depends on a root or workspace selected by earlier MCP traffic
- continuation state is explicit in proof handles
- warm Lean processes, document mirrors, metrics, and diagnostics remain implementation caches

The server does not currently initiate Multi Round-Trip Requests. It recognizes the standard
`inputResponses` and `requestState` fields on `tools/call`, but rejects them with JSON-RPC `-32602`
because Beam never returned the `input_required` result that would authorize a continuation. If
MRTR is added later, `requestState` will remain continuation data for one logical request; it will
not select a workspace.

## Local Workspace Descriptor

The current local descriptor is:

```json
{
  "workspace": {
    "root": "/absolute/path/to/lean/project"
  }
}
```

`workspace` is required on `beam_feedback_report`, `lean_drop_workspace`, and every Lean operation.
The root must be an absolute path to an existing Lean/Lake project. Beam resolves it to a canonical
path and derives a private, deterministic broker cache key from that path. Canonical aliases
therefore share one runtime; clients do not choose process-local workspace ids. For this local
transport, any Lean/Lake project accessible to the MCP server process may be selected; the root is
not restricted to the directory from which the server was started.

There is no distinguished default workspace, `lean-beam-mcp --root`, `lean_init_workspace`,
`lean_list_workspaces`, or MCP `roots/list` fallback. A first ordinary request is sufficient:

```json
{
  "name": "lean_sync",
  "arguments": {
    "workspace": {"root": "/absolute/path/to/project"},
    "path": "Main.lean"
  }
}
```

The server validates the descriptor, lazily creates or reuses its runtime, and echoes the canonical
descriptor in successful Lean results:

```json
{
  "workspace": {"root": "/canonical/path/to/project"}
}
```

This is deliberately a local-only descriptor. Remote workspaces and same-source multiple-toolchain
mirrors need a broader Source/Workspace split and a transport-safe descriptor; they are not modeled
as client-chosen aliases for local roots.

The descriptor selects the Lean runtime and toolchain; it is not a filesystem authorization
boundary. Relative `path` values resolve under the canonical workspace root, while absolute paths
are canonicalized independently of that root and may name dependency sources outside it. A remote
transport must add an explicit Source model and authorization policy rather than treating this
local descriptor as a sandbox.

## Runtime Setup

The installed `bin/lean-beam-mcp` wrapper is the public setup path. It pairs the MCP executable with
the matching installed `beam-cli` and passes `--beam-cli`. On first use of a canonical root,
[Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean) asks
`beam-cli --root <root> mcp-config` for the project-specific Lean command, runAt plugin, and
target-built Lake helper. The helper exchanges only JSON metadata with the MCP broker, so workspace
configuration and zero-build save traces remain owned by the selected Lean/Lake build even when the
MCP executable itself was built with a different Lean commit.

Keep bundle resolution in this CLI/runtime boundary. Normal MCP clients should pass the workspace
descriptor, not raw Lean commands or plugin paths. Source-tree tests and direct developer runs may
instead pass `--lean-cmd` and `--lean-plugin` together when the plugin has a sibling `beam-daemon` in
the standard build or install layout. MCP rejects either explicit flag alone, combining
`--beam-cli` with explicit runtime flags, and an explicit plugin without that sibling helper.

`lean_drop_workspace` is optional cache management, not context selection. It evicts the runtime
for its descriptor and invalidates proof handles owned by that runtime. Drop is idempotent and
returns `dropped: false` with `reason: "notFound"` when no cache exists. A later ordinary request
with the same descriptor recreates the runtime lazily. Retain the canonical descriptor when a Lean
operation, non-confidential feedback result, or drop result echoes it: cache eviction accepts that
absolute descriptor even if the project directory or its Lean/Lake markers have since disappeared.

After editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or
dynamic libraries, drop that workspace or restart the MCP server before the next request. Re-syncing
inside the old Lean process is not sufficient to reload workspace configuration.

## Transport Lifetime

The `lean-beam-mcp` stdio process owns its optional in-process broker runtime. MCP clients do not
start or attach to a wrapper daemon and do not need a separate `lean-beam serve` owner. The
first Lean operation that needs broker execution creates the runtime lazily; later descriptors share
that runtime while the broker remains authoritative for workspace membership. Feedback and cache
eviction can inspect or update an absent runtime without creating one. `lean_drop_workspace` evicts
one cached workspace but does not end the stdio session.

Closing stdin or reaching EOF closes MCP request admission. The server cooperatively cancels active
cancellable requests, waits for every admitted request and non-cancellable workspace eviction to
finish, then closes the broker runtime and all remaining backend sessions. A JSON-RPC request ID is
active only until its request reaches terminal completion. The server retires that exact admission
before publishing its terminal response, so a client may reuse the ID after observing the response;
the completion barrier is resolved only after the terminal response write attempt finishes, including
when that write fails.

CLI ingress has a different transport lifetime: a broker daemon accepts one request per socket
connection, and disconnecting that connection cancels its exact broker admission. MCP carries many
overlapping requests on one stdio stream and therefore owns application-level ID routing,
cancellation, output serialization, and workspace-control fences. Both paths use the same broker
request dispatcher and runtime teardown boundary.

## Code Ownership

- [Beam/Broker/Protocol.lean](../Beam/Broker/Protocol.lean) owns broker request, response, handle,
  and stream envelopes.
- [Beam/Broker/Server.lean](../Beam/Broker/Server.lean) owns workspace runtimes, document state,
  sessions, metrics, cancellation, and handle invalidation.
- [Beam/Lean/Operation.lean](../Beam/Lean/Operation.lean) owns curated Lean operations, typed inputs,
  schemas, and operation-to-broker adapters.
- [Beam/Workspace/Protocol.lean](../Beam/Workspace/Protocol.lean) owns the public local descriptor
  and broker-internal lifecycle types.
- [Beam/Lean/Workspace.lean](../Beam/Lean/Workspace.lean) owns Lean/Lake root validation.
- [Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean) owns MCP tool names, descriptors, schemas,
  and normalized output.
- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean) owns the current MCP JSON-RPC helpers.
- [Beam/Mcp/Runtime.lean](../Beam/Mcp/Runtime.lean) owns root-to-runtime configuration.
- [Beam/Mcp/SelfCheck.lean](../Beam/Mcp/SelfCheck.lean) owns the installed-wrapper self-check.
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean) owns descriptor resolution, lazy broker-runtime
  access, the typed protocol-family state machine, and the synchronous protocol-test seam. The
  broker runtime is authoritative for workspace state.
- [Beam/Mcp/StdioServer.lean](../Beam/Mcp/StdioServer.lean) owns the permanent stdin reader,
  concurrent coordination, cancellation, cache-control barriers, and serialized output.

## Public Tools

`tools/list` contains:

- process utilities: `beam_version`, `beam_stats`
- workspace-bound feedback report: `beam_feedback_report`
- cache eviction: `lean_drop_workspace`
- curated Lean operations projected from `Beam.Lean.Operation`

The Lean operations include update/sync/refresh/save/close operations, runAt and explicit follow-up
handle operations, hover and navigation, document/workspace symbols, goals, todo discovery, and
code-action resolution. Raw LSP methods and generic broker escape hatches are intentionally absent.

Twelve observational tools advertise MCP `annotations.readOnlyHint = true`:

- process inspection: `beam_version`, `beam_stats`
- stateless speculation: `lean_run_at`
- document inspection: `lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`,
  `lean_document_symbols`, `lean_workspace_symbols`, `lean_goals`, and `lean_todo`
- payload resolution without edit application: `lean_code_action_resolve`

The annotation means the tool does not intentionally retain or update Beam semantic state and does
not write Beam-managed artifacts. Incidental cache warming can affect debug statistics, but it is
implementation bookkeeping rather than a project-semantic update. The hint is advisory and is not
an OS sandbox: user-supplied Lean commands and project metaprogramming may perform IO. The generated
descriptions for speculative tools state that boundary directly. Other tools omit the hint. In
particular, the feedback tool has an optional evidence-bundle mode that writes local files, so one
static read-only annotation cannot describe every call.

Two non-read-only tools advertise `annotations.destructiveHint = false` because their
Beam-managed effects are only additive:

- `lean_run_at_handle` may retain a fresh follow-up handle
- `lean_run_with` may retain a fresh continuation handle without consuming its parent

Two destructive lifecycle tools advertise `annotations.idempotentHint = true` because repeating
them has no additional Beam-managed effect:

- `lean_drop_workspace` leaves the cache absent and returns `dropped: false` with
  `reason: "notFound"` when repeated before another request recreates the workspace
- `lean_close` leaves the document closed and succeeds when it is already closed

These hints do not make the tools read-only, approval-free, or safe to parallelize with dependent
operations. Idempotence describes the resulting environment, not identical repeated responses.
All other non-read-only tools retain the protocol defaults: potentially destructive and not
idempotent. This includes `beam_feedback_report`, whose optional evidence-bundle mode writes local
files subject to the concurrent-writer limitation in the [feedback output contract](FEEDBACK.md#output).

`beam_version` returns the running server identity in `structuredContent`. Its `mcp_protocol` field
is the server's preferred revision, not mutable negotiated state for the current request. Installed
runtime identities include the optional Boolean `runtime_current`: `true` means the process belongs
to the runtime selected by the install root's `current` link, while `false` means it is stale or
that the link is missing. Source-checkout identities omit this field. Invalid installed state also
includes the optional string `runtime_error`; the tool call still succeeds so clients can report
the broken identity. Restart an agent or MCP client for `runtime_current: false`. For
`runtime_error`, stop Beam clients and follow the error-specific
[installed-runtime recovery guidance](SETUP.md#prune-old-installed-state) before resuming normal
work.

Direct MCP clients should call `lean_update` or `lean_sync` before snapshot-bound operations and
pass the returned `snapshot` for the same descriptor and path. `lean_workspace_symbols` is
workspace-scoped but has no document snapshot. `lean_run_with`, `lean_run_with_linear`, and
`lean_release` take an opaque handle returned by a previous handle operation. The supplied workspace
descriptor must resolve to the same private runtime identity carried by that handle. `lean_goals`
also requires `mode: "before"` or `mode: "after"`.

Beam's source-file invariant is that Beam never applies source edits to `.lean` files on disk; the
client applies source edits. `lean_update`, `lean_sync`, and `lean_refresh` read the current saved
source from disk into Beam's LSP mirror. `lean_save` and `lean_close_save` additionally write
Lean/Lake build artifacts, never source. `lean_code_action_resolve` only returns a resolved action;
the client must apply any LSP `WorkspaceEdit` it contains.

`lean_run_at`, `lean_run_at_handle`, `lean_run_with`, and `lean_run_with_linear` are speculative.
They test supplied text against a selected document snapshot or follow-up handle without persisting
that text as source. Do not call `lean_sync` as a way to commit a successful probe. To keep a result,
first edit and save the Lean file with the client's normal file-editing tool. Then call `lean_update`
before another snapshot-bound operation, or call `lean_sync` when a diagnostics/readiness barrier is
needed. Both commands read the current on-disk file; neither applies or recovers speculative text.

`lean_code_action_resolve` takes a `code_action` payload previously returned by `lean_todo`. Clients
apply any returned LSP `WorkspaceEdit` themselves, then call `lean_update` or `lean_sync` again so
Beam observes the edited file and reports the new snapshot. Use `lean_sync` instead of `lean_update`
when the client also needs the diagnostics/readiness barrier.

`lean_save` and `lean_close_save` create development checkpoints from the accepted Lean server
snapshot, including structured Lake options, dynamic libraries, and plugins already applied by the
file worker. Modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared
`-D` settings to `leanOptions`, or use `lake build` when the arguments are intentionally batch-only.
Successful checkpoints are normally sufficient for the local development loop, but MCP clients
should describe them as checkpoint success rather than batch-build or CI success. CI must separately
run `lake build` from clean artifacts. If no successful clean CI result is available, perform the
one-time clean local check outside MCP. See the
[checkpoint contract](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).

## Process-Wide Utilities And Feedback

`beam_version` and `beam_stats` are process-wide and accept no workspace descriptor. `beam_stats`
reports all currently cached broker workspaces for debugging; callers must not use it to establish
context for a later operation.

`beam_feedback_report` requires a descriptor to validate its local workspace target. Beam does not
upload or submit the report; the tool returns it to the MCP caller and can optionally write a local
evidence bundle. Non-confidential mode collects project context for that workspace without starting
a Lean runtime solely for feedback; if the descriptor is already cached, its in-process stats and
open files are included. Another workspace's state is not included. Confidential mode does not
collect that project-derived context and does not echo the workspace descriptor in its result.

## Protocol Errors

In both supported revisions:

- malformed or unknown tools are JSON-RPC errors
- request and notification envelopes reject mixed or undeclared top-level members; unsolicited
  client responses are rejected because the server does not send requests
- `tools/call` accepts `name`, `arguments`, and `_meta`; the standard MRTR continuation fields are
  recognized but rejected until Beam can issue an `input_required` result
- invalid inputs for known tools are MCP tool errors with `isError=true`
- undeclared tool-input fields, including undeclared workspace selector aliases, are rejected as
  structured `invalidInput` errors rather than ignored
- invalid, missing, relative, or non-project workspace roots are structured `invalidInput` errors
- Lean semantic failures remain successful tool returns with Lean-specific success fields
- stale or cross-workspace handles remain structured transport/tool errors

Once a request is identified as MCP `2026-07-28`, missing required per-request metadata returns
JSON-RPC `-32602`. `server/discover` is always treated as modern; another request is treated as
modern when it carries any reserved modern MCP metadata key. Before a protocol family is selected,
a bare non-discovery request remains legacy-era input because stdio has no other signal with which
to distinguish a legacy client. The same bare request returns `-32602` after modern operation
traffic has selected the per-request protocol family. An unsupported modern protocol version
returns `-32022` with the requested revision and the server's supported per-request revision list.
Modern `initialize`, `ping`, and `logging/setLevel` requests return `-32601`.

For MCP `2025-11-25`, a well-formed `initialize` followed by `notifications/initialized` remains
required. Beam validates that the client supplied a protocol-version string, capabilities object,
and client identity before changing legacy lifecycle state. The initialize result selects Beam's
supported legacy revision, `2025-11-25`; the client's proposed revision need not already match it.

## Concurrency, Cancellation, And Shutdown

The server has one permanent stdin reader and one serialized stdout sink. Ordinary tool calls may
overlap, and responses may arrive out of request order. Clients must correlate exact JSON-RPC IDs;
string and numeric IDs are distinct.

A request ID is owned from admission through terminal stdout flush. Reuse is valid in the modern
family after that terminal point. A malformed second request using an ID that is still active is
ignored so it cannot create two indistinguishable terminal responses for the same ID.

The server never sends JSON-RPC requests to the client. Under the current protocol it emits only
responses and request-related notifications. In particular, descriptor resolution never invokes
MCP Roots.

`notifications/cancelled` cooperatively cancels active broker work. If cancellation wins the
terminal race, no final response is emitted for that request. `lean_drop_workspace` is
non-cancellable once admitted because partial cache eviction cannot be rolled back safely. Cache
eviction is a full stream-order fence: previously admitted calls drain before the drop runs, while
later calls wait for its terminal result and may then recreate the same descriptor.

For both protocol families, the MCP coordinator binds each ordinary tool call to the exact request
handle produced by broker admission. Cancellation before that binding prevents dispatch;
cancellation afterward targets that handle directly. The handle becomes inert when its dispatch
scope ends, so a late cancellation cannot affect a later request even if a broker client request ID
is reused.

EOF is the transport shutdown in both supported revisions. `lean-beam-mcp` defines no private
shutdown request. This is separate from `lean-beam --root ROOT stop`, which sends the typed shutdown
operation directly to a Beam broker daemon.

## Progress And Diagnostic Logs

For `tools/call`, clients may pass `params._meta.progressToken` as a string or integer. Progress
updates for one request are monotonic and precede that request's final response. Every Lean
operation tool description, plus `beam_feedback_report` and `lean_drop_workspace`, advertises this
metadata so progress tuning is visible in `tools/list` even though MCP places it outside the tool's
`arguments` object.

When a broker-backed Lean operation, `beam_feedback_report`, or `lean_drop_workspace` has no
progress token, fast calls remain quiet. If Lake setup is observed or the call is still pending
after two seconds, Beam emits at most one `notifications/message` event at level `notice` with
logger `beam.status`. Its data contains the exact JSON-RPC `requestId`, tool, state, optional path,
human message, and a
`progressHint` naming `_meta.progressToken`. This is a best-effort liveness notice, not percentage
progress or a readiness result. Legacy clients receive it under the default log level and can
suppress it by raising `logging/setLevel` above `notice`. Modern clients receive it only when that
request's
`_meta["io.modelcontextprotocol/logLevel"]` admits `notice`.

With a progress token, Beam emits one contextual preparation update followed by meaningful,
throttled Lake setup and Lean file-progress changes. It does not send separate generic `starting`,
`preparing`, and `running` updates, and it streams at most one terminal `done=true` file-progress
event. Final sync, refresh, save, and close-save results contain `document_progress` for clients that
do not retain notifications. It is the latest observation available when the response is constructed
and may therefore be newer than the last throttled notification or reused from already-observed
document state. Other tools, including `lean_run_at`, do not inherit this final metadata.
The full `structuredContent` object is also serialized in `content[0].text`, as the
[MCP 2025-11-25 compatibility guidance](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
recommends. Those are two representations of one result; clients should render one rather than
presenting them as two messages.

Incremental Lean diagnostics are separate `notifications/message` events with logger
`lean.diagnostic`. Modern requests receive these logs only when that request includes
`_meta["io.modelcontextprotocol/logLevel"]`; legacy clients use global `logging/setLevel`. Clients
that cannot collect interleaved notifications can pass `diagnostics_in_result: true` to
`lean_sync` or `lean_refresh`. Set `diagnostic_scope: "all"` when live logs or final items should
include warnings, information, and hints rather than only errors. Asking for final replay can
intentionally repeat diagnostics already seen live; it is an alternate delivery path for clients
that cannot consume interleaved events. Silent editor-only Lean messages, such as
`Goals accomplished!`, are removed at reception and are never made visible by `diagnostic_scope`.

### Stable Result Shapes

The `structuredContent` for a clean `lean_sync` has this semantic shape (counts are always present;
`diagnostics.items` appears only when requested):

```json
{
  "workspace": {"root": "/work/demo"},
  "path": "Main.lean",
  "snapshot": "example-session/3",
  "diagnostics": {
    "counts": {"error": 0, "warning": 0, "information": 0, "hint": 0, "unknown": 0, "total": 0}
  },
  "readiness": {
    "save_ready": true,
    "reason": "ok",
    "blocking_error_count": 0,
    "blocking_diagnostics": [],
    "blocking_messages": []
  },
  "document_progress": {"updates": 12, "done": true, "range_end_line": 80}
}
```

`lean_save` returns artifact paths plus `sync` containing that same
path/snapshot/diagnostics/readiness object. Optional backend artifacts (`olean_server`,
`olean_private`, `ir`, and `bc`) appear only when Lean produced them:

```json
{
  "workspace": {"root": "/work/demo"},
  "path": "Main.lean",
  "module": "Main",
  "snapshot": "example-session/3",
  "source_hash": "9a9bdc9950870951",
  "olean": "/work/demo/.lake/build/lib/lean/Main.olean",
  "ilean": "/work/demo/.lake/build/lib/lean/Main.ilean",
  "c": "/work/demo/.lake/build/ir/Main.c",
  "trace": "/work/demo/.lake/build/lib/lean/Main.olean.trace",
  "sync": {
    "path": "Main.lean",
    "snapshot": "example-session/3",
    "diagnostics": {
      "counts": {"error": 0, "warning": 0, "information": 0, "hint": 0, "unknown": 0, "total": 0}
    },
    "readiness": {
      "save_ready": true,
      "reason": "ok",
      "blocking_error_count": 0,
      "blocking_diagnostics": [],
      "blocking_messages": []
    }
  },
  "document_progress": {"updates": 12, "done": true, "range_end_line": 80}
}
```

`lean_close_save` returns `{ "closed": true, "saved": <save-result> }`. Save and close-save
answers are closed typed shapes rather than passthrough broker JSON; unexpected artifact fields are
rejected before an MCP reply is constructed. A `lean_run_at` result is deliberately smaller and
never gains final document progress:

```json
{
  "workspace": {"root": "/work/demo"},
  "success": true,
  "messages": [],
  "traces": [],
  "proof_state": null,
  "next_handle": null
}
```

`readiness.blocking_error_count` counts save-blocking evidence and can include a command message that
has no diagnostic. It may therefore differ from `diagnostics.counts.error`.

### Display-Control Matrix

MCP display behavior has four independent controls. `_meta.progressToken` belongs beside
`arguments` in the `tools/call` envelope. `diagnostic_scope` and `diagnostics_in_result` are ordinary
tool arguments, but only on the tools listed below. Log delivery is session-wide
`logging/setLevel` for legacy clients and per-request
`_meta["io.modelcontextprotocol/logLevel"]` for modern clients.

| Tool or family | With `_meta.progressToken` | Without a token | Diagnostic arguments | Stable final result |
| --- | --- | --- | --- | --- |
| `lean_sync`, `lean_refresh` | Preparation, throttled Lake setup, and file-progress updates. | One `beam.status` on the first setup observation or after two seconds. | `diagnostic_scope`, `diagnostics_in_result` | Path/snapshot, complete diagnostic counts, readiness, `document_progress`, and optional diagnostic items. |
| `lean_save`, `lean_close_save` | Preparation, throttled Lake setup, and file-progress updates. | One `beam.status` on the first setup observation or after two seconds. | `diagnostic_scope` | Checkpoint result embedding the same sync/readiness result and `document_progress`; no diagnostic replay argument. |
| `lean_run_at`, `lean_run_at_handle` | Preparation, Lake setup when observed, and file progress when Lean publishes it. | One `beam.status` on the first setup observation or after two seconds. | None | Run result messages, traces, proof state, and optional handle; no final `document_progress` or full-file diagnostic replay. |
| `lean_run_with`, `lean_run_with_linear` | Preparation and file progress when Lean publishes it. | One `beam.status` after two seconds. | None | Continuation result and optional next handle. |
| `lean_update` | Preparation phase only. | One `beam.status` after two seconds. | None | New document snapshot and changed flag; no readiness barrier. |
| `lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`, `lean_document_symbols`, `lean_goals`, `lean_todo`, `lean_code_action_resolve` | Preparation and file progress when Lean publishes it. | One `beam.status` after two seconds. | None | Operation-specific structured result. |
| `lean_workspace_symbols` | Preparation phase only. | One pathless `beam.status` after two seconds. | None | Workspace-symbol result. |
| `lean_release`, `lean_close` | Preparation, plus file progress for release when Lean publishes it. | One `beam.status` after two seconds if the normally short call is delayed. | None | Release/close result. |
| `lean_drop_workspace` | Preparation phase, emitted before waiting behind earlier requests. | One pathless `beam.status` after two seconds while the drop waits for earlier requests or eviction. | None | Drop and handle-invalidation result. |
| `beam_feedback_report` | Collection phase only. | One `beam.status` after two seconds while collection remains pending. | None | Rendered report and optional collected evidence. |
| `beam_stats` | Quiet; a supplied token is not used. | Quiet. | None | Process statistics. |
| `beam_version` | Quiet; a supplied token is not used. | Quiet. | None | Server identity. |

The no-token `beam.status` cells assume that the active log policy admits `notice`; otherwise those
calls remain quiet.

For `lean_sync` and `lean_refresh`, the diagnostic argument combinations are:

| `diagnostic_scope` | `diagnostics_in_result` | Live `lean.diagnostic` candidates | Final `diagnostics.items` |
| --- | --- | --- | --- |
| omitted or `"errors"` | omitted or `false` | Errors only | Omitted |
| omitted or `"errors"` | `true` | Errors only | Current errors |
| `"all"` | omitted or `false` | Errors, warnings, information, and hints | Omitted |
| `"all"` | `true` | Errors, warnings, information, and hints | Current errors, warnings, information, and hints |

`lean_save` and `lean_close_save` support the same `diagnostic_scope` live filter but do not expose
`diagnostics_in_result`. Diagnostic counts and readiness remain complete regardless of
these display choices.

The active log level applies after the diagnostic filter and never suppresses
`notifications/progress` or fields in the final result. The legacy server starts at `debug`, so all
otherwise-selected log events are enabled until the client changes the level. Modern requests that
omit their per-request log level receive no log notifications:

| Active minimum log level | `beam.status` notice | With `diagnostic_scope: "all"`, visible Lean diagnostic levels |
| --- | --- | --- |
| Modern level omitted | Hidden | None |
| `debug` | Shown | Error, warning, information, hint |
| `info` | Shown | Error, warning, information |
| `notice` | Shown | Error, warning |
| `warning` | Hidden | Error, warning |
| `error` | Hidden | Error |
| `critical`, `alert`, or `emergency` | Hidden | None of the current Lean diagnostic events |

Useful presets are therefore:

- normal legacy call: omit the per-call controls; fast calls are quiet and slow Lean operations get
  one liveness notice under the default log level
- normal modern call with no logs: omit the per-request log level; both diagnostics and automatic
  status logs remain quiet
- modern no-token liveness: request log level `notice`
- detailed progress: add `_meta.progressToken`; progress delivery is independent of diagnostic logs
- quiet modern detailed progress: add `_meta.progressToken` and omit the per-request log level
- rich live sync diagnostics: set the request log level to `debug` and add
  `diagnostic_scope: "all"`; add `_meta.progressToken` separately when detailed progress is also useful
- rich diagnostics for a client that cannot retain notifications: also add
  `diagnostics_in_result: true` on `lean_sync` or `lean_refresh`
- warnings/errors but no automatic status: select log level `warning` and use
  `diagnostic_scope: "all"` where supported

A no-token liveness event has this shape:

```json
{
  "jsonrpc": "2.0",
  "method": "notifications/message",
  "params": {
    "level": "notice",
    "logger": "beam.status",
    "data": {
      "requestId": 42,
      "tool": "lean_sync",
      "state": "running",
      "message": "lean_sync on Main.lean is still working.",
      "path": "Main.lean",
      "progressHint": "For detailed live updates, pass tools/call params._meta.progressToken."
    }
  }
}
```

Global `logging/setLevel` belongs only to the legacy `2025-11-25` path. Modern `2026-07-28`
requests carry their log level independently in
`_meta["io.modelcontextprotocol/logLevel"]`; it is not retained for later calls.

## Testing And Conformance

- [McpProjectionTest.lean](../tests/lean/BeamTest/Broker/McpProjectionTest.lean) checks the curated
  tool surface, descriptor schemas, adapters, and normalized results.
- [McpProtocolTest.lean](../tests/lean/BeamTest/Broker/McpProtocolTest.lean) checks JSON-RPC shapes,
  protocol-family routing and selection, discovery version scope, metadata validation, result/cache
  envelopes, descriptor decoding, lifecycle gating, progress, status logs, errors, and diagnostic
  forwarding.
- [test-mcp-stdio.py](../tests/test-mcp-stdio.py) checks real modern discovery and direct calls,
  malformed modern metadata, modern progress and tool-error envelopes, per-request logging, EOF
  teardown, legacy lifecycle compatibility, lazy first use, canonical aliases, simultaneous cold
  first use of distinct roots, different toolchains in one process, cross-workspace and
  cross-process handle rejection, scoped feedback, eviction/recreation, modern and legacy
  cancellation, response routing, progress, status reporting, and shutdown.
- [test-mcp-http-bridge.py](../tests/test-mcp-http-bridge.py) checks the local test-only HTTP adapter.
- [test-mcp-conformance.sh](../tests/test-mcp-conformance.sh) runs the pinned external
  `2025-11-25` conformance scenarios.
- [test-mcp-modern-sdk.sh](../tests/test-mcp-modern-sdk.sh) uses a pinned release of the official
  `@modelcontextprotocol/client` package against the real stdio executable. It checks automatic and
  pinned modern negotiation, discovery, tool listing, an explicit-workspace Lean call, progress,
  request-scoped diagnostic logging, and clean process teardown. The script owns the package pin.
- [test-mcp-modern-conformance.sh](../tests/test-mcp-modern-conformance.sh) runs pinned modern alpha
  `@modelcontextprotocol/conformance` scenarios that apply to Beam: tool-list structure, Streamable
  HTTP header validation, and DNS-rebinding protection. This is deliberately labeled an alpha lane
  until the upstream modern suite is stable; the script owns the package and scenario pins.

The alpha suite's broad `server-stateless` and `caching` scenarios are not product-neutral today.
They require synthetic diagnostic tools such as `test_missing_capability` and methods that Beam
does not advertise, including prompts and resources. Beam does not add test-only tools to its
public surface to satisfy those scenarios. The protocol test, real stdio harness, and official SDK
test cover Beam's per-request metadata, stateless workspace selection, request-scoped logging, and
absence of server-to-client requests directly.

The Streamable HTTP bridge is a test adapter over the stdio product, not a separate deployment
model. Its modern mode validates the headers and HTTP statuses needed by the conformance runner,
then forwards the same JSON-RPC message to `lean-beam-mcp`; it does not implement a second tool
surface. Remote and load-balanced deployment requires an explicit transport-safe workspace design
and must not infer application identity from a connection.
