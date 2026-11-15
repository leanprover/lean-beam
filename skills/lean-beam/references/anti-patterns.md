# Lean Agent Anti-Patterns

Use this reference as a short checklist of what not to assume in Lean `beam` workflows.

## Do Not Assume

- one `lean-beam run-at` call automatically changes the basis of the next one
- `lean-beam run-at` edits the file or creates a new saved baseline
- `lean-beam run-at` implies a full-file diagnostics barrier
- `lean-beam run-at` fills indentation, inserts missing newlines, or reformats text for you
- `lean-beam sync` recovers speculative text that you never wrote into the file
- `lean-beam save` is valid for any `.lean` file the daemon can open
- a successful `lean-beam save` is equivalent to a fresh batch build
- a downstream probe is trustworthy right after editing an imported dependency
- wrapper `stderr` is the machine-readable surface
- creating a `/tmp` scratch Lean file for a question that belongs at a real source position
- batching unrelated proof attempts into one scratch file just to amortize Lean startup
- treating a detached scratch file success as equivalent to success in the workspace module context

## Prefer Instead

- use `lean-beam hover` and `lean-beam signature-help` for existing semantic info
- use `lean-beam definition`, `lean-beam references`, `lean-beam document-symbols`, and
  `lean-beam workspace-symbols` for semantic navigation
- use `lean-beam goals before` / `lean-beam goals after` for existing proof state
- use `lean-beam run-at` for one speculative snippet on an explicit broker document version
- probe at the real source position with `lean-beam run-at`
- pass multiline speculative text with `--stdin` instead of writing a temporary Lean file
- use `lean-beam run-at-handle` plus `lean-beam run-with` / `lean-beam run-with-linear` for exact speculative chaining
- use a real edit, save, then `lean-beam sync` when the speculative result should become source
- use `lean-beam save` only for a synced workspace module
- use MCP when a client requires machine-readable live diagnostics or progress
- for dependency edits, sync the dependency, require save readiness, checkpoint it, then refresh
  the importer in the same CLI session or MCP workspace; inspect diagnostics and readiness before
  probing again; see the [dependency workflow](workflow-details.md#dependency-edits-and-rebuild-boundary)
- rely on successful Beam checkpoints for ordinary local development, and use a clean CI
  `lake build` for batch-build evidence
- when no successful clean CI result is available or server-sensitive elaboration is suspected,
  follow the [local batch-build procedure](workflow-details.md#before-a-local-batch-build): stop all
  affected CLI owners and drop affected MCP workspaces, then confirm cleanup before `lake clean`
  and `lake build`; if cleanup is pending, failed, or unconfirmed, stop and coordinate
- distinguish batch-build evidence from [independent proof confirmation](trust-and-validation.md);
  readiness, empty goals, and checkpoint success do not replace the latter
