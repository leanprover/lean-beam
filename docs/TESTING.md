# Testing

This is contributor and maintainer documentation. Normal Lean Beam users should not need to read
this document to install or use the CLI.

CI is the validation record for routine checks. PR descriptions should mention tests only for rare
local validation that CI cannot represent; see [CONTRIBUTING.md](../CONTRIBUTING.md#pull-requests).

The repository treats testing as three distinct surfaces:

- `LSP`: every method registered by the Lean plugin in [Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean)
- `Beam`: broker, daemon/client protocol, CLI wrapper, install/runtime packaging, MCP, toolchain support
- `Maintainer`: local workflow helpers and defensive validation wrappers that are not part of the product surface

This split is organizational. It is also the supported top-level test layout.

Importable Lean test code lives under [tests/lean/BeamTest](../tests/lean/BeamTest) and is exposed
to Lake as the `BeamTest` library. The rest of [tests](../tests) contains shell and Python
entrypoints, scenario scripts, interactive golden inputs, fixture projects, and shared test helper
scripts.

When a test copies `tests/save_olean_project`, it excludes the fixture's untracked `.beam`
directory. That directory may contain large machine-local runtime bundles from an earlier run; it
is cache state, not fixture input, and copying it can hide cold-start behavior or exhaust disk
space.

For public CLI failure behavior, pair a cheap typed or parser-level test with the focused wrapper
test that exercises the real command line. Run that focused entrypoint after the final error
assertion is written; a pass obtained before the assertion or through a neighboring suite does not
validate the public wording or exit path.

The LSP surface also has a lightweight coverage registry under
[tests/lsp-coverage](../tests/lsp-coverage). The registry ties every method registered by
[Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean) to concrete test pointers and required coverage
tags such as isolation, stale-edit, cancellation, handle lifecycle, and mixed concurrency.
Method-isolated Lean request tests live under
[tests/lean/BeamTest/LSP/Requests](../tests/lean/BeamTest/LSP/Requests), with
[tests/lean/BeamTest/LSP/RequestSurfaceTest.lean](../tests/lean/BeamTest/LSP/RequestSurfaceTest.lean)
remaining as the aggregate request-surface runner.

## Race-Test Discipline

Race and concurrency regressions should wait for observable state, not for guessed wall-clock
delays. Prefer request IDs plus cancellation acknowledgements, wrapper progress text, registry
files, non-empty response files, and Lean-side sentinel files that prove a slow command reached the
intended phase. Use [tests/lib/beam-wrapper-common.sh](../tests/lib/beam-wrapper-common.sh) helpers
for repeated shell polling patterns. Prefer its JSON assertion helpers for wrapper response checks
so failures print payloads and captured context consistently.

Keep `fileProgress` and readiness distinct in assertions. For `lean-beam sync`, `lean-beam save`,
and `lean-beam close-save`, completed progress is part of the diagnostics/save barrier contract.
For other wrapper requests, progress text is a useful synchronization marker only; it is not proof
that the file or request has reached a stronger semantic readiness state.

Fixed sleeps are acceptable only when the behavior under test is explicitly elapsed-time behavior,
such as "the daemon remains live after a short idle interval". When a test is trying to observe
startup, overlap, cancellation, or a stale-state transition, add a bounded polling helper or a
fixture sentinel instead.

## LSP Surface

Primary entrypoint:

- [tests/test-lsp.sh](../tests/test-lsp.sh)
- [tests/lsp-coverage/check.py](../tests/lsp-coverage/check.py) validates LSP coverage metadata
  before the executable LSP tests run.

Current LSP coverage includes:

- interactive file-anchored regressions through [tests/interactive](../tests/interactive) and [tests/lean/BeamTest/LSP/TestRunner.lean](../tests/lean/BeamTest/LSP/TestRunner.lean)
- multi-document and async scenario coverage through [tests/scenario](../tests/scenario) and [tests/lean/BeamTest/LSP/ScenarioRunner.lean](../tests/lean/BeamTest/LSP/ScenarioRunner.lean)
- programmatic scenario API coverage in [tests/lean/BeamTest/LSP/Scenario/ApiTest.lean](../tests/lean/BeamTest/LSP/Scenario/ApiTest.lean)
- shuffled concurrent workload coverage in [tests/lean/BeamTest/LSP/Scenario/StressTest.lean](../tests/lean/BeamTest/LSP/Scenario/StressTest.lean)
- handle API, restart, lifecycle, and nested-failure coverage in [tests/lean/BeamTest/LSP/Handle](../tests/lean/BeamTest/LSP/Handle)
- full registered LSP request coverage through request-family tests under [tests/lean/BeamTest/LSP/Requests](../tests/lean/BeamTest/LSP/Requests), aggregated by [tests/lean/BeamTest/LSP/RequestSurfaceTest.lean](../tests/lean/BeamTest/LSP/RequestSurfaceTest.lean), including `$/lean/todo` and `$/lean/runAt` composition
- search-style handle workflows in [tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean](../tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean)
- parallel multi-sorry workflow coverage in [tests/lean/BeamTest/LSP/Scenario/ParallelGrindBatchTest.lean](../tests/lean/BeamTest/LSP/Scenario/ParallelGrindBatchTest.lean), which queries actionable todos with `$/lean/todo`, validates one `$/lean/runAt` request per returned item, and then mirrors those exact replacements in one atomic batched `didChange`
- lightweight search-workload latency reporting in [tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean](../tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean) and [scripts/search-workload-report.sh](../scripts/search-workload-report.sh)

Run the LSP surface when the change touches request semantics, proof-vs-command basis selection, positions, cancellation, handles, stale snapshots, per-request isolation, or any method in [Beam/LSP/Plugin.lean](../Beam/LSP/Plugin.lean).

## Beam Surface

Default Beam entrypoints:

- [tests/test-beam-fast.sh](../tests/test-beam-fast.sh): fast broker stream, barrier, request-contract,
  MCP projection, HTTP bridge, self-check, and toolchain CI-matrix guard coverage
- [tests/test-beam-slow.sh](../tests/test-beam-slow.sh): wrapper, MCP stdio stress and
  multi-toolchain workspace coverage, sandbox-wrapper, and save-replay coverage
- [tests/test-beam-install.sh](../tests/test-beam-install.sh): installer and installed-runtime layout
- [tests/test-beam.sh](../tests/test-beam.sh): aggregate default Beam surface

Additional Beam lanes:

- [tests/test-beam-doctor.py](../tests/test-beam-doctor.py): missing-toolchain and missing-project-marker
  inspection, session output before toolchain probing, selected-session incident reporting,
  preserved recovery evidence, failure exit status, and absence of setup writes

- [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) `<toolchain>`: exact
  validated or release-line-compatible bundle qualification, admission diagnostics, module save/replay
  (including the required `.ir.sig` companion), and stale-import diagnostic wording compatibility
- [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh): external MCP `2025-11-25`
  conformance scenarios over the local Streamable HTTP bridge
- [tests/test-mcp-modern-sdk.sh](../tests/test-mcp-modern-sdk.sh): released official TypeScript
  client interoperability with the real `2026-07-28` stdio server
- [tests/test-mcp-modern-conformance.sh](../tests/test-mcp-modern-conformance.sh): applicable
  `2026-07-28` scenarios from the pinned alpha conformance runner over the test-only HTTP bridge

Current Beam coverage includes:

- fast Beam daemon smoke, broker stream ordering, save-stream, wrapper-readiness codec checks,
  backend-startup failure with provisional backend cleanup, tracked-diagnostic dedup,
  exact broker request-handle lifetime, identity-matched daemon-generation probes, terminal shutdown
  response delivery, shutdown after the requesting TCP client resets its connection, protocol tests,
  and validated-toolchain/release-line CI policy consistency through
  [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- wrapper coverage through [tests/test-beam-wrapper.sh](../tests/test-beam-wrapper.sh), which reports
  focused probe, runtime, sync/save, handle, and diagnostic slices independently
- focused daemon lifecycle coverage in [tests/test-beam-wrapper-daemon.sh](../tests/test-beam-wrapper-daemon.sh),
  including the no-implicit-start contract, duplicate-owner rejection, authenticated generation
  probes, interruption of a request whose authenticated endpoint stops reading during send,
  mode-`0700` session-directory and mode-`0600` descriptor publication, rejection of symlinked or non-private
  existing session paths without mutating their targets, stable missing-path canonicalization,
  wrong-root status classification and recovery rejection with
  byte-for-byte descriptor preservation, unauthorized-shutdown rejection without listener teardown, oversized-frame
  and first-message limits, cross-root
  unsafe-registry preservation that does not affect the daemon
  serving the other root, configuration-drift preservation of the owner and active request,
  explicit stop, committed-state reporting after shutdown delivery failure, cancellation of requests
  active during shutdown or owner loss, exact-generation cleanup that preserves a replacement
  registry, idempotent repeated stop, a published draining fence while
  a daemon is paused, rejection of attachment or replacement while that generation remains
  published, forced process-group cleanup of the daemon and its backend,
  holder reporting and recovery-required projection after an unexpected daemon crash, abrupt owner
  death through inherited-pipe EOF,
  read-only crash-fence lookup, four-state status projection, ambiguity-safe human root inference,
  explicit-root lifecycle commands, exact-generation non-signalling recovery, exact session-directory
  selection, and self-termination after the project worktree disappears without recreating it
- Linux-only PID-isolated sandbox wrapper coverage in [tests/test-beam-wrapper-sandbox.sh](../tests/test-beam-wrapper-sandbox.sh),
  including cross-namespace endpoint attachment, duplicate-owner rejection, a paused owner without
  time-based expiry, explicit stop, killed-owner EOF cleanup, fail-closed preservation of an
  unavailable foreign-domain descriptor before explicit recovery, distinct generation identity,
  and the absence of legacy lease/retirement artifacts
- zero-build save replay, structured-setup support, batch-only-argument rejection, and stale-save
  race coverage in
  [tests/test-beam-save-olean.sh](../tests/test-beam-save-olean.sh)
- install flow, installed runtime layout, manifest metadata, exact/compatible toolchain selection,
  shell/Lean owned-root marker parity, required artifact and executable-mode validation,
  content-addressed runtime reuse, reused-runtime source-commit refresh and clearing, schema-2 reuse
  rejection and cleanup compatibility,
  `validated-toolchains`,
  `compatible-release-lines`, `doctor`, installed-state pruning, and installed MCP wrapper coverage
  in [tests/test-beam-install.sh](../tests/test-beam-install.sh), with focused prune safety and
  invalid-runtime identity cases in [tests/test-beam-prune.sh](../tests/test-beam-prune.sh)
- MCP protocol-family selection, projection, modern and legacy stdio, HTTP bridge, self-check, released
  official-client interoperability, and external legacy/modern conformance coverage

Run the Beam surface when the change touches broker protocol or transport, request/progress/diagnostics streams, daemon session or restart logic, wrapper CLI behavior, bundle resolution, install layout, `doctor`, `validated-toolchains`, save replay, save barriers, and MCP.

For save-only work, use [tests/test-beam-save-olean.sh](../tests/test-beam-save-olean.sh) as the
local development loop. The slow and aggregate Beam suites remain useful CI or pre-release signals,
but save replay by itself does not require running them locally.

The user-facing installer behavior, write locations, MCP registration paths, and toolchain options
are documented in [SETUP.md](SETUP.md). The notes below cover maintainer test fixtures and
offline validation knobs.

`tests/test-beam-install.sh` uses fresh fake homes, so first runs may otherwise download Lean
toolchains repeatedly. By default it opportunistically pre-seeds each fake `ELAN_HOME` with symlinks
to matching toolchains already present in the host elan cache. Set
`BEAM_INSTALL_TEST_PRESEED_ELAN=0` to force fully fresh fake homes, or set
`BEAM_INSTALL_TEST_PRESEED_ELAN=require` when working on a slow/offline connection and you want the
test to fail fast if an exact validated toolchain is missing from the host cache.

Installer tests should keep filesystem side effects inside their fake homes and owned temp roots.
Use [tests/lib/install-fixtures.sh](../tests/lib/install-fixtures.sh) for installer-specific
fixtures and [tests/lib/tmp-guards.sh](../tests/lib/tmp-guards.sh) for generic shell-test cleanup
guards. New tests that remove temp paths should declare their expected `/tmp` prefix explicitly and
use the guard helpers instead of raw `rm -rf`; the helpers also allow the nested
`/tmp/beam-validate-*/tmp/...` layout used by [scripts/validate-defensive.sh](../scripts/validate-defensive.sh).

For slow or offline validation, pre-seed the host elan cache before running installer tests. A
typical setup is:

```bash
grep -v '^[[:space:]]*#' validated-lean-toolchains | sed '/^[[:space:]]*$/d' |
  while IFS= read -r toolchain; do
    elan toolchain install "$toolchain"
  done

BEAM_INSTALL_TEST_PRESEED_ELAN=require bash tests/test-beam-install.sh
```

The save suite also runs [tests/test-beam-deferred-save.py](../tests/test-beam-deferred-save.py).
It uses the oldest supported Lean release pinned by `tests/save_olean_project/lean-toolchain`.
Deferred compilation is required on all supported releases; both the wrapper and LSP tests run
without a feature-availability skip. The wrapper test checks both Lake options and declaration-scoped
`compiler.postponeCompile`: sync must report the unsupported readiness reason, both save commands
must reject the checkpoint, and every prior artifact and the Lake trace must remain unchanged.

Use [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh) to validate one
supported bundle lane at a time. The module-save case requires and removes the batch-produced IR
signature, edits `SaveSmoke.ModuleB`, and saves it through `close-save`. It checks the complete artifact
family and requires `lake --no-cache build -v SaveSmoke/ModuleB.lean` to replay the saved outputs;
`CheckModuleB.lean` then imports the saved definition and checks its new value.
`lake --no-cache build checkModuleBNative` compiles and links a consumer that calls the saved
`@[noinline]` definition; running it must print the new value. The lane also checks
that Lean's stale-import diagnostic wording
still matches Beam's temporary text-based detector while the structured Lean stale-dependency API is
pending. If bundle installation stalls on a slow machine, raise
`BEAM_TOOLCHAIN_COMPAT_TIMEOUT` from its default 600 seconds. On failure, the test prints the fake
home, agent homes, bundle directory, platform, and captured build/bundle/stale-diagnostic
log tails so the bundle or stale-diagnostic state can be diagnosed from the test log. Set
`BEAM_TOOLCHAIN_COMPAT_KEEP_TMP_ON_FAILURE=1` to preserve the fake roots for local inspection after
a failed run.

## Save Replay Timeout Investigation

[tests/test-beam-save-olean.sh](../tests/test-beam-save-olean.sh) includes a save-race case
that injects a slow Lean command into `SaveSmoke/B.lean`. The command writes
`LEAN_BEAM_SAVE_RACE_SENTINEL` when elaboration reaches the intended race window, then sleeps long
enough for the shell test to edit the source file while `close-save` is still in flight.

If the sentinel is not written before `BEAM_SAVE_RACE_SENTINEL_TIMEOUT` (default 60 seconds), the
test now dumps the active save PID, runner CPU/platform context, Beam/Lean process snapshot, current
`SaveSmoke/B.lean`, the sentinel file state, daemon registry, daemon log tail, and captured save
stdout/stderr. The race and cancel-sentinel cases start their daemon with broker trace enabled by
default (`BEAM_SAVE_RACE_BROKER_TRACE=1`) and a diagnostics-barrier watchdog
(`BEAM_SAVE_RACE_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000`) so macOS/low-core stalls preserve useful
phase information in the daemon log.

## MCP Stdio Timeout Investigation

When investigating MCP stdio timeouts, prefer the focused descriptor-bound sync repro before
rerunning the full smoke suite:

```bash
lake build Beam.LSP:shared beam-daemon lean-beam-mcp
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-mcp-stdio.py \
  --scenario progress-sync \
  --repro-runs 100 \
  --timeout 30 \
  --slow-threshold 5 \
  --server-trace
```

That scenario runs `lean_sync` with an explicit workspace descriptor and a progress token, then
checks the resulting progress notifications. On failure, the
timeout report includes the client label, pending request parameters, recent completed requests,
recent server requests received from `lean-beam-mcp`, recent notifications, runner CPU/platform
context, relevant CI and Lean thread env vars, the stderr tail, and a Beam/Lean process snapshot.

For the same-process concurrency contract, run:

```bash
lake build Beam.LSP:shared beam-daemon lean-beam-mcp
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-mcp-stdio.py \
  --scenario concurrent-dispatch \
  --timeout 40
```

This scenario covers out-of-order tool responses, exact string/numeric request-ID separation,
duplicate active-ID suppression, repeated asynchronous request-ID reuse after terminal responses,
exact modern and legacy broker cancellation, per-request progress ordering, deterministic overlap
between a gated request in one workspace and a fast request in another, single-flight first use,
simultaneous cold first use of distinct roots, stateless multi-root isolation, non-cancellable cache
eviction with ordering on both sides of the global fence, lazy recreation, and EOF cancellation and
teardown. The full stdio suite also checks modern request-ID reuse, synchronous and workspace-control
closed-output teardown, and rejects a proof handle carried across an MCP process restart. The slow
Beam suite runs
`--scenario multi-toolchain-workspaces` after installing both fixture toolchains and verifies that
one MCP process keeps both project-specific Lean sessions active.

If this scheduler-sensitive timeout appears on an unrelated CI PR, copy the timeout headline and
diagnostic excerpt to [#110](https://github.com/leanprover/lean-beam/issues/110) so repeated
occurrences can be correlated in one place. Include the PR URL and branch, failing run URL, failing
job URL, job name, runner OS/arch, run attempt, commit SHA, failing test or scenario, relevant
request/progress or sentinel diagnostics from the log, and the rerun URL plus whether it passed or
reproduced.
The optional `--server-trace` flag enables opt-in `lean-beam-mcp` and broker trace lines in that
stderr tail without changing normal test stderr expectations. To look for scheduler-sensitive
behavior locally, prefer a low-core or CPU-contended run. On a large local machine, run CPU load in
one shell:

```bash
stress-ng --cpu 24 --timeout 90s --metrics-brief
```

Then run the focused scenario in another shell while the stressors are active.

For the scheduler-sensitive progress-smoke path that has reproduced timeouts locally, use the
parallel repro scenario while the stressors are active:

```bash
PYTHONDONTWRITEBYTECODE=1 python3 tests/test-mcp-stdio.py \
  --scenario progress-smoke-parallel \
  --parallel-workers 8 \
  --repro-runs 10 \
  --timeout 30 \
  --slow-threshold 5
```

Set `--server-trace` to add MCP/broker trace lines to the timeout dump, and set
`LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000` to emit an opt-in broker trace if a
`waitForDiagnostics` barrier is still pending after that many milliseconds. The slow Beam suite
runs the stdio stress harness with `BEAM_MCP_STDIO_TIMEOUT` defaulting to 60 seconds, enables
`BEAM_MCP_SERVER_TRACE=1` for the stdio harness by default, and sets the diagnostics-barrier watchdog
to `BEAM_MCP_STDIO_WAIT_DIAGNOSTICS_WATCHDOG_MS=10000`. Set `BEAM_MCP_STDIO_SERVER_TRACE=0` only
when intentionally checking the quiet stderr path. The fast suite's installed-wrapper self-check uses
`BEAM_MCP_SELF_CHECK_TIMEOUT_MS`, defaulting to 120 seconds, because first-time bundle setup may
build the local fixture under CI contention. Keep `--timeout 30` for local repro attempts unless you
are specifically checking the CI budget. The focused daemon lifecycle fixture explicitly prebuilds
its toolchain into one owned shared cache before timing daemon startup, so cold bundle compilation
is not misdiagnosed as a daemon-readiness timeout.

MCP self-check is an installation smoke test with best-effort internal waits. The fast suite and
installed-wrapper suite supervise it using `tests/lib/process_watchdog.py`, with
`BEAM_MCP_SELF_CHECK_WATCHDOG_SECONDS` defaulting to 600 seconds. The MCP protocol test executable,
which includes self-check child fixtures, has a separate 240-second external watchdog configurable
with `BEAM_MCP_PROTOCOL_TEST_WATCHDOG_SECONDS`.

The watchdog captures stdout/stderr in files and reads at most the final 1 MiB of each, so inherited
writers cannot keep output collection waiting for EOF. On timeout it exits 124 after cleanup,
targeting only its owned POSIX process group or its Windows process tree through
[`taskkill /PID ... /T /F`](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/taskkill).
Process creation is outside the wait deadline; cleanup has separate five-second bounds for the
Windows tree-termination command and direct-child reaping. `python3 tests/test-process-watchdog.py`
checks successful logging, nonzero exit, bounded captured output, and timeout with inherited output
and a partial response. Windows execution still needs qualification on a Windows runner.

The focused CLI daemon test also checks that a failed stderr evidence sink does not stop pipe
draining, that sink failure observation is synchronized, and that a pipe held open past leader exit
produces a bounded `pipeStillOpen` outcome rather than an unbounded task join.

The focused harness also accepts `no-progress-sync` to isolate whether a timeout depends on MCP
progress notifications or the underlying `lean_sync` / `waitForDiagnostics` path.

## Maintainer Surface

The maintainer surface covers local workflow helpers:

- [tests/test-maintainer.sh](../tests/test-maintainer.sh)
- [tests/test-codex-harness.sh](../tests/test-codex-harness.sh)
- [tests/test-validate-defensive.sh](../tests/test-validate-defensive.sh)
- [tests/test-extended-ci.py](../tests/test-extended-ci.py): offline destination, revision, and CLI
  failure checks for the fork-CI helper; also included in the fast suite

The aggregate maintainer runner skips [tests/test-codex-harness.sh](../tests/test-codex-harness.sh) when the current checkout has tracked edits, because that harness regression intentionally verifies that new task worktrees start from a clean primary checkout.

Run these when the change touches [scripts/codex-harness.sh](../scripts/codex-harness.sh),
[scripts/codex-session-start.sh](../scripts/codex-session-start.sh),
[scripts/validate-defensive.sh](../scripts/validate-defensive.sh), or
[scripts/extended-ci.py](../scripts/extended-ci.py).

## CI Map

The GitHub Actions repository variable `BEAM_FULL_MACOS_CI` selects the macOS layout for pull
requests, `main` pushes, and manual runs:

- Unset or `false`: one combined `macos-platform` job, alongside the parallel Linux jobs.
- `true`: the full Linux and macOS job matrices; the combined macOS job is skipped.

Use the default combined mode in `leanprover/lean-beam`. Enable full mode in forks where the full
macOS matrix is desired. Repository names and actors do not select the policy.

The combined `macos-platform` job covers every test family.
It runs shell lint, fast broker tests, LSP tests, MCP conformance and SDK tests, the slow suite,
pinned-toolchain qualification, and installer tests as separate steps in one checkout.
The job shares Lean setup and incremental build outputs; each suite keeps its own temporary
projects and homes. Independent test steps continue after another test fails, while a failed step
still fails the job. The job has a 120-minute timeout.

Each layout runs shell lint once per operating system, separately from the slow suite. The slow
suite owns the full MCP stdio harness, including four iterations and three restart cycles; the fast
suite retains protocol, projection, HTTP bridge, and self-check coverage. `test-lsp.sh` builds its own prerequisites, so the
workflow does not run a separate build before it. The local aggregate and default defensive
validation commands also run shell lint once before their product suites.

Linux retains the separate parallel jobs and the exact toolchain compatibility matrix in both
modes. The combined macOS job runs toolchain qualification once at the repository-pinned Lean
version. Full mode runs the complete per-version macOS compatibility matrix.
Installer tests still prebuild every toolchain in `validated-lean-toolchains`.

The variable belongs to the repository running the workflow. A fork-originated PR running in
`leanprover/lean-beam` therefore uses the upstream repository's setting. To enable full mode in a
fork and request a run for a branch, replace `OWNER/REPO` with that fork's repository:

```bash
gh variable set BEAM_FULL_MACOS_CI --repo OWNER/REPO --body true
gh workflow run ci.yml --repo OWNER/REPO --ref BRANCH
```

The current GitHub Actions workflow maps to the testing surfaces like this:

- `macos-platform`: the combined macOS job described above
- `lsp`: [tests/test-lsp.sh](../tests/test-lsp.sh)
- `beam-fast`: [tests/test-beam-fast.sh](../tests/test-beam-fast.sh)
- `mcp-conformance`: [tests/test-mcp-conformance.sh](../tests/test-mcp-conformance.sh)
- `mcp-modern`: [tests/test-mcp-modern-sdk.sh](../tests/test-mcp-modern-sdk.sh) followed by
  [tests/test-mcp-modern-conformance.sh](../tests/test-mcp-modern-conformance.sh)
- `beam-slow`: [tests/test-beam-slow.sh](../tests/test-beam-slow.sh)
- `beam-install`: [tests/test-beam-install.sh](../tests/test-beam-install.sh)
- `beam-toolchain-compat`: [tests/test-beam-toolchain-compat.sh](../tests/test-beam-toolchain-compat.sh)
  `<toolchain>` for the latest stable point of each supported stable line plus the pinned RC before
  its stable release, on Linux and in full
  macOS mode. Combined macOS mode qualifies the repository-pinned version.
  Other RCs and superseded stable points qualify locally instead of receiving dedicated CI jobs.
- `shell-lint`: [scripts/lint-shell.sh](../scripts/lint-shell.sh)

## Extended Fork CI

For macOS-sensitive changes that need the complete per-version and per-suite matrix, maintainers
and Codex can request CI on the dedicated [test fork](https://github.com/ejgallego/lean-beam-ci-macos):

```bash
# Run from a clean, committed task worktree. Requires authenticated gh and SSH push access.
python3 scripts/extended-ci.py --wait
```

[scripts/extended-ci.py](../scripts/extended-ci.py) verifies the fork's exact repository name,
upstream relationship, active `ci.yml` workflow, and `BEAM_FULL_MACOS_CI=true` setting. It pushes
`HEAD` to `extended-ci/<full-commit-sha>`, dispatches CI there, and prints the commit and run URL.
It preserves local remotes and the fork's default branch. Existing runs for the same revision are
reused; failed runs must be rerun explicitly through GitHub. Without `--wait`, the command returns
after finding the run. With `--wait`, it exits unsuccessfully if CI fails.

Use `--repo OWNER/REPO` for another fork configured as above. That fork must already have an
enabled `ci.yml` supporting `workflow_dispatch` on its default branch. Redirects are rejected:
`ejgallego/lean-beam` redirects to upstream and must not be used as a testing fork.

For a fork that already has the workflow on its default branch, the one-time configuration is:

```bash
gh variable set BEAM_FULL_MACOS_CI --repo OWNER/REPO --body true
gh workflow enable ci.yml --repo OWNER/REPO
```

If GitHub disables workflows on a newly created fork, enable them in that fork's Actions tab first,
as described in [GitHub's fork workflow guidance](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflows-in-forked-repositories).

To inspect or retry a failed run, use its numeric ID from the reported run URL:

```bash
gh run view RUN_ID --repo OWNER/REPO --log-failed
gh run rerun RUN_ID --repo OWNER/REPO --failed
```

Compare the reported commit with the PR head before marking a PR ready. Changes made afterward
need another run. Share the run URL in review coordination; routine results belong in CI rather
than in the public PR description. A fork run is additional evidence and does not replace required
upstream PR checks.

## Coverage Gaps

The main current gaps are:

- search-style LSP coverage is correctness-heavy, but not yet a larger benchmark-style workload with much deeper branching pressure
- Codex worktree-harness regressions are documented and runnable, but separate from the default
  product CI lanes
