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

The descriptor selects the Lean runtime, toolchain and document root. Paths used to read or open a
document must resolve to existing regular files inside the canonical workspace root, with canonical
filenames ending in the case-sensitive suffix `.lean`. Relative paths and aliases are supported:
`Alias.txt` resolving to `Main.lean` is accepted, while `Alias.lean` resolving to `notes.txt` is
rejected. Unsupported source paths return `invalidParams` before reading contents or opening a
worker. Source contents must be valid UTF-8; invalid encoding also returns `invalidParams` before
opening a worker. Select an external target's own workspace to open it. Normal Lean imports and
navigation results may still refer to external dependencies.

Plain `lean_close` cleans up tracked identity even after a source is deleted or becomes an
unsupported kind. Its `closed` value reports actual tracked removal: `true` once, then `false` for
repeated or unknown closes. Both outcomes fence earlier source reads; a fresh request can reopen
the document. Close does not start a worker or read source contents.

### OS permissions and transport

Document admission is not an OS filesystem sandbox. Lean metaprogramming can perform IO with the
permissions available to the MCP server and its children. A sandbox on the client's shell commands
does not automatically constrain a separately launched MCP server; sandbox the actual server
process and its descendants when isolation is required.

The stdio server creates its broker runtime directly. It uses pipes for Lean/Lake child processes
and does not connect to a `lean-beam serve` daemon. CLI daemon communication instead requires
IPv4 loopback TCP. See [sandbox and network permissions](SETUP.md#sandbox-and-network-permissions)
for the permissions needed by each integration and the separate dependency-download requirements.
A remote transport needs an explicit Source model and authorization policy.

## Runtime Setup

The installed `bin/lean-beam-mcp` wrapper starts the MCP executable from its concrete installation.
It forwards its arguments. `--max-unfinished-requests N` sets the ordinary execution-admission pool
(default 32) described under [Transport Lifetime](#transport-lifetime); `N` must be a decimal integer
from 1 to 1024, and any other value is rejected at startup, before the server reads stdin.
This is unrelated to Lean's thread count and to the output byte budgets.
Both standalone and bundled MCP use
[Beam/Installation/Lookup.lean](../Beam/Installation/Lookup.lean) to select a complete runtime
from the installation's published component set. A standalone set may contain several targets;
a bundled Lean toolchain contains one. Installation constructs and qualifies those targets before
publication. Normal MCP execution never builds a missing target, searches another Beam provider,
or executes a candidate compiler to decide whether to reject it.

Project selectors resolve through local paths, locally linked Elan aliases, or exact installed
Elan descriptors. Floating selectors require an explicit local link or exact pin; they do not
trigger network resolution. An unavailable target produces installer guidance. Raw `--beam-cli`,
`--lean-cmd`, and `--lean-plugin` composition options are rejected by the shipped executable.

A workspace retains its accepted runtime description. Read-only admission before reuse rejects
selector or installation-generation changes without retargeting live documents and handles.
Dropping a workspace and protocol discovery remain available when admission fails. Process identity
retains the startup installation record: replacing that record requires a restart, while switching
a launcher's `current` pointer affects future processes only.

The recorded target-built helper exchanges JSON metadata with the broker. Project configuration
and zero-build save traces remain owned by that selected Lean/Lake build even when a standalone
MCP frontend was built with another compiler. Each daemon and helper validates its own recorded
role before using components; wire requests cannot supply an alternative compiler or plugin.

`lean_drop_workspace` is optional cache management, not context selection. It evicts the runtime
for its descriptor and invalidates proof handles owned by that runtime. Drop is idempotent and
returns `dropped: false` with `reason: "notFound"` when no cache exists. A later ordinary request
with the same descriptor recreates the runtime lazily. Workspace removal commits before backend
cleanup: if cleanup fails, drop reports the error and the cache entry remains evicted. The next
ordinary request can recreate it without a second drop; unrelated workspace entries remain cached.
Retain the canonical descriptor when a Lean operation, non-confidential feedback result, or drop
result echoes it: cache eviction accepts that absolute descriptor even if the project directory or
its Lean/Lake markers have since disappeared.

After editing a lakefile, manifest, package override, Lean options, plugins, or
dynamic libraries, drop that workspace or restart the MCP server before the next request. Re-syncing
inside the old Lean process is not sufficient to reload workspace configuration.
Bundled selector changes to another alias of the same installation preserve documents and handles.
Selecting another installation is rejected; use its matching MCP server for that workspace.

## Transport Lifetime

The `lean-beam-mcp` stdio process owns its optional in-process broker runtime. MCP clients do not
start or attach to a wrapper daemon and do not need a separate `lean-beam serve` owner. The
first Lean operation that needs broker execution creates the runtime lazily; later descriptors share
that runtime while the broker remains authoritative for workspace membership. Feedback and cache
eviction can inspect or update an absent runtime without creating one. `lean_drop_workspace` evicts
one cached workspace but does not end the stdio session.

Loading a Lean server's Lake configuration currently holds the broker's shared state lock.
A slow or hung load can therefore block broker-backed tool calls, workspace admission, and stats
for other workspaces in the same MCP process. This loading step has no fixed response deadline.
Send `notifications/cancelled` to request [soft cancellation](STATUS.md#soft-cancellation).
Active loading may need to settle before its resources can be released. `lean_drop_workspace`
waits for earlier uncancelled requests and does not itself interrupt a stalled load. If loading never settles,
stop the MCP server through its client or process supervisor and restart it after its owned processes
have stopped. Cooperative shutdown can also wait on the load; if it cannot finish, use the supervisor's
process-termination facilities and verify that old worker/helper processes have stopped before
starting a replacement. Closing a connection or starting another server does not establish cleanup.
This is a current concurrency limitation; workspaces are not isolated from each other's cold-load latency.

Reuse admission observes the selected installation outside the server-wide runtime mutex. The
server checks the retained workspace instance again before dispatch and when binding the broker
handle, so a concurrent drop/recreate cannot apply an old admission to a new workspace. Stdio
workspace control operations use one global execution fence: they await execution and cleanup of
earlier admitted, uncancelled requests across workspaces before dropping a workspace. Installation admission
reads local metadata and paths, without launching selector or compiler probes. Cancellation is checked around admission; rejected or cancelled reuse
does not replace the retained runtime.

The transport reserves space for a small terminal error before accepting work. One writer owns
stdout. Execution admission is released after operation cleanup, independently of pending delivery.
An execution admission covers a request from registration until its execution settles: queued,
running, and client-cancelled but unsettled work all hold one. A client-cancelled call keeps its
admission until it settles; cancellation alone never frees capacity. Admission is split into pools:

- the ordinary pool holds at most `--max-unfinished-requests` admissions (default 32, range
  1–1024; see [Runtime Setup](#runtime-setup))
- `lean_drop_workspace` uses the ordinary pool while it has room, and otherwise a fixed reserve
  of 2
- `beam_version`, `beam_stats`, and `ping` use the ordinary pool while it has room, and otherwise
  a separate fixed reserve of 2, so queued drops cannot starve them

At most `N + 4` requests are therefore admitted at once, where `N` is the ordinary limit. A request
is charged to the first pool in which both its execution slot and its terminal-reply storage fit,
and is released from that pool exactly once. If
ordinary work that never observes cancellation fills the ordinary pool and is cancelled, a drop
can still be admitted: its backend shutdown stops that work, which then releases its capacity.
The reserves do not make every stall recoverable. A drop still waits for uncancelled earlier
calls, does not interrupt a Lake load holding the broker state lock, and cannot deliver its
response if the client never reads stdout.

Normal output shares a 64 MiB budget; each ordinary admission reserves 4 KiB from it, and an
encoded successful response may use up to 8 MiB. Reserve-pool admissions take their 4 KiB from
their own 512 KiB output budget, one for drops and one for observation. A full ordinary output
budget therefore does not deny recovery, and undelivered drop replies cannot deny observation. A
reserve-pool response that does not fit its budget receives `-32023`.
These frame budgets include envelope metadata, the newline, and retained diagnostic labels.
They do not bound broker computation, input decoding, or result construction.

If a completed result exceeds its frame limit or cannot fit the shared output budget, that request
receives JSON-RPC error `-32023`. Its `data.operation_may_have_completed` is `true`: the response could
not be delivered, but effects such as a committed save are not undone. Do not blindly retry an
operation that may have effects. A missing or cancelled response is likewise not evidence that a
save did not commit. Delayed output retains neither broker resources nor publication authority
after operation cleanup. Admission overload instead produces error `-32024` before the
request executes, when every pool the request may use is full; the client may retry after pending
work/output drains. Neither condition closes
other requests or workspaces.

Busy replies and unowned protocol errors use a separate 256 KiB reserve, enough for 64 small
replies. If this reserve also fills, the input reader waits for output space without holding
coordinator locks. Admitted workers and the writer continue. Cancellation and EOF later in stdin
are delayed until input resumes. These limits are internal, not client settings. An envelope whose
ID cannot fit even the reserved error reply is outside these transport limits and is rejected
before that request is admitted or begins effects.

Diagnostic and status log notifications preserve a bounded prefix: at most 256 KiB and 64 pending
records per request, also charged to shared output storage. After overflow, later omissions are
counted. The final result reports them in `result._meta["lean-beam/output"].diagnostics_omitted`;
an ordinary JSON-RPC error reports them in
`error.data["lean-beam/output"].diagnostics_omitted`. The reserved `-32023` fallback instead reports
incomplete output without an exact omission count; its fixed shape was checked before admission.
Retained logs precede the response. Progress has one replaceable pending notification of at most
64 KiB; oversized
or obsolete progress may be discarded. Responses are never truncated. Cancelled execution retains
its small terminal reservation until cleanup finishes.

Once the stdin reader observes EOF, the server closes admission and cancels cooperative requests,
including workspace evictions still queued behind a control fence. It starts broker runtime closure
before joining outstanding execution, since backend closure may itself release a request. A started
eviction is protected from client cancellation and must retain a truthful result. Accepted responses
can continue draining while backend cleanup proceeds. A blocked protocol reply, parse error, or
progress write cannot prevent this teardown after EOF is observed. Complete rejection-reserve
saturation can delay observing EOF as described above. Process exit has no fixed bound while synchronous
stdout writes remain blocked; the client must read or close its pipe to release them.

Workspace-control fences wait for execution and cleanup, independently of stdout delivery. Later
broker work can therefore execute even if an earlier response remains blocked on stdout. The
server retires an exact request-ID admission before publishing its terminal response, so a client
may reuse the ID after observing that response. Completing a write attempt does not establish that
the client consumed or acknowledged the reply.

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
- [Beam/Mcp/Projection.lean](../Beam/Mcp/Projection.lean) owns MCP tool names, descriptors, and schemas.
- [Beam/Output.lean](../Beam/Output.lean) owns the shared CLI/MCP result and error projection.
- [Beam/Mcp/Protocol.lean](../Beam/Mcp/Protocol.lean) owns the current MCP JSON-RPC helpers.
- [Beam/Mcp/Application.lean](../Beam/Mcp/Application.lean) composes executable startup, installation
  identity, exact membership lookup for workspace creation, and admission against the retained
  runtime description on reuse. It uses the installation adapter directly.
- [Beam/Version.lean](../Beam/Version.lean) holds pure identity data and rendering; installation
  discovery belongs to the application adapters.
- [Beam/Mcp/Server.lean](../Beam/Mcp/Server.lean) owns descriptor resolution, lazy broker-runtime
  access, the typed protocol-family state machine, and the synchronous protocol-test seam. Runtime
  resolution and process identity are supplied as explicit application effects. The broker runtime
  is authoritative for workspace state.
- [Beam/Mcp/StdioServer.lean](../Beam/Mcp/StdioServer.lean) owns the permanent stdin reader,
  concurrent coordination, cancellation, cache-control barriers, and serialized output.
- [tests/lib/installed-mcp-smoke.py](../tests/lib/installed-mcp-smoke.py) verifies installed and
  native executables through the shared external stdio client in
  [tests/test-mcp-stdio.py](../tests/test-mcp-stdio.py). Process supervision for this integration
  check belongs to the test harness.

## Public Tools

`tools/list` contains:

- process utilities: `beam_version`, `beam_stats`
- workspace-bound feedback report: `beam_feedback_report`
- cache eviction: `lean_drop_workspace`
- curated Lean operations projected from `Beam.Lean.Operation`

The Lean operations include update/sync/refresh/save/close operations, runAt and explicit follow-up
handle operations, hover and navigation, document/workspace symbols, goals, todo discovery, and
code-action resolution. Raw LSP methods and generic broker escape hatches are intentionally absent.

The [proof-probe limitations](STATUS.md#operational-notes) also apply to `lean_run_at`,
`lean_run_at_handle`, `lean_run_with`, and `lean_run_with_linear`: introducing a local `let rec` in a
tactic returns `success=false`, the original proof state, and no successor handle, even when the
recursion is valid. Save the complete enclosing declaration and call `lean_sync` to validate it;
use the returned version and fresh handles after the edit. Complete command probes use Lean's
normal termination checks. The skill's
[local recursion workflow](../skills/lean-beam/references/lean-run-at-semantics.md#5-introducing-local-recursion-in-a-tactic-probe)
also explains why this boundary exists and how linear handle consumption applies on failure.

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
identities retain the concrete installation generation and source revision accepted by the process.
Changing a launcher's `current` link affects future launches, without retargeting existing servers.
Replacing or corrupting a running server's own installation makes identity reporting fail; the
server cannot adopt the replacement generation. Protocol discovery and workspace drop remain
available. Restart clients after selecting a new installation, and stop clients before pruning
their original installation. See the [installed-runtime recovery guidance](SETUP.md#prune-old-installed-state).

Direct MCP clients should call `lean_update` or `lean_sync` before snapshot-bound operations and
pass the returned `version` for the same descriptor and path. `lean_workspace_symbols` is
workspace-scoped but has no document version. `lean_run_with`, `lean_run_with_linear`, and
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

The four speculative execution tools accept optional `profile: true`. The result then includes
`profile` when execution reached elaboration, even if the Lean text failed. Parse failures and
unrequested profiling omit it. `profile` contains `elapsed_ms`, `threshold_ms` (currently 1),
`spans`, and `truncated`. Each span has `thread`, `category`, `tag`, `start_ms`, `duration_ms`,
optional `parent` (an earlier span index), and optional `range` relative to the submitted text.
Known-empty spans remain `[]`. Ranges are not document coordinates.

This measures speculative re-elaboration in the already-loaded environment. The wall-clock interval
starts after parsing and ends after request-owned elaboration tasks settle; it excludes snapshot
selection, import loading, response projection, and transport. It is neither the original file's
elaboration time nor cold-build or native CPU time. Scope intervals can overlap across nesting and
threads: do not sum them or treat them as exclusive costs. Instrumentation itself adds overhead.

Profiling returns at most 1024 spans, visits at most 8192 trace nodes, and limits traversal depth to
128. `truncated: true` signals that projection stopped at a limit. These bounds limit response
construction, not Lean's upstream trace allocation. Profiling preserves ordinary diagnostics but
returns `traces: []` instead of formatting the trace tree's lazy labels. The profiler settings and
trace state are request-local and do not persist into follow-up handles.

`lean_todo` inspects the whole file unless all four range fields are given; code actions need a
range (see below), and a whole-file request omits them. It reports one item per
problem, and each item composes with `lean_run_at`: running text at the item's `run_at_position`
starts from the item's `proof_state`, when it has one. The goal of a `sorry` or hole term comes from
the lookup `lean_run_at` uses; for the goals that tactics left, Beam checks that `lean_run_at` selects
those goals there, and omits `run_at_position` otherwise: for example for the
goals left after a branch bullet, or goals left by a tactic that ran once per goal, as `skip` does
in `constructor <;> skip`. Edit the file to work on those goals.

- A `sorry` item carries the goal the `sorry` fills; a `sorry` tactic that ran once per goal, as
  under `<;>`, carries every goal.
- A `hole` item is a `_` or `?x` term that Lean did not fill, for example by unification. A `?_` that
  a tactic turned into a goal is reported where that goal stays open, or not at all once a later
  tactic handles it.
- In a proof, `lean_run_at` text is always tactics. At a `sorry` or hole written as a term, it runs
  against that placeholder's goal like the tactics of a `by ...` block there; supply a term with
  `exact`.
- An `incomplete_proof` item marks goals still open at the end of their proof block, attributed to
  the last tactic that left them open; a goal that a later step of the block solves is proof
  progress and is not reported, including steps a tactic runs internally, such as the `assumption`
  in `rwa`. Goals left at one tactic share one item. Goals of a branch that backtracking abandoned,
  as in `first`, are not reported.
- An error inside a tactic proof carries the goals of its innermost tactic and runs at that
  tactic's start, so the text replaces the failing tactic. The goal it leaves open is not reported
  again as an `incomplete_proof` when the error, or the hole it names, is in the same result; a
  narrower range that excludes them keeps the `incomplete_proof`.
- Lean diagnostics that only restate an item are dropped: the unsolved goals of a block, a
  placeholder Lean could not synthesize, and a declaration's `sorry` warning, when the items report
  every goal or `sorry` they name. They remain when those item kinds are filtered out.

For `code_action` items, Beam forwards the range to Lean
once; Lean selects one command snapshot using the range end and runs its code-action providers
there, with the diagnostics of that command only.
A range spanning several commands does not enumerate code actions for every command. Query a point
inside the relevant tactic, hole, or diagnostic, or use a range wholly within one command. Providers
can further restrict which actions apply, so an empty code-action result does not establish that
the whole range or file has no actions.

`lean_code_action_resolve` takes a `code_action` payload previously returned by `lean_todo`. Clients
apply any returned LSP `WorkspaceEdit` themselves, then call `lean_update` or `lean_sync` again so
Beam observes the edited file and reports the new version. Use `lean_sync` instead of `lean_update`
when the client also needs the diagnostics/readiness barrier.

`lean_save` and `lean_close_save` create development checkpoints from the accepted Lean server
snapshot, including structured Lake options, dynamic libraries, and plugins already applied by the
file worker. Modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared
`-D` settings to `leanOptions`, or use `lake build` when the arguments are intentionally batch-only.
If an import changed on disk after the file worker loaded it, saving fails with `saveImportsChanged`;
call `lean_refresh` so the worker reloads its imports, then save again.
Successful checkpoints are normally sufficient for the local development loop, but MCP clients
should describe them as checkpoint success rather than batch-build or CI success. CI must separately
run `lake build` from clean artifacts. If no successful clean CI result is available, perform the
one-time clean local check outside MCP. See the
[checkpoint contract](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).
`save_ready` means checkpoint eligibility, including snapshots with `sorry` warnings. Tool success,
empty goals, and checkpoint success do not independently confirm a theorem. Follow
[trust and proof confirmation](../skills/lean-beam/references/trust-and-validation.md) when that
stronger acceptance is required.

## Process-Wide Utilities And Feedback

`beam_version` and `beam_stats` are process-wide and accept no workspace descriptor. `beam_stats`
reports all currently cached broker workspaces for debugging; callers must not use it to establish
context for a later operation.

Each entry in the `workspaces` result from `beam_stats` has a `session` object describing its
current Lean server session and a `metrics` object containing workspace operation counters.
Workspace identity and root appear on the enclosing entry. An inactive session has `active: false`;
an active session also has `epoch` and `open_doc_count`.
The counters include earlier Lean sessions of that workspace, so a session restart increments
`session_restarts` without resetting the request counters. Resetting the workspace, or dropping and
recreating it, starts fresh counters. Recreating the broker process also starts fresh counters.

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

A request ID routes to its exact admission until the server commits its terminal outcome, before
publishing the response. The admission remains retained separately until its terminal write attempt
finishes, so delivery cleanup still refers to that exact request generation. In the modern
family, clients may safely reuse the ID after observing the response. A malformed second request
using an ID that is still active is ignored so it cannot create two indistinguishable terminal
responses for the same ID.

The server never sends JSON-RPC requests to the client. Under the current protocol it emits only
responses and request-related notifications. In particular, descriptor resolution never invokes
MCP Roots.

`notifications/cancelled` requests [soft cancellation](STATUS.md#soft-cancellation) of active broker
work; it does not establish that the work or its cleanup has finished. If cancellation wins the
terminal race, no final response is emitted for that request. `lean_drop_workspace` is
cancellable while queued. After it acquires execution ownership, it is protected from client
cancellation because partial cache eviction cannot be rolled back safely. Cache
eviction uses a global execution fence: previously admitted calls across workspaces finish execution
and cleanup before the drop runs; later workspace-bound calls wait for the drop's execution and
cleanup and may then recreate the same descriptor. A call the client has cancelled stops fencing
the drop, even if it has not settled: it keeps its execution admission until it does, and the
drop's backend shutdown can be what stops it. To evict a workspace whose earlier call is stuck,
cancel that call; this also releases a drop that is already waiting. A queued drop keeps its
admission until its fence clears, even if cancelled. `beam_version` and `beam_stats` never wait
for the fence. These fences never wait for stdout. Responses may arrive out
of execution order, including responses to workspace control operations.
Registration or a progress notification alone does not grant execution ownership.

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
updates for one request are monotonic and precede that request's final response. Because MCP
places this metadata outside each tool's `arguments`, the server instructions (returned by both
`initialize` and `server/discover`) advertise it once instead of repeating it in every tool
description. The instructions also state the transport-wide workspace-descriptor and source-edit
rules.

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

With a progress token, Beam offers a contextual preparation update followed by meaningful,
throttled Lake setup and Lean file-progress changes. The writer retains only the latest unsent
update per request and removes obsolete progress when accepting the final response. A fast call
may therefore return without a progress notification; clients must use the final result for its
outcome. Beam does not produce separate generic `starting`, `preparing`, and `running` updates,
and it offers at most one terminal `done=true` file-progress event. Operation results include
`document_progress` whenever Lean progress was observed, including for `lean_run_at`. Barrier calls
may reuse the latest observation available when the response is constructed, so it may be newer
than the last throttled notification. Progress can be partial; clients must not treat it as the
operation's final success verdict.
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

Raw Lake helper output covers configuration evaluation, dependency cloning, and save helpers;
dependency module builds use the existing diagnostic channel. It is separate from Lean diagnostics
and progress counters. Beam forwards stdout/stderr fragments as `notifications/message` events
with level `info` and logger `lake.output`. Legacy clients that send `initialize` start at `debug`,
so these logs are **on by default**. Send `logging/setLevel` with `{"level":"notice"}` or a higher
threshold to suppress raw Lake logs; `notice` still allows Beam's liveness notices. Modern calls
receive no raw logs unless their `params._meta["io.modelcontextprotocol/logLevel"]` admits `info`
(for example, `"info"` or `"debug"`). Lake logger entries themselves use Lake's normal `info`
threshold, so trace-level git command logs are hidden even when MCP logging is at `debug`.
Each event's `data` contains `requestId`,
`tool`, `source` (`stdout` or `stderr`), `text`, and `omittedBefore`. Stderr is a stream identity,
not an inferred error severity. Fragments need not end in a newline.

Pending raw text is limited to 256 KiB and 256 chunks per request. Slow readers cause the oldest
pending text to be dropped; `omittedBefore: true` marks that gap before the retained text. Normal
completion preserves the bounded tail before the final response. Cancellation discards pending
text; a packet already in flight may finish. There is no transcript file or replay API. Lean can
buffer `run_cmd` output until the command returns, so forwarding cannot make those messages appear
earlier. Legacy log-level changes apply when the writer prepares each raw packet for delivery;
modern logging policy stays fixed for the request. These optional logs do not change the operation's
typed result or diagnostic omission count.

### Stable Result Shapes

For the distinction between request success, execution success, open goals, save readiness, and
committed checkpoints, see [Interpreting operation outcomes](SYNC_AND_DIAGNOSTICS.md#interpreting-operation-outcomes)
and its open-goal and retained-receipt examples.

Beam operation results share one normalized field shape across transports. MCP returns that object
as `structuredContent`; the CLI returns it as the value of `result` inside its
`{ "ok": true, "result": ... }` envelope. Workspace-bound operation results include the same
`workspace: {"root": ...}` descriptor on both surfaces. Both
use snake_case for Beam-owned operation fields, including readiness and `document_progress`. The
CLI emits compact JSON by default; `--pretty` changes whitespace only. Standard Lean/LSP values
embedded in results keep their protocol-defined field names. Broker error codes and typed
`error.data` remain structured. Beam-owned error fields use snake_case, including typed nested sync
and save results. Beam-owned wrapper keys for opaque backend evidence also use snake_case, while the
evidence contents keep their original shape. Data with no known typed projection is retained under
`data.original_data` (an explicit JSON `null` remains `null`). If recognized Beam-owned data fails
its schema check, `data.projection_error` explains the mismatch and `data.original_data` retains
all original evidence. Such a response does not provide normalized recovery fields; inspect the
evidence and report the schema mismatch rather than blindly retrying. The original error code and
message remain unchanged. If a completed broker response cannot be projected
into the public schema, `invalidResult` retains that original response under
`error.data.observed_response`. Inspect that receipt before repeating an operation that may have
committed; a projection failure does not undo it.

Known-empty arrays are emitted as `[]`. Optional fields are omitted when a value is unavailable,
not applicable, or not requested. For example, `diagnostics.items` is absent unless replay was
requested, and a failed probe with no successor handle omits `next_handle`. This distinguishes an
empty collection from an absent optional value without creating configurable result schemas.
Structured operation results are always JSON objects. If an operation's underlying value is an
array, scalar, or `null`, MCP places that value under `value` in `structuredContent`, and the CLI
places it under `value` inside the `result` object. This wrapper is present even when no
`document_progress` was observed.

For an array-valued document-symbol query, the decoded shapes are
`{ "ok": true, "result": { "value": [ ... ] } }` on the CLI and
`structuredContent: { "value": [ ... ] }` on MCP.

Broker failures use the same structured `code`, `message`, optional `data`, and observed
`document_progress` fields on both surfaces. The CLI keeps them in `{ "ok": false, "error": ... }`;
MCP returns the error object as `structuredContent` with `isError: true`, inside the MCP transport
response. Beam-owned error fields in `data` use the same snake_case projection as successful typed
results, including nested `sync` and `saved` values. Opaque backend evidence under wrapper keys such
as `observed_response`, `operation_response`, and `original_data` preserves its supplied JSON
contents. An explicit JSON `null` is retained; `data` is omitted when no data was supplied.

The `structuredContent` for a clean `lean_sync` has this semantic shape (counts are always present;
`diagnostics.items` appears only when requested):

```json
{
  "workspace": {"root": "/work/demo"},
  "path": "Main.lean",
  "version": 3,
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
path/version/diagnostics/readiness object. Optional backend artifacts (`olean_server`,
`olean_private`, `ir`, `ir_sig`, and `bc`) appear only when Lean produced them:

```json
{
  "workspace": {"root": "/work/demo"},
  "path": "Main.lean",
  "module": "Main",
  "version": 3,
  "source_hash": "9a9bdc9950870951",
  "olean": "/work/demo/.lake/build/lib/lean/Main.olean",
  "ilean": "/work/demo/.lake/build/lib/lean/Main.ilean",
  "c": "/work/demo/.lake/build/ir/Main.c",
  "trace": "/work/demo/.lake/build/lib/lean/Main.olean.trace",
  "sync": {
    "path": "Main.lean",
    "version": 3,
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

`lean_close_save` returns `{ "closed": true, "saved": <save-result> }`. Once its source is
accepted, it reserves the document through checkpointing and closure. Competing document tools
return `contentModified` with `error.data.reason = "documentClosing"`; coordinate with the
close-save caller before retrying. A delayed request invalidated by closure or backend replacement
uses `documentAdmissionExpired`. Beam-owned fields in the error data use snake_case; opaque backend
evidence keeps its supplied shape.
See the [close-save contract](SYNC_AND_DIAGNOSTICS.md) for failure cleanup and checkpoint receipts.

Save and close-save
answers are closed typed shapes rather than passthrough broker JSON; unexpected artifact fields are
rejected before a tool reply is constructed. The CLI `result` for the same operation has the same
operation fields. A `lean_run_at` result is deliberately smaller; it can include
`document_progress` when Lean reported progress:

```json
{
  "workspace": {"root": "/work/demo"},
  "success": true,
  "messages": [],
  "traces": []
}
```

When Lean returns a proof state or the operation retains a follow-up handle, the result adds
`proof_state` or `next_handle` respectively. They are omitted when absent.

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
| `lean_sync`, `lean_refresh` | Preparation, throttled Lake setup, and file-progress updates. | One `beam.status` on the first setup observation or after two seconds. | `diagnostic_scope`, `diagnostics_in_result` | Path/version, complete diagnostic counts, readiness, `document_progress`, and optional diagnostic items. |
| `lean_save`, `lean_close_save` | Preparation, throttled Lake setup, and file-progress updates. | One `beam.status` on the first setup observation or after two seconds. | `diagnostic_scope` | Checkpoint result embedding the same sync/readiness result and `document_progress`; no diagnostic replay argument. |
| `lean_run_at`, `lean_run_at_handle` | Preparation, Lake setup when observed, and file progress when Lean publishes it. | One `beam.status` on the first setup observation or after two seconds. | None | Run result messages, traces, proof state, optional handle, and `document_progress` when observed; no full-file diagnostic replay. |
| `lean_run_with`, `lean_run_with_linear` | Preparation and file progress when Lean publishes it. | One `beam.status` after two seconds. | None | Continuation result, optional next handle, and `document_progress` when observed. |
| `lean_update` | Preparation phase only. | One `beam.status` after two seconds. | None | New document version and changed flag; no readiness barrier. |
| `lean_hover`, `lean_signature_help`, `lean_definition`, `lean_references`, `lean_document_symbols`, `lean_goals`, `lean_todo`, `lean_code_action_resolve` | Preparation and file progress when Lean publishes it. | One `beam.status` after two seconds. | None | Operation-specific structured result. |
| `lean_workspace_symbols` | Preparation phase only. | One pathless `beam.status` after two seconds. | None | Workspace-symbol result. |
| `lean_release`, `lean_close` | Preparation, plus file progress for release when Lean publishes it. | One `beam.status` after two seconds if the normally short call is delayed. | None | Release/close result. |
| `lean_drop_workspace` | Preparation phase, emitted before waiting behind earlier requests. | One pathless `beam.status` after two seconds while the drop waits for earlier uncancelled requests or eviction. | None | Drop and handle-invalidation result. |
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
