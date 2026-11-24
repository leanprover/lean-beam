# Lean Workflow Details

Use this reference when a task needs details beyond the default loop in `SKILL.md`.

Error paths below use CLI notation (`error.data`). For MCP tool failures with `isError: true`, read
the same fields under `structuredContent.data`; JSON-RPC transport errors use a separate envelope.

## Position Semantics

- `run-at` and `run-at-handle` take `<version> <line> <character>` using the version returned by
  `sync`, `update`, or `refresh`.
- `line` is 0-based; `character` is a 0-based UTF-16 code unit offset.
- Empty lines allow only character `0`. On an indented blank line, either probe at the existing
  column offset or probe at character `0` and include the indentation in the text.
- `position ... is outside the document` means the coordinate is out of bounds for the saved file;
  `no command or tactic snapshot` means Lean has no usable execution basis there (common on
  standalone comments, blank lines, and declaration headers). Neither implies an unhealthy daemon.
- To replace a tactic, probe at its first character after indentation (before-state); inside or at
  the end of a simple tactic, Lean usually selects the after-state.
- At an unfilled `sorry`, `_`, or `?x`, the probe runs tactics against that placeholder's goal
  (use `exact t` for a term). Only that placeholder's type is checked.
- Probes check text against the selected goal without running declaration-level termination checks,
  so a probe referencing the enclosing declaration can succeed even when the real edit fails; always
  confirm with a real edit and `sync`.

Example `BeamRunAtProbe.lean`:

```lean
example (a b : Nat) (h : a = b) : 0 + a = b := by
  simp
  exact h
```

| Position `(line, char)` | Selected state | Probe `exact h` |
| --- | --- | --- |
| `1 2` (start of `simp`) | Before `simp`: `0 + a = b` | Fails |
| `1 3` (inside `simp`) | After `simp`: `a = b` | Succeeds |
| `2 2` (start of `exact h`) | Before `exact h`: `a = b` | Succeeds |

`goals before` / `goals after` inspect both sides of a tactic without affecting later `run-at` calls.

### Todo ranges and point queries

- `todo FILE VERSION` inspects the whole file; `todo FILE VERSION SL SC EL EC` restricts to a range.
- Goal-bearing items with both `run_at_position` and `proof_state` can be probed directly at
  `run_at_position`. When `run_at_position` is omitted, edit the source to expose those goals.
- Nonempty ranges use half-open overlap (end excluded). An empty range (`SL SC == EL EC`) is a point
  query matching items containing that point, including their end.
- Code actions require an explicit range: Lean selects one command snapshot from the range end.
  Query a point inside the relevant syntax or a range within one command; an empty result does not
  prove whole-file completeness.

## Command Details

Handles (for exact speculative continuation; see [mcts-search.md](mcts-search.md)):

```bash
lean-beam run-with "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam run-with-linear "Foo.lean" --handle-file handle.json "exact trivial"
lean-beam release "Foo.lean" --handle-file handle.json
# or pipe handle JSON on stdin with `-`
```

- Profiling (`--profile` / MCP `profile: true`): see [profiling.md](profiling.md).
- Search helper: `lean-beam-search mint|branch|playout|release` wraps handle commands for shell loops.
- Read-only inspection & navigation: `goals before|after`, `hover`, `signature-help`, `definition`,
  `references` (waits for full elaboration like `sync`), `document-symbols`, and `workspace-symbols`
  (no document version).
- Checkpoints: `lean-beam save "MyPkg/Sub/Module.lean"` and `lean-beam close-save "MyPkg/Sub/Module.lean"`.
  Structured Lake options, dynamic libraries, and plugins applied by the file worker are supported.
  Batch-only `moreLeanArgs` fail with `saveUnsupportedSetup` (move shared `-D` flags to
  `leanOptions`, or use `lake build` after [cleanup](#before-a-local-batch-build)). If an import
  changed on disk after the worker loaded it, `save` fails with `saveImportsChanged`; run `refresh`
  and retry `save`.
- Lake workspace config changes (lakefile, manifest, `lean-toolchain`, options, plugins, dylibs)
  are not reloaded by `refresh`; stop the owner (or drop the MCP workspace) and restart.

## Save Eligibility

Valid `save` / `close-save` targets:
- synced successfully and belongs to the current Lake workspace package graph (resolves to a module).
- `save` writes Lean/Lake build artifacts for that module; it never edits `.lean` source.

Not valid: standalone `.lean` files outside the Lake package module graph (valid for `sync`, not `save`).

## Source-File And Execution Model

- Beam reads only saved `.lean` files on disk and never edits source.
- Default inner loop: edit & save → `sync` (returns diagnostics, readiness, and `version`); probe
  with `run-at` / `goals` / `todo` against that `version`. Use `update` only when you want a fresh
  `version` without waiting for diagnostics.
- `--text-file` and `--handle-file` require regular files (symlinks to regular files allowed); use
  `--stdin` or `-` for streaming. Input is read to EOF before the interrupt watcher starts.
- Local argument errors report omitted character counts in `error.data.argument`; control-bearing
  remedies on stderr are escaped displays—execute the exact argv from `error.data.remedy_command`.
- Same-document edits invalidate pending requests/handles (`contentModified` with
  `documentVersionMismatch` gives `error.data.accepted_version`).
- For transport/session/document-state errors, read
  [CLI troubleshooting](troubleshooting.md#cli-transport-and-session-recovery).

## Diagnostics, Progress, And Request IDs

- `sync`, `refresh`, `save`, and `close-save` stream fresh request-scoped diagnostics on CLI stderr
  (errors by default; add `+all-diagnostics` for warnings/info/hints). Do not parse stderr.
- Check `result.readiness.save_ready` (`result.sync.readiness.save_ready` for `save`,
  `result.saved.sync.readiness.save_ready` for `close-save`). Failed `save` / `close-save` due to
  document errors returns `invalidParams` with `error.data.sync`.
- Use MCP when structured live diagnostics (`lean.diagnostic`) or progress (`_meta.progressToken`)
  are needed. See the
  [online sync and save contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md).
- `BEAM_PROGRESS=0|1` overrides TTY-based stderr progress lines.
- `BEAM_REQUEST_ID=<id>` tags a CLI request (`client_request_id` in stdout JSON; `beam[<id>]:` on
  stderr) and enables `lean-beam cancel <id>`. `Ctrl-C` cancels the active one-request connection
  without requiring `BEAM_REQUEST_ID`.

## File Progress And Readiness

Treat `document_progress` as observability, not proof of a full barrier:

- After `sync`, expect `result.document_progress.done = true`. Successful transport does not mean
  error-free: inspect `result.readiness.save_ready`, `blocking_error_count`, and blocking diagnostics
  (use `result.diagnostics.counts.error` only if you specifically need error-severity counts).
- After `run-at`, `document_progress.done = false` is normal (it waits only for its target snapshot).
- On `syncBarrierIncomplete`, entries in `completion_blocking_diagnostics` mark `completion_blocking=true`;
  follow [sync barrier recovery](troubleshooting.md#sync-barrier-recovery).

## Cost Model

- Once a per-root daemon (or MCP workspace) and target document are warm, `run-at`, `goals`, and
  navigation probes are cheap local checks against the saved snapshot and can run in parallel.
- Avoid detached `/tmp` scratch files for module-context questions: they reload imports from cold
  state and miss local options/instances/proof context.
- `sync` sends the full document text (`O(N)`), not just the diff (`O(C)`), and `save` checkpoints
  one module without rebuilding reverse dependencies. The win is avoiding repeated cold `lake build`
  loops and isolating proof exploration.

## Dependency Edits And Rebuild Boundary

If `B.lean` imports `A.lean`, checkpoint the dependency before refreshing the importer in the same
CLI session or MCP workspace:

```bash
lean-beam sync "A.lean"
# confirm ok=true and readiness.save_ready=true, then:
lean-beam save "A.lean" && lean-beam refresh "B.lean"
```

Stop on any failure, then inspect `B.lean`'s diagnostics, readiness, and new `version`. Save any
edits to `B.lean` before `refresh`. Repeat in dependency order for other importers you use; CLI and
MCP runtimes are separate and do not share checkpoints until saved and refreshed.

### Before a local batch build

Do not run `lake build` while Beam retains the affected workspace. First stop every affected CLI
owner (from its original installation, with matching `--root` and `--session-dir`) and drop every
affected MCP workspace:

```bash
"/path/to/original/installation/bin/lean-beam" --root ROOT stop
```

`stop` only acknowledges shutdown; before building, have the original owner or supervisor confirm
that the owner, daemon, and all backend/helper processes have stopped and cleaned up (do not rely on
cancellation, elapsed time, or `recover` to bypass cleanup).

Once cleanup is confirmed:
- For ordinary recovery (including batch-only `moreLeanArgs`), run `lake build` from the project root.
- For clean batch evidence, prefer CI `lake build`; if a local clean build is required, run
  `lake clean && lake build` once, then recreate the affected sessions afterward.
- For independent proof confirmation, see [trust-and-validation.md](trust-and-validation.md).

## Stats And Signs Of Good Use

`lean-beam open-files` and `lean-beam stats` (MCP: `beam_stats`) are debugging/telemetry tools—do
not call them during routine authoring turns.

- `open-files` reports each tracked file's `disk_status` (`matches_tracked`, `differs_from_tracked`,
  `missing`, `unknown`), `checkpointed` marker (daemon-recorded, not a Lake trace check), and last
  `document_progress`.
- `stats` reports in-memory per-daemon request counts and latencies.
