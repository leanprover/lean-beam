---
name: lean-beam
description: Work on external Lean projects through the installed `lean-beam` wrapper, using speculative checks and zero-build module checkpoints instead of repeated inner-loop builds.
---

# Lean Beam

Beam provides speculative Lean probes in the real module environment and zero-build module
checkpoints. This Lean-only skill includes its linked references.

Use the `lean-beam` wrapper, not raw JSON or raw LSP. If your client exposes the `lean-beam-mcp`
tools (`lean_run_at`, `lean_sync`, ...), the same rules apply; MCP owns its session automatically,
so do not start `lean-beam serve` for MCP calls.

## Session

```bash
# keep one foreground owner running for the project (separate terminal or background process)
lean-beam serve
# when finished: interrupt it, or
lean-beam --root ROOT stop
```

- Document commands attach to a live `serve` owner and never start one implicitly. `doctor`, help,
  and version inspection can run without an owner.
- In a read-only or sandboxed tree, set `BEAM_SESSION_ROOT` to a writable directory.
- After editing a lakefile, manifest, Lean options, plugins, or other Lake configuration, run
  `lean-beam --root ROOT stop` and start a new `serve`; `refresh` does not restart the server.
- If startup, toolchain selection, or session state looks wrong, run `lean-beam doctor` before
  guessing. See [setup and recovery](references/setup-and-recovery.md).

## The Edit Loop

Beam reads only the on-disk file and never edits `.lean` sources; you edit files with your own tools.

1. Edit and save the file.
2. `lean-beam update Foo.lean` and take `result.version` from its JSON.
3. Probe with that version (`run-at`, `goals`, `hover`, ...).
4. `lean-beam sync Foo.lean` when you need diagnostics and readiness (`result.readiness.save_ready`;
   MCP: `structuredContent.readiness.save_ready`).
5. Optionally `lean-beam save MyPkg/Sub/Module.lean` to checkpoint a synced workspace module.

```bash
version="$(lean-beam update Foo.lean | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"
lean-beam goals before Foo.lean "$version" 10 2
lean-beam run-at Foo.lean "$version" 10 2 "omega"
printf 'first | omega | simp\n' | lean-beam run-at Foo.lean "$version" 10 2 --stdin
lean-beam sync Foo.lean            # errors stream on stderr; add +all-diagnostics for warnings
lean-beam save MyPkg/Sub/Module.lean
```

- Every version-bound command needs the version from the latest `update` or `sync`. On
  `contentModified` with `error.data.reason = "documentVersionMismatch"`, retry with
  `error.data.accepted_version` or run `update` again; never guess a version.
- Cancellation is soft: interrupting the client does not prove backend work has stopped. Active
  preparation may finish before cleanup; cancellation does not undo committed effects. Do not remove
  temporary files solely because the client exited.
- Use `refresh` for fresh diagnostics after an upstream dependency changed; it reads before reopening.
- `save` checkpoints only that module. It does not validate importers, and it records the Lean
  server's environment, which can differ from batch elaboration. Modules with batch-only
  `moreLeanArgs` fail with `saveUnsupportedSetup`; move shared `-D` settings to `leanOptions`, or
  use `lake build` when the arguments are intentionally batch-only.
- If `close-save` fails with `error.data.reason = "savedDocumentChanged"`, `error.data.saved` is an
  already committed checkpoint of the earlier version; run `update` or `sync` and save again if
  needed.

- `close-save` reserves the accepted document. On `contentModified` with reason `documentClosing`,
  coordinate with its caller before issuing a new command; do not run an update/sync retry loop.
  During claimed canonical publication, same-workspace changes wait for settlement.
- `documentAdmissionExpired` means closure or backend replacement invalidated this request. After
  coordination, issue a new request and reacquire handles if the backend was replaced.
- Other postcommit failures also retain `error.data.saved`, with prior data under
  `error.data.original_data`. An uncertain close does not assert `closed = false`; cancellation does
  not undo a committed checkpoint.

## Choosing A Command

| Need | Command |
|---|---|
| Proof state at a tactic | `goals before FILE VERSION LINE CHAR` (or `goals after`) |
| Try Lean text without editing | `run-at FILE VERSION LINE CHAR TEXT` (or `--stdin`, `--text-file`) |
| Continue from an exact speculative state | `run-at-handle`, then `run-with` / `run-with-linear`, `release` |
| Type and docs at a position | `hover`, `signature-help` |
| Navigation and symbols | `definition`, `references`, `document-symbols FILE VERSION`, `workspace-symbols QUERY` |
| Sorries, holes, errors, code actions in a range | `todo FILE VERSION SL SC EL EC` |
| Fresh diagnostics after a real edit | `sync` (or `refresh`) |
| Checkpoint one synced module | `save`, `close-save` |
| Daemon or tracked-file trouble | `open-files`, `doctor`, `stats` |
| Shell search loops over handles | `lean-beam-search` |
| Bug report card | `feedback-report` (see [feedback](references/feedback.md)) |

Handles are pre-stable: use them only when exact continuation matters. They are invalidated by
edits to the same document, close, worker restart, or daemon restart.

For `todo --kind code_action`, query a point inside the relevant tactic, hole, or diagnostic, or a
range within one command. Lean selects one command snapshot using the range end; broad ranges do
not enumerate every command's actions, and an empty result is not a file-wide verdict.
For a point query, use `lean-beam todo FILE VERSION LINE CHAR LINE CHAR --kind code_action`.

## run-at Rules

`run-at` means "try this Lean text here", not "edit the file here".

- Positions are LSP coordinates: line and character are zero-based, characters count UTF-16 code
  units, and on an empty line only character `0` is valid.
- To replace a tactic, probe at its first character after indentation (its before-state).
- Each probe is isolated and starts from the version it names, so independent probes can run in
  parallel. This isolates elaboration state, not external effects: Lean code may perform IO.
- Command positions accept one command; for several, use handles or edit the file and `sync`.
- Pass the exact text Lean should parse, including indentation and newlines; prefer `--stdin` for
  multiline text. Beam does not re-indent.
- At a tactic position, the text may be a tactic sequence: start each tactic at the same column, or
  separate them with `;`. Do not start it with `by`; the probe already runs inside the proof.
- At an unfilled `sorry`, `_`, or `?x` term, run-at starts from its goal; text is still tactics.
- `run-at` returns no file diagnostics; use `sync` after a real edit for those.
- Tactic probes reject new local `let rec` definitions, even valid ones. Save the
  enclosing declaration and `sync` instead, or probe one complete declaration at a command position.

Prefer small probes at the real source position. Scratch files reload imports and lose context;
use them only for context-free syntax checks.

## Output Contract

- Check the exit status first. Completed broker operations print one JSON object on stdout.
- A successful transport does not mean a successful Lean probe: inspect `result.success` for wrapper
  probes. For MCP probes, require `isError` to be absent or false and `structuredContent.success` true.
- stderr is for humans: progress and streamed diagnostics. Never parse it. Selector, setup, or
  transport failures may print only to stderr.
- `sync` failures carry structured `error.data`; save failures with document errors put the
  blocking verdict in `error.data.sync`.

## When To Stop Probing

Before `lake build`, stop the CLI owner or drop the MCP workspace and wait for cleanup;
recreate the session afterward.

- The probe result should become real source: edit, save, `update`/`sync`.
- Probes stop clarifying the problem: change approach rather than repeating variants.
- `save` fails with `saveImportsChanged`: `refresh`, then save.
- `sync` fails with `syncBarrierIncomplete`: follow `error.data.recovery_plan`, saving only the
  listed `error.data.save_deps` and refreshing the target. If it repeats across several dependency
  hops, run `lake build`.
- You edited a dependency and need trustworthy importers: `save` is not enough; rebuild.
- `contentModified`, stale state, or rebuild trouble keeps appearing unexpectedly: inspect
  `open-files` and `doctor`, then stop and report it rather than working around it.

Batch-build evidence comes from a clean `lake build`, normally in CI. When no successful clean CI result
is available, or server-sensitive elaboration is suspected, run once outside the inner loop:
`lean-beam --root ROOT stop && lake clean && lake build`. Do not do this after every checkpoint.

Beam is a non-adversarial development tool. Checkpoint readiness can include `sorry` warnings; it
is not proof acceptance. For independent confirmation, use the separate
[trust and proof confirmation workflow](references/trust-and-validation.md), including a trusted
challenge and external checkers. Do not add it to every inner-loop operation.

## References

Open as needed:

- [Workflow details](references/workflow-details.md): positions, handles, text inputs, save eligibility,
  diagnostics, request IDs, progress, dependency edits
- [Run-at examples](references/lean-run-at-semantics.md): common mistakes, including local recursion
- [Commit a probe](references/commit-speculative.md): turning a good probe into a saved edit
- [Handle search](references/mcts-search.md): branching, linear playouts, release patterns
- [Anti-patterns](references/anti-patterns.md): assumptions to avoid
- [Setup and recovery](references/setup-and-recovery.md): installation, runtime identity, ownership, recovery
- [Feedback](references/feedback.md): report input and confidentiality
