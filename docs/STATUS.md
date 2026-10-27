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
- internal basis selection: an unfilled `sorry`, `_`, or `?x` term first, then a proof, then the
  command
- typed response payload with messages, traces, optional proof state, and optional follow-up handle
- optional follow-up execution through `$/lean/runWith` and `$/lean/releaseHandle`
- agent-oriented `$/lean/todo` inspection of a file or range for actionable items such as sorries,
  holes, diagnostics, code actions, and incomplete proofs. Goal-bearing items can include a
  position where `runAt` selects those goals; diagnostics and code actions need not carry a proof
  state. The operation is exposed through the broker, `lean-beam todo`, and MCP `lean_todo`.
- versioned broker/MCP code-action resolution for raw Lean code actions returned by `lean_todo`;
  clients still apply returned LSP workspace edits themselves and then update or sync the file
- small Lean semantic navigation wrappers for hover, signature help, definition, references,
  document symbols, workspace symbols, and mode-based goal inspection, exposed through the broker,
  `lean-beam`, and MCP
- explicit Lean `lean-beam sync` barrier with diagnostics wait and compact `document_progress` reporting
- zero-build `lean-beam save` development checkpoint for one synced workspace module, including
  structured Lake setup already applied by the Lean file worker
- typed sync summaries with current diagnostic/readiness counts for the synced document version

### Local Beam Layer

- foreground-owned local Beam daemon with typed `lean-beam` operations for Lean workflows
- read-only `lean-beam doctor clients` inspection for local Codex, Claude Code, Pi, OpenCode,
  and Mistral Vibe configuration; this does not test running clients or loaded tools
- experimental Lean wrapper commands for follow-up handle continuation and release
- `lean-beam-search` helper from the standalone installer for shorter shell branching/playout workflows
- explicit `ok` / `error` response envelopes on typed wrapper operations
- `lean-beam open-files` daemon introspection for tracked documents, including `disk_status`,
  the daemon-recorded `checkpointed` marker, and the last compact `document_progress`
- local broker workspaces keyed by explicit workspace ids, each owning its own LSP session, document
  mirror, handles, sync/save history, and metrics
- compact `document_progress` metadata on CLI and MCP results; values can be initialized,
  retained from earlier progress, or derived from a diagnostics barrier, and are not by themselves
  an operation-success or save-readiness verdict
- explicit support for installed custom elan-linked Lean toolchains through
  `--custom-toolchain <toolchain>`, recorded as constructed members of the installation
- conservative installed-state maintenance through `lean-beam prune`, with a dry run by default,
  ownership and manifest validation
- a [native build/install interface for Lean distributors](TOOLCHAIN_BUNDLING.md), using one selected
  Lean installation and its bundled Beam artifacts without standalone runtime caches

### MCP And Agent Integration

- installed experimental `lean-beam-mcp` stdio server exposing the curated Lean Beam tool set
  through stateless MCP `2026-07-28`; initialization-based MCP `2025-11-25` remains available during
  the transition
- MCP implementation backed directly by the broker runtime rather than by a second daemon/client
  connection
- bug-report identity surfaces: `lean-beam --version`, `lean-beam-mcp --version`, and MCP
  `beam_version` for the running server process, including its manifest source revision and retained generation; malformed or replaced records
  fail identity reporting while discovery and cleanup remain available
- feedback report-card surfaces: `lean-beam feedback-report` and MCP `beam_feedback_report` return
  structured JSON containing pasteable Markdown, metadata, collection warnings, and optional
  evidence bundle paths without uploading or submitting feedback; CLI output and MCP
  `include_collected: true` include collected version/stats/open-file context, daemon registry
  context, and recent daemon incident paths; `confidential: true` instead omits automatically
  collected project debug context, request/response payloads, and evidence, forces HOME-path
  redaction, and marks the report as unsuitable for public posting
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
- bundled Lean skills for supported agent clients

### Coverage
- repo-local regression coverage around isolation, stale state, cancellation, and handle invalidation
- broker, wrapper, install, MCP, and CI coverage described in [docs/TESTING.md](TESTING.md)

## Soft Cancellation

Request cancellation in Beam is currently **soft (cooperative)**: it asks an operation to stop at a
safe boundary. It does not guarantee immediate interruption, rollback, or completion within a fixed
time. Lean must poll for interruption, and active serialization, helper work, or synchronous I/O may
need to finish before the operation can release its resources. A client may stop waiting before
backend work has settled; cancellation alone is not evidence that its files are safe to remove.

An operation that has crossed its commit boundary may still complete successfully. Cancellation
does not undo a committed checkpoint. Close-save can retain its document reservation while private
preparation settles; coordinate with its caller rather than repeatedly retrying conflicting work.
See the [save contract](SYNC_AND_DIAGNOSTICS.md#command-model) and
[MCP cancellation and shutdown rules](MCP.md#concurrency-cancellation-and-shutdown) for exact outcomes.

Forced process termination and backend/channel failures are separate lifecycle events. More
responsive cancellation remains a future improvement; callers should not rely on stronger stopping
guarantees today.

## Operational Notes

The base request remains intentionally small:

- one document
- one position
- one Lean command or tactic-sequence payload
- no required command/tactic mode flag

Request-level failures stay at the transport layer. Semantic Lean outcomes stay in the normal typed
response payload.

Proof probes through `$/lean/runAt` and `$/lean/runWith` do not support newly introduced local
`let rec` declarations. They return a semantic failure with the original proof state and no successor
handle, including when the recursion is valid in ordinary Lean. Lean checks these definitions and
their termination when finalizing the enclosing declaration; a tactic fragment has no such step.
Add valid recursive definitions to the document and sync before probing their use. Command probes
that elaborate a complete declaration use Lean's normal finalization and termination checks.
See the skill's [local recursion workflow](../skills/lean-beam/references/lean-run-at-semantics.md#5-introducing-local-recursion-in-a-tactic-probe)
for saved-file validation, version updates, and handle invalidation.

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
receive one final JSON response for completed broker operations and ordinary operation failures, with
human diagnostics on stderr. Broker failures retain their code and data; local usage errors exit
`2`, a missing live owner exits `3`, and request interruption exits `130`. Unexpected faults remain
`internalError`. Check the exit status and the command's output contract; see the
[CLI error and exit contract](SETUP.md#cli-output-and-lifecycle-reference). Clients that require structured live
progress and diagnostics should use MCP. Beam does not install a raw generic broker client. A
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
- The supported Lean release window is 4.34–4.36; the repository defaults to the 4.36.0-rc1
  release candidate. Lean 4.28–4.33 are no longer supported.
- Exact CI-validated toolchains use the latest stable point of each supported stable line plus
  the pinned RC before its stable release, as listed in
  [validated-lean-toolchains](../validated-lean-toolchains). Canonical RC and patch variants from
  [compatible-lean-release-lines](../compatible-lean-release-lines) are admitted separately and
  must build and pass a local plugin load/elaboration probe for their exact fingerprint.
  See the [CI map](TESTING.md#ci-map) for Linux coverage and the configurable macOS layout.
- The supported fast path is the Lean toolchain pinned by this repository's `lean-toolchain`, because
  the plugin uses internal Lean APIs.
- MCP sync, probe, `lean_save`, and `lean_close_save` operations can use a target runtime built from
  a different Lean commit than the MCP server. The target bundle computes Lake server arguments and
  authors save traces in its own process; live Lake workspace values never cross Lean builds.
- The installer prebuilds the pinned validated toolchain by default and can prebuild additional
  validated, release-line-compatible, or explicitly custom toolchains; setup flags and offline notes live in
  [SETUP.md](SETUP.md).
- Runtime requests select only complete entries in their concrete installation's recorded target
  set. Missing targets fail with installer guidance, without candidate execution, runtime builds,
  downloads, or provider search.
- Local aliases normalize to canonical Lean executables. Unlinked floating selectors require an
  exact project pin or explicit local link; admission performs no remote resolution.
- Each install builds its targets from scratch; Beam keeps no construction cache. Reinstalling a
  changed target set publishes another immutable generation.
- Workspace reuse readmits local selection and compares its retained runtime. A change requires
  dropping and recreating the workspace; an old process cannot adopt a replacement installation
  record. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md).

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
  instead exits abnormally during that drain, Beam preserves the exact draining descriptor for
  explicit recovery. Failed cleanup never changes a draining generation back to live.
  Ordinary lookups take no mutation lock, create no control files, use the frozen workspace
  configuration, and preserve unsafe session state. A competing owner computes its proposed
  configuration but cannot replace a mismatched live owner.
- `lean-beam status` projects internal descriptor observations onto public states: `absent`,
  `running`, `shutdownUnconfirmed`, `recoveryRequired`, and `unresponsive`. `running` means the selected generation
  answered an authenticated workspace probe; it does not establish Lean worker readiness.
  `serve` refuses any existing descriptor without probing its endpoint and directs a matching-root
  descriptor marked `live` to `status` with `setupError`. `unresponsive` means an endpoint
  did not validate as the expected generation, including incomplete or malformed replies; it is not
  proof of producer settlement. Recovery refuses that state and preserves the descriptor.
  Root inference selects the nearest Lean/Lake project. Automated callers should pass
  an explicit canonical `--root`; `stop` and `recover` require one. Successful lifecycle commands
  use one top-level `ok`/`result` envelope; `serve` projects its private backend warm-up onto the
  public running-session result instead of exposing broker workspace or epoch fields. `stop`
  acknowledges a newly committed shutdown request as `stopping` and retains committed state in its
  result when immediate shutdown delivery produces a typed warning. A retained shutdown descriptor
  means completion is unconfirmed: `status` reports `shutdownUnconfirmed`, and repeated stop, serve,
  or attachment returns `sessionShutdownUnconfirmed` with an owning-installation `status` remedy.
  Let cleanup finish and check for `absent` before restarting. This makes no active-cleanup or
  owner-death inference; a separate owning-installation `recovery_command` is conditional on every
  original producer stopping. If cleanup does not finish within the caller's waiting budget, inspect
  the original supervisor rather than inferring settlement from elapsed time.
- Abnormal or ambiguous state is never reclaimed automatically. The descriptor remains as a fence
  after an unexpected broker/owner exit; an unexpected broker exit preserves the live descriptor,
  whose failed connection-establishment probe projects to `recoveryRequired`. After independently
  establishing that the matching owner, daemon, and every other producer have stopped,
  `lean-beam --root ROOT recover --generation ID` quarantines
  that exact descriptor without signalling persisted PIDs. Stop and recovery require the invoking
  executable to belong to the recorded owning installation, even when its plugin, selector, or
  provenance is unusable. Opaque or malformed descriptors cannot establish that ownership and must
  be preserved for operator diagnosis; after independently stopping their original owner, archive
  them explicitly. Recovery additionally requires a root recorded in the descriptor, so a wrong-root caller using
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
- Once the Beam daemon is running, a Lean backend handshake failure is returned with the
  bounded tail of that backend's stderr. This backend diagnostic is separate from the selected
  session directory's daemon startup log, which covers startup of the Beam daemon process itself.
- Typed broker transport, invalid-response, and request-timeout failures include registry/log
  context and, while the selected private session directory still exists, write a JSON incident
  record below it. Incident kinds are `brokerTransportFailure`, `invalidBrokerResponse`, and
  `brokerRequestTimeout`; callback/display failures do not create daemon incidents. Beam keeps the
  latest 50 incident records, and `lean-beam doctor` lists recent incident paths. Incident logging
  never recreates a deleted project or session directory.
- `Ctrl-C` is observed across wrapper connect, generation greeting, request send, and response
  receive. Attached commands watch the first SIGINT; subsequent SIGINTs can terminate a client
  blocked in diagnostic output. Their TERM/HUP dispositions remain inherited, and their completed
  response rendering runs after the watcher closes. Interruption closes or abandons that operation's
  one-request connection without waiting behind a
  blocked write; the daemon's
  connection-owned disconnect watcher cancels the exact admitted request without requiring a
  caller-supplied request ID and is joined when the handler completes. The interrupted client exits
  `130` with a CLI `requestCancelled` JSON response on stdout; this reports client interruption,
  not a broker acknowledgement or producer settlement. `lean-beam cancel ID` remains the explicit
  cross-process cancellation surface. A `cancelled: true` result acknowledges that a matching active
  request was marked for [soft cancellation](#soft-cancellation); it does not confirm request
  completion or backend settlement.
- The foreground owner retains SIGINT and POSIX SIGTERM/SIGHUP handlers from acquisition through
  daemon cleanup, and its initial request borrows that same stop observation. Repeated signals remain
  latched without forcing exit. Lock/readiness waits can defer observation; synchronous output or
  filesystem operations can block, so owner shutdown has no unconditional hard deadline. POSIX
  SIGHUP handling overrides inherited ignore dispositions such as `nohup`.
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
  safely. Previously admitted, uncancelled calls drain first; a cancelled call that has not settled
  does not delay the drop, whose backend shutdown can stop it. Later workspace-bound calls wait for
  eviction to finish and may recreate the same descriptor; `beam_version` and `beam_stats` do not.
- MCP stdio admits at most `--max-unfinished-requests` ordinary requests (default 32), counting
  queued, running, and cancelled-but-unsettled work. `lean_drop_workspace` and process observation
  (`beam_version`, `beam_stats`, `ping`) keep small fixed reserves, so cancelled work that never
  settles cannot block the drop that would stop it; at most `N + 4` requests are admitted at once.
  Requests beyond every applicable pool receive
  `-32024` without executing.
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
  Deferred compilation (`compiler.postponeCompile`, including declaration-scoped settings) also
  rejects zero-build saves; use `lake build` for that pipeline. See
  [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#command-model) for readiness and preservation guarantees.
- Running Lake builds on the workspace while a Beam session has documents open is unsupported.
  As a temporary safeguard ([#370](https://github.com/leanprover/lean-beam/issues/370)), `save` and
  `close-save` refuse with `saveImportsChanged` when they observe that a module the Lean file worker
  loaded may have changed since loading: its Lake trace differs, Beam saved it afterwards, or its
  trace cannot be located unambiguously. Recover with `refresh` and save again. The check is
  conservative but not complete: an external rebuild racing the worker's import load can still go
  unobserved. Stop affected CLI owners and drop any affected MCP workspaces before running Lake,
  confirm cleanup, and start fresh sessions afterward.
- Beam does not reload Lake workspace configuration during a running Lean session. Runtime-selection
  checks can reject a changed `lean-toolchain`; they do not establish that other configuration is
  unchanged. After editing a lakefile, manifest, package override, `lean-toolchain`, Lean options,
  plugins, or dynamic libraries, confirm cleanup of affected owners/workspaces before recreating
  them. Use the [toolchain-change procedure](SETUP.md#changing-the-project-toolchain) when selecting
  a replacement installation; `lean-beam refresh` does not restart the server.
- A Beam checkpoint contains the Lean server's accepted environment. Elaborators can
  distinguish server execution from batch execution, so exceptional custom elaboration can produce
  an artifact that differs from a fresh `lake build` artifact. Successful checkpoints are normally
  sufficient during local development. Batch-build evidence should come from a clean CI `lake build`;
  if no successful clean CI result is available, run the one-time local batch-validation sequence in
  [SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).
- Beam supports non-adversarial development, not independent proof validation or OS isolation.
  Checkpoint readiness can include `sorry` warnings. See
  [trust and proof confirmation](../skills/lean-beam/references/trust-and-validation.md) for the
  ownership assumptions and separate comparator workflow.
- After a dependency edit, report it through `update`/`sync`, checkpoint as needed, and refresh affected
  importers before using their results. Before an external rebuild, stop/drop the owning session
  and wait for cleanup; recreate it afterward. If an external rebuild bypasses this boundary, `sync`
  can still report readiness from stale imports. `save` refuses the stale imports it can observe, but
  a rebuild racing the import load can still publish a checkpoint that incremental `lake build`
  accepts, even when its proof fails kernel replay. Restarting the session or refreshing
  affected importers does not repair checkpoints already published. See
  [external-build recovery](../skills/lean-beam/references/trust-and-validation.md#external-builds-and-retained-state).
- Full file-worker crash recovery ([#339](https://github.com/leanprover/lean-beam/issues/339))
  is deferred beyond 0.2.0. Recovery currently depends on an explicit worker-failure reply; a crash
  need not produce one. After an observed failure, use `sync` to reopen the affected file as described
  in [worker recovery](SYNC_AND_DIAGNOSTICS.md). A request that never receives a failure reply is
  not covered by that recovery path; stop the session and wait for cleanup before starting a new one.
- For open files in Lake workspaces, Beam uses Lean's native stale-dependency diagnostic when a synced
  source change makes an importer need refresh. Beam does not yet implement Lean's dynamic watched-file
  registration, so external source changes that never pass through `sync` remain outside the current
  watcher surface.
- `error.data.stale_direct_deps` recovery hints are still broker-derived metadata. Beam currently
  uses direct imports returned by Beam's diagnostics barrier request from Lean's accepted header
  snapshot and combines those imports with broker sync/save history to infer stale direct
  dependencies and `needs_save`. The planned Lean-side backlog item is to expose structured
  stale-dependency metadata from Lean's watchdog/file-worker
  path, so Beam can derive these hints from Lean instead of duplicating that state in the broker.

### Distribution

Windows support is experimental. Native Windows builds and CI exercise the implementation, but
official elan Windows distribution is deferred until the libuv investigation and required fixes
are complete. Native build or test success alone does not establish readiness for that distribution.

- The agent skill ships in the source checkout. Install it with the checkout installer or
  [copy the complete skill directory manually](SETUP.md#install-the-lean-skill-manually); it is not
  yet published through a registry or marketplace flow.
- Rocq goal inspection and its agent skill are available in the separate, frozen [rocq-beam](https://github.com/ejgallego/rocq-beam) project.

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
- track an upstream Lean API improvement for a pure frontend readiness/reporting helper, close to
  `SnapshotTree.runAndReport` but returning the build-blocking decision and message counts without
  printing
- add richer MCP progress percentages or bounded work-unit totals if Lean exposes them; keep
  structured MCP log messages for incremental diagnostics rather than overloading progress
  notifications or the final tool result
- keep the `sync`, `refresh`, `save`, and `close-save` projections aligned as the canonical
  sync-result schema evolves
- keep Beam-daemon-side conveniences useful without turning them into a large public surface too early
- add a short comparison against Pantograph in the docs, to clarify where `runAt` fits among nearby Lean tooling
- keep cross-surface utility code such as root resolution and workspace-relative path derivation in
  shared Beam modules, not copied across CLI, broker, MCP, and test helpers

### Lean Support Window

The supported window is 4.34–4.36. Lean 4.33 is retired because its module writer can miss
late output errors before Beam copies the generated artifact. The validated 4.34.1 producer
checks stream failure after close. This correctness improvement satisfies the
[minimum-version change rule](COMPATIBILITY.md#change-rule), which requires a benefit beyond
reduced CI time. Raising the minimum to 4.34 removes no existing production compatibility adapter.
Lean 4.34 and 4.35 still require the generated-C descriptor adapter in
`Beam/Broker/LakeSave.lean`. Its selection happens during elaboration, so removing it would not
eliminate per-request dispatch. That cleanup does not justify retiring the supported stable
releases.

The 4.36 default already receives upstream [timer/signal fixes](https://github.com/leanprover/lean4/pull/15523),
[type-class cache restoration fixes](https://github.com/leanprover/lean4/pull/15355), and the
[UTF-8 conversion leak fix](https://github.com/leanprover/lean4/pull/15654) without retiring older
targets. Next opportunities are:

- use [`lake samply`](https://github.com/leanprover/lean4/pull/12545) for native executable profiles
  with demangled Lean names; this developer workflow does not require a higher product minimum
- evaluate [`String.fromUTF8Lossy`](https://github.com/leanprover/lean4/pull/15651) for preserving
  readable subprocess stderr around invalid UTF-8 bytes; direct adoption needs a 4.36 minimum,
  and this diagnostic improvement alone does not justify dropping the stable targets
- preserve the distinct-compiler coverage in `tests/save_olean_project` before reducing support to
  a single release line; custom, nightly, and rebuilt toolchains still need exact fingerprints and
  target-specific Lake helpers

Signal watcher teardown is an independent cleanup: `Signal.stop` already releases its pending
promise on 4.34–4.35, despite their stale API documentation. See the
[compatibility notes](DEVELOPMENT.md#lean-compatibility-shims) and the watcher lifecycle regression
in `tests/test-interrupt-watcher.py`. The process I/O APIs do not provide cancellable synchronous
pipe reads, so bounded stderr draining and process cleanup remain necessary.

## Release Priorities

Release work should stay conservative:

- keep the current `runAt`, `lean-beam`, and MCP surfaces small and documented
- keep CLI and MCP as thin projections over shared typed operation adapters
- keep supported Lean-toolchain and install behavior covered in CI
- take stability fixes when they materially improve release confidence
- defer broader dependency/readiness redesigns until Lean or Lake expose stronger primitives
