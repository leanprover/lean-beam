---
name: lean-beam
description: Work on external Lean projects through the installed `lean-beam` wrapper, using speculative checks and zero-build module checkpoints instead of repeated inner-loop builds.
---

# Lean Beam

Beam provides speculative Lean probes in the real module environment and zero-build module
checkpoints. This skill is Lean-only.

Use the CLI or MCP tools, not raw LSP. Bundled CLI examples need `elan run SELECTOR lean-beam`
instead of bare `lean-beam`; see [setup and sessions](references/setup-and-recovery.md#installation).
MCP owns its sessions; do not start `lean-beam serve` for MCP calls.

## Session (CLI only)

```bash
lean-beam serve                  # keep one owner running
lean-beam --root ROOT stop       # when finished (or interrupt serve)
```

- Document commands attach to a live `serve` owner and never start one implicitly.
- In a read-only or sandboxed tree, set `BEAM_SESSION_ROOT` to a writable directory.
- After Lake/toolchain/option changes, stop the owner, confirm cleanup (`status` is `absent`), and
  start a new `serve`; `refresh` does not reload workspace config.

## The Edit Loop

Beam only reads saved `.lean` files and never edits them.

1. Edit and save the file with your own tools.
2. Run `lean-beam sync Foo.lean` (MCP: `lean_sync`) — updates the mirror, waits for diagnostics, and
   returns `version`, `save_ready`, and `blocking_diagnostics` (omit MCP `diagnostics_in_result`
   while fixing errors; set `true` only for warnings).
3. When stuck on a proof, probe against that `version` with `run-at`, `goals`, or `todo`. Use
   `update` only to grab a fresh `version` without waiting for diagnostics.
4. Optionally `lean-beam save MyPkg/Sub/Module.lean` to checkpoint one synced module.

```bash
lean-beam sync Foo.lean                    # returns result.version and readiness; add +all-diagnostics for warnings
lean-beam goals before Foo.lean 1 10 2
lean-beam run-at Foo.lean 1 10 2 "omega"
printf 'first | omega | simp\n' | lean-beam run-at Foo.lean 1 10 2 --stdin
lean-beam save MyPkg/Sub/Module.lean
```

- Always pass the `version` returned by the latest `sync`, `update`, or `refresh`; never guess it.
- Use `refresh` after an upstream dependency changed; `save` checkpoints only one module (does not
  validate importers, and records the server environment).
- Cancellation is soft: client exit does not prove backend settlement or undo a committed save.
  For `close-save` overlap or post-commit recovery, see
  [troubleshooting](references/troubleshooting.md#sync-and-save-failures).
- Do not call `stats`, `doctor`, or `open-files` during routine work; use them only when
  diagnosing failures.

## Commands

| Need | Command |
|---|---|
| Sync file, get diagnostics + version | `sync` (or `refresh` after upstream dep edits; `update` for version only) |
| Try Lean text without editing | `run-at FILE VERSION LINE CHAR TEXT` (`--stdin`, `--text-file`, `--profile`) |
| Proof state at a tactic | `goals before\|after FILE VERSION LINE CHAR` |
| Sorries, holes, errors, code actions | `todo FILE VERSION [SL SC EL EC]` |
| Checkpoint one synced module | `save`, `close-save` |
| Types / navigation / symbols | `hover`, `signature-help`, `definition`, `references`, `document-symbols`, `workspace-symbols` |
| Exact multi-step speculation (handles) | `run-at-handle`, `run-with`, `run-with-linear`, `release`, `lean-beam-search` |

## run-at Rules

`run-at` means "try this Lean text here", not "edit the file here".

- Positions are 0-based LSP coordinates (`line`, UTF-16 `character`); empty lines allow only char `0`.
- To replace a tactic, probe at its first character after indentation (before-state).
- Probes are isolated in elaboration state (safe in parallel) but not an OS sandbox (Lean code may
  perform IO). `run-at` returns no file diagnostics; edit and `sync` to commit and check the file.
- Command positions accept one command; tactic positions accept a tactic sequence (same column or
  `;`). Do not start tactic text with `by`; Beam does not re-indent (use `--stdin` for multiline).
- At `sorry`, `_`, or `?x` (or a `todo` item's `run_at_position`), `run-at` starts from its goal.
- Tactic probes reject new local `let rec`; save the enclosing declaration and `sync` instead.

## Output & Stop Rules

- Check exit status first. Completed CLI calls print one JSON object on stdout; stderr is human
  progress/diagnostics (never parse it).
- Check `result.success` (MCP: `isError` absent/false and `structuredContent.success` true) and
  `readiness.save_ready`. CLI errors use `error.data`; MCP tool errors use `structuredContent.data`.
- Before `lake build`, stop affected CLI owners and drop affected MCP workspaces, confirm cleanup,
  then recreate them afterward. Prefer clean CI `lake build` for batch validation; do not repeat
  full builds after every checkpoint.
- On `syncBarrierIncomplete`, setup/transport errors, or stalled calls, read
  [troubleshooting](references/troubleshooting.md) before retrying or resetting.
- Checkpoint readiness can include `sorry` warnings and is not independent proof confirmation; see
  [trust and validation](references/trust-and-validation.md) when adversarial checking is needed.

## References

Open only when needed:

- [Workflow details](references/workflow-details.md): positions, handles, code actions, batch fallback
- [Profiling](references/profiling.md): `--profile` / `profile: true` timing scope and span summaries
- [Run-at examples](references/lean-run-at-semantics.md): common mistakes, local recursion
- [Commit a probe](references/commit-speculative.md): turning a probe into a saved edit
- [Handle search](references/mcts-search.md): branching, linear playouts, release patterns
- [Anti-patterns](references/anti-patterns.md): assumptions to avoid
- [Setup and sessions](references/setup-and-recovery.md): installation, sandbox permissions, ownership
- [Troubleshooting](references/troubleshooting.md): sync barriers, stalls, recovery
