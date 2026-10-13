---
name: lean-beam
description: Use this when an AI should work on an external Lean project through the installed `lean-beam` wrapper, giving it direct efficient access to Lean's proof engine to avoid repeated inner-loop rebuilds through cheap speculative checks and zero-build module checkpoints.
---

# Lean Beam

Use this skill for Lean projects when you want the AI to replace repeated inner-loop `lake build`
runs with cheap speculative Lean probes, optional follow-up handle execution, and targeted file
checkpoints. A successful checkpoint is normally enough for local development. CI should run a
clean `lake build`; do not force an expensive clean local rebuild after every checkpoint. Before
calling work batch-validated, require a successful clean CI build, or run one clean local build when
no such CI result is available or server-sensitive elaboration is suspected.

This is the Lean-only skill. It should stay focused on Lean and should not require Rocq setup or Rocq concepts.
Do not factor shared Lean/Rocq skill instructions into a common helper; duplicate short guidance if
both skills need it.

## Setup

From the `lean-beam` repo root:

```bash
./scripts/install-beam.sh --codex
```

Use `--claude`, `--pi`, `--opencode`, or `--vibe` instead when installing for Claude Code,
Pi Agent, OpenCode, or Mistral Vibe. Use `--all-skills` when you want every supported agent skill
target.

The installer puts `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` in `~/.local/bin`, stages
the self-contained runtime under `BEAM_INSTALL_ROOT` (default `~/.local/share/beam`), requires
`elan` on `PATH`, prebuilds the pinned `lean-toolchain` bundle by default, and installs the bundled
Lean skill only for the agent flags you request. Use the setup docs for additional supported or
custom toolchain prebuilds.

Use `lean-beam --version` for CLI bug reports and installed runtime identity checks. Use
`lean-beam-mcp --version` to verify which installed MCP server wrapper, server binary, runtime
payload hash, manifest, and source commit a client command resolves. Source checkout runs also
report git commit/branch/dirty state when available. From a live MCP session, call `beam_version`
to report the running server process identity as structured content. Installed identities include
`runtime_current`; if a live session reports `false` after reinstalling, restart the agent or MCP
client so it launches the current runtime. If a newly resolved installed wrapper still reports
`false`, the install root's `current` link is missing or broken; stop normal Beam work and reinstall.
If an installed identity reports `runtime_error`, do not treat it as a source checkout or try to
clean it with `lean-beam prune`. After stopping active Beam agents and MCP clients, move an invalid
manifest runtime out of `BEAM_INSTALL_ROOT/snapshots`, preserve it for inspection, and rerun the
installer. For an invalid install-root marker, preserve and rename the exact `BEAM_INSTALL_ROOT` as
a unit before reinstalling; do not recreate its ownership marker in place or delete the preserved
state.

MCP workspace-bound tools carry an explicit local workspace descriptor on every call. Dropping that
workspace only evicts its cached runtime and retained handles; it does not prove the MCP server
binary itself was refreshed. Retain the canonical descriptor when a Lean operation,
non-confidential feedback result, or drop result echoes it so a cached runtime can still be dropped
if the project path or its Lean/Lake markers become unavailable.

Restart active agent or MCP client sessions after installation.

For the authoritative install and bundle-resolution order, see the repo
[docs/SETUP.md](../../docs/SETUP.md) and [Validated And Compatible Toolchains](../../docs/SETUP.md#validated-and-compatible-toolchains)
sections.

## Skill Surface

This skill documents the current Lean-facing `lean-beam` workflow surface. Use the smallest command
family that fits the task.

Agents may access Beam through the `lean-beam` wrapper or through a registered `lean-beam-mcp`
server. This skill names wrapper commands because they are always available after installation. When
your client exposes the matching MCP tools, use them with the same saved-file, snapshot, update, sync,
and isolation rules; do not treat MCP as a raw Lean LSP proxy.

Supported command families:

- start and own a wrapper session: `lean-beam serve`
- inspect the selected session state: `lean-beam status`
- inspect existing code, navigation data, or proof state: `lean-beam hover`,
  `lean-beam signature-help`, `lean-beam definition`, `lean-beam references`,
  `lean-beam document-symbols`, `lean-beam workspace-symbols`, `lean-beam goals before`,
  `lean-beam goals after`
- inspect actionable Lean items in a range: `lean-beam todo`
- inspect file or daemon state: `lean-beam open-files`, `lean-beam doctor`, `lean-beam stats`
- produce a local, pasteable bug report card from JSON input: `lean-beam feedback-report`
- try one isolated speculative Lean snippet: `lean-beam run-at`
- continue from one exact speculative state: `lean-beam run-at-handle`, `lean-beam run-with`,
  `lean-beam run-with-linear`, `lean-beam release`
- refresh or checkpoint one tracked workspace module: `lean-beam sync`, `lean-beam refresh`,
  `lean-beam save`, `lean-beam close-save`
- run shell-oriented search loops over the same handle APIs: `lean-beam-search`

What to treat as the normal agent workflow surface:

- default workflow commands: `lean-beam hover`, `lean-beam signature-help`,
  `lean-beam definition`, `lean-beam references`, `lean-beam document-symbols`,
  `lean-beam workspace-symbols`, `lean-beam goals`, `lean-beam todo`, `lean-beam run-at`,
  `lean-beam sync`,
  `lean-beam refresh`
- operational commands: `lean-beam open-files`, `lean-beam doctor`, `lean-beam stats`,
  `lean-beam feedback-report`, `lean-beam save`,
  `lean-beam close-save`
- pre-stable support APIs: `lean-beam run-at-handle`, `lean-beam run-with`, `lean-beam run-with-linear`,
  `lean-beam release`, `lean-beam-search`

Core workflow contract:

- use `lean-beam`, not raw JSON and not raw LSP
- Beam never applies source edits to `.lean` files on disk; the client applies source edits
- `lean-beam` only sees the on-disk file, not unsaved editor buffers
- before using wrapper workflow commands, start one foreground `lean-beam serve` process
  and keep it running across shell invocations; interrupt it or run
  `lean-beam --root ROOT stop` when finished
- MCP owns its stdio runtime session automatically; do not start a separate wrapper holder solely
  for MCP tool calls
- after every real Lean source edit: save the file normally, then run `lean-beam update` before the
  next snapshot-bound probe; run `lean-beam sync` when you need diagnostics/readiness
- use `lean-beam save` only for a synced workspace module path in the current Lake workspace package
  graph, for example `MyPkg/Sub/Module.lean`
- `lean-beam save` checks readiness and checkpoints only the module snapshot you save; it does not
  validate importers of that module
- `lean-beam save` writes the accepted Lean server environment, including structured Lake options,
  dynamic libraries, and plugins already applied by the file worker; an elaborator can behave
  differently in server and batch mode, so treat the result as a development checkpoint rather than
  final build evidence
- modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared `-D` settings
  to `leanOptions`, or use `lake build` when the arguments are intentionally batch-only
- after changing a lakefile or related Lake workspace configuration, run `lean-beam --root ROOT stop`
  before the next command that uses the Lean server; `lean-beam refresh` does not restart it
- check wrapper exit status before parsing output; completed broker operations use final stdout JSON,
  while selector, setup, or transport failures may have human-facing stderr and no JSON
- use MCP when a client requires structured live progress or diagnostic notifications
- `lean-beam feedback-report` and `beam_feedback_report` return a report to the caller; Beam does not
  upload or submit it; before posting non-confidential output, review caller-authored narrative,
  request/response payloads, local paths, Beam stats, open-file data, daemon logs/incidents, and
  bundle evidence
- `lean-beam feedback-report` does not accept free-form notes; pass a JSON object with required string
  fields `title`, `summary`, `reproduction`, `expected`, and `actual`
- use optional feedback triage fields `kind` (`bug`, `ux`, `perf`, `docs`, `question`) and
  `severity` (`low`, `medium`, `high`, `critical`) when they help route the report
- set feedback `confidential` to `true` for a non-public workspace; this forces HOME-path redaction
  and omits automatically collected project debug context, request/response payloads, evidence, and
  the echoed MCP workspace descriptor; requested bundles still return operational paths locally
- confidential feedback retains other caller-authored narrative without scanning it for arbitrary
  secrets; review those fields before sharing through an authorized private channel, and never post
  the report publicly
- do not assume hidden mutable session state carries across unrelated requests

## Agent Cost Model

Prefer Beam probes over detached scratch Lean files for project-local questions.

A standalone scratch file has a high fixed cost: it starts from a detached module, reloads imports
and environment, and encourages simplified contexts that may not match the real source position.

A `lean-beam run-at` probe has low marginal cost once the per-project daemon and module context are
warm: it asks one speculative question against an explicit broker document snapshot and the real
module environment.

This changes the right agent behavior:

- prefer many small `run-at` probes at the source position over one large scratch experiment
- use `goals before`, `goals after`, `hover`, `signature-help`, `definition`, `references`, and
  symbol queries instead of reconstructing semantic state elsewhere
- issue independent `run-at` probes or handle-rooted search sequences in parallel when you have many
  candidates to check; use distinct request IDs if you need per-request cancellation or tracing
- do not batch unrelated questions just to amortize Lean startup; future batch APIs may reduce
  per-call overhead, but high-bandwidth clients can already get most of the throughput benefit by
  keeping independent probe sequences in flight
- after a real source edit, run `lean-beam update <file>` before later probes; run
  `lean-beam sync <file>` when you need diagnostics/readiness
- use `lake build` for dependency-cone validation and in clean CI; use a local
  `lean-beam --root ROOT stop` / `lake clean` / `lake build` sequence once when no successful
  clean CI result is available or server-sensitive elaboration is suspected
- use scratch files only for context-free Lean syntax checks or Beam incident isolation

## Prompting Contract

Prefer the smallest command that matches the actual task:

- use `lean-beam hover` when you want semantic information about existing code at one position
- use `lean-beam signature-help` when you want callable-argument signature information at one
  position
- use `lean-beam definition` or `lean-beam references` when you want navigation targets for an
  existing symbol
- use `lean-beam document-symbols` for file-local symbol outlines and `lean-beam workspace-symbols`
  for workspace-wide symbol search
- use `lean-beam goals before` or `lean-beam goals after` when you want existing proof state at one
  tactic position
- use `lean-beam todo` when you want actionable items in a saved file range, such as sorries, holes,
  diagnostics, code actions, or incomplete proofs
- use `lean-beam run-at` when you want to try one speculative Lean snippet without editing the file
- for a tactic replacement, probe at its first character after indentation to use its before-state;
  positions inside a simple tactic can use its after-state
- before `lean-beam run-at`, `lean-beam run-at-handle`, `lean-beam hover`,
  `lean-beam signature-help`, `lean-beam definition`, `lean-beam references`,
  `lean-beam document-symbols`, `lean-beam goals`, or `lean-beam todo`, call
  `lean-beam update <file>` and pass the returned `snapshot`; `lean-beam workspace-symbols` takes
  only a query
- if a request fails with `contentModified`, read the current source and resolve the intended
  position, range, or code action again, then obtain a fresh `snapshot` from `lean-beam update`
  or `lean-beam sync` before retrying; changing only the token does not repair stale coordinates
- for `lean-beam run-at`, `lean-beam hover`, `lean-beam signature-help`,
  `lean-beam definition`, `lean-beam references`, `lean-beam goals`, and `lean-beam todo`, treat
  line and character arguments as Lean/LSP coordinates: line `0` is the first line, character `0`
  is the first UTF-16 code unit, and on a truly empty line only character `0` is valid
- use `lean-beam run-at-handle` and then `lean-beam run-with` or `lean-beam run-with-linear` only when exact
  speculative continuation matters
- for multiline speculative text, prefer `--stdin` as the normal path; use `--text-file <path>`
  when the text already lives in a file
- for handle-based continuation, prefer `--handle-file <path>` as the normal path; deeper shell-loop
  variants such as stdin handle piping live in the reference docs
- do not expect one `lean-beam run-at` call to become the basis of the next one automatically
- parallel probes are fine when they are independent; do not concurrently reuse a linear handle or
  assume ordered side effects between separate speculative sequences
- use `lean-beam update` right after every real saved edit before the next speculative probe
- use `lean-beam sync` when you need diagnostics/readiness before saving or checkpointing
- use `lean-beam save` or `lean-beam close-save` only for a synced workspace module path such as
  `MyPkg/Sub/Module.lean`

Stop probing and change tactics when:

- the speculative result now needs to become real source: edit the file, save it, then `lean-beam sync`
- repeated `lean-beam run-at` probes are no longer clarifying the problem
- you edited a dependency and now need trustworthy downstream results; `lean-beam save` only
  checkpoints the module you save, not downstream importers
- stale-state, `contentModified`, or rebuild trouble keeps appearing; inspect with `lean-beam open-files`
  and `lean-beam doctor`
- no successful clean CI result is available, or the task may depend on
  server-sensitive elaboration; stop Beam and perform the clean batch build once
- if `lean-beam sync` fails with `syncBarrierIncomplete`: inspect `error.data.staleDirectDeps`,
  `error.data.saveDeps`, and `error.data.recoveryPlan`; save only the listed direct deps that still
  need checkpointing, then `lean-beam refresh "Target.lean"` if the plan says to;
  if this repeats across multiple dependency hops, escalate to `lake build`

When those conditions hold, prefer a real edit plus `lean-beam sync`, or escalate to `lake build`
when the task has become dependency freshness across importers or explicitly requires the optional
batch-equivalence check rather than one-file probing.

## Lean-Run-At Semantics

`lean-beam run-at` is a speculative execution request against one explicit broker document snapshot.
Read it as "try this Lean text here", not as "edit the file here".

What `lean-beam run-at` does not do:

- it does not edit the source file or create a new on-disk baseline for the next request
- it does not make the speculative text become the basis of the next `lean-beam run-at` call
- it does not wait for or return the full diagnostics barrier for the rest of the file
- it does not replay full-file diagnostics in its final JSON payload
- it does not auto-indent or synthesize leading spaces when you probe at an indented empty line
- it does not reinterpret blank-line coordinates; if the line is truly empty then character `1` is
  already out of range
- in command mode, one `run-at` request accepts one Lean command, not a complete top-level command
  sequence; use `run-at-handle` plus `run-with` for explicit sequencing, or make a real edit and
  `sync`

Use the right tool for each goal:

- if you made a real edit and want fresh file diagnostics: save the file, then use `lean-beam sync`
- if you want exact continuation from speculative state: mint a handle with `lean-beam run-at-handle`,
  then continue with `lean-beam run-with` or `lean-beam run-with-linear`
- if you want to test several top-level commands together: write them to the file and sync, or split
  the experiment into explicit handle continuations
- for handle-based commands, `--handle-file <path>` is the easiest way to avoid inlining handle json
- if surface syntax depends on indentation or layout: pass the exact text you want Lean to parse, or
  make a real edit in the file instead of expecting the wrapper to fill whitespace for you

Open [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md) when the task needs
concrete examples for:

- full-file diagnostics after a speculative probe
- chaining speculative state across multiple calls
- indentation-sensitive or newline-sensitive probes on blank or layout-sensitive lines

Open [references/workflow-details.md](references/workflow-details.md) for position semantics,
text/handle input variants, and wrapper debugging.

Open [references/commit-speculative.md](references/commit-speculative.md) when the task needs the
current workflow for turning a good speculative probe into a real saved edit.

Open [references/anti-patterns.md](references/anti-patterns.md) when you want a short checklist of
what Lean agents should not assume about `lean-beam run-at`, `lean-beam sync`, handles, or dependency edits.

## Lean Wrapper

Use `lean-beam`, not raw JSON and not raw LSP.

`lean-beam` for Lean:

- infers the target project root from the current directory or `--root`
- keeps one owner per resolved workspace and session-directory selector; the default descriptor is
  `<root>/.beam/beam-daemon.json`
  - in sandboxed or read-only project trees, set `BEAM_SESSION_ROOT` to a writable directory;
    `lean-beam` uses a per-root subdirectory there
  - for an exact stable alternate session location, pass the same absolute path with
    `--session-dir DIR` to the owner and every attaching command; Beam does not search alternate
    session directories
- resolves a toolchain-keyed Lean bundle, preferring the installed beam bundle cache and
  falling back to a project-local runtime bundle under `<root>/.beam/bundles` or `BEAM_BUNDLE_DIR`
- fully validates exact Lean toolchains listed in `validated-lean-toolchains`, locally qualifies
  canonical RC/patch variants from `compatible-lean-release-lines`, and accepts exact custom names
  recorded by the installer in `custom-lean-toolchains`
- gives daemon startup authority only to `lean-beam serve`; ordinary wrapper commands attach
  to its registry generation and never start a daemon implicitly
- owns stopping and descriptor handling
- resolves Lean with `elan which lean`
- builds and plugin-qualifies a local fallback bundle only when no matching installed bundle exists
  for the exact accepted toolchain fingerprint
- fails early on toolchains that are neither validated, canonical members of a compatible release
  line, nor explicitly custom; use `lean-beam validated-toolchains`,
  `lean-beam compatible-release-lines`, and `lean-beam doctor` to inspect the decision
- after effective Lean startup configuration changes, requires shutting down the old session and
  starting a new `lean-beam serve` owner
- after abnormal owner/broker exit, preserves the session fence until explicit
  `recover --generation ID`; recovery quarantines metadata and never signals its persisted PIDs
- `lean-beam --root ROOT stop` requires an explicit root; `lean-beam status` and `lean-beam stats`
  may infer a unique root
- `lean-beam prune` previews old installed runtimes; restart active agents and MCP clients before
  any `--apply`, and add `--bundles` when stale installed bundle caches should also be removed
- wrapper commands talk to the per-project Beam daemon over localhost TCP; they are not direct in-process Lean calls
- `lean-beam serve` prints a running-session JSON response after backend readiness and keeps the wrapper
  process alive as the session owner; an inherited pipe ties daemon lifetime to that process without
  heartbeat files or lease expiry
- the OS assigns the internal loopback endpoint and the daemon reports it through a private typed
  readiness handshake; callers select sessions by root and optional session directory rather than
  by transport details
- interrupting an ordinary wrapper call closes its one-request connection so the daemon cancels
  that exact admission; `lean-beam cancel <id>` remains available for cross-process cancellation
- interrupting the holder or using `lean-beam --root ROOT stop` performs bounded owner cleanup;
  killing the holder closes the owner pipe and requests cooperative daemon shutdown, while the
  session fence remains for explicit recovery

`lean-beam` is more than a one-shot probe:

- the common path is still a single isolated `lean-beam run-at` request, which wraps the standalone Lean
  method `$/lean/runAt`
- the underlying Lean side can also retain follow-up state through opaque handles for continuation
  and branching when one-shot probing is not enough, through follow-up methods
  `$/lean/runWith` and `$/lean/releaseHandle`
- treat handles as pre-stable support APIs: useful, real, and powerful, but more fragile than the base
  request
- handles are document-bound and are invalidated by same-document edits, close, worker restart, or
  Beam daemon restart
- do not present handles as the main story unless the task actually needs continuation from the
  exact speculative state

Default rules:

- use `lean-beam`, not raw JSON and not raw LSP
- start and keep one `lean-beam serve` owner before issuing wrapper workflow commands
- start with `lean-beam run-at`
- after every real source edit: save the file to disk normally, then `lean-beam update` before the
  next snapshot-bound probe; use `lean-beam sync` for diagnostics/readiness
- if exact continuation matters: mint a handle
- if search branches: use `lean-beam run-with`, `lean-beam run-with-linear`, and `lean-beam release`
- if you want shorter shell commands for search loops: use `lean-beam-search`
- if bundle resolution or startup looks wrong: check `lean-beam doctor` before guessing

## Fast Path

If you only remember one workflow, use this one:

```bash
# terminal or long-lived agent process 1: keep this running
lean-beam serve

# terminal or agent process 2: inspect existing code or proof state
update_out="$(lean-beam update "Foo.lean")"
printf '%s\n' "$update_out"
snapshot="$(printf '%s\n' "$update_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
lean-beam hover "Foo.lean" "$snapshot" 10 2
lean-beam signature-help "Foo.lean" "$snapshot" 10 2
lean-beam definition "Foo.lean" "$snapshot" 10 2
lean-beam references "Foo.lean" "$snapshot" 10 2
lean-beam document-symbols "Foo.lean" "$snapshot"
lean-beam workspace-symbols "Foo.bar"
lean-beam goals before "Foo.lean" "$snapshot" 10 2

# try speculative Lean text without editing the file
lean-beam run-at "Foo.lean" "$snapshot" 10 2 "exact trivial"
# for multiline probes, prefer stdin
printf 'example : True := by\n  trivial\n' | lean-beam run-at "Foo.lean" "$snapshot" 10 2 --stdin

# after every real edit saved to disk, use update for the next probe snapshot
lean-beam update "MyPkg/Sub/Module.lean"

# when you need diagnostics/readiness, on that same workspace module path
lean-beam sync "MyPkg/Sub/Module.lean"
lean-beam refresh "MyPkg/Sub/Module.lean"

# only for a synced workspace module path, after a successful sync
lean-beam save "MyPkg/Sub/Module.lean"

```

CI should run `lake build` from a clean checkout or clean Lake build directory. If no successful
clean CI result is available, or server-sensitive elaboration is suspected, run this sequence once
outside the inner loop:

```bash
lean-beam --root ROOT stop
lake clean
lake build
```

Read the save path as a progression, not as three unrelated commands:

- `lean-beam sync` establishes the synced, diagnostics-complete snapshot for the current on-disk file
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`; use it when a tracked file needs a fresh basis after upstream changes
- `lean-beam save` is `lean-beam sync` plus a zero-build checkpoint for that synced workspace module
- `lean-beam save` checks and checkpoints only that module snapshot; it does not validate downstream
  importers
- `lean-beam save` supports structured Lake options, dynamic libraries, and plugins already applied
  by the Lean file worker
- modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared `-D` settings
  to `leanOptions`, or use `lake build` when the arguments are intentionally batch-only
- after changing a lakefile or related Lake workspace configuration, run
  `lean-beam --root ROOT stop`
  before the next command that uses the Lean server; `lean-beam refresh` is not sufficient
- `lean-beam close-save` is `lean-beam save` plus closing the tracked file afterward
- a Beam save checkpoints the accepted Lean server environment; it does not rerun batch elaboration
- the one-time `stop` / `lake clean` / `lake build` sequence discards development checkpoints
  and supplies final batch evidence when no successful clean CI result is available; routine local
  Beam work does not require it after every checkpoint

Diagnostic defaults on that path:

- `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, and `lean-beam close-save` always stream fresh diagnostics for the current request
- by default they stream only errors
- add `+all-diagnostics` to widen the current request to warnings, info, and hints
- the final JSON reports the current synced-state verdict rather than replaying streamed
  diagnostics
- use `result.readiness.saveReady` for sync/refresh decisions,
  `result.sync.readiness.saveReady` for save, and `result.saved.sync.readiness.saveReady` for
  close-save; use the corresponding `blockingErrorCount` and blocking evidence to explain blocked
  verdicts
- when `lean-beam sync` fails with `syncBarrierIncomplete`, the JSON error may include
  `error.data.staleDirectDeps`, `error.data.saveDeps`, `error.data.recoveryPlan`, and
  `error.data.completionBlockingDiagnostics`
- `lean-beam save` returns the sync verdict it established before checkpointing in `result.sync`;
  `lean-beam close-save` returns it in `result.saved.sync`
- when `lean-beam save` or `lean-beam close-save` fails with `invalidParams` because the document still has
  errors, `error.message` includes a compact preview of underlying diagnostics and/or command
  messages, and `error.data.sync` contains the blocking sync verdict
- readiness semantics and field-level progress/diagnostic/readiness details live in
  [../../docs/SYNC_AND_DIAGNOSTICS.md](../../docs/SYNC_AND_DIAGNOSTICS.md)

Surface rule:

- wrapper `stderr` is the human-facing diagnostic surface
- wrapper `stderr` may distinguish request-level failures from a completed request whose payload
  failed inside Lean; check exit status first, then use stdout JSON when the broker completed
- do not parse wrapper `stderr` in tooling
- MCP clients can attach `tools/call` `_meta.progressToken` for detailed live updates; without one,
  Beam keeps fast broker-backed Lean operations, feedback collection, and workspace drops quiet and
  emits at most one `beam.status` notice when Lake setup is detected or the call remains pending for
  two seconds, provided the request's logging policy admits notice-level events
- MCP `diagnostic_scope: "all"` widens diagnostic severity and `diagnostics_in_result: true` replays
  selected diagnostics in the final sync or refresh result; neither setting controls progress, and
  requested replay may intentionally duplicate matching diagnostics already consumed live
- the operation-by-operation MCP display matrix, including log-level interactions and tools without
  an automatic no-token status, lives in [../../docs/MCP.md](../../docs/MCP.md#display-control-matrix)

## Quick Picks

Use this when you are deciding between commands:

- human checking existing code: `lean-beam hover`
- human checking callable arguments: `lean-beam signature-help`
- human following code navigation: `lean-beam definition` / `lean-beam references`
- human listing symbols: `lean-beam document-symbols` / `lean-beam workspace-symbols`
- human checking existing proof state: `lean-beam goals before` / `lean-beam goals after`
- human trying speculative Lean text: `lean-beam run-at`
- human after a real saved edit: `lean-beam sync`
- human checkpointing one synced module: `lean-beam save` or `lean-beam close-save`
- human diagnosing daemon or save-state trouble: `lean-beam open-files` and `lean-beam doctor`
- tooling that wants structured live diagnostics or progress: use the MCP server

## References

Open these only when the task needs the detail:

- [references/lean-run-at-semantics.md](references/lean-run-at-semantics.md):
  common `lean-beam run-at` confusion cases, chaining, indentation-sensitive and newline-sensitive probes
- [references/commit-speculative.md](references/commit-speculative.md):
  how to turn a good speculative probe into a real saved edit today
- [references/anti-patterns.md](references/anti-patterns.md):
  short “do not assume this” checklist for common agent mistakes
- [references/mcts-search.md](references/mcts-search.md):
  handle-based branching, linear playouts, release patterns
- [references/workflow-details.md](references/workflow-details.md):
  position semantics, save eligibility, file-progress interpretation, stats, dependency and rebuild rules

## Policy

- prefer `lean-beam run-at` before editing when feasible
- treat `lean-beam update` as mandatory after every real Lean file edit before the next speculative probe
- do not assume one successful probe changes the basis of the next one; each probe starts from the explicit document snapshot it names
- when continuation really matters, prefer an explicit stored handle over hoping the next probe will
  recover the same internal basis by accident
- prefer `lean-beam save` / `lean-beam close-save` over a full `lake build` when only one file needs checkpointing
- treat `lean-beam save` as a single-module checkpoint, not as dependency-cone validation
- use `lake build` for initial failure discovery, coarse dependency checkpoints, and clean CI; after
  Beam saves, use `lean-beam --root ROOT stop`, `lake clean`, and `lake build` locally once only when no
  successful clean CI result is available or server-sensitive elaboration is suspected
- if you edit a dependency of the target file, `lean-beam save` is not enough for downstream trust;
  rebuild before trusting importers
- if daemon/save-state behavior looks wrong, inspect `lean-beam open-files` and `lean-beam doctor`
  before assuming the wrapper is confused
- if a file is open in the Beam daemon, do not edit it out of band without following with `lean-beam sync` or a close/reopen workflow
- if Lean reports stale state, `contentModified`, or rebuild trouble unexpectedly, stop and report it explicitly
