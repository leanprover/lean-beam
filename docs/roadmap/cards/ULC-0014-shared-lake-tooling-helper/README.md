# ULC-0014 Share Lake tooling subprocess machinery with the file worker

- Status: candidate
- Priority: high
- Origin: Beam / Lean file worker / Lake
- Last reviewed: 2026-10-21
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

Lean's file worker runs `lake setup-file` in a subprocess to obtain module setup.
Beam separately runs a target-built helper for workspace configuration and
zero-build module saves. Both need results, diagnostic output, cancellation and
owned process cleanup. Beam additionally maintains private request/response IPC
and adapters to Lake's build metadata.

Explore sharing the file worker's Lake subprocess machinery rather than growing
a second tooling protocol. Keep the subprocess boundary: project configuration
can load code, mutate process-global state, exit or block. Bundling Beam with a
toolchain supplies matching code; it does not make configuration evaluation safe
inside the broker.

Three operation contracts need investigation:

1. **Server configuration:** obtain the workspace environment and additional Lean
   server arguments without launching the server, preserving the distinction
   between no Lake configuration and invalid configuration. Lake already computes
   this for `lake serve`, but does not expose that result as a standalone tooling
   operation at the inspected revision.
2. **Save preparation:** resolve a module's output paths and dependency trace for
   an exact source snapshot without rebuilding. Report stale dependencies,
   changed source and unsupported setup structurally. `setup-file --no-build`
   already exists; the missing contract is a snapshot-bound save plan for artifacts
   that the Lean worker will produce, not another no-build switch.
3. **Artifact registration:** record the artifacts produced by the Lean worker
   and publish the corresponding Lake trace using the target Lake version's
   hashing and metadata rules. This operation does not elaborate the module or
   generate its artifacts.

Sharing a runner alone would reduce transport duplication, but would not remove
the save metadata adapters. A usable external operation contract is needed for
that removal; an in-process library API alone still requires a target-built
adapter. The API shape, ownership and independently landable operation slices
remain open. This card selects neither a wire protocol nor a persistent Lake
service.

## Evidence and acceptance

Source inspection, rather than a fresh runtime reproduction:

- Lean `c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:
  [SetupFile.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/FileWorker/SetupFile.lean)
  launches `lake setup-file`, reads JSON from stdout and reports stderr lines;
  its no-build path adds `--no-build --no-cache`.
  [Serve.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/lake/Lake/CLI/Serve.lean)
  computes the environment, server arguments and invalid-configuration fallback
  before launching Lean.
- Beam `f7bc8451b5f37620e72b4a2191fe4a46c4597eca`:
  [LakeHelper.lean](https://github.com/leanprover/lean-beam/blob/f7bc8451b5f37620e72b4a2191fe4a46c4597eca/Beam/Broker/LakeHelper.lean)
  defines `serverEnv`, `prepareSave` and `writeSaveTrace` with private JSON files.
  [LakeEnv.lean](https://github.com/leanprover/lean-beam/blob/f7bc8451b5f37620e72b4a2191fe4a46c4597eca/Beam/Broker/LakeEnv.lean)
  computes the server environment;
  [LakeSave.lean](https://github.com/leanprover/lean-beam/blob/f7bc8451b5f37620e72b4a2191fe4a46c4597eca/Beam/Broker/LakeSave.lean)
  checks the snapshot and no-build dependency trace, serializes target metadata
  and adapts `ModuleOutputDescrs.c` versus `c?`.

Before migration, demonstrate equivalent configuration fallbacks and server
arguments, stale/source-changed save rejection, and a subsequent `lake build`
accepting worker-produced artifacts without rebuilding the saved module. Keep
operation results and errors structured across the process boundary; logs are
optional display output, not completion authority. Preserve a known publication
outcome if later cleanup fails. Slow output consumers must not prevent
cancellation or process cleanup; any temporary output files must be removed when
the helper is retired, without leaving a transcript archive.

No shared-runner implementation or Windows/macOS/Linux runtime validation is
claimed here. Cross-platform cancellation, parent-loss and failure tests are
required before replacing the current helper.

## Beam workaround and removal

A complete external replacement could remove Beam's `lake-helper` dispatch,
private job files and response polling in
[LakeHelper](../../../../Beam/Broker/LakeHelper.lean) and
[LakeHelperMain](../../../../Beam/Broker/LakeHelperMain.lean), then the duplicated
server configuration and save metadata adapters in
[LakeEnv](../../../../Beam/Broker/LakeEnv.lean) and
[LakeSave](../../../../Beam/Broker/LakeSave.lean).

Beam retains document/snapshot authority, save admission and publication policy,
request isolation, and bounded ephemeral output delivery. Sharing machinery does
not transfer these responsibilities to Lake or remove the owned subprocess
requirements in [ULC-0009](../ULC-0009-owned-subprocess-lifetime/README.md).
[ULC-0003](../ULC-0003-structured-setup-file-progress/README.md) is the independent
diagnostic-tagging improvement; it does not supply these operations or retire the
helper.

## Next action

The Beam integration coordinator should identify a design owner, search existing
Lean/Lake issues and PRs, and discuss reuse of the file worker's `setup-file`
machinery with maintainers. Reduce each operation to a caller example before
choosing an API or splitting implementation cards. No upstream implementation or
first complete providing version is identified. Keep the current helper until
the complete replacement is available across the admitted toolchains, then use
the [migration rule](../../README.md#migration-and-ownership) to delete obsolete
paths rather than retain parallel strategies. This card does not authorize an
upstream write or a supported-toolchain change.
