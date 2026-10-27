# Lean Workflow Details

Use this reference when the task needs more than the default loop in `SKILL.md`.

## Position Semantics

- `lean-beam run-at` and `lean-beam run-at-handle` take the broker document version before
  Lean/LSP `Position` coordinates: `<version> <line> <character>`; use the version from `update`
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
- on a `sorry`, `_`, or `?x` term that the command left unfilled, the text is tactics run against
  a goal with that placeholder's type and local context, like the tactics of a `by ...` block there;
  use `exact t` for a term. Only the placeholder's type is checked, not later parts of the
  enclosing term
- a successful probe is not proof that the edit elaborates: probes check the text against its goal
  only and do not run Lean's termination checking, so text that uses the declaration being proved
  can succeed; confirm with a real edit and `sync`
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

After updating the file, this replacement probe correctly returns `result.success=false`:

```bash
lean-beam run-at "BeamRunAtProbe.lean" <version-from-update> 1 2 -- "exact h"
```

Nested tactics and whitespace may select an enclosing or neighboring tactic. `goals before` and
`goals after` inspect both sides of the selected tactic; they do not configure a later `run-at`.

### Todo ranges and point queries

`todo FILE VERSION` queries the whole file. Supply `SL SC EL EC` to restrict the query to a range.
When an item includes `run_at_position`, a probe there starts from its `proof_state`. The field
is omitted when no source position selects that goal; edit the source instead in that case.

For sorries, holes, diagnostics, and incomplete proofs, a nonempty `todo` query uses half-open
range overlap: its end is excluded. An empty range is a point query. It matches items containing
that point, including an item's end, so a `run_at_position` immediately after a tactic, when
supplied, can be used for inspection.

Code actions require an explicit range and use Lean's provider selection: Lean chooses one command
snapshot using the query's end. A range across several commands does not enumerate actions for every command. Query
a point inside the relevant tactic, hole, or diagnostic, or use a range within one command. An empty
code-action result does not establish that the whole file has no actions.

## Command Details

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
lean-beam-search mint "Foo.lean" <version-from-update> 10 2 "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search branch "Foo.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search playout "Foo.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search release "Foo.lean"
```

Inspect Lean type/term information at a specific position:

```bash
lean-beam hover "Foo.lean" <version-from-update> 10 2
lean-beam signature-help "Foo.lean" <version-from-update> 10 2
```

Follow semantic navigation and symbol information:

```bash
lean-beam definition "Foo.lean" <version-from-update> 10 2
lean-beam references "Foo.lean" <version-from-update> 10 2
lean-beam document-symbols "Foo.lean" <version-from-update>
lean-beam workspace-symbols "Foo.bar"
```

Inspect Lean proof goals at an existing tactic position:

```bash
lean-beam goals before "Foo.lean" <version-from-update> 10 2
lean-beam goals after "Foo.lean" <version-from-update> 10 2
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
batch-only. If an import changed on disk after the file worker loaded it, for example through an
external `lake build`, saving fails with `saveImportsChanged`; run `lean-beam refresh FILE` so the
worker reloads its imports, then save again.

Beam assumes Lake workspace configuration remains unchanged while the Lean server is running. After
editing a lakefile, manifest, package override, `lean-toolchain`, Lean options, plugins, or dynamic
libraries, run `lean-beam --root ROOT stop` before the next command that uses the Lean server.
`lean-beam refresh` only reopens a file within the current server and is not sufficient. Runtime-selection checks can reject a changed `lean-toolchain`, but Beam does not reload workspace
configuration in an existing server.

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
  read-only semantic navigation commands against a specific document version
- `lean-beam references` waits for the whole document version to elaborate, so its first call after
  an edit can take as long as `sync`
- `lean-beam workspace-symbols` is a read-only workspace query and does not take a document version
- `lean-beam goals before` and `lean-beam goals after` are the normal read-only proof-state
  inspection commands for an existing tactic position
- `lean-beam goals before` / `lean-beam goals after` return `result.goals`, not speculative execution output,
  and do not accept speculative text
- `lean-beam` only sees the on-disk file, not unsaved editor buffers
- actual source edits happen through the normal file-edit workflow
- after every real source edit to a Lean file, save the file in the normal editor/file sense and
  then run `lean-beam update "Foo.lean"` before the next version-bound probe; use
  `lean-beam sync "Foo.lean"` when the workflow needs a diagnostics/readiness barrier
- use `lean-beam refresh "Foo.lean"` to refresh a tracked document from saved source, especially after
  saving an upstream dependency; see the [refresh contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md#command-model)
- treat `lean-beam sync` as the explicit supported boundary between real file edits and Beam daemon
  session state
- after a completed broker operation, `lean-beam sync` returns compact machine-readable JSON (`--pretty` adds indentation only) on
  stdout with the current diagnostic counts and readiness result and streams human diagnostics on
  stderr; automated callers must check the process exit status before parsing stdout
- if imported targets are stale or the Lean worker cannot finish that diagnostics barrier,
  `lean-beam sync` fails; do not treat a failed sync as safe to follow with `lean-beam save`
- `lean-beam sync` prints one final JSON response on stdout for completed operations and ordinary
  CLI failures; diagnostics and progress go to stderr. Exit `2` means local usage/input error;
  exit `3` (`noLiveSession`) includes the exact `serve` remedy; exit `130` (`requestCancelled`)
  reports interruption without establishing producer settlement. Preserve broker failure codes and
  data when deciding recovery; never treat failed sync as save-ready.
  Local remedies are in `error.data.remedy_command` and on their own stderr line.
  `sessionRecoveryRequired` (exit `1`) includes the generation when known; obey its
  `recovery_precondition` and independently verify that the matching owner, daemon, and all other
  producers have stopped before running recovery. An unavailable endpoint alone is insufficient
  evidence. `status` state `unresponsive` means the endpoint did not validate, including incomplete
  or malformed replies; `sessionUnresponsive` (exit `1`) preserves the descriptor and refuses
  recovery. Resume or inspect the original owner and daemon through their supervisor before retrying
- `serve` checks the selected descriptor locally without probing its endpoint. An existing
  matching-root descriptor marked `live` fails with `setupError`, recorded/requested configuration hashes,
  and an exact `status` remedy. This does not establish owner liveness. `status` state `running`
  means an authenticated workspace probe succeeded, not that Lean elaboration is ready or complete
- the first successful `stop` acknowledges a shutdown request with `state: "stopping"`. A retained
  shutdown descriptor means completion is unconfirmed: `status` reports `shutdownUnconfirmed`, and
  repeated stop, serve, or attachment gives `sessionShutdownUnconfirmed` with the generation and an
  owning-installation `status` remedy. Wait for cleanup and check for `absent` before restarting.
  Execute the absolute executable in `remedy_command`; a different installation on `PATH` cannot
  control this session (`sessionInstallationMismatch`). A foreign control refusal preserves the
  attempted command and generation in the owning-installation remedy. A mismatched recovery
  generation instead returns `invalidParams`/exit `2` with the recorded `generation`, before
  ownership admission. Do not automatically substitute the recorded generation and retry: confirm
  the intended generation and independently verify that its owner, daemon, and every other producer
  have stopped. If the owning installation's executable is missing,
  interrupt the original owner or use its supervisor. `recovery_command` is a separate conditional
  command: if cleanup cannot finish within the caller's waiting budget, perform full supervised cleanup of every original producer
  before recovering any remaining descriptor. Neither the record nor its age establishes owner death
- remedy strings use POSIX shell syntax, including on Windows. Use Bash/MSYS2 for these strings;
  cmd.exe/PowerShell and shell-independent remedies are tracked in [#371](https://github.com/leanprover/lean-beam/issues/371)
- `--text-file` and `--handle-file` require regular-file targets and allow ordinary symlinks;
  directories, devices, FIFOs, and symlink loops observed at admission fail with
  `invalidParams`/exit `2` before dispatch. The target check and later open are separate operations,
  so concurrent path replacement remains possible. Use `--stdin` or handle `-` for streaming. Input is read to EOF before the broker interrupt watcher
  starts; on POSIX, SIGINT in this phase may exit `130` without JSON
- local argument previews identify their field and omitted-character count in `error.data.argument`.
  CLI error stderr escapes terminal controls. Control-bearing remedies are labelled escaped
  displays; execute the exact command from `error.data.remedy_command`, not that display
- every `lean-beam run-at` request probes one on-disk document version without changing its real
  elaboration state; Lean code can still perform external IO
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
- when `contentModified` includes `error.data.reason = "documentVersionMismatch"`,
  `error.data.accepted_version` names the broker-accepted version to retry with, and
  `error.data.current_version` may echo the current tracked document version
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
- use `result.readiness.save_ready` for sync/refresh decisions,
  `result.sync.readiness.save_ready` for save, and `result.saved.sync.readiness.save_ready` for
  close-save; use the corresponding `blocking_error_count` and blocking evidence to explain blocked
  verdicts
- when `lean-beam save` or `lean-beam close-save` returns `invalidParams` for document errors, the transport
  `error.message` includes a compact preview of underlying diagnostics and/or command messages, and
  `error.data.sync` contains the blocking sync verdict
- wrapper `stderr` is the human-facing diagnostic surface
- use MCP when a client requires structured live diagnostics or progress
- streamed diagnostics are request-scoped observations; they may carry `completion_blocking=true`,
  but save-blocking evidence is attached to the final sync/save verdict
- additional field-level progress, diagnostic, and readiness details are documented in the optional
  [online sync and save contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md)
- do not parse wrapper `stderr` in tooling
- `BEAM_PROGRESS` controls stderr progress output for slow calls
- by default, progress prints when stderr is a TTY
- set `BEAM_PROGRESS=1` to force progress output in scripts or CI
- `serve` reports elapsed preparation time when progress is enabled; its stdout readiness result
  appears only after workspace preparation completes
- `BEAM_REQUEST_ID=<id>` attaches optional request metadata to the broker request
- the final stdout JSON echoes it as `client_request_id`
- streamed stderr progress/diagnostic lines are annotated as `beam[<id>]: ...`
- a second live request using the same id is rejected with `invalidParams`
- `lean-beam cancel <id>` cancels an in-flight broker request by that request ID
- `Ctrl-C` interrupts the owning one-request connection, and the daemon cancels that exact admitted
  request when it observes the disconnect; this does not require `BEAM_REQUEST_ID`, exits nonzero,
  and does not fabricate a terminal stdout response after the connection is gone

## File Progress And Readiness

Treat `document_progress` as observability, not as proof that every call is a full barrier.

```bash
# with `lean-beam serve` running in another process
sync_out="$(lean-beam sync "Foo.lean")"
printf '%s\n' "$sync_out"
version="$(printf '%s\n' "$sync_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"

probe_out="$(lean-beam run-at "Foo.lean" "$version" 10 2 "exact trivial")"
printf '%s\n' "$probe_out"
```

Interpretation:

- after `lean-beam sync`, expect `result.document_progress.done = true`
- successful `lean-beam sync` transport does not mean the file is error-free; inspect
  `result.readiness.save_ready` for current save-readiness; use `blocking_error_count` and blocking
  evidence to explain blocked verdicts
- if you need to know whether Lean published error-severity diagnostics, inspect
  `result.diagnostics.counts.error`; do not use that field as the save/checkpoint
  decision
- if `lean-beam sync` fails with an incomplete diagnostics barrier, inspect the JSON
  `error.data.stale_direct_deps`, `error.data.save_deps`, `error.data.recovery_plan`, and
  `error.data.completion_blocking_diagnostics`; the recovery hints are based on direct imports from
  Lean's accepted header snapshot and broker sync/save history, and entries in
  `completion_blocking_diagnostics` carry `completion_blocking=true`
- `error.data.recovery_plan` is an ordered array of copyable command strings; follow the listed
  steps after checking the current state, stopping if any step fails
- follow `error.data.save_deps` only for the listed direct deps that still need checkpointing, then
  `lean-beam refresh` the stale target before relying on downstream probes
- after `lean-beam run-at`, `result.document_progress` may exist with `done = false`; that is normal
  because the request only waited for its own target snapshot
- use `lean-beam hover` or `lean-beam signature-help` for semantic inspection and
  `lean-beam goals before` / `lean-beam goals after` for existing proof state; use
  `lean-beam run-at` only when you need speculative execution
- if you need a real ready/fresh boundary after edits, use `lean-beam sync`, not a successful probe

For `syncBarrierIncomplete`, save only dependencies named by the plan as needing a checkpoint,
then refresh the target. For example, if the plan names `U.lean` and target `T.lean`:

```bash
lean-beam save "U.lean" &&
  lean-beam refresh "T.lean"
```

After refresh succeeds, inspect its diagnostics and `readiness.save_ready` before continuing. If a step fails,
saving is unsupported, or the barrier remains incomplete, stop retries and inspect upstream
diagnostics and configuration. If no plan is supplied, diagnose that failure rather than inventing
save targets or appending a build command.

External `lake build` is a separate fallback, not part of the Beam recovery plan. Before a required
external build, stop the CLI owner or drop the MCP workspace and confirm completed cleanup through
its owner or supervisor; see [the local build procedure](#before-a-local-batch-build). Create a
fresh session/workspace afterward. This targeted recovery is not a full dependency scheduler.

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
- runtime lookup never builds missing components; an unavailable project target requires explicit
  installer work before normal execution can resume
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
b_version="$(printf '%s\n' "$b_update" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"
lean-beam run-at "B.lean" "$b_version" 12 2 "#check someNameFromA"
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

### Before a local batch build

For the one-time local completion fallback, request shutdown through the original owning
installation, using the same root and session-directory selection:

```bash
"/path/to/original/installation/bin/lean-beam" --root ROOT stop
```

Repeat any `--session-dir DIR` selection on that command. A successful `stop` response acknowledges
the shutdown request; it does not establish completed cleanup. Before continuing, have the original
`serve` owner or its supervisor confirm that the owner, daemon, and all backend/helper producers
have stopped and cleanup completed successfully. For MCP, drop the workspace and establish cleanup
completion through the owning server or its supervisor instead.

If cleanup is pending, failed, or cannot be confirmed, stop and coordinate with the owner. Do not
clean or rebuild. A stop acknowledgement, cancellation, or elapsed time is not evidence of
settlement; do not recover a descriptor to bypass this prerequisite.

Only after cleanup is confirmed, discard the development checkpoints and build from the project
root:

```bash
lake clean
lake build
```

Do not run this sequence merely because Beam saved a checkpoint: successful checkpoints are
normally sufficient during the inner loop. Keep using targeted Beam probes and checkpoints instead
of repeatedly cleaning the build directory. Batch-build evidence should come from CI running `lake
build` from clean artifacts, or from this one-time local fallback when no successful clean CI result
is available.

These builds are separate from [independent proof confirmation](trust-and-validation.md).
Recreate the owning session after the batch build; do not rely on retained server state noticing
external build changes.

## Stats And Signs Of Good Use

Use:

```bash
lean-beam open-files
lean-beam stats
```

`lean-beam open-files` shows the files currently tracked by the Beam daemon for the current project,
along with on-disk `disk_status`, the daemon-recorded `checkpointed` marker, and the last compact
`document_progress` observed for that tracked version. `disk_status` is `matches_tracked`,
`differs_from_tracked`, `missing`, or `unknown`. `checkpointed` means this daemon successfully saved
the unchanged tracked version; it does not revalidate Lake artifacts. Run `lean-beam save` to
perform the authoritative Lake module, readiness, trace, and setup checks.

Stats are in-memory only and scoped to the current project Beam daemon.

The Beam daemon is helping if:

- many local probes happen before one edit
- `lake build` is not the inner loop
- stats show more `lean-beam run-at` / `lean-beam save` than full builds
