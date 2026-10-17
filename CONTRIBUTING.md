# Contributing

This repository is public but still pre-stable. Favor conservative, well-tested changes over feature
sprawl.

## Workflow

- prefer short branches and small PRs
- start with an issue or RFC-sized discussion before larger changes
- run the smallest relevant local suite before opening a PR
- keep user-facing docs aligned with behavior when the workflow surface changes
- do not treat the broker as a replacement for Lake; when behavior gets too build-system-specific,
  say so explicitly in the PR

For local AI-first workflow guidance, see [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
For agent-specific runtime instructions, see [AGENTS.md](AGENTS.md).

## Documentation

Public docs should be readable without local worktree history or private review context. Prefer
compact prose, but do not compress several policies or failure modes into one abstract phrase.

Keep source-of-truth boundaries clear:

- user setup, supported toolchains, first CLI use, MCP setup, installer locations, and offline notes
  belong in [docs/SETUP.md](docs/SETUP.md)
- public beta scope, limitations, and direction belong in [docs/STATUS.md](docs/STATUS.md)
- exact MCP implementation, protocol, tool-list, and conformance notes belong in
  [docs/MCP.md](docs/MCP.md)
- exact sync, save, progress, diagnostics, readiness, and stale-version behavior belongs in
  [docs/SYNC_AND_DIAGNOSTICS.md](docs/SYNC_AND_DIAGNOSTICS.md)

Guidelines:

- put one decision, expectation, or limitation in each sentence
- define Beam-specific terms before using them as shorthand
- make testing claims concrete by naming the command, CI job, scenario, fixture, or failure code
- separate what exists now from what is intentionally unsupported, planned, or a safe follow-up
- use examples when documenting a subtle policy, failure mode, or recovery path

## Commits

Follow Lean upstream's commit-message shape:

```text
<type>: <subject>

<body>
```

Supported `<type>` values:

- `feat`
- `fix`
- `doc`
- `style`
- `refactor`
- `test`
- `chore`
- `perf`

Guidelines:

- use imperative, present tense
- do not capitalize the first letter in the subject
- do not end the subject with a period
- keep the first line concise and behavior-oriented
- mention the user-visible behavior or subsystem being changed
- use the body to explain motivation and contrast with previous behavior when that context matters
- avoid mixing unrelated changes into one commit when the diff can be split cleanly

Examples:

- `fix: improve refresh and stale dependency recovery`
- `fix: improve save readiness reporting`
- `doc: split human-facing README from contributor workflow guidance`

This repository does not yet enforce Lean's `changelog-*` label process.

## Changelog Entries

Add user-facing changes under the appropriate subsection of `CHANGELOG.md`'s `Unreleased` section.
Keep each entry outcome-oriented and end it with the pull request number and primary author's GitHub
handle in this form:

```markdown
- Describe the user-visible outcome
  ([#216](https://github.com/leanprover/lean-beam/pull/216), @ejgallego).
```

Use the pull request author unless the contributors agree that another primary author is more
accurate. Related changes from one pull request may share one entry; unrelated user-visible changes
should remain separate. Documentation-only maintenance does not need an entry unless it changes
public guidance or records a compatibility or behavior correction.

## Pull Requests

PRs should make review cheap and should also read well as the final squash commit message.
Before opening or editing a PR, run:

```sh
scripts/pr-message.sh
```

Use the emitted title/body scaffold as the public PR metadata. Do not hand-roll the PR body from
local status notes or validation transcripts.

When the combined upstream job is insufficient for a macOS-sensitive change, use
`python3 scripts/extended-ci.py --wait` from a clean, committed worktree before marking the PR ready.
See [extended fork CI](docs/TESTING.md#extended-fork-ci) for setup and how to associate a result with
the exact PR revision.

Guidelines:

- use the commit convention for the PR title: `<type>: <subject>`
- start the PR body with a short paragraph beginning `This PR ...`
- summarize the problem and useful outcome in the body itself; issue links are not a substitute
- add a few bullets only for behavior, compatibility, review risk, or maintainer-visible workflow
  changes
- keep local worktree names, write-scope notes, and routine command transcripts out of the public
  body
- do not add a `Testing` or `Validation` section for routine checks that CI already runs
- treat CI as the validation record; mention tests only for rare validation that CI cannot represent,
  and explain why that result matters to review
- put questions and extra coordination in PR comments rather than the PR description

If the change affects the wrapper, install flow, bundle resolution, or broker protocol, say that
explicitly.

## Author Identity

Use the repository's Lean work identity for authored commits unless there is a deliberate reason not
to:

- `Emilio Jesus Gallego Arias <emilio@lean-fro.org>`

Keep author and committer identity consistent for normal local commits.

## Test Guidance

Use the smallest relevant suite first:

- `bash tests/test-lsp.sh`: the full LSP/plugin surface, including all registered LSP methods
- `bash tests/test-beam-fast.sh`: Beam broker stream, barrier, and request-contract changes
- `python3 tests/test-mcp-stdio.py --iterations 1 --restart-cycles 1 --timeout 60`: focused MCP stdio
  lifecycle and workspace-routing coverage
- `bash tests/test-beam-slow.sh`: Beam wrapper, save replay, and bundle-resolution changes
- `bash tests/test-beam-install.sh`: installer, complete runtime layout, immutable reuse, and `doctor`
- `bash tests/test-beam-toolchain-compat.sh <toolchain>`: supported-toolchain bundle validation
- `bash tests/test-beam.sh`: aggregate default Beam surface
- `bash tests/test-maintainer.sh`: maintainer harness and defensive-validation helpers
- `bash scripts/lint-shell.sh`: shell wrappers, installer, and shell tests

Focused stdio, wrapper, and save scripts require `BEAM_TEST_INSTALLATION` to name a concrete
constructed installation containing their project targets. `tests/test-beam-slow.sh` constructs
that installation automatically; see [the test fixture guidance](docs/TESTING.md#beam-surface) for
focused runs.

More detail lives in [docs/TESTING.md](docs/TESTING.md).
