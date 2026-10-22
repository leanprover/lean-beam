# Setup, Sessions, And Recovery

Installation, runtime identity, session ownership, and recovery details for `lean-beam`. The main
skill covers the everyday session commands; open this when installing, diagnosing startup, or
recovering from an abnormal session.

## Installation

From the `lean-beam` repo root:

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

## Session Ownership

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
- After changing effective Lean startup configuration, stop the old session and start a new
  `serve` owner.

## Recovery

- Interrupting the owner or running `stop` performs bounded cleanup. If the owner is killed, the
  daemon shuts down cooperatively but the session fence remains.
- After an abnormal owner or broker exit, the session stays fenced until
  `lean-beam --root ROOT recover --generation ID`. Recovery quarantines the metadata and never
  signals its recorded PIDs.
- `lean-beam prune` previews old installed runtimes. Restart active agents and MCP clients before
  `prune --apply`.
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
