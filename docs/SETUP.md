# Setup

Beam has two installation paths:

- If your elan-installed Lean toolchain includes Beam, follow
  [Use Beam Bundled With Lean](#use-beam-bundled-with-lean).
- Otherwise, follow [Install Beam From This Checkout](#install-beam-from-this-checkout).

The checkout installer targets Linux and macOS; Windows x86_64 uses the bundled toolchain runtime.

Use this document to set up and run Beam through either installation path.
It covers installation, validated and compatible Lean toolchains, first CLI use, MCP registration,
installer locations, and offline setup notes.

You do not add Beam to the target project's `lakefile` or install a copy into each project.
Beam detects the project root from the current directory or `--root`.

After installation, go directly to [the CLI workflow](#use-beam-from-a-lean-project) or
[MCP setup](#mcp-setup). Session recovery and installed-state maintenance are covered afterward.

## Use Beam Bundled With Lean

This path requires a Lean distribution that includes Beam; an ordinary elan toolchain need not
contain it. Replace `SELECTOR` below with the installed elan toolchain name:

```bash
cd /path/to/lean/project
elan run SELECTOR lean-beam --version
elan run SELECTOR lean-beam doctor
```

Use the same `elan run SELECTOR` prefix for the commands in
[Use Beam From A Lean Project](#use-beam-from-a-lean-project), including `serve` and `stop`.
You can also invoke the toolchain's `bin/lean-beam` directly (`lean-beam.exe` on Windows).
If the project has a `lean-toolchain` file, its selector must resolve to that same Lean installation.
A different installation is rejected even if its Lean version is identical.

The bundled MCP server is `bin/lean-beam-mcp` (`lean-beam-mcp.exe` on Windows). Launch it directly
or with `elan run SELECTOR lean-beam-mcp`, and follow [MCP Setup](#mcp-setup) to register it.
One bundled server serves projects using its containing Lean installation. To work with another
toolchain, launch that toolchain's server.

Update or repair Beam through the containing toolchain's distributor. Release builders use the
[native toolchain build/install interface](TOOLCHAIN_BUNDLING.md#build-and-install).

## Install Beam From This Checkout

The current public distribution path starts from a Lean Beam source checkout. To install a specific
release, check out that tag first, then run the installer from the checkout root. After installation,
run the installed commands from the Lean project you want to work on.

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
- project runtimes for the selected toolchains (the repo-pinned toolchain by default)

Each install rebuilds the runtime binaries from the current source checkout before staging the
immutable runtime payload and its provenance manifest. After reinstalling, restart active MCP client
sessions so they launch the new runtime instead of continuing to use an already-running server
process.

The installer includes the matching Lean/Lake shared libraries with Beam's commands and selected
project runtimes. No separate library setup is required.

The agent flags install the bundled Lean skill into the corresponding agent home. Rocq goal
probes and the Rocq skill are installed separately from the frozen [rocq-beam](https://github.com/ejgallego/rocq-beam) project.

If you previously installed the Rocq skill with `--rocq-skill`, move that agent home's
`skills/rocq-beam` directory aside before installing from `rocq-beam`. The old copy uses a
`.lean-beam-skill` ownership marker; the standalone installer requires `.rocq-beam-skill` and
refuses to overwrite the old directory. Install the standalone Rocq skill for the same agent,
then restart active agent sessions so they load the new `rocq-beam` commands.

The installer requires `elan` on `PATH`. Make sure `~/.local/bin` is on `PATH` before using the
installed wrappers directly.

## Validated And Compatible Toolchains

This section describes toolchain selection for checkout installations. Bundled Beam uses its
[containing Lean installation](#use-beam-bundled-with-lean).

The supported Lean release window is 4.33–4.36. The repository defaults to 4.36.0-rc1, a release
candidate. Projects on Lean 4.28–4.32 must upgrade their Lean
toolchain or keep a Beam checkout that still supports their release line.

Lean Beam distinguishes exact validated toolchains from compatible release lines. Exact toolchains
listed in [`validated-lean-toolchains`](../validated-lean-toolchains) receive dedicated Linux
compatibility jobs. The [CI macOS mode](TESTING.md#ci-map) selects one combined job or the full
macOS matrix. Installer tests prebuild every validated toolchain in either mode.
That list contains the latest stable point release in each stable line (4.33.1, 4.34.1, and
4.35.0), plus the pinned 4.36.0-rc1 until 4.36 has a stable release. Other RCs and superseded
stable points use local qualification.
The repository file is the installer's validated allowlist, rather than a runtime-selection policy.

[`compatible-lean-release-lines`](../compatible-lean-release-lines) lists canonical Lean release
lines whose other patch and release-candidate toolchains the installer may build and qualify locally.

For example, a `leanprover/lean4:v4.33` entry admits canonical immutable names such as
`leanprover/lean4:v4.33.0-rc1` and `leanprover/lean4:v4.33.2`. It does not admit nightlies, mutable
aliases, linked toolchains, other vendors, or malformed version spellings. Release-line admission is
not the same claim as exact CI validation: the installer builds a bundle for the exact resolved toolchain
fingerprint and loads the resulting plugin in a small Lean elaboration probe before marking that
bundle ready.

The repository's [`lean-toolchain`](../lean-toolchain) is selected when no toolchain flags or
interactive choices specify another set. Each successful installer run publishes the **complete selected
target set**. It does not add to the previous installation's targets or automatically retain the
repo-pinned target when you select others. Include every toolchain you want to keep using.

For example, select two project toolchains in one invocation:

```bash
./scripts/install-beam.sh \
  --toolchain leanprover/lean4:v4.33.1 \
  --toolchain leanprover/lean4:v4.35.0
```

Alternatively, select every exact validated toolchain:

```bash
./scripts/install-beam.sh --all-validated
```

`--all-validated` prebuilds the finite exact validated allowlist; it does not attempt every possible
RC or patch version from compatible release lines. To select a compatible RC or patch variant,
include its exact name, such as `--toolchain leanprover/lean4:v4.33.0-rc1`, in the target list.

If you are working on Lean itself or another local Lean build through an elan-linked toolchain, use
`--custom-toolchain <toolchain>` to explicitly accept and prebuild that toolchain for this Beam
install:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

To retain other project targets too, include their `--toolchain` or `--custom-toolchain` flags
in that same invocation, including when reinstalling after a local Lean rebuild.

Custom toolchains are not validated release targets. The installer records each selected Lean
installation and its qualified matching runtime in the published component set. After rebuilding
Lean or relinking a local toolchain, rerun the installer and restart its Beam clients.
See [CUSTOM_TOOLCHAINS.md](CUSTOM_TOOLCHAINS.md) for the full model.

Each install builds its selected targets in fresh temporary workspaces inside its staging
directory. It copies each target's declared daemon, plugin, and shared libraries into staging,
rejects missing or linked outputs, qualifies the staged plugin, and checks the staged daemon's
compiler origin. After removing the temporary workspaces, it hashes the completed installation and
publishes its manifest. Beam keeps no construction cache between installs; Lake may reuse build
artifacts from its own cache (`~/.cache/lake` by default), which makes rebuilding an unchanged
target fast. Lake does not bound that cache's size. Failed setup removes its staging directory and
leaves the existing `current` installation unchanged.

Earlier Beam versions kept a construction cache under `BEAM_INSTALL_ROOT/state/install-bundles`.
Current installers neither read nor remove it. To reclaim that space, stop any running installer
and delete that directory yourself.

Normal execution can use only those constructed targets. If a project's target is unavailable,
rerun the installer with that target and every other target you want to retain. Beam does not build
missing runtimes in projects, search other providers, or download a target during admission.

If you are unsure which runtime bundle is active or why a toolchain is rejected, use:

```bash
lean-beam doctor
```

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

`lean-beam doctor` reports session state, recovery details, and recent daemon incident paths before
inspecting Lean setup. The session report is flushed to stdout before any Lean setup probe; setup
failures then appear on stderr and produce a nonzero exit status. Pass `--root PATH` to inspect a
known directory after its Lean project markers disappear, and `--session-dir PATH` when the session
uses a separate control directory. Inspection preserves the session descriptor and incident files
and does not start a session or build a bundle.

Start one foreground owner for the wrapper session and keep it running. In another terminal or agent
process, ask questions against saved Lean files in that project:

```bash
# terminal/session 1
lean-beam serve

# terminal/session 2
if update_json="$(lean-beam update "Foo.lean")" &&
   version="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["version"])')"; then
  printf '%s\n' "$update_json"
  lean-beam hover "Foo.lean" "$version" 10 2
  lean-beam definition "Foo.lean" "$version" 10 2
  lean-beam goals before "Foo.lean" "$version" 10 2
  lean-beam run-at "Foo.lean" "$version" 10 2 "exact trivial"
fi
```

Replace `Foo.lean` and the coordinates with a saved file and position in your project.
The guard skips JSON parsing and probes when `update` fails; read its stderr diagnostic first.

`lean-beam serve` is the only wrapper command that starts a project session. Its
inherited ownership pipe defines the session lifetime: interrupt the holder, or run
`lean-beam --root ROOT stop`, to close the daemon and its backend processes. Lean queries and file
operations attach to an existing owner and report the exact `serve` command when no session exists.
Help, version reporting, `doctor`, `status`, and `prune` can run without a live owner.
MCP clients do not need a separate holder; the stdio MCP process owns its runtime session.
For alternate session directories, status details, and abnormal-exit recovery, see
[Sessions And Recovery](#sessions-and-recovery).

Machine clients should pass an explicit `--root`, invoke the typed wrapper operations, and check
the process exit status before parsing stdout. Completed broker operations print final JSON,
including typed semantic failures. Selector, setup, and transport failures can exit nonzero with a
human-readable stderr diagnostic and no JSON. Use MCP when a client requires structured live
progress, diagnostics, or failures; Beam intentionally does not expose its raw port, session
capability, or generic broker request record as an installed client interface.

The `python3` line extracts `result.version` for shell examples. You can also copy that version
number from the printed `lean-beam update` JSON.

Beam reads the saved file on disk, not unsaved editor buffers. After a real source edit, save the
file normally and then update or sync that workspace module before trusting later probes:

```bash
lean-beam update "MyPkg/Sub/Module.lean"
lean-beam sync "MyPkg/Sub/Module.lean"
```

For multiline speculative Lean text, pass the text on stdin:

```bash
printf '%s\n' 'example : True := by' '  trivial' |
  lean-beam run-at "Foo.lean" "$version" 10 2 --stdin
```

Read those commands like this:

- `lean-beam update` opens or updates the broker's LSP mirror and returns the current document
  version without waiting for diagnostics
- `lean-beam run-at` tries speculative Lean text without editing the file
- `lean-beam sync` waits for diagnostics/readiness after a real saved edit
- `lean-beam refresh` is `lean-beam close` plus `lean-beam sync`
- `lean-beam save` checkpoints one synced workspace module; it does not validate downstream importers
- `lean-beam doctor` explains toolchain support and runtime bundle selection

Tactic probes through the CLI or MCP cannot introduce local `let rec` definitions, even valid ones.
Save the complete enclosing theorem or definition and sync to check it, then use the returned
version for later probes; edits invalidate existing handles. A speculative check of one complete
declaration at a command position uses Lean's normal termination checks. See the skill's
[local recursion workflow](../skills/lean-beam/references/lean-run-at-semantics.md#5-introducing-local-recursion-in-a-tactic-probe).

Position and range probes are version-bound. Use the `version` returned by `lean-beam update` or
`lean-beam sync` for `run-at`, `hover`, `signature-help`, `definition`, `references`,
`document-symbols`, `goals`, and `todo`. Workspace symbol queries are workspace-scoped and do not
take a file version. If Beam reports `contentModified`, update or sync the file again and retry
with the accepted current version rather than guessing.

Useful follow-up commands:

```bash
lean-beam open-files
lean-beam refresh "MyPkg/Sub/Module.lean"
lean-beam save "MyPkg/Sub/Module.lean"
```

`lean-beam open-files` reports only documents tracked by the current project daemon. Each file's
`diskStatus` is `matchesTracked`, `differsFromTracked`, `missing`, or `unknown`, comparing the current
on-disk source with the broker's tracked text. `checkpointed` means this daemon recorded a successful
`lean-beam save` for that tracked version and the source still matches. It does not revalidate Lake
artifacts or predict whether another save will succeed; `lean-beam save` is authoritative for those
checks.

The `open-files` result contains `session.active` and `session.files`. The workspace result from
`lean-beam stats` also has a single `session` object, plus `metrics` for operation counters retained
across Lean server session restarts. Workspace identity and root appear on the enclosing result;
an active stats session adds only `epoch` and `openDocCount` to `active`. Resetting or recreating the
workspace starts fresh counters, as does restarting the daemon.

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
[../skills/lean-beam/SKILL.md](../skills/lean-beam/SKILL.md).

## MCP Setup

Use this section only when your editor or agent client speaks MCP. The ordinary `lean-beam` CLI
workflow does not require MCP.

Both installation paths provide the experimental stdio MCP server as `lean-beam-mcp`.
The checkout installer can register its server automatically for Codex, Claude Code, or Mistral Vibe.
For Mistral Vibe, the installer edits `~/.vibe/config.toml` directly: it replaces any existing `lean-beam` entry in
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

To register either installation manually, use the absolute path to its MCP command:

- Checkout installation: `$HOME/.local/bin/lean-beam-mcp`, or your chosen wrapper location.
- Bundled toolchain: the toolchain's `bin/lean-beam-mcp` (`lean-beam-mcp.exe` on Windows).

Replace `/absolute/path/to/lean-beam-mcp` below with that path. This lets the client launch the
matching server independently of its working directory and `PATH`.

```bash
codex mcp add lean-beam -- "/absolute/path/to/lean-beam-mcp"
claude mcp add --scope user lean-beam -- "/absolute/path/to/lean-beam-mcp"
opencode mcp add
```

### Verify The MCP Server

To verify the installed MCP path without writing JSON-RPC by hand, change to the Lean project.
Use the same absolute MCP command you registered above:

```bash
cd /path/to/lean/project
"/absolute/path/to/lean-beam-mcp" --self-check MyPkg/Sub/Module.lean
```

The self-check starts a child MCP server, calls `lean_sync` with an explicit descriptor for the
current project, and shuts the child server down. The project target must already be a member of
the installed component set; the self-check does not construct missing runtimes. Success requires valid discovery and sync
responses and a zero server exit status. It verifies that sync can run, without requiring completed
elaboration, a file without Lean diagnostics, or readiness to save artifacts. Server stderr is
diagnostic: logging does not fail an otherwise successful check, and failures include the final
64 KiB of captured stderr when available.
The smoke test uses one best-effort timeout for discovery, sync, and shutdown, including stderr
draining; notifications do not restart it. Process creation and failure cleanup are outside that
budget, and blocked I/O tasks can delay process exit. If a very slow machine needs a longer wait,
set `LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS` to a positive timeout in milliseconds (default 120000).
CI supervises the command with a separate process watchdog. Maintainer details
for MCP live in the [MCP maintainer notes](MCP.md).

### Workspaces And Server Identity

The following applies to every MCP client. Every workspace-bound tool call includes an explicit
local descriptor:

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

The executable remains bound to its concrete installation and recorded target set.

Use `lean-beam --version` for bug reports and CLI refresh checks, and `lean-beam-mcp --version` to
check the registered server's recorded identity. The MCP `beam_version` tool reports the running
process's installation generation and source revision as structured content. Installed identity
comes from its manifest rather than a surrounding Git checkout. Malformed or replaced records make
identity reporting fail; protocol discovery and recorded-owner cleanup remain available.

After reinstalling, restart owners and MCP clients to use the newly selected generation. Changing
the launcher's `current` link does not retarget a running process. Prior immutable installations
remain usable while intact; explicitly stop their clients before pruning them.

Use `lean-beam feedback-report --stdin` to create a local report when reporting setup or runtime
issues; Beam does not upload or submit it. See [FEEDBACK.md](FEEDBACK.md).

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

## Sessions And Recovery

`lean-beam status` reports the public session state as `absent`, `running`, `stopping`, or
`recoveryRequired`, together with the resolved workspace and session directory. Human-facing
commands infer a Lean/Lake project root from the current directory and its ancestors. Automated
callers should pass an explicit root; `stop` and `recover` always require one.

Attaching commands use the owner's frozen configuration and do not rebuild a competing desired
configuration. A second owner resolves its proposed configuration and reports any mismatch while
preserving the old owner. During stopping the descriptor reports `draining` and a replacement owner
is refused until owned cleanup completes after graceful or process-group teardown and daemon-leader
reaping. Abnormal session state reports explicit recovery guidance.

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

Use the same `--session-dir` selection and the original owning installation when applicable.
Stop and recovery do not require its current plugin, selector, or provenance. A different Beam
installation cannot control that owner, even if its binaries are identical. Recovery preserves a
typed old descriptor under a `beam-daemon.recovered-*.json` name for diagnosis. Opaque or malformed
descriptors cannot establish installation ownership: preserve them, independently stop their
original owner, then archive the descriptor explicitly as an operator. There is no force bypass.

For a current descriptor, the selected `--root` must match its recorded workspace;
using the same session directory with an unrelated root cannot quarantine the session. `status`
reports this as `sessionSelectorMismatch`, not as a lifecycle state or recovery requirement.

## Prune Old Installed State

The checkout installer publishes each distinct content payload as an immutable runtime payload under
`BEAM_INSTALL_ROOT/versions`. Reinstalling an identical payload reuses its existing runtime only
after validating its ownership marker, manifest, required files, executable commands, and payload
contents. The schema-4 manifest records fixed companions and the complete constructed target set.
Its generation includes that membership and source provenance. Reuse preserves the manifest byte
for byte; a different target set or provenance produces another generation. Qualified target
executables and plugins live inside that version under `runtimes/`. Prior distinct versions remain
available when `current` changes and are not removed automatically. Earlier installation manifests
require reinstallation before they can establish current component membership. Preview old state with:

```bash
lean-beam prune
```

The preview validates the Beam ownership marker, requires the command to come from the current
installed runtime, and checks every candidate's manifest. It never selects the current runtime.
Stop foreground owners through their original installation and restart agents and MCP clients
before removing an old version. A different installation cannot control those owners after the
original version is removed.

Apply the displayed runtime cleanup with:

```bash
lean-beam prune --apply
```

Restart active owners, agents, and MCP clients before `prune --apply`; a process can remain bound
to an old generation after the launcher's `current` link changes. Pruning coordinates with the
installer's atomic-directory lock and refuses symlinked or unmarked runtime directories. A crashed
installer fails closed and requires explicit recovery rather than automatic stale-lock removal.

Apply is incremental rather than transactional: Beam validates and removes one displayed path at a
time and reports each successful removal immediately. If a later path fails validation or its lock
cannot be acquired, earlier reported removals remain applied. Resolve the reported error and rerun
`lean-beam prune` to preview what remains.

If reinstalling reports that an existing runtime does not match its payload hash, stop active Beam
agents and MCP clients first. Move only the exact reported runtime directory out of
`BEAM_INSTALL_ROOT/versions` and preserve it for inspection, then rerun the installer. Do not remove
the whole `versions` directory. `lean-beam prune` deliberately refuses invalid state and the current
runtime, so it is not the repair path for this case. Use the same recovery when reinstalling refuses
to reuse a older runtime manifest schema.

If pruning reports an invalid install-root marker, preserve the whole install root for inspection.
Do not recreate that ownership marker in place. Stop active Beam clients, rename the exact
`BEAM_INSTALL_ROOT` as a unit, then rerun the installer to create a fresh owned root. Do not delete
the preserved root until its contents are understood.

The command is intentionally unavailable from a source checkout because there is no owned
immutable install root to prune there.

## Installer Locations And Overrides

The checkout installer's default locations are listed below. Bundled commands live in the Lean
toolchain's `bin`; their [packaged layout](TOOLCHAIN_BUNDLING.md#installed-files-and-publication)
is managed by that toolchain's distributor.

| Purpose | Default | Override |
| --- | --- | --- |
| Command wrappers | `$HOME/.local/bin` | interactive `change`, or `BEAM_BIN_HOME` |
| Runtime root | `$HOME/.local/share/beam` | interactive `change`, or `BEAM_INSTALL_ROOT` |
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
