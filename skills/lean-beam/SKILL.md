---
name: lean-beam
description: Work on external Lean projects through the installed `lean-beam` wrapper, using speculative checks and zero-build module checkpoints instead of repeated inner-loop builds.
---

# Lean Beam

Speculative Lean probes in the real module environment plus zero-build module checkpoints (Lean-only).
Use CLI or MCP, not raw LSP. Bundled CLI uses `elan run SELECTOR lean-beam`; MCP owns its sessions
(never run `lean-beam serve` for MCP).

## Session (CLI only)

```bash
lean-beam serve                  # keep one owner running
lean-beam --root ROOT stop       # closes docs and stops owner
```

- Document commands attach to a live `serve` owner and never start one implicitly.
- Set `BEAM_SESSION_ROOT` to a writable directory in read-only or sandboxed trees.
- After Lake/toolchain/option changes, stop the owner, confirm `status` is `absent`, and restart
  `serve` (`refresh` does not reload workspace config).

## Inner Loop

Beam only reads saved `.lean` files and never edits them.

1. Edit and save the `.lean` file with your own tools.
2. Sync to update the mirror, wait for diagnostics, and get `version`, `save_ready`, and
   `blocking_diagnostics`:
   ```bash
   lean-beam sync Foo.lean                  # add +all-diagnostics for warnings
   lean-beam run-at Foo.lean 1 10 2 "omega" # or --stdin / --text-file / --profile
   lean-beam save MyPkg/Sub/Module.lean     # optional zero-build checkpoint (one module)
   ```
   (MCP: call `lean_sync` without `diagnostics_in_result` while fixing errors; set `true` only to
   check warnings.)
3. Always pass the `version` returned by the latest `sync`, `update`, or `refresh` (use `update`
   only to get a version without waiting for diagnostics; `refresh` after upstream dependency edits).
4. Other commands when needed: `goals before|after`, `todo`, `close-save`, `hover`,
   `signature-help`, `definition`, `references`, `document-symbols`, `workspace-symbols`, handles
   (`run-at-handle`, `run-with`, `run-with-linear`, `release`, `lean-beam-search`).
5. Do not call `stats`, `doctor`, or `open-files` during routine work; use only for failure triage.

## `run-at` Rules

`run-at` means "try this Lean text here", not "edit the file here".

- 0-based LSP coordinates (`line`, UTF-16 `character`); empty lines allow only char `0`.
- To replace a tactic, probe at its first char after indentation. At `sorry`, `_`, or `?x` (or a
  `todo` item's `run_at_position`), `run-at` starts from that goal.
- Isolated in elaboration state (safe in parallel), not an OS sandbox (Lean code may run IO).
  Returns no file diagnostics; edit and `sync` to commit.
- Command positions take one command; tactic positions take a tactic sequence (same column or `;`,
  no leading `by`, no re-indent — use `--stdin` for multiline). Tactic probes reject new local
  `let rec` (save and `sync` instead).

## Output, Cancellation & Stop Rules

- Check exit status first. CLI prints one JSON object on stdout; stderr is human diagnostics (do not
  parse). Verify `result.success` (MCP: `isError` absent/false, `structuredContent.success` true)
  and `readiness.save_ready`. Errors live in `error.data` (MCP: `structuredContent.data`).
- Cancellation is soft: client exit does not prove backend settlement or undo a committed save.
- Before `lake build`, stop CLI owners / drop MCP workspaces, confirm cleanup, then recreate
  afterward. Prefer clean CI `lake build` over rebuilding after every checkpoint.
- `save_ready` can include `sorry` warnings and is not adversarial proof confirmation.

## References (open only when needed)

- [Workflow details](references/workflow-details.md) · [Profiling](references/profiling.md) ·
  [Run-at examples](references/lean-run-at-semantics.md) ·
  [Commit a probe](references/commit-speculative.md) ·
  [Handle search](references/mcts-search.md) · [Anti-patterns](references/anti-patterns.md) ·
  [Setup & sessions](references/setup-and-recovery.md) ·
  [Troubleshooting](references/troubleshooting.md) (read before retrying `syncBarrierIncomplete` or stalls)
