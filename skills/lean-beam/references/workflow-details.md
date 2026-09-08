# Lean Workflow Details

Use this reference when the task needs more than the default loop in `SKILL.md`.

## Position Semantics

- `lean-beam run-at` and `lean-beam run-at-handle` take the broker document snapshot before
  Lean/LSP `Position` coordinates: `<snapshot> <line> <character>`; use the snapshot from `update`
- line `0` is the first line, and character `0` is the first UTF-16 code unit on that line
- on a truly empty line, only character `0` is valid; character `1` is already out of range
- on an indented blank line, either probe after the existing spaces using that exact character
  offset, or probe at character `0` and include the indentation in the text yourself
- `position ... is outside the document` means the requested coordinate is not a valid Lean/LSP
  position for the current on-disk file
- `no command or tactic snapshot` means the coordinate is in the document, but Lean has no usable
  execution basis there
- valid probe positions are not arbitrary file coordinates; `lean-beam run-at` needs a command basis or
  proof/tactic snapshot at that position, or one Lean can recover from nearby syntax
- for a tactic replacement, select its first character after indentation to use its before-state;
  inside a simple tactic or at its end, Lean generally selects the after-state
- standalone comments, blank lines, and many declaration headers often do not have a usable basis
- nearby whitespace/comments may still work when Lean can recover a neighboring basis, but do not
  assume that from arbitrary file positions
- those errors do not by themselves mean the Beam daemon is unhealthy

For `BeamRunAtProbe.lean` containing exactly these three lines:

```lean
example (a b : Nat) (h : a = b) : 0 + a = b := by
  simp
  exact h
```

| Position (line, character) | Selected state | Probe `exact h` |
| --- | --- | --- |
| `1 2`: start of `simp` | Before `simp`: `0 + a = b` | Fails |
| `1 3`: inside `simp` | After `simp`: `a = b` | Succeeds |
| `2 2`: start of `exact h` | Before `exact h`: `a = b` | Succeeds |

Read the source and select the intended position first. Stop if `update` fails; after it succeeds,
extract its token. This replacement probe correctly returns `result.success=false`:

```bash
update_json="$(lean-beam update "BeamRunAtProbe.lean")"
snapshot="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
lean-beam run-at "BeamRunAtProbe.lean" "$snapshot" 1 2 -- "exact h"
```

Nested tactics and whitespace may select an enclosing or neighboring tactic. `goals before` and
`goals after` inspect both sides of the selected tactic; they do not configure a later `run-at`.

## Command Details

The following position examples use `Foo.lean`; obtain its token separately after reading that file.
Stop if `update` fails.

```bash
update_json="$(lean-beam update "Foo.lean")"
snapshot="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
```

Continue from a stored handle:

```bash
# `--handle-file` avoids inlining handle json and frees stdin for continuation text
lean-beam run-with "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam run-with-linear "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam release "Foo.lean" --handle-file handle.json

# stdin handle flow remains supported when it fits your shell loop better
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with-linear "Foo.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam release "Foo.lean" -
```

Short search helper:

```bash
lean-beam-search mint "Foo.lean" "$snapshot" 10 2 "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search branch "Foo.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search playout "Foo.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search release "Foo.lean"
```

Inspect Lean type/term information at a specific position:

```bash
lean-beam hover "Foo.lean" "$snapshot" 10 2
lean-beam signature-help "Foo.lean" "$snapshot" 10 2
```

Follow semantic navigation and symbol information:

```bash
lean-beam definition "Foo.lean" "$snapshot" 10 2
lean-beam references "Foo.lean" "$snapshot" 10 2
lean-beam document-symbols "Foo.lean" "$snapshot"
lean-beam workspace-symbols "Foo.bar"
```

Inspect Lean proof goals at an existing tactic position:

```bash
lean-beam goals before "Foo.lean" "$snapshot" 10 2
lean-beam goals after "Foo.lean" "$snapshot" 10 2
```

These commands return structured goals in `result.goals`. A solved state uses
`result.goals = []`.

Checkpoint one synced workspace module without a full project build:

```bash
lean-beam save "MyPkg/Sub/Module.lean"
lean-beam close-save "MyPkg/Sub/Module.lean"
```

These commands require a synced file that belongs to the current Lake workspace and resolves to a
module in the package graph. A standalone `.lean` file that the daemon can open but Lake cannot map
to a module is a valid `lean-beam sync` target, but not a valid `lean-beam save` target.

The checkpoint contains the environment accepted by the Lean server. It avoids a batch
re-elaboration during the inner loop, so it is a development artifact rather than final build
evidence. An elaborator that observes server mode can behave differently under `lake build`.
Structured Lake options, dynamic libraries, and plugins are supported when the file worker has
already applied them. Modules with batch-only `moreLeanArgs` fail with `saveUnsupportedSetup`; move
shared `-D` settings to `leanOptions`, or use `lake build` when the arguments are intentionally
batch-only.

Beam assumes Lake workspace configuration remains unchanged while the Lean server is running. After
editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic
libraries, run `lean-beam --root ROOT stop` before the next command that uses the Lean server.
`lean-beam refresh` only reopens a file within the current server and is not sufficient. Beam does
not detect this configuration drift.

## Save Eligibility

When `lean-beam save` is valid:

- the file has already been synced successfully
- the file belongs to the current Lake workspace package graph
- Lake resolves that path to a module
- `lean-beam save` means checkpointing a synced Lake module; it does not mean saving editor buffers or
  writing source text to disk

What is not a valid checkpoint target:

- a standalone `.lean` file at repo root that is outside the package module graph
- any file the daemon can open but Lake cannot map to a workspace module

## Source-File And Execution Model

- `lean-beam run-at` does not edit `Foo.lean`
- `lean-beam hover` and `lean-beam signature-help` are normal read-only semantic inspection
  commands for an existing position
- `lean-beam definition`, `lean-beam references`, and `lean-beam document-symbols` are normal
  read-only semantic navigation commands against a specific document snapshot
- `lean-beam workspace-symbols` is a read-only workspace query and does not take a document snapshot
- `lean-beam goals before` and `lean-beam goals after` are the normal read-only proof-state
  inspection commands for an existing tactic position
- `lean-beam goals before` / `lean-beam goals after` return `result.goals`, not speculative execution output,
  and do not accept speculative text
- `lean-beam` only sees the on-disk file, not unsaved editor buffers
- actual source edits happen through the normal file-edit workflow
- after every real source edit to a Lean file, save the file in the normal editor/file sense and
  then run `lean-beam update "Foo.lean"` before the next snapshot-bound probe; use
  `lean-beam sync "Foo.lean"` when the workflow needs a diagnostics/readiness barrier
- use `lean-beam refresh "Foo.lean"` when a tracked file needs `lean-beam close` plus `lean-beam sync`
  as one step, especially after saving an upstream dependency
- treat `lean-beam sync` as the explicit supported boundary between real file edits and Beam daemon
  session state
- after a completed broker operation, `lean-beam sync` returns ordered machine-readable JSON on
  stdout with the current diagnostic counts and readiness result and streams human diagnostics on
  stderr; automated callers must check the process exit status before parsing stdout
- if imported targets are stale or the Lean worker cannot finish that diagnostics barrier,
  `lean-beam sync` fails; do not treat a failed sync as safe to follow with `lean-beam save`
- for completed broker operations, `lean-beam sync` keeps machine-readable JSON on stdout;
  interactive progress text goes to stderr, while selector, setup, or transport failures may exit
  nonzero with no JSON
- every `lean-beam run-at` request is an isolated read-only probe against one on-disk document
  snapshot
- `lean-beam run-at-handle` is the same style of isolated probe, but asks Lean to retain follow-up
  state
- `lean-beam run-with` preserves the current handle and branches from it
- `lean-beam run-with-linear` consumes the current handle and returns a successor handle for linear
  continuation
- `lean-beam release` explicitly drops a preserved handle
- `lean-beam-search` is a small convenience wrapper around these same commands
- the request may wait for the Lean snapshot at the requested position to finish elaborating; this
  is normal
- the probe does not mutate the document's real elaboration state and does not create hidden state
  for the next probe
- the Beam daemon may implicitly open or update the file from disk before a probe, but that is not
  the supported diagnostics/readiness barrier after edits
- use `lean-beam sync` when the workflow needs an explicit diagnostics/readiness boundary;
  `lean-beam run-at` only waits for the snapshot it needs
- if the same document changes while a request or stored handle is pending, expect
  `contentModified` or handle invalidation instead of hidden reuse
- after `contentModified`, read the source and resolve the intended target or code action again;
  call `update` or `sync` for a fresh `snapshot` before retrying. `currentSnapshot` identifies
  the observed replacement; it does not rebase old coordinates or actions
- `lean-beam save` / `lean-beam close-save` checkpoint the current synced Lake module only; they do not
  rebuild reverse dependencies or make downstream files fresh by themselves

## Diagnostics, Progress, And Request IDs

- `lean-beam sync`, `lean-beam refresh`, `lean-beam save`, and `lean-beam close-save` always stream
  fresh diagnostics for the current request
- by default they stream only errors
- add `+all-diagnostics` to widen the current request to warnings, info, and hints
- the final JSON reports the current synced-state verdict rather than replaying streamed
  diagnostics
- streamed diagnostics are request events, not a since-last-sync diff
- successful `lean-beam save` includes the sync verdict it established in `result.sync`
- successful `lean-beam close-save` includes the sync verdict in `result.saved.sync`
- use `result.readiness.saveReady` for sync/refresh decisions,
  `result.sync.readiness.saveReady` for save, and `result.saved.sync.readiness.saveReady` for
  close-save; use the corresponding `blockingErrorCount` and blocking evidence to explain blocked
  verdicts
- when `lean-beam save` or `lean-beam close-save` returns `invalidParams` for document errors, the transport
  `error.message` includes a compact preview of underlying diagnostics and/or command messages, and
  `error.data.sync` contains the blocking sync verdict
- wrapper `stderr` is the human-facing diagnostic surface
- use MCP when a client requires structured live diagnostics or progress
- streamed diagnostics are request-scoped observations; they may carry `completionBlocking=true`,
  but save-blocking evidence is attached to the final sync/save verdict
- the field-level progress, diagnostic, and readiness contract lives in
  [../../../docs/SYNC_AND_DIAGNOSTICS.md](../../../docs/SYNC_AND_DIAGNOSTICS.md)
- do not parse wrapper `stderr` in tooling
- `BEAM_PROGRESS` controls stderr progress output for slow calls
- by default, progress prints when stderr is a TTY
- set `BEAM_PROGRESS=1` to force progress output in scripts or CI
- `BEAM_REQUEST_ID=<id>` attaches optional request metadata to the broker request
- the final stdout JSON echoes it as `clientRequestId`
- streamed stderr progress/diagnostic lines are annotated as `beam[<id>]: ...`
- a second live request using the same id is rejected with `invalidParams`
- `lean-beam cancel <id>` cancels an in-flight broker request by that `clientRequestId`
- `Ctrl-C` interrupts the owning one-request connection, and the daemon cancels that exact admitted
  request when it observes the disconnect; this does not require `BEAM_REQUEST_ID`, exits nonzero,
  and does not fabricate a terminal stdout response after the connection is gone

## File Progress And Readiness

Treat `fileProgress` as observability, not as proof that every call is a full barrier.

```bash
# with `lean-beam serve` running in another process
sync_out="$(lean-beam sync "Foo.lean")"
printf '%s\n' "$sync_out"
snapshot="$(printf '%s\n' "$sync_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"

probe_out="$(lean-beam run-at "Foo.lean" "$snapshot" 10 2 "exact trivial")"
printf '%s\n' "$probe_out"
```

Interpretation:

- after `lean-beam sync`, expect top-level `fileProgress.done = true`
- successful `lean-beam sync` transport does not mean the file is error-free; inspect
  `result.readiness.saveReady` for current save-readiness; use `blockingErrorCount` and blocking
  evidence to explain blocked verdicts
- if you need to know whether Lean published error-severity diagnostics, inspect
  `result.diagnostics.counts.error`; do not use that field as the save/checkpoint
  decision
- if `lean-beam sync` fails with an incomplete diagnostics barrier, inspect the JSON
  `error.data.staleDirectDeps`, `error.data.saveDeps`, `error.data.recoveryPlan`, and
  `error.data.completionBlockingDiagnostics`; the recovery hints are based on direct imports from
  Lean's accepted header snapshot and broker sync/save history, and entries in
  `completionBlockingDiagnostics` carry `completionBlocking=true`
- follow `error.data.saveDeps` only for the listed direct deps that still need checkpointing, then
  `lean-beam refresh` the stale target before relying on downstream probes
- after `lean-beam run-at`, top-level `fileProgress` may exist with `done = false`; that is normal
  because the request only waited for its own target snapshot
- use `lean-beam hover` or `lean-beam signature-help` for semantic inspection and
  `lean-beam goals before` / `lean-beam goals after` for existing proof state; use
  `lean-beam run-at` only when you need speculative execution
- if you need a real ready/fresh boundary after edits, use `lean-beam sync`, not a successful probe

Recovery loop for `syncBarrierIncomplete`:

```bash
# target T failed: lean-beam sync "T.lean"

# 1) if error.data.saveDeps lists direct deps that still need checkpointing, save them
lean-beam save "U.lean"

# 2) force the target tracked document to refresh its basis, then retry
lean-beam refresh "T.lean"
```

Practical boundary:

- this is a targeted recovery loop, not a full dependency scheduler
- if retries keep walking additional modules, or if you need final workspace trust, stop and run
  `lake build`

## Cost Model

For agent workflows, distinguish fixed startup cost from marginal probe cost.

Detached scratch files, including temporary files outside the workspace module graph, pay the cost
of constructing an artificial Lean context and often reload imports from a colder basis. They are
useful for context-free syntax checks, but they are the wrong default for questions whose answer
depends on the real module, imports, options, notation, instances, or proof state.

Beam is designed for the opposite loop. Once the per-root daemon and target document are warm,
`run-at`, `hover`, `signature-help`, `definition`, `references`, `document-symbols`, and `goals`
are cheap local questions against the saved source snapshot. The intended agent style is therefore
small, source-position probes, not large detached experiments.
High-bandwidth clients do not need to wait for a batch API to exploit this shape: they can keep many
independent `run-at` probes or handle-rooted search sequences in flight concurrently. Future
batching can reduce per-call overhead and simplify client code, but it is a minor gain compared with
parallelizing independent probes against a warm daemon. Coordinate only the cases that truly share
state, such as a linear handle that is consumed by its next step.

Write the on-disk document as `prefix ++ E ++ suffix`.

- `N := |prefix| + |E| + |suffix|` is the full document length
- `C := |E|` is the changed region length
- the wrapper is cheap only after the per-root daemon and matching bundle already exist
- `lean-beam run-at`, `lean-beam run-at-handle`, `lean-beam run-with`, and `lean-beam release` do not edit the file;
  they are speculative checks on one current snapshot, so their cost is not a workspace rebuild cost
- independent speculative checks can be launched in parallel by the client; batching is an
  ergonomics and per-call-overhead improvement, not the main scaling mechanism for clients that can
  already keep requests in flight
- `lean-beam sync` always transmits the full current file text to Lean, so the wire/update cost is
  `O(N)`, not `O(C)`, even when `C << N`
- `lake build Foo.lean` is also at least `O(N)` in the target file length for that file
- the intended win is avoiding repeated `lake build` loops and repeated cold starts, not making
  one-file rebuild asymptotically sublinear
- `lean-beam save` and `lean-beam close-save` checkpoint one synced module after a completed barrier; they do
  not rebuild reverse dependencies and they do not turn workspace freshness into an `O(C)` problem
- first-use bundle resolution is the expensive outlier: if no installed bundle matches the
  toolchain, `beam` may build a local fallback bundle under `<root>/.beam/bundles`, which is real
  `lake build`
- if imported targets are stale or broken, `lean-beam sync` / `lean-beam save` fail instead of silently
  paying dependency-cone rebuild cost

## Dependency Edits And Rebuild Boundary

If you edit `A.lean` and `B.lean` imports `A.lean`, a successful probe in `B.lean` is not enough by
itself to prove the dependency cone is fresh.

```bash
# with `lean-beam serve` running in another process
# make a real edit in A.lean and save the source file to disk
lean-beam sync "A.lean"
b_update="$(lean-beam update "B.lean")"
b_snapshot="$(printf '%s\n' "$b_update" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
lean-beam run-at "B.lean" "$b_snapshot" 12 2 "#check someNameFromA"
```

Rules:

- the downstream probe in `B.lean` may still be a bad basis for trust after editing `A.lean`
- after dependency edits, prefer a rebuild or checkpoint before trusting downstream results
- once the task is “refresh a dependency cone” rather than “probe one edited file”, stop and run
  `lake build`

Use `lake build` when:

- you edited a dependency and now need trustworthy downstream results
- repeated probing is no longer clarifying the situation
- stale-state or rebuild trouble keeps appearing
- CI is validating the project from a clean checkout or clean Lake build directory
- no successful clean CI result is available, or server-sensitive elaboration is suspected

For the one-time local completion fallback, discard Beam checkpoints before the batch build:

```bash
lean-beam --root ROOT stop
lake clean
lake build
```

Do not run this sequence merely because Beam saved a checkpoint: successful checkpoints are
normally sufficient during the inner loop. Keep using targeted Beam probes and checkpoints instead
of repeatedly cleaning the build directory. Final batch evidence should come from CI running `lake
build` from clean artifacts, or from this one-time local fallback when no successful clean CI result
is available.

## Stats And Signs Of Good Use

Use:

```bash
lean-beam open-files
lean-beam stats
```

`lean-beam open-files` shows the files currently tracked by the Beam daemon for the current project,
along with on-disk `diskStatus`, the daemon-recorded `checkpointed` marker, and the last compact
`fileProgress` observed for that tracked snapshot. `diskStatus` is `matchesTracked`,
`differsFromTracked`, `missing`, or `unknown`. `checkpointed` means this daemon successfully saved
the unchanged tracked snapshot; it does not revalidate Lake artifacts. Run `lean-beam save` to
perform the authoritative Lake module, readiness, trace, and setup checks.

Stats are in-memory only and scoped to the current project Beam daemon.

The Beam daemon is helping if:

- many local probes happen before one edit
- `lake build` is not the inner loop
- stats show more `lean-beam run-at` / `lean-beam save` than full builds
