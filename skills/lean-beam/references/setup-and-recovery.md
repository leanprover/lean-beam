# Setup, Sessions, And Recovery

Installation, runtime identity, session ownership, and recovery details for `lean-beam`. The main
skill covers the everyday session commands; open this when installing, diagnosing startup, or
recovering from an abnormal session.

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

## Runtime Identity

- `lean-beam --version`: CLI bug reports and installed runtime identity.
- `lean-beam-mcp --version`: which MCP server wrapper, server binary, runtime payload hash,
  manifest, and source commit a client command resolves.
- MCP `beam_version`: the running server's retained installation identity.
- `lean-beam doctor`: the selected installation, toolchain support, and target membership.

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

## Recovery

- On `workerCrashed` or `workerExited`, use `lean-beam sync PATH` (MCP: `lean_sync`) to reopen the
  affected file and wait for readiness before further probes. A fresh `save` or `close-save` also
  recovers during its initial synchronization. Reopening invalidates that worker's old handles and
  elaborates saved source again; source-level effects can run again.
- If a request stalls and you suspect an idle worker has died, use explicit `lean-beam refresh PATH`
  (MCP: `lean_refresh`). Elapsed time or generic fatal progress alone does not establish worker exit.
  Refresh resets the tracked document. An unresolved close-save still owns its file: cooperative
  cancellation does not establish settlement, and recovery may require restarting the owning
  session/runtime. See the [worker recovery contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md#worker-errors-and-document-recovery).
- Interrupting the owner or running `stop` requests shutdown. A successful `stop` acknowledges
  that request; it does not establish completed cleanup or an overall shutdown deadline. Confirm
  settlement with the owner or supervisor before replacement or external builds. If the owner is
  killed, the daemon shuts down cooperatively but the session fence remains.
- After an abnormal owner or broker exit, the session stays fenced until
  `lean-beam --root ROOT recover --generation ID`. Recovery quarantines the metadata and never
  signals its recorded PIDs.
- `lean-beam prune` previews old installed runtimes. Before `prune --apply`, stop old owners and
  confirm cleanup, update clients pinned to old executables, and verify the running server's
  intended installation with `beam_version` for each MCP server in use. Do not apply pruning while
  any previewed runtime is still in use; the command removes all previewed old runtimes.
- If a runtime's own manifest is corrupted or replaced, identity reporting fails: stop normal Beam
  work and preserve that installation for inspection. Do not try to repair it with `prune`. After
  stopping active Beam agents and MCP clients, move the invalid runtime out of
  `BEAM_INSTALL_ROOT/versions`, keep it for inspection, and rerun the installer.
- For an invalid install-root marker, preserve and rename the whole `BEAM_INSTALL_ROOT` before
  reinstalling. Do not recreate the ownership marker in place or delete the preserved state.

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
