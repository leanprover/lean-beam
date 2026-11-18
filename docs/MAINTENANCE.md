# Maintenance and recovery

Use this guide when upgrading Beam, changing a project toolchain, recovering a session, or
removing old installed runtimes. For installation, agent configuration, and connection checks,
start with [Setup](SETUP.md).

- [Before an upgrade](#before-an-upgrade)
- [Changing the project toolchain](#changing-the-project-toolchain)
- [Sessions and recovery](#sessions-and-recovery)
- [Prune old installed state](#prune-old-installed-state)

## Before An Upgrade

Keep the original installation available until its foreground owners and MCP servers have stopped.
For each CLI session, use that installation's command with the same root and session-directory
selection, for example:

```bash
"/path/to/original/installation/bin/lean-beam" --root "/workspace/a" \
  --session-dir "/workspace/control" stop
```

`stop` acknowledges the transition to stopping; wait for the foreground owner to finish cleanup.
Stop MCP servers through their clients too. If cleanup fails or remains pending, preserve the old
installation and session state and follow [Sessions And Recovery](#sessions-and-recovery) before
starting a replacement. A timeout is not evidence that the old generation has stopped.
Do not run `recover` while the original owner, daemon, or any of its producers may still be running.

Then update the installation, restart clients, and inspect `lean-beam --version` and
`lean-beam-mcp --version` to confirm their identity. A live MCP client's `beam_version` reports the
server it is actually using. Prune old standalone versions only after these steps.

## Changing The Project Toolchain

A running session retains its selected runtime. Changing `lean-toolchain` does not retarget that
session: runtime admission can reject an unavailable target, a target outside the installation, or
a mismatch with the retained workspace. For CLI use, stop the original owner using its original
installation and exact session selection. Confirm with that owner or its supervisor that the
owner and all producers have completed cleanup before starting `serve` with the installation that
contains the new target. If cleanup is pending, failed, or unconfirmed, stop and coordinate instead
of starting a replacement. Stop does not require the newly selected target to be usable.

For MCP, call `lean_drop_workspace` with the retained workspace descriptor before using another
target. Confirm completed cleanup with the original server or supervisor before a request recreates
the workspace. If cleanup is pending, failed, or unconfirmed, stop and coordinate. A standalone
MCP installation can select another target in its recorded component set;
a bundled MCP server requires the new toolchain's server. Restart the MCP server if its installation
generation changed, confirming that the old server's producers have stopped before replacement.
Drop invalidates the old workspace's handles.

If only the selector changed and restoring it resolves to the original runtime, admission can
succeed again without recreation. This does not reload other project configuration. Changes to a
lakefile, manifest, dependencies, Lean options, plugins, or dynamic libraries still require a fresh
Lean server; see [configuration changes](SYNC_AND_DIAGNOSTICS.md#project-configuration-changes).

## Sessions And Recovery

`lean-beam status` reports the public session state as `absent`, `running`, `shutdownUnconfirmed`,
`recoveryRequired`, or `unresponsive`, together with the resolved workspace and session directory.
`running` means the selected generation answered an authenticated workspace probe. It is a
point-in-time session check; it does not establish Lean worker readiness or successful elaboration.
`unresponsive` means the endpoint did not validate as the expected generation; this includes
timeouts, incomplete or malformed replies, and interrupted probes. It does not establish that the
owner, daemon, or other producers stopped. `stop` and `recover` preserve this descriptor
and fail with `sessionUnresponsive` (exit `1`), without suggesting a recovery command. Resume or
inspect the original owner and daemon through their supervisor before retrying. Human-facing
commands infer a Lean/Lake project root from the current directory and its ancestors. Automated
callers should pass an explicit root; `stop` and `recover` always require one.

`serve` checks the selected session descriptor locally, without probing its endpoint. Any existing
descriptor blocks a replacement owner. A matching-root descriptor marked `live` produces `setupError` with
the recorded generation, recorded and requested configuration hashes, and an exact `status` command
to inspect it. This refusal makes no claim that its owner is alive; `status` supplies endpoint
diagnostics before any decision to stop or recover the session.

Attaching commands check their required runtime against the owner's frozen configuration and reject
mismatches, including a different installation or Lean toolchain. A second owner resolves its proposed configuration and reports any mismatch while
preserving the old owner. During stopping the descriptor reports `draining` and a replacement owner
is refused until owned cleanup completes after graceful or process-group teardown and daemon-leader
reaping. Abnormal session state reports explicit recovery guidance.

Successful `serve`, `status`, `stop`, and `recover` commands emit the same top-level
`{"ok": true, "result": ...}` shape. `serve` reports the public running session rather than its
private backend warm-up request. The first `stop` reports `state: "stopping"` and `changed: true`
when it commits the shutdown request; this acknowledges the request, not completed cleanup.
If the transition commits but its immediate authenticated shutdown delivery fails, the successful
stopping result includes a typed warning. Recovery reports `state: "absent"` and whether it changed
the selected session fence.

A retained shutdown descriptor means completion is unconfirmed. `status` reports `shutdownUnconfirmed`;
repeated `stop`, `serve`, and attached commands fail with `sessionShutdownUnconfirmed` (exit `1`),
the exact generation and an owning-installation `status` command. Wait for cleanup, then check status;
start `serve` once it is `absent`. The record can also survive owner loss and does not establish
active cleanup or owner death. `error.data.recovery_command` supplies the exact owning-installation
recovery command as a separate, conditional next step; use it only after `recovery_precondition` is
independently established. If cleanup cannot finish, have
the client supervisor perform full cleanup of the original generation. Independently establish that
the owner, daemon and every other producer stopped before recovering any remaining descriptor.
Recovery still refuses a responding or uncertain endpoint. Use a caller-chosen waiting budget and
escalate to the original supervisor if cleanup does not finish. Expiry is not evidence that producers
stopped and does not authorize recovery. No automatic takeover is performed.

The default session descriptor and lock live in `<root>/.beam`. This is intentional for
project-scoped agent sandboxes: clients that can access the same workspace can discover the same
session. On POSIX, before creating a lock or capability-bearing descriptor, Beam makes the selected session
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

For experimental Windows use, an existing session directory must belong to the current user and
use ordinary allow entries granting that user full access. SYSTEM and Administrators may also have access; other
ordinary accounts may not. Beam conservatively rejects deny, object, and callback entries instead
of evaluating their effective access, and leaves rejected directories unchanged.

If an existing directory is rejected, preserve it. Before replacing a session selection, establish
that its original owner and all producers have completed cleanup. Then choose an unused leaf under
an appropriate parent with `--session-dir` and let Beam create the leaf privately. Use that same
selection for subsequent commands. Do not change namespaces to bypass an unsettled session fence.

The session selector is the canonical workspace root plus the resolved session directory. Beam
admits at most one owner for that selector; choosing another session directory deliberately chooses
another namespace. A shared `BEAM_SESSION_ROOT` can coordinate several workspaces without sharing
their broker processes: each canonical root receives its own derived session directory and owner.

Every participant must supply the same `--root` and an absolute `--session-dir`; Beam does not
search alternate session directories. An existing directory must already meet the platform's privacy
requirements; Beam will not adopt it by silently changing permissions. `BEAM_SESSION_ROOT=/writable/base` is the
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
descriptor as a safety fence. A connection-establishment failure retains explicit operator recovery;
it is not proof that the recorded generation has stopped. After independently establishing that the
matching owner, daemon, and every other producer have stopped, quarantine that exact record
without signalling its recorded PIDs:

```bash
"/path/to/original/installation/bin/lean-beam" --root "/workspace/a" \
  --session-dir "/workspace/control" recover --generation GENERATION_ID
```

Replace the executable path, root, session directory, and generation with the original session's
values. Omit `--session-dir` only if that session used the default selection.
Stop and recovery do not require its current plugin, selector, or provenance. A different Beam
installation cannot control that owner, even if its binaries are identical. Recovery preserves a
typed old descriptor under a `beam-daemon.recovered-*.json` name for diagnosis. Opaque or malformed
descriptors cannot establish installation ownership: preserve them, independently stop their
original owner, then archive the descriptor explicitly as an operator. There is no force bypass.

The descriptor to preserve is `beam-daemon.json` inside the selected session directory: normally
`<root>/.beam/beam-daemon.json`, or `<session-dir>/beam-daemon.json` for an explicit selection.
With `BEAM_SESSION_ROOT`, use the resolved per-root directory reported by `status` or `doctor`,
not the base directory. For an old or malformed descriptor, first stop the original owner and
establish that its daemon and workers can no longer act on the workspace. Then move only that exact
descriptor to a distinct archive path that does not already exist. Preserve its contents for
diagnosis; do not rewrite its schema, remove the whole session directory, or signal a PID copied
from the record. If the original owner cannot be identified or stopped, leave the fence in place.

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
An old unsupported manifest schema, including a schema-2 or schema-3 standalone runtime mixed with
current schema-4 runtimes, prevents planning; Beam does not silently skip it or authorize its
deletion. After stopping all users of the old runtime, preserve and move only the exact reported
runtime directory outside `versions`, then rerun the preview. Do not apply that procedure to the
current runtime or to an unknown, foreign, or symlinked entry without establishing its ownership.
Before removing an old runtime, stop its foreground owners through their original installation
and confirm cleanup. Update any client registration pinned to that old runtime and restart clients
against the intended installation. For each MCP server in use, check its running identity with
`beam_version`. A restart alone can select the same old absolute executable.
Leave a runtime in place while any process still uses it; pruning does not discover active users.
Coordinate clients so no process starts using a removal candidate before apply completes.

Preview and apply each acquire the install lock and compute a fresh plan. `--apply` does not reuse
an earlier preview. Coordinate installers and other maintenance so no other process changes the
installed generations or `current` selection between preview and completion of apply. If that state changes,
preview again and repeat the usage checks: a generation that was current during the earlier preview
may now be a removal candidate.

After those checks, apply runtime cleanup with:

```bash
lean-beam prune --apply
```

Apply only after the cleanup and installation checks above. Pruning coordinates with the
installer's atomic-directory lock and refuses symlinked or unmarked runtime directories. A crashed
installer fails closed and requires explicit recovery rather than automatic stale-lock removal.

Prune acquires the install lock before planning or removing runtimes. A lock-acquisition failure
leaves all runtimes in place.

Apply is incremental rather than transactional: Beam validates and removes one displayed path at a
time and reports each successful removal immediately. If validation or removal of a later path
fails, earlier reported removals remain applied. A lock-release error also leaves completed removals
applied and is reported to the caller. Resolve the reported error and rerun `lean-beam prune` to
preview what remains.

If reinstalling reports that an existing runtime does not match its payload hash, stop active Beam
agents and MCP clients first. Move only the exact reported runtime directory out of
`BEAM_INSTALL_ROOT/versions` and preserve it for inspection, then rerun the installer. Do not remove
the whole `versions` directory. `lean-beam prune` deliberately refuses invalid state and the current
runtime, so it is not the repair path for this case. Use the same recovery when reinstalling refuses
to reuse an older runtime manifest schema.

If pruning reports an invalid install-root marker, preserve the whole install root for inspection.
Do not recreate that ownership marker in place. Stop active Beam clients, rename the exact
`BEAM_INSTALL_ROOT` as a unit, then rerun the installer to create a fresh owned root. Do not delete
the preserved root until its contents are understood.

The command is intentionally unavailable from a source checkout because there is no owned
immutable install root to prune there.

