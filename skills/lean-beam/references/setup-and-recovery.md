# Setup And Sessions

Installation, sandbox permissions, and session ownership for `lean-beam`. Open this when setting up
or configuring a session. For failed or stalled calls, unexpected approval, or abnormal shutdown,
read [troubleshooting](troubleshooting.md) instead. The main skill covers everyday session commands.

## Installation

For Beam bundled with a Lean toolchain, use `elan run SELECTOR lean-beam` in place of every bare
`lean-beam` command in this skill, or use that toolchain's absolute `bin/lean-beam` path. Check its
identity and keep that choice for `serve`, attached requests, and `stop`; do not switch to a
standalone command on `PATH`. The project must use the same Lean installation. The standalone
`lean-beam-search` script is not included in the native bundle.

For a standalone installation, run from a matching Beam source checkout:

```bash
./scripts/install-beam.sh --codex
```

Use `--claude`, `--pi`, `--opencode`, or `--vibe` instead when installing for Claude Code, Pi
Agent, OpenCode, or Mistral Vibe; `--all-skills` installs every supported agent skill target.

The installer puts `lean-beam`, `lean-beam-search`, and `lean-beam-mcp` in `~/.local/bin`, stages
the self-contained runtime under `BEAM_INSTALL_ROOT` (default `~/.local/share/beam`), requires
`elan` on `PATH`, and prebuilds the pinned `lean-toolchain` target by default. Select additional
project toolchains with repeated `--toolchain NAME` or `--custom-toolchain NAME` flags. Each run
selects the complete target set: include every target you want to keep, because explicit selections
do not retain the pinned target or targets from the previous installation.

Restart active agent and MCP client sessions after installing. Changing the launcher's `current`
link does not retarget a running process.

Optional online references: the
[setup guide](https://github.com/leanprover/lean-beam/blob/main/docs/SETUP.md) and
[toolchain selection](https://github.com/leanprover/lean-beam/blob/main/docs/SETUP.md#validated-and-compatible-toolchains).

## Toolchain Selection

- `lean-beam` resolves the project's exact locally available Lean target and looks it up in the
  component set recorded by the running installation. Local aliases of the same installation work.
- It uses only that entry's recorded compiler, daemon, and plugin. It never runs a foreign
  candidate, downloads or builds a runtime, or borrows components from another installation.
- A missing target requires rerunning the installer with that target selected explicitly.
- Floating selectors need an exact local target or an explicit local link.

## Sandbox permissions

- CLI communication requires IPv4 loopback TCP: the daemon binds/listens on `127.0.0.1` at an
  OS-selected port recorded in its session descriptor; attaching commands connect to that port.
  Owner and clients need the same network namespace and writable session directory. Select the
  session by root/directory, not by port. IPC needs neither internet access nor a public bind.
- MCP stdio creates its runtime directly and uses pipes to Lean/Lake children. It does not attach
  to the CLI daemon, so that path does not require CLI loopback TCP permissions.
- **Use the registered Beam MCP tools when each shell command runs in a separate network
  namespace** (for example Claude Code on Linux/WSL2). A healthy `serve` owner can be unreachable:
  CLI commands report `sessionRecoveryRequired`, and `doctor` reports recovery required. For CLI
  use, the owner and every attaching command must share a network namespace.
- **Do not run `recover` until you have independently confirmed that the matching owner, daemon,
  and every other producer have stopped.** Connection refusal, `sessionRecoveryRequired`, and a
  returned `remedy_command` do not establish this. If you cannot confirm shutdown, stop and
  coordinate with the operator.
- For CLI use in Claude Code, run both owner and clients outside the Bash sandbox: request
  `dangerouslyDisableSandbox: true` on each Bash call, or
  add `"sandbox": {"excludedCommands": ["lean-beam *"]}` to `.claude/settings.local.json` for direct
  `lean-beam` calls, where client policy permits. See
  [Claude Code's sandbox guidance](https://code.claude.com/docs/en/sandboxing#run-commands-outside-the-sandbox-with-excludedcommands).
- CLI Lean work runs in the existing owner's workers with that owner's launch permissions, not
  the attaching command's sandbox. A sandboxed client can therefore reach a more privileged owner.
- Both run Lean IO with their actual process permissions. A sandbox on agent shell commands does
  not automatically constrain an MCP server launched separately by the client. Configure isolation
  on the actual owner/server and its descendants; Beam does not create an OS sandbox.
- Keep project, toolchain, and required build/cache paths accessible. Installation or Lake
  dependency downloads may separately need internet access; prepare them before offline work.
  See the [setup permission table](https://github.com/leanprover/lean-beam/blob/main/docs/SETUP.md#sandbox-and-network-permissions).
- If denied, inspect the specific process and denied operation. Do not disable the sandbox or
  grant broad network access as a workaround; request the needed access or report the blocker.

## Session Ownership

Opening or syncing a Lean file can run Lake dependency setup and build stale imports, consuming
build-like CPU, memory, and time even for a single-file request. Avoid overlapping preparation
with another heavy build when resources are limited, and do not treat client cancellation as
evidence that preparation stopped; see the
[setup guide](https://github.com/leanprover/lean-beam/blob/main/docs/SETUP.md#use-beam-from-a-lean-project).

- One owner per resolved workspace and session directory. The default descriptor is
  `<root>/.beam/beam-daemon.json`.
- `BEAM_SESSION_ROOT=DIR` places sessions under a per-root subdirectory of `DIR`, for sandboxed or
  read-only trees. For an exact alternate location, pass the same absolute `--session-dir DIR` to
  the owner and every attaching command; Beam does not search alternate session directories.
- `lean-beam serve` alone has daemon startup authority. It prints a running-session JSON response
  after backend readiness (loading status goes to stderr) and keeps running as the owner. An
  inherited pipe ties daemon lifetime to that process; there are no heartbeat files.
- Wrapper commands reach the per-project daemon over loopback TCP chosen by the OS; select sessions
  by root and optional session directory, never by port.
- `lean-beam --root ROOT stop` requires an explicit root; `status` and `stats` may infer a unique
  root.
- Interrupting an ordinary wrapper call cancels that exact request. `lean-beam cancel <id>` cancels
  a request by its `BEAM_REQUEST_ID` from another process.
- Cancellation is cooperative. `cancelled: true` means a matching request was marked, not that Lean
  execution has stopped. Non-polling `#eval` IO may continue; cancellation does not restart its worker.
- After changing effective Lean startup configuration, stop the original owner, confirm completed
  cleanup and that the selected session is absent, then start a new `serve` owner.

## MCP Workspaces

Paths used to read or open documents must resolve inside the selected workspace, including after
following symlinks.
On `invalidParams` saying the document resolves outside the workspace root, select a workspace
containing the file (`lean-beam --root /path/to/project sync Foo.lean`, or that MCP
`workspace.root`) and retry.
Do not retry the same external path against the old root. Normal dependency imports remain usable.

MCP workspace-bound tools carry an explicit local workspace descriptor on every call. Dropping a
workspace (`lean_drop_workspace`) evicts only its cached runtime and handles; it does not refresh
the MCP server binary. Keep the canonical descriptor a result echoes, so a cached runtime can still
be dropped if the project path or its Lean/Lake markers disappear. MCP clients that need live
progress can pass `tools/call` `_meta.progressToken`; the full display matrix is in the optional
[online MCP reference](https://github.com/leanprover/lean-beam/blob/main/docs/MCP.md#display-control-matrix).
