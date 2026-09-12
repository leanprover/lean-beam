# Changelog

This project keeps a lightweight, reverse-chronological changelog. Dates use `YYYY-MM-DD`.

## Unreleased

0.2.0 beta development is open. Add user-facing changes here as they land.

### Added

- Additive retained-handle MCP tools advertise `destructiveHint = false`, while workspace eviction
  and document close advertise `idempotentHint = true` without being classified as read-only.
- Ten additional observational MCP tools advertise the read-only hint, covering server inspection,
  hover and navigation, symbol and goal queries, and code-action resolution without edit
  application.
- Confidential feedback report cards omit project-derived debug context and caller-supplied
  request, response, and evidence payloads from CLI, MCP, and bundle output
  ([#220](https://github.com/leanprover/lean-beam/pull/220), @ejgallego).
- `lean-beam prune` previews obsolete installed runtime snapshots; `--apply` removes them, and
  `--bundles` also selects stale or incomplete installed bundle-cache entries.
- Installed runtime identities report whether the running CLI or MCP process still belongs to the
  current runtime selected by the installer and expose invalid installed state without
  misclassifying it as a source checkout.
- Canonical Lean RC and patch toolchains from declared compatible release lines can now build
  exact-fingerprint bundles that pass a local plugin qualification probe before use.
- Validated Lean `v4.34.0-rc1` support.
- Validated Lean `v4.33.0` support and made it the repository's default Lean toolchain.
- Validated Lean `v4.32.0` support and made it the repository's default Lean toolchain
  ([#219](https://github.com/leanprover/lean-beam/pull/219), @ejgallego).
- Mistral Vibe skill installation and MCP registration support through `--vibe`, `--vibe-mcp`,
  `--vibe-home`, and `VIBE_HOME`
  ([#213](https://github.com/leanprover/lean-beam/pull/213), @archiebrowne).

### Changed

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
  `diagnostics.items`, and readiness whose `blockingErrorCount` is explicitly distinct from raw
  diagnostic counts. Save and close-save embed that same result. MCP exposes snake_case equivalents
  and reserves final `document_progress` for sync/refresh/save/close-save rather than attaching file
  progress to unrelated results such as `lean_run_at`.
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
- `lean-beam open-files` now reports tracked-document state through `diskStatus`, `checkpointed`, and
  `fileProgress`. It no longer emits redundant `saved`, obsolete `savedOlean`, or the partial
  `saveEligible`, `saveReason`, `saveModule`, and `saveDetail` preflight fields; `lean-beam save`
  remains the authoritative save eligibility check.
- Lean MCP tool descriptions now state the source-file invariant: Beam reads saved `.lean` source
  but never applies source edits. Speculative tools do not persist source, save commands write build
  artifacts only, and code-action edits are returned for clients to apply.
- Install manifest schema 3 names immutable creation-time toolchain provenance explicitly and lists
  only required staged artifacts; schema-2 runtimes remain readable for identity and safe cleanup but
  are not reused by reinstall.

### Documentation

- Added a descriptive related-tools comparison for `lean-lsp-mcp`, Pantograph, and Beam's
  saved-file probe layer.

### Fixed

- Backend handshake and worker-exit failures now include a bounded stderr tail. Feedback report
  cards show the complete source commit and runtime payload, and reusing an installed runtime
  refreshes its source commit so reports identify the checkout that performed the install
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
- Bundle readiness and installed-cache pruning now require regular, non-symlinked runtime artifacts
  instead of accepting any existing filesystem entry at an artifact path.
- Install and prune control-file reads now reject non-regular or symlinked paths, and a failed lock
  owner-PID write removes the lock directory acquired by that process.
- `lean-beam serve` now exits cleanly and promptly after `SIGINT`.
- `save` and `close-save` now stage and commit complete artifact sets, preserving prior
  outputs on reported failure or cancellation and preventing same-worker saves from mixing files
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
- `lean-beam-mcp --self-check` now waits long enough for valid first-use local bundle builds and
  documents the `LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS` override
  ([#208](https://github.com/leanprover/lean-beam/pull/208), @ejgallego).

### Documentation

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
