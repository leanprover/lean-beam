# Changelog

This project keeps a lightweight, reverse-chronological changelog. Dates use `YYYY-MM-DD`.

## Unreleased

### Added

- Add opt-in re-elaboration profiling to speculative Lean probes on the CLI, LSP, and MCP surfaces.
  Results include request-local wall time and bounded trace spans; spans may overlap or be partial
  when Lean code overrides profiler options ([#258](https://github.com/leanprover/lean-beam/pull/258)).
- `lean-beam-mcp --max-unfinished-requests N` sets the MCP ordinary execution-admission limit
  (default 32, range 1–1024). Invalid values are rejected at startup
  ([#396](https://github.com/leanprover/lean-beam/pull/396), @ejgallego).

### Fixed

- Clarify that installer skill and MCP setup summaries describe only actions performed during
  the current run, so skipped registration does not imply that existing client setup is absent
  ([#394](https://github.com/leanprover/lean-beam/pull/394), @ejgallego).
- `references` now waits for Lean to finish the requested document version, so a query right after
  `update` reports that version's references instead of `[]` or locations from the previous text
  ([#399](https://github.com/leanprover/lean-beam/pull/399), @ejgallego).
- Tactic probes that hit `maxRecDepth` or `maxHeartbeats` now return `success: false` with the
  original proof state and the limit diagnostic, instead of an `internalError` transport failure
  ([#393](https://github.com/leanprover/lean-beam/pull/393), @ejgallego).
- Cancelled MCP calls that never settle can no longer lock out recovery. `lean_drop_workspace`
  and `beam_version`, `beam_stats`, and `ping` fall back to small fixed admission and output
  reserves when the ordinary pool is full, with separate reserves so queued drops cannot starve
  observation. At most `N + 4` requests are admitted at once
  ([#396](https://github.com/leanprover/lean-beam/pull/396), @ejgallego).
- A client-cancelled MCP call no longer blocks `lean_drop_workspace`. Before, if the cancelled
  call never observed cancellation (for example a looping `#eval` probe), the drop never ran and
  every later tool call queued behind it. Now the drop evicts the workspace and its backend
  shutdown stops the abandoned call. `beam_version` and `beam_stats` no longer wait behind a
  workspace drop. Uncancelled earlier calls still finish before the drop runs
  ([#392](https://github.com/leanprover/lean-beam/pull/392), @ejgallego).

## 0.2.0 - 2026-10-27

Beam remains experimental beta software. This release targets Linux and macOS; Windows remains
experimental and is not an official elan-bundled release target.

Before upgrading, stop existing CLI owners and MCP servers and confirm their cleanup. Install the
new runtime with every project target you want to retain, then restart clients. Changing a launcher
does not retarget a running owner. See [setup and recovery](docs/SETUP.md#before-an-upgrade).

### Added

- Run tactics at unfilled `sorry`, `_`, and `?x` terms using their expected type and local context,
  alongside the existing tactic/command basis selection. A speculative success does not validate
  replacement of an entire declaration
  ([#384](https://github.com/leanprover/lean-beam/pull/384)).
- Inspect a whole file with `todo`, or narrow it to a range. Worklist items carry their goals and
  expose `run_at_position` only when that position selects the reported goals. Completed tactic
  steps and filled holes do not produce unfinished-proof items. Code actions still require an
  explicit range ([#377](https://github.com/leanprover/lean-beam/pull/377)).
- Inspect local agent setup with `lean-beam doctor clients` for Codex, Claude Code, Pi, OpenCode,
  and Mistral Vibe. This reads configuration and skill locations without starting clients or
  claiming that registered MCP tools are running
  ([#272](https://github.com/leanprover/lean-beam/pull/272)).
- Support Lean 4.34–4.36, with exact validated SDKs 4.34.1, 4.35.0, and 4.36.0-rc1.
  The repository defaults to 4.36.0-rc1; compatible patch/RC variants qualify locally.
- Qualify dated Lean nightlies with the same native distribution test used by release SDKs,
  retaining compiler identity, test outcome, and native runtime diagnostics in CI
  ([#265](https://github.com/leanprover/lean-beam/pull/265), @ejgallego).
- Build and install `lean-beam` for an explicitly selected native Lean installation, with a
  relocatable bundled runtime, installed provenance, and session invalidation on payload changes.
  The native distribution includes the CLI, MCP server, daemon, and LSP plugin. Project-loading
  Lake helpers retain subprocess ownership through cancellation and cleanup; workspace reuse
  admission does not hold the server-wide runtime lock
  ([#262](https://github.com/leanprover/lean-beam/pull/262), @ejgallego).
- Additive retained-handle MCP tools advertise `destructiveHint = false`, while workspace eviction
  and document close advertise `idempotentHint = true` without being classified as read-only.
- Ten additional observational MCP tools advertise the read-only hint, covering server inspection,
  hover and navigation, symbol and goal queries, and code-action resolution without edit
  application.
- Confidential feedback report cards omit project-derived debug context and caller-supplied
  request, response, and evidence payloads from CLI, MCP, and bundle output
  ([#220](https://github.com/leanprover/lean-beam/pull/220), @ejgallego).
- `lean-beam prune` previews obsolete installed runtimes; `--apply` removes only validated,
  owned entries. Unsupported older manifest schemas require explicit operator retirement.
- Installed runtime identities report whether the running CLI or MCP process still belongs to the
  current runtime selected by the installer and expose invalid installed state without
  misclassifying it as a source checkout.
- Canonical Lean RC and patch toolchains from declared compatible release lines can now build
  exact-fingerprint bundles that pass a local plugin qualification probe before use.
- Mistral Vibe skill installation and MCP registration support through `--vibe`, `--vibe-mcp`,
  `--vibe-home`, and `VIBE_HOME`
  ([#213](https://github.com/leanprover/lean-beam/pull/213), @archiebrowne).

### Changed

- CLI JSON and MCP structured results now share snake_case names for Beam-owned result and
  error-data fields, including `proof_state`, `run_at_position`, `blocking_error_count`, and
  `recovery_plan`. Opaque continuation handles, standard Lean/LSP objects, and evidence payloads
  retain their original field names. Evidence wrappers use snake_case, including `original_data`,
  `observed_response`, and `operation_response`. Error codes and reason values are unchanged
  ([#373](https://github.com/leanprover/lean-beam/pull/373)).
- Retire Lean 4.33 support and raise the supported window to 4.34–4.36. Lean 4.33 can miss
  module-generation write failures before Beam copies the output; the validated minimum 4.34.1
  checks stream failure after close. Compatible release-line admission starts at 4.34; the oldest
  exact validated SDK and multi-toolchain fixtures use 4.34.1. Projects on 4.33 must upgrade or
  use an earlier Beam checkout.
- Document reads and probes reject paths outside the selected workspace with `invalidParams`,
  including parent traversal and escaping symlinks. Normal dependency imports and hover/definition
  navigation from an in-workspace document remain available. Opening an external dependency as a
  document for `run-at`, goals or diagnostics requires selecting a workspace containing that file;
  restarting the same server does not change this boundary. Refresh validates and reads saved source
  before reopening, preserving the tracked document on read failure and respecting newer accepted reads.
- Close-save reserves its accepted document through checkpointing and closure. During preparation,
  competing document operations fail with `contentModified` / `documentClosing`; invalidated delayed
  requests use `documentAdmissionExpired`. Callers coordinate retries after the closing request
  finishes. Private preparation failures preserve a healthy backend and its documents and
  continuation handles. Caller cancellation waits for private serialization or trace preparation
  to finish so acknowledged private files can be removed; true channel loss can still retain them.
  Uncertain artifact-request or final-close delivery can retire the captured owner. The broker
  alone publishes canonical checkpoints after preparation and final document/cancellation checks.
- Shrink the installed `lean-beam` skill from about 32 KB to under 10 KB by stating each workflow
  rule once. Installation, session internals, recovery, and feedback details move to the new
  `references/setup-and-recovery.md` and `references/feedback.md`. MCP tool descriptions drop
  per-tool progress and source-edit boilerplate (about 12k to under 4k characters); the server
  instructions, now also returned by legacy `initialize`, state those rules once. Fast checks
  enforce both budgets.
- Save finalization now checks the exact accepted document before marking or closing it.
  A refused close-save reports `contentModified` with reason `savedDocumentChanged`, the
  committed checkpoint in `error.data.saved`, and `closed: false`; any replacement is left intact.
  Other failures after checkpoint commit preserve their error code and message, but move any
  original error data beneath `error.data.original_data` alongside `saved`. Clients reading those
  original fields must use that nested path for these finalization failures. The original evidence
  retains its field names inside `original_data`
  ([#309](https://github.com/leanprover/lean-beam/pull/309)).
- Remove the standalone installer's persistent construction cache under
  `BEAM_INSTALL_ROOT/state/install-bundles`, which grew by roughly 300 MB per target for every
  source change and had no cleanup command. Each install now builds its targets in a temporary
  directory inside staging; Lake's artifact cache keeps rebuilds of unchanged targets fast. An
  existing `state/` directory is no longer used and can be deleted.
- Document CLI/MCP launch for Beam bundled with Lean alongside checkout installation.
  Clarify complete installer target selections, make installed skill links portable, and correct
  the documented construction-cache and session descriptor schema versions
  ([#266](https://github.com/leanprover/lean-beam/pull/266), @ejgallego).
- Publish standalone installations with complete, qualified target runtimes and a hashed membership
  record. Reinstallation preserves existing generation manifests instead of rewriting their provenance
  ([#262](https://github.com/leanprover/lean-beam/pull/262), @ejgallego).
- Workspace statistics expose `session` and `metrics` directly, and `open-files` exposes
  `session.files`. Remove the former `sessions.lean` and `byBackend.lean` wrappers.
  Stats session details no longer repeat the enclosing workspace identity and root.
- `lean-beam doctor` reports session and recovery diagnostics before inspecting Lean setup.
  An explicit root can be inspected after Lean project markers disappear; setup failures still
  produce a nonzero exit status.
- Clarify zero-based `run-at` coordinates and how tactic positions select before/after proof states,
  with guidance for probing tactic replacements
  ([#253](https://github.com/leanprover/lean-beam/pull/253), @ejgallego).
- Local builds now write to Lake's toolchain-scoped artifact cache and restore cached outputs into
  `.lake/build`, preserving the paths used by Beam's wrapper, installer, and tests. CI restores that
  cache for Lean jobs and lets one job per OS publish each commit's updated cache.
- The pre-stable `lean-beam request-stream` and raw `beam-client` executable have been removed.
  Automated wrapper callers use typed commands, check exit status, and parse final stdout JSON when
  present; selector, setup, or transport failures can report human stderr without JSON. Clients
  that need structured live events and failures use MCP. The wrapper-to-daemon stream remains an
  internal, library-tested transport. The `lean-beam` shell now only locates its matching runtime;
  `beam-cli` directly implements the one public command vocabulary instead of accepting a second
  `lean-*` command language. Ordinary broker calls select an initialized workspace without
  redundantly repeating its root, and the unused `reset-stats` operation has been removed.
  Session descriptor schema 4 no longer records or hashes a client executable or a caller-selected
  port; Beam selects the internal loopback endpoint.
- Wrapper lifecycle commands now use the explicit `serve`, `status`, and `stop` vocabulary;
  `stop` and `recover` require `--root`, alternate selectors use `--session-dir`, and wrapper
  descriptors contain exactly one frozen workspace. Successful lifecycle commands use typed
  `ok`/`result` envelopes, diagnostics preserve the complete session selector, and every wrapper
  observation revalidates the selected directory without following a symbolic-link leaf. Project
  state writers share private-directory preparation, and Lean execution commands require text at
  the typed CLI boundary instead of constructing incomplete broker requests. Missing session paths
  canonicalize their existing ancestor before creation, abnormal daemon exits project to
  `recoveryRequired`, selector mismatches stay separate from lifecycle state, and repeated `stop`
  reports `changed: false`
  ([#243](https://github.com/leanprover/lean-beam/pull/243), @ejgallego).
- Wrapper daemons now have explicit session ownership: only the foreground owner command starts a
  generation, ordinary wrapper commands attach to it, and holder exit
  cancels admitted requests before closing the daemon through an inherited pipe without heartbeat
  leases or time-based retirement
  ([#241](https://github.com/leanprover/lean-beam/pull/241), @ejgallego).
- Long-running Lean operations now separate liveness status, request progress, and diagnostics.
  Sync and refresh use the discoverable `diagnostic_scope: "errors" | "all"` and
  `diagnostics_in_result` controls, while save and close-save use `diagnostic_scope`; the obsolete
  boolean diagnostic arguments and CLI `+full` flag have been removed, with `+all-diagnostics` as
  the explicit wrapper spelling.
- Sync results now report one canonical path/version with `diagnostics.counts`, optional
  `diagnostics.items`, and readiness whose `blocking_error_count` is explicitly distinct from raw
  diagnostic counts. Save and close-save embed that same result. CLI and MCP results can include
  `document_progress`, including on probes, navigation, and handle operations. This metadata can
  contain initial values, reuse earlier progress, or reflect barrier completion; it may be partial
  and does not establish save readiness or operation success.
- Silent Lean editor messages, including decorative `Goals accomplished!` output, are filtered at
  reception and no longer enter Beam diagnostic streams, result counts/items, todo output, or
  speculative execution messages.
- Feedback report-card entry points are now named `lean-beam feedback-report` and MCP
  `beam_feedback_report`; their help and tool descriptions state that Beam returns reports to callers
  and does not upload or submit them
  ([#233](https://github.com/leanprover/lean-beam/pull/233)).
- Broker-backed Lean MCP operations, feedback collection, and delayed `lean_drop_workspace` calls
  without `_meta.progressToken` now emit at most one structured `beam.status` notice when Lake setup
  is observed or the call remains pending for two seconds and the active logging policy admits
  notice-level events. Tokened calls use concise, throttled phase/file updates instead of generic
  start/prepare/run chatter and duplicate terminal progress; queued workspace eviction reports
  before it waits behind earlier requests.
- Broker stream-message decoding now requires the payload selected by its `kind` and rejects
  missing, conflicting, undeclared, or redundant response-correlation fields. The client no longer
  accepts obsolete bare response objects on the streamed endpoint.
- The exact-validation registry and CLI command are now named `validated-lean-toolchains` and
  `validated-toolchains`; `--all-validated` prebuilds that finite exact matrix.
- `lean-beam open-files` reports `disk_status`, `checkpointed`, and document progress under
  `session.files`. A checkpoint marker does not revalidate dependencies; `save` remains the
  authoritative checkpoint-eligibility check.
- Lean MCP tool descriptions now state the source-file invariant: Beam reads saved `.lean` source
  but never applies source edits. Speculative tools do not persist source, save commands write build
  artifacts only, and code-action edits are returned for clients to apply.
- Standalone installation manifests use schema 4; native toolchain bundles use schema 3.
  Installation membership and creation-time provenance are explicit. Older standalone manifests
  and session descriptors may require manual retirement; follow the upgrade and recovery guide.

### Fixed

- Retain explicit worker-exit failures and reopen saved source on a fresh update, sync, save, or
  close-save request under normal admission, without automatically replaying a failed request.
  Idle worker-death detection still depends on the Lean server; see
  [worker errors and document recovery](docs/SYNC_AND_DIAGNOSTICS.md#worker-errors-and-document-recovery).

- Check private ILean, generated-C, and copied module-artifact flushes before successful save
  completion, so buffered write errors cannot publish a successful checkpoint. This does not
  promise power-loss durability ([#381](https://github.com/leanprover/lean-beam/pull/381)).
- Preserve a selected local Elan alias as the target even when its compiler is unavailable.
  A broken alias fails instead of falling through to a different installed release.
- Preserve both helper-operation and cleanup failures, and distinguish acknowledged shutdown
  from confirmed producer cleanup. Owner-loss recovery remains explicit and generation-bound.
- Preserve request outcome details in CLI failure reports. Lost replies explain that the operation
  may have completed; failed live stderr output retains the actual response and checkpoint receipts.
  Failed final JSON writes do not append a replacement reply. Worker failures carry recovery hints
  specific to the helper, backend, or file worker
  ([#361](https://github.com/leanprover/lean-beam/pull/361), @ejgallego).
- Parse tactic `runAt` text and handle continuations as a tactic sequence, as in the body of a
  `by` block. Previously the text was one tactic with no indentation reference, so `simp⏎exact h`
  and `simp; exact h` failed with `expected end of input`, and a line break could not end a
  tactic's arguments: `intro a⏎omega` succeeded by introducing a hypothesis named `omega` without
  running `omega`. A line at the first tactic's column now starts a new tactic; a more indented
  line still continues the previous one.
- Sync and save accept Lean's normalized CRLF document text while preserving saved-byte versions
  and Lake fingerprints. Completed elaboration snapshots remain authoritative when busy progress
  notifications arrive late
  ([#268](https://github.com/leanprover/lean-beam/pull/268), @ejgallego).
- Saves reject deferred compilation before changing artifacts or the Lake trace, including
  declaration-scoped `compiler.postponeCompile`, and report the unsupported readiness reason
  ([#263](https://github.com/leanprover/lean-beam/pull/263), @ejgallego).
- Module saves publish IR signature companions and write the matching Lake
  dependency trace across supported toolchains so a subsequent build reuses the saved artifacts
  ([#263](https://github.com/leanprover/lean-beam/pull/263), @ejgallego).
- Backend handshake and worker-exit failures now include a bounded stderr tail. Feedback report
  cards show the complete source commit and runtime payload. Reusing an installed generation
  preserves its original provenance
  ([#242](https://github.com/leanprover/lean-beam/pull/242), @ejgallego).
- MCP `lean_run_at` and `lean_todo` again advertise the read-only hint used by approval- and
  concurrency-aware clients. Codex MCP registration also enables parallel tool calls so independent
  probes need not be serialized by the client.
- Feedback input now rejects unknown JSON fields so misspelled privacy controls cannot silently
  produce a non-confidential report
  ([#220](https://github.com/leanprover/lean-beam/pull/220), @ejgallego).
- `save` and `close-save` now reuse the accepted server snapshot for structured Lake
  `leanOptions`, dynamic libraries, and plugins. Modules with batch-only `moreLeanArgs` still fail
  with `saveUnsupportedSetup`, now with guidance to use `leanOptions` or `lake build`. Running Lean
  sessions must be restarted after Lake workspace configuration changes before the next operation
  that uses the Lean server.
- Reinstalling an existing content-addressed runtime now validates its owned install marker, typed
  manifest, required artifacts, executable commands, and payload contents instead of silently
  reusing corrupted installed state, and failed validation releases the installer lock.
- Install and prune control-file reads now reject non-regular or symlinked paths, and a failed lock
  owner-PID write removes the lock directory acquired by that process.
- `SIGINT` initiates owned cleanup of `lean-beam serve`; cleanup has no hard latency guarantee.
- `save` and `close-save` prepare complete artifact sets before canonical publication, preserving
  prior canonical outputs when preparation fails or is cancelled and isolating concurrent attempts
  ([#217](https://github.com/leanprover/lean-beam/pull/217), @ejgallego).
- `save` and `close-save` now invalidate prior Lake trace metadata before publishing
  artifacts and replace the new trace atomically, preventing prior metadata from describing newly
  published artifacts after a trace-write failure
  ([#218](https://github.com/leanprover/lean-beam/pull/218), @ejgallego).
- Module-mode `save` and `close-save` now checkpoint the complete Lake artifact family,
  preventing replay from reusing stale `.olean.server`, `.olean.private`, or `.ir` files
  ([#214](https://github.com/leanprover/lean-beam/pull/214), @ejgallego).
- Save-readiness decoding now rejects incomplete response envelopes instead of inferring that a
  document is ready to save
  ([#214](https://github.com/leanprover/lean-beam/pull/214), @ejgallego).

### Removed

- Remove `lean-beam-mcp --self-check`. Verify the configured MCP client with a normal `lean_sync`
  call; installed and native stdio smoke tests run through the external test harness.
- Move Rocq goal probes, agent skill, and `coq-lsp` setup to the independent `rocq-beam` project.
  Lean Beam no longer accepts Rocq broker requests, `serve rocq`, or `--rocq-skill`.
- Remove the redundant backend selector from broker requests and continuation handles. CLI commands
  `serve`, `doctor`, and `validated-toolchains` no longer accept a trailing `lean` argument. Lean goals reject
  the former Rocq-only `text`, `compact`, and `ppFormat` options.
- Require complete Lean configuration in CLI session descriptors and reject undeclared descriptor
  and workspace-binding fields.

### Documentation

- Rework the setup path around installation, matching agent skills, connection checks, and
  confirmed recovery. CLI communication uses local IPv4 loopback TCP; MCP stdio uses child pipes.
  Lean runs with the actual owner/server's OS permissions, not an attaching client's sandbox
  ([#380](https://github.com/leanprover/lean-beam/pull/380)).
- State the non-adversarial development contract and the distinction between speculative
  results, checkpoint readiness, ordinary batch builds, and independent proof confirmation.
  Independent confirmation follows the documented Lean comparator guidance.
- Clarify that zero-build saves are development checkpoints for the inner loop, make clean CI the
  preferred final batch validation, and use one clean local build when no clean CI result is
  available
  ([#216](https://github.com/leanprover/lean-beam/pull/216), @ejgallego).
- Align the status page with the current broker protocol, which requires explicit `ok` / `error`
  response envelopes
  ([#216](https://github.com/leanprover/lean-beam/pull/216), @ejgallego).

## 0.1.0 - 2026-07-07

Initial public release.

### Added

- Isolated `$/lean/runAt` execution with internal proof-first, command-fallback basis selection.
- Minimal typed request and response surface for speculative Lean probes.
- Optional follow-up handles through `$/lean/runWith` and `$/lean/releaseHandle`.
- Version-bound `lean-beam update`, `sync`, `save`, and `close-save` workflows.
- Semantic navigation wrappers for hover, signature help, definitions, references, symbols, goals,
  and todo-style actionable items.
- Local Beam broker/client and `lean-beam` wrapper for saved-file Lean workflows.
- Experimental `lean-beam-mcp` stdio server over the shared Beam operation layer.
- Installed skills for supported agent clients and an optional Rocq goal-probe surface.
- Runtime identity and diagnostic surfaces such as `lean-beam --version`, `beam_version`,
  `open-files`, and broker stats.
- Feedback report cards through `lean-beam feedback` and MCP `beam_feedback`.

### Compatibility And Reliability

- Validated Lean toolchains are listed in
  [`validated-lean-toolchains`](validated-lean-toolchains); the repository-pinned default is
  recorded in [`lean-toolchain`](lean-toolchain).
- Repo-local and CI coverage exercise isolation, stale edits, cancellation, invalid positions,
  handle invalidation, sync/save readiness, MCP protocol behavior, installer behavior, and supported
  Lean toolchain compatibility.

### Documentation

- Human-facing [README](README.md), [setup](docs/SETUP.md), [compatibility](docs/COMPATIBILITY.md),
  [status](docs/STATUS.md), [testing](docs/TESTING.md), [MCP](docs/MCP.md), and
  [skill workflow](skills/lean-beam/SKILL.md) docs for the public alpha surface.
- Conservative release posture: keep the public API small, document known limitations, and defer
  broader dependency/readiness redesigns until Lean or Lake expose stronger primitives.
