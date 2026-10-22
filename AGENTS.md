# AGENTS.md

## Purpose

This repository hosts the pre-stable Beam Lean plugin, wrapper, and local broker tooling.

Treat the repo as public but still experimental: prefer conservative, well-tested changes over
feature sprawl.

Current public status and limitations live in [docs/STATUS.md](docs/STATUS.md).
Compatibility policy lives in [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md).
User setup lives in [docs/SETUP.md](docs/SETUP.md). Exact MCP behavior lives in
[docs/MCP.md](docs/MCP.md), and exact sync/save/diagnostic behavior lives in
[docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md).

## Product Priorities

In order:

1. dead-simple public API
2. rock-solid stability
3. type-safe boundaries
4. isolation of each request
5. performance

Performance matters, but not at the cost of correctness or stability.

## Public API Guardrails

The core public request should remain conceptually:

- `runAt(pos, "lean text")`

Rules:

- no required public mode flag for command vs tactic execution
- backend selection is internal
- keep request and response structures small and typed
- use transport errors for invalid params, stale state, cancellation, and internal faults
- avoid exposing internal execution details unless a concrete client need forces it

Follow-up handle APIs exist, but they are pre-stable extensions around the basic request, not the main
story of the project.

## Execution Model

Each request should behave like an isolated sandbox:

- never mutate the document's real elaboration state
- never depend on side effects from a previous request
- never leak internal mutable state through the base API
- discard derived execution state unless the request explicitly stores a follow-up handle

## Cancellation Policy

Request cancellation is currently **soft (cooperative)** across Beam. Observe it at safe boundaries;
do not promise immediate interruption, rollback, or a universal completion deadline. An active
effect may need to settle before the request releases its resources or reports cancellation.

- cancellation signalling or a cancelled response is not proof that a producer has stopped
- retain ownership and cleanup obligations until settlement is established
- respect each operation's commit boundary; cancellation cannot undo a committed effect
- do not terminate a healthy shared backend solely to make request cancellation immediate
- treat forced shutdown and genuine delivery failure separately from ordinary cancellation

More responsive cancellation is future work, not a current guarantee or a reason to weaken safety.
See the [current caller contract](docs/STATUS.md#soft-cancellation).

## Testing Priorities

Tests matter more than cleverness.

Focus on:

- position selection and boundary behavior
- whitespace and comment positions
- proof-vs-command basis selection
- stale snapshot and file-changed behavior
- nested tactic cases
- no state leakage across requests
- cancellation behavior
- handle invalidation when handle behavior is touched

If a behavior is subtle, encode it in tests before optimizing it.

## Common Code Smells

- do not stringify typed errors or responses and later parse the rendered exception text to recover
  control flow; keep `Response`, `BrokerFailure`, or structured error data typed across
  async/pending boundaries, and stringify only at transport, CLI, or diagnostic display edges
- do not add useless backward compatibility support; this pre-stable project has no legacy users, so
  remove obsolete aliases, inferred envelope shapes, and compatibility branches unless they support
  an explicitly listed Lean/tooling/protocol version or another target named in
  [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)

## Skill Boundaries

The `lean-beam` skill is Lean-only. Rocq integration and its skill belong to the separate
[rocq-beam](https://github.com/ejgallego/rocq-beam) project; do not introduce a shared skill layer between the projects.

Keep the loaded `skills/lean-beam/SKILL.md` and MCP discovery text concise. Move optional workflow
details to `skills/lean-beam/references/` and shared MCP guidance to server instructions. Each tool
description must still make its effects and important limits clear when read on its own. Stay within
the budgets enforced by `tests/test-skill-budget.py` and `BeamTest.Broker.McpProjectionTest`.

## Public Writing

Docs, skill text, and PR descriptions should be readable without local worktree history or private
review context.

- define project-specific terms before using them as shorthand
- name concrete commands, CI jobs, fixtures, or failure codes when making testing claims
- separate current behavior from unsupported cases, planned work, and safe follow-ups
- in agent-facing skill text, prefer exact commands, stop conditions, stdout/stderr behavior, and
  known stale-state recovery paths
- do not describe aspirational or planned MCP/CLI behavior as if it already exists

## Local Tooling

The repo includes:

- `lake exe beam-daemon`
- `lake exe beam-daemon-smoke-test`
- [scripts/lean-beam](scripts/lean-beam)
- [scripts/codex-harness.sh](scripts/codex-harness.sh)
- [scripts/codex-session-start.sh](scripts/codex-session-start.sh)
- [scripts/validate-defensive.sh](scripts/validate-defensive.sh)

The Codex harness scripts are maintainer workflow helpers for this repository. They are not part of
the public `lean-beam` API or the installed skill surface.

When working locally:

- start new Codex tasks from `./scripts/codex-harness.sh session start <task-id>` so the task runs
  in a dedicated git worktree instead of the primary checkout
- let the harness keep its default persistent worktree root under
  `<repo>/.codex-worktrees/lean-beam`; do not place long-lived task worktrees under `/tmp`
- keep destructive shell cleanup scoped to owned temp/worktree paths; do not use broad `rm` or
  `rm -rf` against repo-local `.beam`, install caches, or user homes as part of normal workflows
- for LSP request / handle / scenario changes, run `bash tests/test-lsp.sh`
- for Beam broker protocol / stream / barrier changes, run `bash tests/test-beam-fast.sh` first
- for MCP stdio lifecycle or workspace-routing changes, also run
  `python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 --timeout 60`; the slow suite
  owns the longer stdio stress run
- for Beam wrapper / install / bundle-resolution changes, also run `bash tests/test-beam-slow.sh`
- for supported Lean toolchain changes, add `bash tests/test-beam-toolchain-compat.sh <toolchain>`
- for risky local install / wrapper validation, prefer `bash scripts/validate-defensive.sh` so slow
  suites run in a cloned `/tmp` sandbox with fake homes and guarded path operations
- use `bash tests/test-beam.sh` when you want the aggregate default Beam suite
- prefer the wrapper over raw LSP when the task fits
- if a file is open in the broker, do not edit it out of band
- if Lean reports stale or rebuild trouble unexpectedly, stop and surface it loudly

## Pull Request Messages

- Before opening or editing a PR, run `scripts/pr-message.sh` and use the emitted title/body
  scaffold as the source of truth.
- For macOS-sensitive changes to CI, native helpers, wrappers, installation, bundle resolution, or
  supported toolchains, request the extended fork matrix when the combined upstream job is
  insufficient: commit the task worktree, then run `python3 scripts/extended-ci.py --wait`.
  The helper uses `ejgallego/lean-beam-ci-macos` by default. See
  [extended CI guidance](docs/TESTING.md#extended-fork-ci) for fork setup and result handling.
  Check that its reported commit matches the PR head before using the result to mark a PR ready.
- Keep the public PR title/body suitable as the final squash commit message.
- Start PR bodies with a short paragraph beginning `This PR ...`; summarize the problem and useful
  outcome instead of pasting local status notes.
- Do not add generator or tool prefixes such as `[codex]` to public PR titles.
- Keep local worktree names, write-scope notes, command transcripts, and routine validation logs out
  of public PR bodies.
- Do not add a `Testing` or `Validation` section for checks that CI already runs; mention tests only
  for rare validation that CI cannot represent, and explain why that result matters to review.

Helpful repo docs:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/SETUP.md](docs/SETUP.md)
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- [docs/TESTING.md](docs/TESTING.md)
- [skills/lean-beam/SKILL.md](skills/lean-beam/SKILL.md)
