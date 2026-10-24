# ULC-0003 Tag setup-file diagnostics structurally

- Status: open
- Priority: medium
- Origin: Lean file worker
- Last reviewed: 2026-10-24
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and smallest upstream change

Lean turns `lake setup-file` stderr lines into information diagnostics at a
synthetic file-start range. Beam recognizes progress by range and text shape.
Tag these diagnostics using an existing stable code/data marker while retaining
the caption and current clearing behavior. Defer a dedicated progress protocol.

## Evidence

Source inspection at Lean `a946636` found the raw stderr callback in
[SetupFile.lean](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Server/FileWorker/SetupFile.lean#L71-L97) and
diagnostic construction in
[FileWorker.lean](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Server/FileWorker.lean#L391-L405).
No focused upstream issue or implementation is linked.

## Acceptance and scope

Source rechecked at Lean 4.36.0-rc1 revision
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`: the
[file-worker callback](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/FileWorker.lean#L388-L405)
still constructs informational diagnostics from setup stderr and clears them afterward.

Use an unbuilt local import to exercise setup progress and a user `logInfo` at
file start as the negative control. Test the serialized marker, unchanged human
caption, completion/failure clearing, and URI/version identity. Ordinary user
diagnostics must not acquire this tag. These acceptance fixtures remain proposed.
Keep normal `$/lean/fileProgress` semantics unchanged. Neither progress signal
is checkpoint-readiness authority.

## Beam workaround and removal

Delete the synthetic-range, prefix, and verb matchers in
[SyncSaveSupport](../../../../Beam/Broker/SyncSaveSupport.lean). Preserve the raw
caption for display and carry the stable classification through `StreamDiagnostic`.
Do not expose a Lake text parser as public API.

## Next action

Agree a marker with Lean maintainers and prepare a reduced setup-file fixture.
Use the [migration rule](../../README.md#migration-and-ownership) after support lands.
Historical todo filtering remains separate in
[BUC-0005](../BUC-0005-diagnostics-todo-progress/README.md).
The duplicate save-readiness evidence removed by proposed
[Beam #369](https://github.com/leanprover/lean-beam/pull/369) is a separate Beam
producer fix; it neither requires this upstream change nor implements the marker.
