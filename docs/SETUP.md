# Setup

Use this document as the single path from a Lean Beam checkout to a working `lean-beam` command.
It covers installation, validated and compatible Lean toolchains, first CLI use, MCP registration,
installer locations, and offline setup notes.

Lean Beam setup has two separate locations:

- the Lean Beam checkout, where you run the installer once
- the Lean project you want to work on, where you run the installed `lean-beam` wrapper

You do not add Lean Beam to the target project's `lakefile`, and you do not install a copy into each
project. The wrapper detects the target project root from the current directory or `--root`.

## Install Beam From This Checkout

The current public distribution path starts from a Lean Beam source checkout. To install a specific
release, check out that tag first, then run the installer from the checkout root.

From a Lean Beam checkout, run one installer command that matches how you plan to use it:

```bash
./scripts/install-beam.sh            # CLI and MCP wrappers only
./scripts/install-beam.sh --codex    # wrappers plus Codex skills
./scripts/install-beam.sh --claude   # wrappers plus Claude Code skills
./scripts/install-beam.sh --pi       # wrappers plus Pi Agent skills
./scripts/install-beam.sh --opencode # wrappers plus OpenCode skills
./scripts/install-beam.sh --vibe     # wrappers plus Mistral Vibe skills
./scripts/install-beam.sh --all-skills # wrappers plus every supported agent skill
```

The default installer is interactive: it asks which Lean toolchains, agent skills, and
MCP client registrations to set up. It then shows a compact write summary and asks once for the Beam
runtime/wrapper install area, selected skill locations, and selected MCP config locations. For
non-interactive scripts, pass `--dont-ask`; this only skips prompts for requested Beam-owned
install/config paths and does not allow replacing unrelated user files.

These forms install:

- `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` into `~/.local/bin`
- an immutable runtime payload under `BEAM_INSTALL_ROOT`, default `~/.local/share/beam`
- a bundle cache under `~/.local/share/beam/state/install-bundles`
- a prebuilt bundle for the repo-pinned validated Lean toolchain

Each install rebuilds the runtime binaries from the current source checkout before staging the
immutable runtime payload and its provenance manifest. After reinstalling, restart active MCP client
sessions so they launch the new runtime instead of continuing to use an already-running server
process.

The agent flags install the bundled Lean skill into the corresponding agent home. Rocq support is a
separate optional skill; add `--rocq-skill` to a selected agent target when you also want the Rocq
skill:

```bash
./scripts/install-beam.sh --codex --rocq-skill
./scripts/install-beam.sh --all-skills --rocq-skill
```

`--rocq-skill` is only a modifier. It must be paired with `--codex`, `--claude`, `--pi`,
`--opencode`, `--vibe`, `--all-skills`, or an interactive skill target. Rocq-specific setup is
documented in [ROCQ.md](ROCQ.md).

The installer requires `elan` on `PATH`. Make sure `~/.local/bin` is on `PATH` before using the
installed wrappers directly.

## Validated And Compatible Toolchains

Lean Beam distinguishes exact validated toolchains from compatible release lines. Exact toolchains
listed in [`validated-lean-toolchains`](../validated-lean-toolchains) receive the full CI matrix.
The wrapper reports that validated allowlist with:

```bash
lean-beam validated-toolchains
```

[`compatible-lean-release-lines`](../compatible-lean-release-lines) lists canonical Lean release
lines whose other patch and release-candidate toolchains Beam may build and qualify locally. Inspect
those lines after install with:

```bash
lean-beam compatible-release-lines
```

For example, a `leanprover/lean4:v4.31` entry admits canonical immutable names such as
`leanprover/lean4:v4.31.0-rc1` and `leanprover/lean4:v4.31.2`. It does not admit nightlies, mutable
aliases, linked toolchains, other vendors, or malformed version spellings. Release-line admission is
not the same claim as exact CI validation: Beam builds a bundle for the exact resolved toolchain
fingerprint and loads the resulting plugin in a small Lean elaboration probe before marking that
bundle ready.

The repository's [`lean-toolchain`](../lean-toolchain) is the default toolchain prebuilt by the
installer. If your target projects use another validated toolchain or a compatible canonical
RC/patch variant, prebuild those bundles by exact name:

```bash
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.31.0
./scripts/install-beam.sh --toolchain leanprover/lean4:v4.31.0-rc1
./scripts/install-beam.sh --all-validated
```

`--all-validated` prebuilds the finite exact validated allowlist; it does not attempt every possible
RC or patch version from compatible release lines.

If you are working on Lean itself or another local Lean build through an elan-linked toolchain, use
`--custom-toolchain <toolchain>` to explicitly accept and prebuild that toolchain for this Beam
install:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

Custom toolchains are not validated release targets. Beam records exact custom names in the
installed runtime's `custom-lean-toolchains` registry and includes the resolved Lean/Lake identity
in bundle keys, so relinking a local toolchain creates a different bundle rather than reusing stale
helpers. See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the full model.

If a validated, release-line-compatible, or explicitly custom target toolchain was not prebuilt,
first use can still build and qualify a project-local fallback bundle under that project's Beam
state. On a cold machine, that fallback may need network access to fetch dependencies.

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

## Prune Old Installed State

The installer publishes each distinct content payload as an immutable runtime payload under
`BEAM_INSTALL_ROOT/versions`. Reinstalling an identical payload reuses its existing runtime only
after validating its ownership marker, manifest, required files, executable commands, and payload
contents. The schema-3 manifest field `createdWithToolchains` records the toolchain selection that
first created that immutable payload. On reuse, the installer refreshes only the manifest's
`sourceCommit` to the current source checkout commit, or clears it when no commit is available;
`createdWithToolchains` remains unchanged. Later prebuilds add mutable bundle-cache entries without
changing the runtime payload. Beam keeps prior distinct runtimes so publishing `current` stays
atomic, but those snapshots are not removed automatically. Schema-2 manifests are readable only
for identity and cleanup; reinstalling never republishes a schema-2 runtime. Preview old state with:

```bash
lean-beam prune
```

The preview validates the Beam ownership marker, requires the command to come from the current
installed runtime, and checks every candidate's manifest. It never selects the current runtime.
Apply the displayed runtime cleanup with:

```bash
lean-beam prune --apply
```

Installed bundle-cache keys include the toolchain name and resolved fingerprint, runtime source
hash, and platform. To also preview stale-source or incomplete entries while preserving bundles
that match the current runtime source, add `--bundles`:

```bash
lean-beam prune --bundles
lean-beam prune --apply --bundles
```

This only scans the installer-owned cache under `BEAM_INSTALL_ROOT/state/install-bundles`; it does
not remove project-local fallback bundles under `<project>/.beam/bundles`. A complete installed
bundle is preserved when its runtime source still matches, even when that toolchain fingerprint is
not currently in use.

Restart active agent and MCP client sessions before any `prune --apply`; otherwise a process may
still be running from a runtime selected for removal. A later request rebuilds any needed bundle
that was pruned. Pruning uses the same atomic-directory install lock as the shell installer and a
kernel-backed file lock for each selected bundle. Bundle lock files remain as stable coordination
inodes after release; kernel ownership disappears automatically when the holder exits. The install
lock is never stale-reaped, so a crashed installer fails closed and requires explicit recovery.
Pruning also refuses symlinked installed bundle-cache roots or symlinked and unmarked runtime
directories.

Apply is incremental rather than transactional: Beam validates and removes one displayed path at a
time and reports each successful removal immediately. If a later path fails validation or its lock
cannot be acquired, earlier reported removals remain applied. Resolve the reported error and rerun
`lean-beam prune` (with `--bundles` when applicable) to preview what remains.

If reinstalling reports that an existing runtime does not match its payload hash, stop active Beam
agents and MCP clients first. Move only the exact reported runtime directory out of
`BEAM_INSTALL_ROOT/versions` and preserve it for inspection, then rerun the installer. Do not remove
the whole `versions` directory. `lean-beam prune` deliberately refuses invalid state and the current
runtime, so it is not the repair path for this case. Use the same recovery when reinstalling refuses
to reuse a cleanup-only schema-2 runtime.

If `runtime_error` instead reports an invalid install-root marker, do not recreate that ownership
marker in place or move only one runtime: the marker protects the boundary of the whole managed
root. Stop active Beam clients, rename the exact `BEAM_INSTALL_ROOT` as a unit and preserve it for
inspection, then rerun the installer so it creates a fresh owned root. Do not delete the preserved
root until its contents are understood.

The command is intentionally unavailable from a source checkout because there is no owned
immutable install root to prune there.

## Use Beam From A Lean Project

Move to the Lean project you want to work on and check the resolved setup:

```bash
cd /path/to/lean/project
lean-beam doctor
```

Command positions use Lean/LSP coordinates: line and character are zero-based, and character counts
UTF-16 code units. To probe a tactic replacement, select its first character after indentation
to use its before-state. See [Position Semantics](../skills/lean-beam/references/workflow-details.md#position-semantics)
for the argument order and a before/after example.

Start one foreground owner for the wrapper session and keep it running. In another terminal or agent
process, ask questions against saved Lean files in that project:

```bash
# terminal/session 1
lean-beam serve

# terminal/session 2
update_json="$(lean-beam update "Foo.lean")"
printf '%s\n' "$update_json"
snapshot="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
lean-beam hover "Foo.lean" "$snapshot" 10 2
lean-beam definition "Foo.lean" "$snapshot" 10 2
lean-beam goals before "Foo.lean" "$snapshot" 10 2
lean-beam run-at "Foo.lean" "$snapshot" 10 2 "exact trivial"
```

`lean-beam serve` is the only wrapper command that starts a project session. Its
inherited ownership pipe defines the session lifetime: interrupt the holder, or run
`lean-beam --root ROOT stop`, to close the daemon and its backend processes. All other wrapper
commands attach to an existing owner and report the exact `serve` command when no session exists.
Abnormal fenced state instead reports the explicit recovery command. Attaching commands use the
owner's frozen configuration and do not rebuild a competing desired configuration. A second owner
does resolve its proposed configuration and reports any mismatch while preserving the old owner.
During stopping the descriptor reports `draining` and a replacement owner is refused until owned
cleanup completes after graceful or process-group teardown and daemon-leader reaping. MCP clients
do not need a separate holder; the stdio MCP process owns its runtime session.

`lean-beam status` reports the public session state as `absent`, `running`, `stopping`, or
`recoveryRequired`, together with the resolved workspace and session directory. Human-facing
commands may infer a root only when the result is unique. If Lean and Rocq markers identify
different candidate roots, Beam lists the ambiguity and requires `--root`. Automated callers should
pass an explicit root; `stop` and `recover` always require one.

Successful `serve`, `status`, `stop`, and `recover` commands emit the same top-level
`{"ok": true, "result": ...}` shape. `serve` reports the public running session rather than its
private backend warm-up request. `stop` reports whether it committed the transition to `stopping`;
repeating it while already stopping returns `changed: false`. If the transition commits but its
immediate authenticated shutdown delivery fails, the successful stopping result includes a typed
warning. Recovery reports `state: "absent"` and whether it changed the selected session fence.

The default session descriptor and lock live in `<root>/.beam`. This is intentional for
project-scoped agent sandboxes: clients that can access the same workspace can discover the same
session. Before creating a lock or capability-bearing descriptor, Beam makes the selected session
directory account-private (`0700`) when the leaf does not exist; the published descriptor is
`0600`. An existing selection must already be a real, non-symlinked directory with mode `0700`, or
Beam refuses it without changing its permissions. This permits coordination between sandboxes and
agents running as the same local account, but a group-shared or traversable session directory is
not a supported authentication boundary. Use an exact alternate directory when the project is
read-only or several same-account clients need another stable control plane:

```bash
lean-beam --root /workspace/a --session-dir /workspace/control serve
lean-beam --root /workspace/a --session-dir /workspace/control stats
```

The session selector is the canonical workspace root plus the resolved session directory. Beam
admits at most one owner for that selector; choosing another session directory deliberately chooses
another namespace. A shared `BEAM_SESSION_ROOT` can coordinate several workspaces without sharing
their broker processes: each canonical root receives its own derived session directory and owner.

Every participant must supply the same `--root` and an absolute `--session-dir`; Beam does not
search alternate session directories. If the exact directory already exists, prepare its `0700` mode explicitly;
Beam will not adopt it by silently changing permissions. `BEAM_SESSION_ROOT=/writable/base` is the
sandbox convenience form and must be absolute: Beam canonicalizes the base, then derives a separate
hashed directory for each canonical root below it.

For a missing explicit session directory, Beam canonicalizes its longest existing ancestor before
retaining the missing suffix. The selector therefore has the same spelling before and after Beam
creates it, including through platform aliases such as macOS `/tmp`.

Beam rejects an explicit symbolic-link leaf before canonicalizing `--session-dir` and revalidates
the selected leaf without following links before every status or attachment operation. Permission
drift therefore fails closed instead of silently weakening an already published session boundary.

Each wrapper session publishes exactly one frozen workspace. Wrapper mode does not allow runtime
`init_workspace`, `list_workspaces`, or `drop_workspace` requests. Use the dedicated
`lean-beam --root ROOT stop` command for lifecycle control.

Use a stable external session directory when ownership must remain fenced while the project path is
deleted and recreated; deleting a project-local `.beam` necessarily deletes its default fence.

An abnormal owner or broker exit, including a nonzero broker exit after stopping begins, leaves the
descriptor as a safety fence. After independently
establishing that the recorded generation is no longer authoritative, quarantine that exact record
without signalling its recorded PIDs:

```bash
lean-beam --root /workspace/a recover --generation GENERATION_ID
```

Use the same `--session-dir` selection when applicable. `recover --force` is reserved for opaque
legacy, unsupported, or malformed descriptors. Recovery preserves the old file under a
`beam-daemon.recovered-*.json` name for diagnosis.

For a current descriptor, the selected `--root` must match its recorded workspace;
using the same session directory with an unrelated root cannot quarantine the session. `status`
reports this as `sessionSelectorMismatch`, not as a lifecycle state or recovery requirement.

Machine clients should pass an explicit `--root`, invoke the typed wrapper operations, and check
the process exit status before parsing stdout. Completed broker operations print final JSON,
including typed semantic failures. Selector, setup, and transport failures can exit nonzero with a
human-readable stderr diagnostic and no JSON. Use MCP when a client requires structured live
progress, diagnostics, or failures; Beam intentionally does not expose its raw port, session
capability, or generic broker request record as an installed client interface.

The `python3` line extracts `result.snapshot` for shell examples. You can also copy that snapshot
string from the printed `lean-beam update` JSON.

Beam reads the saved file on disk, not unsaved editor buffers. After a real source edit, save the
file normally and then update or sync that workspace module before trusting later probes:

```bash
lean-beam update "MyPkg/Sub/Module.lean"
lean-beam sync "MyPkg/Sub/Module.lean"
```

For multiline speculative Lean text, pass the text on stdin:

```bash
printf '%s\n' 'example : True := by' '  trivial' |
  lean-beam run-at "Foo.lean" "$snapshot" 10 2 --stdin
```

Read those commands like this:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  snapshot without waiting for diagnostics
- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam sync` waits for diagnostics/readiness after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers
- `lean-beam doctor` explains toolchain support and runtime bundle selection

Position and range probes are snapshot-bound. Use the `snapshot` returned by `lean-beam update` or
`lean-beam sync` for `run-at`, `hover`, `signature-help`, `definition`, `references`,
`document-symbols`, `goals`, and `todo`. Workspace symbol queries are workspace-scoped and do not
take a file snapshot. If Beam reports `contentModified`, update or sync the file again and retry
only after reading the current source and resolving the intended target again. A fresh snapshot
token does not repair old coordinates or code actions.

Useful follow-up commands:

```bash
lean-beam open-files
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

`lean-beam open-files` reports only documents tracked by the current project daemon. Each file's
`diskStatus` is `matchesTracked`, `differsFromTracked`, `missing`, or `unknown`, comparing the current
on-disk source with the broker's tracked text. `checkpointed` means this daemon recorded a successful
`lean-beam save` for that tracked snapshot and the source still matches. It does not revalidate Lake
artifacts or predict whether another save will succeed; `lean-beam save` is authoritative for those
checks.

The running Lean server and existing file workers are not guaranteed to pick up Lake workspace
configuration changes. After editing a lakefile, manifest, package override, `lean-toolchain`, Lean
options, plugins, or dynamic libraries, run `lean-beam --root ROOT stop`, then start a new
`lean-beam serve` owner before the next wrapper command that uses the Lean server.
`lean-beam refresh` reopens a file within the current server and is not sufficient for this case.

### Final Batch Validation

`lean-beam save` is an inner-loop development checkpoint from Lean's accepted server state. It
includes structured Lake options, dynamic libraries, and plugins already applied by the file worker
and avoids repeated module builds. Modules with batch-only `moreLeanArgs` fail with
`saveUnsupportedSetup`; move shared `-D` settings to `leanOptions`, or use `lake build` when the
arguments are intentionally batch-only. A successful checkpoint is normally sufficient for local
development, so do not run a clean build after every Beam loop. At the end of the development loop,
use a successful CI `lake build` from a clean checkout or clean Lake build directory as the final
batch-validation result.

If no successful clean CI result is available, or when investigating code that may observe server
mode, validate the project once from clean local Lake artifacts:

```bash
lean-beam --root ROOT stop
lake clean
lake build
```

This sequence is a completion fallback, not a step after every Beam checkpoint. The exact checkpoint
contract and the distinction between the inner loop and final batch validation live in
[SYNC_AND_DIAGNOSTICS.md](SYNC_AND_DIAGNOSTICS.md#development-checkpoints-and-batch-validation).

Detailed Lean workflow guidance lives in
[../skills/lean-beam/SKILL.md](../skills/lean-beam/SKILL.md). The narrower Rocq surface is
summarized in [ROCQ.md](ROCQ.md), with agent workflow details in
[../skills/rocq-beam/SKILL.md](../skills/rocq-beam/SKILL.md).

## MCP Setup

Use this section only when your editor or agent client speaks MCP. The ordinary `lean-beam` CLI
workflow does not require MCP.

The installer includes the experimental stdio MCP server as `lean-beam-mcp`. It can register the
server automatically for Codex, Claude Code, or Mistral Vibe. For Mistral Vibe, the
installer edits `~/.vibe/config.toml` directly: it replaces any existing `lean-beam` entry in
`[[mcp_servers]]`, removes Vibe's default empty `mcp_servers = []` line (TOML forbids extending an
inline array with `[[mcp_servers]]` tables), and leaves other entries untouched. If the config
holds other servers as inline `mcp_servers = [...]` entries, the installer refuses; move those
entries to `[[mcp_servers]]` tables first. For OpenCode, the installer prints the
`opencode mcp add` values to use manually. Pi Agent does not support MCP; install its skill with
`--pi`. Codex registration also sets `supports_parallel_tool_calls = true` on the `lean-beam`
server entry so Codex can keep independent Lean probes in flight concurrently.

The server prefers stateless MCP `2026-07-28` and also accepts the initialization-based
`2025-11-25` lifecycle while clients migrate. This is automatic: modern clients can discover the
server and attach protocol metadata to each call, while older supported clients initialize
normally. The workspace descriptor shown below is explicit in both cases.

```bash
./scripts/install-beam.sh --codex-mcp
./scripts/install-beam.sh --claude-mcp
./scripts/install-beam.sh --opencode-mcp
./scripts/install-beam.sh --vibe-mcp
./scripts/install-beam.sh --all-mcp
```

To register an existing install manually, use an absolute path so the client can launch the server
even if `~/.local/bin` is not on its PATH:

```bash
codex mcp add lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
claude mcp add --scope user lean-beam -- "$HOME/.local/bin/lean-beam-mcp"
opencode mcp add
```

### Codex

Codex CLI `0.147.0` is Beam's validated target for this client-specific adapter; see the
[compatibility policy](COMPATIBILITY.md#current-targets). After manual Codex registration, edit the
generated `[mcp_servers.lean-beam]` table in `~/.codex/config.toml` so it contains:

```toml
[mcp_servers.lean-beam]
command = "/absolute/path/to/lean-beam-mcp"
supports_parallel_tool_calls = true
```

The installer performs this edit automatically. The setting allows concurrent calls; it does not
make dependent handle continuations safe to parallelize.

### Claude Code

Claude Code needs no corresponding per-server parallel setting: it can schedule MCP tools carrying
the read-only hint concurrently. Tool approval is a separate user policy, which the Beam installer
does not change. For example, users who want to auto-approve only two common read-only calls can add
this to `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": [
      "mcp__lean-beam__lean_run_at",
      "mcp__lean-beam__lean_todo"
    ]
  }
}
```

Avoid a blanket `mcp__lean-beam__*` allow rule unless save, synchronization, feedback-bundle,
document-lifecycle, handle, and workspace-eviction calls should also run without approval.

### OpenCode

When `opencode mcp add` prompts for the server, use:

```text
name: lean-beam
type: local
command: /absolute/path/to/lean-beam-mcp
```

Beam leaves OpenCode MCP registration and permission policy manual and does not require an
additional Beam-specific parallel-call field. Because OpenCode's CLI and configuration shape vary
by release, follow the prompts shown by the installed client; Beam does not edit its MCP config.

### Mistral Vibe

To register with Mistral Vibe manually, remove any `mcp_servers = []` line from
`~/.vibe/config.toml`, then append this entry:

```toml
[[mcp_servers]]
name = "lean-beam"
transport = "stdio"
command = "/absolute/path/to/lean-beam-mcp"
args = []
tool_timeout_sec = 600
```

Use that command as-is. Every workspace-bound tool call includes an explicit local descriptor:

```json
{"workspace":{"root":"/absolute/path/to/lean/project"},"path":"Main.lean"}
```

The root must be an absolute path to an existing Lean/Lake project. No setup call is required: the
first ordinary Lean tool lazily creates or reuses the runtime for the canonical root. The same
server process can serve several roots because every relevant request identifies its own workspace.
There is no connection-wide current or default workspace.

To evict one cached runtime after project-configuration changes, call `lean_drop_workspace` with:

```json
{"workspace":{"root":"/absolute/path/to/lean/project"}}
```

Drop invalidates proof handles for that runtime. It does not select context for later calls; a later
request with the same descriptor recreates the runtime. Retain the canonical `workspace` descriptor
when a Lean operation, non-confidential feedback result, or drop result echoes it; it can still evict
cached state after the project path or its Lean/Lake markers become unavailable. `beam_version` and
`beam_stats` are process-wide and accept no descriptor. Exact tool and version semantics live in the
[MCP protocol notes](MCP.md#public-tools).

The wrapper resolves the matching installed Beam runtime for each project.

Use `lean-beam --version` for bug reports and CLI refresh checks. Use `lean-beam-mcp --version` to
check which MCP server command a client registration resolves. From a live MCP session, call the
`beam_version` tool to report the running server process identity as structured content. Installed
identities include `runtime_current`: `false` means that process is not selected by the install
root's `current` link, usually because it belongs to a superseded runtime but also when that link is
missing. Restart the agent or MCP client after reinstalling. A newly resolved installed wrapper
should report `runtime current: true`; if it does not, treat the missing or broken `current` link as
an installation-integrity failure. An owned runtime with an invalid marker or manifest reports
`runtime_error` instead of being presented as a source checkout. Follow the error-specific recovery
guidance in [Prune Old Installed State](#prune-old-installed-state).

Use `lean-beam feedback-report --stdin` to create a local report when reporting setup or runtime
issues; Beam does not upload or submit it. See [FEEDBACK.md](FEEDBACK.md).

To verify the installed MCP path without writing JSON-RPC by hand, change to the Lean project and
run:

```bash
cd /path/to/lean/project
lean-beam-mcp --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, calls `lean_sync` with an explicit descriptor for the
current project, and shuts the child server down. On first use for a project/toolchain, this
may also build the matching local Beam runtime bundle. If a very slow machine needs a longer wait,
set `LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS` to a positive timeout in milliseconds. Maintainer details
for MCP live in the [MCP maintainer notes](MCP.md).

## Installer Locations And Overrides

Default install locations are:

| Purpose | Default | Override |
| --- | --- | --- |
| Command wrappers | `$HOME/.local/bin` | interactive `change`, or `BEAM_BIN_HOME` |
| Runtime root | `$HOME/.local/share/beam` | interactive `change`, or `BEAM_INSTALL_ROOT` |
| Install bundle cache | `$HOME/.local/share/beam/state/install-bundles` | derived from the runtime root |
| Source build output | `<repo>/.lake` | fixed by Lake for this checkout |
| Codex skill and MCP home | `$HOME/.codex` | interactive `change`, `CODEX_HOME`, or `--codex-home` |
| Codex MCP config | `$HOME/.codex/config.toml` | derived from the Codex home |
| Claude Code skill home | `$HOME/.claude` | interactive `change`, or `CLAUDE_HOME` |
| Claude Code MCP config | `$HOME/.claude.json` | interactive `change`, `BEAM_CLAUDE_MCP_CONFIG`, or `--claude-mcp-config` |
| Pi Agent skill home | `$HOME/.pi/agent` | interactive `change`, `PI_CODING_AGENT_DIR`, or `--pi-home` |
| OpenCode config directory | `$HOME/.config/opencode` | interactive `change`, `OPENCODE_CONFIG_DIR`, or `--opencode-config-dir` |
| OpenCode skill home | `$HOME/.config/opencode/skills` | derived from the OpenCode config directory |
| Mistral Vibe home | `$HOME/.vibe` | interactive `change`, `VIBE_HOME`, or `--vibe-home` |
| Mistral Vibe skill home | `$HOME/.vibe/skills` | derived from the Mistral Vibe home |
| Mistral Vibe MCP config | `$HOME/.vibe/config.toml` | derived from the Mistral Vibe home |

For sandboxed config locations, pass the target paths explicitly:

```bash
./scripts/install-beam.sh --codex-mcp --codex-home /path/to/sandbox/.codex
./scripts/install-beam.sh --claude-mcp --claude-mcp-config /path/to/sandbox/.claude.json
./scripts/install-beam.sh --vibe-mcp --vibe-home /path/to/sandbox/.vibe
```

The same Codex, Claude, and Mistral Vibe overrides are available as `CODEX_HOME`,
`BEAM_CLAUDE_MCP_CONFIG`, and `VIBE_HOME`. Interactive installs can also choose `change` at the
write-location prompt before approving writes.

## Slow Or Offline Installs

On a cold machine, first bundle builds may need network access to fetch dependencies. When
travelling or working on a slow connection, install the exact validated Lean toolchains into the
host elan cache ahead of time:

```bash
grep -v '^[[:space:]]*#' validated-lean-toolchains | sed '/^[[:space:]]*$/d' |
  while IFS= read -r toolchain; do
    elan toolchain install "$toolchain"
  done
```

Then run the installer with `--toolchain <toolchain>` for the target releases you need, or
`--all-validated` for the full validated allowlist.
