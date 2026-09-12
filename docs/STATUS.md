# Status

Lean Beam is experimental beta software. The repository is public for collaboration, early use,
and feedback, but interfaces and installation details may still change before a stable release.

The main product idea is a small, type-safe, isolated execution surface for Lean. Beam is the shared
thin layer on top of Lean LSP plus Beam-specific extensions: the Lean plugin provides low-level
facts, and the local Beam layer turns those facts into practical CLI, broker, MCP, and skill
workflows.

Pre-stable compatibility policy lives in [Compatibility Policy](COMPATIBILITY.md).

## Current Scope

### Core Lean Surface

- standalone Lean plugin for `$/lean/runAt`
- internal proof-first, command-fallback basis selection
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- agent-oriented `$/lean/todo` range inspection for actionable items such as sorries, holes,
  diagnostics, code actions, and incomplete proofs, exposed through the broker, `lean-beam todo`,
  and MCP `lean_todo`
- versioned broker/MCP code-action resolution for raw Lean code actions returned by `lean_todo`;
  clients still apply returned LSP workspace edits themselves and then update or sync the file
- small Lean semantic navigation wrappers for hover, signature help, definition, references,
  document symbols, workspace symbols, and mode-based goal inspection, exposed through the broker,
  `lean-beam`, and MCP
- explicit Lean `lean-beam sync` barrier with diagnostics wait and compact `fileProgress` reporting
- zero-build `lean-beam save` development checkpoint for one synced workspace module, including
  structured Lake setup already applied by the Lean file worker
- typed sync summaries with current diagnostic/readiness counts for the synced document version

### Local Beam Layer

- foreground-owned local Beam daemon with typed `lean-beam` operations for Lean and Rocq workflows
- optional Rocq Beam goal probes through `coq-lsp`, documented separately in
  [docs/ROCQ.md](ROCQ.md)
- experimental Lean wrapper commands for follow-up handle continuation and release
- installed `lean-beam-search` helper for shorter shell branching/playout workflows
- explicit `ok` / `error` response envelopes on typed wrapper operations
- `lean-beam open-files` daemon introspection for tracked documents, including `diskStatus`,
  the daemon-recorded `checkpointed` marker, and the last compact `fileProgress`
- local broker workspaces keyed by explicit workspace ids, each owning its own LSP session, document
  mirror, handles, sync/save history, and metrics
- compact `fileProgress` reporting on slow Lean wrapper calls when matching LSP progress
  notifications were observed while the request was pending
- explicit support for installed custom elan-linked Lean toolchains through
  `--custom-toolchain <toolchain>`, recorded in the runtime's `custom-lean-toolchains` registry
- conservative installed-state maintenance through `lean-beam prune`, with a dry run by default,
  ownership and manifest validation, and optional stale installed bundle-cache cleanup

### MCP And Agent Integration

- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set
  through stateless MCP `2026-07-28`; initialization-based MCP `2025-11-25` remains available during
  the transition
- MCP implementation backed directly by the broker runtime rather than by a second daemon/client
  connection
- bug-report identity surfaces: `lean-beam --version`, `lean-beam-mcp --version`, and MCP
  `beam_version` for the running server process, including manifest commit or source checkout
  commit/branch/dirty data, installed `runtime_current` status, and structural `runtime_error`
  reporting for invalid owned markers or manifests
- feedback report-card surfaces: `lean-beam feedback-report` and MCP `beam_feedback_report` return
  structured JSON containing pasteable Markdown, metadata, collection warnings, and optional
  evidence bundle paths without uploading or submitting feedback; CLI output and MCP
  `include_collected: true` include collected version/stats/open-file context, daemon registry
  context, and recent daemon incident paths; `confidential: true` instead omits automatically
  collected project debug context, request/response payloads, and evidence, forces HOME-path
  redaction, and marks the report as unsuitable for public posting
- `lean-beam-mcp --self-check <lean-file>` verification from a Lean project through a real
  descriptor-bound `lean_sync` call
- request-stateless local MCP workspaces: every workspace-bound call carries
  `{"workspace":{"root":"/absolute/project"}}`; runtimes are cached lazily by canonical root,
  `lean_drop_workspace` evicts one cache, and there is no default workspace, setup tool, startup
  `--root`, or Roots discovery
- projected MCP tools for versioned Lean file operations, semantic navigation, todo/code-action
  workflows, follow-up handles, save/sync operations, version/stats, and feedback report cards; the
  generated tool list and client semantics are documented in [MCP.md](MCP.md)
- MCP progress notifications for requests that pass `_meta.progressToken`
- MCP diagnostic log notifications for incremental Lean diagnostics during `lean_sync`,
  `lean_refresh`, `lean_save`, and `lean_close_save`, with protocol-era opt-in documented in
  [MCP.md](MCP.md#progress-and-diagnostic-logs)
- MCP `lean_sync` and `lean_refresh` `diagnostics_in_result` option for clients that need selected
  current diagnostics replayed in the final structured result instead of collecting only
  interleaved log notifications
- bundled Lean skills for supported agent clients, plus optional Rocq skills when installed with
  `--rocq-skill`

### Coverage
- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation
- broker, wrapper, install, MCP, and CI coverage described in [docs/TESTING.md](TESTING.md)

## Operational Notes

The base request remains intentionally small:

- one document
- one position
- one Lean command or tactic-block payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

Follow-up handles exist, but they should be treated as pre-stable support APIs rather than as a frozen
long-term contract. They are opaque, workspace- and document-bound, invalidated by same-document
edits, document close, worker or daemon restart, and reset/drop of their owning workspace. Exact
continuation requires an explicit handle path; separate `lean-beam run-at` calls do not chain
through hidden state.

The `lean-beam update`, `lean-beam sync`, `lean-beam save`, and `lean-beam close-save` commands are
a progression:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  version without waiting for diagnostics
- `lean-beam sync` establishes the diagnostics-complete saved file snapshot for the current document
  version
- `lean-beam save` creates a development checkpoint from that server snapshot for one module
- `lean-beam close-save` creates the same checkpoint and then closes the tracked file

Position/range/document operations are version-bound across the broker, MCP, and wrapper surfaces.
Clients first update or sync a saved file, then pass the returned document version to later probes.
Workspace symbol queries are workspace-scoped and do not take a file version. The canonical
field-level contract for update, sync, save, progress, diagnostics, stale-version failures,
readiness, and recovery hints lives in [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md).

If a speculative probe looks right and should become real source, the current contract is still:
make the real edit in the file, save it, then run `lean-beam sync`. After the client has written and
saved accepted text, the intended future direction is for `lean-beam update` or `lean-beam sync` to
reuse matching speculative execution rather than replaying it from scratch. Beam would still not
apply the source edit.

Programmatic wrapper consumers invoke the same typed `lean-beam` operations as human callers and
must check the process exit status before parsing stdout. Completed broker operations, including
semantic failures, print final JSON; selector, setup, or transport failures can exit nonzero with a
human-readable stderr diagnostic and no JSON. Clients that require structured live progress,
diagnostics, and failures should use MCP. Beam does not install a raw generic broker client. A
foreground `lean-beam serve` process owns each wrapper daemon. Normal owner exit tears it down;
abrupt owner loss closes the ownership pipe, requests cooperative shutdown, and leaves the session
fenced for explicit recovery without imposing an independent hard shutdown deadline. Attaching
requests do not acquire daemon ownership. Broker responses require an explicit top-level
`ok` boolean, giving projection layers an unambiguous
success/error discriminator. A successful response always includes `result`; response and stream
envelopes reject undeclared fields, and typed save/close-save results reject incomplete or extended
artifact shapes. The wrapper and daemon use a streamed private transport whose correlation and
event-ordering contract is tested as an implementation boundary rather than exposed as a supported
client protocol.

`lean-beam-mcp` is the experimental stdio MCP entry point. User setup lives in
[SETUP.md](SETUP.md#mcp-setup); implementation, protocol, tool-list, and conformance notes live in
[MCP.md](MCP.md).

## Known Limitations

### Toolchains And Bundles

- Lean plugin loading currently depends on `-Dexperimental.module=true`.
- Lean plugin loading is toolchain-keyed, not toolchain-agnostic.
- Exact CI-validated Lean toolchains are listed in
  [validated-lean-toolchains](../validated-lean-toolchains). Canonical RC and patch variants from
  [compatible-lean-release-lines](../compatible-lean-release-lines) are admitted separately and
  must build and pass a local plugin load/elaboration probe for their exact fingerprint.
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs.
- MCP sync, probe, `lean_save`, and `lean_close_save` operations can use a target runtime built from
  a different Lean commit than the MCP server. The target bundle computes Lake server arguments and
  authors save traces in its own process; live Lake workspace values never cross Lean builds.
- The installer prebuilds the pinned validated toolchain by default and can prebuild additional
  validated, release-line-compatible, or explicitly custom toolchains; setup flags and offline notes live in
  [SETUP.md](SETUP.md).
- Runtime requests first try that installed bundle cache, then fall back to a project-local
  runtime bundle under `.beam/bundles/` for validated, release-line-compatible, or explicitly custom
  toolchains.
- Toolchains outside the validated exact list and compatible canonical release lines that are not
  explicitly custom fail early instead of attempting an opportunistic build.
- Bundle rebuild keys intentionally exclude the full `.lake/packages` checkout tree and instead use
  the resolved toolchain fingerprint, the runtime source tree, `lean-toolchain`,
  `lake-manifest.json`, `validated-lean-toolchains`, `compatible-lean-release-lines`, and
  `custom-lean-toolchains`. See
  [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the custom toolchain and runtime-bundle model.
- The first use of an accepted but not-yet-prebuilt toolchain must still build and qualify a matching
  local fallback bundle.
- On a cold machine, that local fallback build may need network access to fetch dependencies.

### Runtime And Sandbox Behavior

- In sandboxed agent environments, Beam daemon startup itself may require elevated permissions even
  when the installed bundle and project-local `.beam` paths resolve correctly.
- Wrapper sessions use explicit ownership. `lean-beam serve` is the only wrapper command that
  starts a project daemon; it passes the daemon an inherited pipe and remains alive as the owner.
  Ordinary wrapper calls only attach to that generation and
  fail with the exact owner-start command when none is live. Beam chooses the internal loopback
  endpoint and publishes it only through the session descriptor. Owner EOF shuts down request admission,
  marks admitted requests for cancellation, and closes backend sessions and the daemon after those
  requests drain; a backend success that completed before cancellation remains successful. This
  happens without heartbeat timeouts or filesystem leases and works across PID namespaces because
  authority does not depend on observing persisted PIDs. Ordinary calls select the descriptor,
  verify its generation through a bounded greeting on the request's own connection, and only then
  send the capability-bound operation; lifecycle and diagnostic commands additionally classify
  bounded root and generation-identity probe results. Each wrapper
  request carries a random per-generation capability from a mode-`0600` descriptor inside a
  mode-`0700` session directory. A paused owner retains the session; a killed owner closes the pipe;
  explicit
  `lean-beam --root ROOT stop` changes the descriptor to `draining`, and that fence remains until normal
  owner cleanup has reaped the daemon leader after graceful or process-group teardown. If the daemon
  instead exits abnormally during that drain, Beam restores the exact conservative fence so status
  reports `recoveryRequired` rather than treating leader exit as successful cleanup.
  Ordinary lookups take no mutation lock, create no control files, use the frozen workspace
  configuration, and preserve unsafe session state. A competing owner computes its proposed
  configuration but cannot replace a mismatched live owner.
- `lean-beam status` projects internal descriptor observations onto four public states: `absent`,
  `running`, `stopping`, and `recoveryRequired`. Backend-neutral root inference accepts a unique
  Lean/Rocq candidate and rejects different candidates as ambiguous. Automated callers should pass
  an explicit canonical `--root`; `stop` and `recover` require one. Successful lifecycle commands
  use one top-level `ok`/`result` envelope; `serve` projects its private backend warm-up onto the
  public running-session result instead of exposing broker workspace or epoch fields. `stop`
  distinguishes a newly committed transition from an already-stopping session and retains committed
  state in its result when immediate shutdown delivery produces a typed warning.
- Abnormal or ambiguous state is never reclaimed automatically. The descriptor remains as a fence
  after an unexpected broker/owner exit; an unexpected broker exit preserves the live descriptor,
  whose unavailable endpoint projects to `recoveryRequired`. Once the operator has established that
  the matching session is no longer authoritative, `lean-beam --root ROOT recover --generation ID` quarantines
  that exact descriptor without signalling persisted PIDs. Legacy, unsupported, or malformed
  descriptor state requires the deliberately broader `recover --force` form. Current-descriptor
  recovery additionally requires a root recorded in that descriptor, so a wrong-root caller using
  the same session directory cannot quarantine the session. Such a wrong-root selection is reported
  as `sessionSelectorMismatch`, outside the public lifecycle states.
- The default authoritative descriptor is `<root>/.beam/beam-daemon.json`, which keeps discovery
  available inside project-scoped agent sandboxes. An absolute `--session-dir DIR` selects one exact
  alternate
  session directory; callers must repeat the same selection for every owner, request, diagnostic,
  stop, and recovery command. `BEAM_SESSION_ROOT` is the sandbox convenience that derives a
  per-root subdirectory below an absolute writable base. Uniqueness is per canonical root plus
  resolved session directory, not globally per root. Beam requires every selected session
  directory to be account-private (`0700`) before creating its lock or capability descriptor: it
  creates and privatizes a missing leaf, but accepts an existing path only when it is a real,
  non-symlinked mode-`0700` directory. It rejects broader existing permissions without changing
  them. Explicit symbolic-link leaves are rejected before canonicalization, and read-only status or
  attachment operations revalidate the exact leaf and its permissions without mutating it. The
  capability-bearing `beam-daemon.json` leaf is likewise rejected when it is a symbolic link or not
  a regular file; stop and recovery do not read or mutate its target.
  Wrapper sessions contain exactly one frozen workspace; dynamic workspace mutation remains
  unavailable in wrapper mode. MCP retains its independent multi-workspace behavior.
- Deleting the project tree also deletes its default project-local fence. Workflows that may remove
  and immediately recreate the same canonical path, and need exclusion to survive that operation,
  should select a stable external `--session-dir`; this tradeoff keeps the default usable from
  project-scoped agent sandboxes without assuming access to a host-global runtime directory.
- Wrapper-owned brokers currently use authenticated loopback TCP. The supported trust boundary is
  one local OS account with a private session directory and descriptor-file permissions; another
  user who can only discover the port cannot issue requests without the generation capability.
  Direct `beam-daemon` use is maintainer tooling, not a supported shared-host service.
  Unix-domain/per-user native IPC remains a possible later transport improvement.
- A startup failure that reports `operation not permitted` through `.beam/beam-daemon-startup.log` is
  usually an environment restriction, not a bundle-resolution mismatch.
- Wrapper daemon startup uses an OS-assigned loopback port and a bounded private typed readiness message;
  the owner publishes the descriptor only after validating the reported generation and
  configuration. Daemon stderr is copied to the already-open private startup log only until
  readiness or a 64-KiB bound, without a shell or a second pathname lookup. A log-sink failure is
  retained as startup failure while the shared bounded capture continues draining the daemon pipe.
  Capture cleanup is bounded and reports a still-open pipe instead of waiting indefinitely on a
  synchronous pipe read; abnormal daemon exits include the retained stderr tail in their diagnostic.
- Once the Beam daemon is running, a Lean or Rocq backend handshake failure is returned with the
  bounded tail of that backend's stderr. This backend diagnostic is separate from the selected
  session directory's daemon startup log, which covers startup of the Beam daemon process itself.
- Typed broker transport, invalid-response, and request-timeout failures include registry/log
  context and, while the selected private session directory still exists, write a JSON incident
  record below it. Incident kinds are `brokerTransportFailure`, `invalidBrokerResponse`, and
  `brokerRequestTimeout`; callback/display failures do not create daemon incidents. Beam keeps the
  latest 50 incident records, and `lean-beam doctor` lists recent incident paths. Incident logging
  never recreates a deleted project or session directory.
- `Ctrl-C` is observed across wrapper connect, generation greeting, request send, and response
  receive. It closes or abandons that operation's one-request connection without waiting behind a
  blocked write; the daemon's
  connection-owned disconnect watcher cancels the exact admitted request without requiring a
  caller-supplied request ID and is joined when the handler completes. The interrupted client exits
  nonzero without fabricating a terminal broker response on
  stdout. `lean-beam cancel ID` remains the explicit cross-process cancellation surface.
  Cancellation is cooperative; prompt stopping depends on inner elaboration polling interruption.
- Wrapper sessions deliberately publish one frozen workspace. Remote workspaces and same-source
  multi-toolchain mirrors are not implemented yet.

### MCP

- `lean-beam-mcp` prefers MCP `2026-07-28` and implements `server/discover`, required per-request
  protocol metadata, modern result envelopes, cache hints, and request-scoped diagnostic logging.
  It also supports the initialization-based `2025-11-25` lifecycle as an explicit transition
  target; older revisions are not advertised or tested.
- `beam_feedback_report`, `lean_drop_workspace`, and all Lean operation tools require an explicit
  local workspace descriptor. Dropping a workspace invalidates its proof handles; a later request
  with the same descriptor recreates its runtime lazily.
- `lean-beam-mcp` can execute ordinary tool calls concurrently in one process. Responses may arrive
  out of request order and are routed by exact JSON-RPC ID, with string and numeric IDs kept distinct.
- The observational tools enumerated in the [MCP tool documentation](MCP.md#public-tools) advertise
  `annotations.readOnlyHint = true`. Codex MCP registration also sets
  `supports_parallel_tool_calls = true`, allowing Codex to schedule independent probes
  concurrently. The annotation describes Beam-managed state and artifacts; it is not an OS sandbox
  for arbitrary Lean metaprogramming.
- Additive retained-handle tools advertise `annotations.destructiveHint = false`, while idempotent
  workspace-drop and document-close tools advertise `annotations.idempotentHint = true`. These
  remain non-read-only operations; the hints describe Beam-managed effects rather than client
  approval or scheduling policy.
- Tool calls that include `_meta.progressToken` receive concise live MCP progress notifications.
  Updates for one request remain strictly ordered before its final response, while different
  requests may interleave; clients should use distinct tokens for concurrently active requests.
  Without a token, fast broker-backed Lean operations, feedback collection, and workspace drops stay
  quiet; if one enters Lake setup or remains pending for two seconds, it emits at most one structured
  `beam.status` log with the request id and a progress-token discovery hint when the active legacy or
  per-request modern log policy admits `notice`. Other local MCP tools do not receive this watchdog.
- MCP `notifications/cancelled` cooperatively cancels active broker work. Lazy runtime creation and
  workspace eviction remain serialized. Once admitted, `lean_drop_workspace` ignores client
  cancellation and returns its terminal result because partial eviction cannot be rolled back
  safely. Previously admitted calls drain first; later calls wait for eviction to finish and may
  recreate the same descriptor.
- MCP JSON-RPC envelopes, `tools/call` parameters, and broker operation fields are closed at their
  current protocol boundaries; undeclared or operation-irrelevant fields are rejected rather than
  ignored. MCP `_meta` remains open for protocol-defined metadata.
- Incremental Lean diagnostics are forwarded as `lean.diagnostic` MCP log notifications. Recognized
  Lake setup/build observations use `beam.status` or tokened progress instead.
- The Streamable HTTP bridge is test-only; the product entry point remains stdio.
- Exact protocol behavior and conformance notes live in [MCP.md](MCP.md).

### Sync, Save, And Staleness

- Zero-build `lean-beam save` helps checkpoint one module, but it is not a whole-workspace freshness
  solution. Structured Lake options, dynamic libraries, and plugins are supported when the Lean file
  worker has already applied them; batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`.
- Beam does not detect Lake workspace configuration changes during a running Lean session. After
  editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic
  libraries, run `lean-beam --root ROOT stop`, then start a new `lean-beam serve` owner before the
  next wrapper command that uses the Lean server; `lean-beam refresh` does not restart the server.
- A Beam checkpoint contains the Lean server's accepted environment. Elaborators can
  distinguish server execution from batch execution, so exceptional custom elaboration can produce
  an artifact that differs from a fresh `lake build` artifact. Successful checkpoints are normally
  sufficient during local development. Final batch evidence should come from a clean CI `lake build`;
  if no successful clean CI result is available, run the one-time local batch-validation sequence in
  [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).
- If you edit a dependency of the target file, downstream speculative results should be treated as
  stale until rebuild or checkpoint.
- For open files in Lake workspaces, Beam uses Lean's native stale-dependency diagnostic when a synced
  source change makes an importer need refresh. Beam does not yet implement Lean's dynamic watched-file
  registration, so external source changes that never pass through `sync` remain outside the current
  watcher surface.
- `error.data.staleDirectDeps` recovery hints are still broker-derived metadata. Beam currently
  uses direct imports returned by Beam's diagnostics barrier request from Lean's accepted header
  snapshot and combines those imports with broker sync/save history to infer stale direct
  dependencies and `needsSave`. The planned Lean-side backlog item is to expose structured
  stale-dependency metadata from Lean's watchdog/file-worker
  path, so Beam can derive these hints from Lean instead of duplicating that state in the broker.

### Distribution And Rocq

- Agent-skill distribution currently relies on a local checkout and local install script; it is not
  yet published through a registry or marketplace flow.
- Rocq support is currently limited to goal inspection through `coq-lsp`; it is not yet a full
  stateful execution layer.

## Direction

Near-term work is mostly about hardening and simplifying:

- keep the base `runAt` request small
- preserve strict per-request isolation
- reduce packaging and workspace rough edges
- publish a smoother distribution path, likely GitHub-backed install for Codex and plugin
  marketplace packaging for Claude
- improve stale-dependency handling, especially by moving structured stale-dependency metadata into
  Lean's native stale-dependency signal instead of broker-side reconstruction
- upstream structured JSON-RPC error data for Lean request failures, so plugin-level
  `contentModified` errors can carry machine-readable recovery fields such as
  `documentVersionMismatch` without requiring broker-side preflight rejection
- replace broker-side diagnostics/fileProgress barrier inference with a stronger backend-facing
  readiness primitive, so `lean-beam sync` / `lean-beam save` can trust one authoritative completion
  signal instead of reconstructing barrier completeness from multiple LSP channels
- track an upstream Lean API improvement for a pure frontend readiness/reporting helper, close to
  `SnapshotTree.runAndReport` but returning the build-blocking decision and message counts without
  printing
- add richer MCP progress percentages or bounded work-unit totals if Lean exposes them; keep
  structured MCP log messages for incremental diagnostics rather than overloading progress
  notifications or the final tool result
- keep the `sync`, `refresh`, `save`, and `close-save` projections aligned as the canonical
  sync-result schema evolves
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too early
- keep the related-tools comparison current as nearby Lean agent and proof-search tooling evolves
- keep cross-surface utility code such as root resolution and workspace-relative path derivation in
  shared Beam modules, not copied across CLI, broker, MCP, and test helpers

## First Alpha Release Focus

The first public Lean release should stay conservative:

- keep the current `runAt`, `lean-beam`, and MCP surfaces small and documented
- keep CLI and MCP as thin projections over shared typed operation adapters
- keep supported Lean-toolchain and install behavior covered in CI
- take stability fixes when they materially improve release confidence
- defer broader dependency/readiness redesigns until Lean or Lake expose stronger primitives
