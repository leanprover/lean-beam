# ULC-0001 Preserve the stale dependency URI

- Status: open
- Priority: high
- Origin: Lean server
- Last reviewed: 2026-10-19
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and smallest upstream change

Lean already sends a typed stale dependency URI to the file worker, which
discards that parameter and emits only a sticky warning. Preserve the URI in
existing diagnostic metadata with a stable diagnostic code. A new document-state
service is unnecessary for this first fix.

## Evidence

Source inspection at Lean `a946636` found the URI in
[`LeanStaleDependencyParams`](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Data/Lsp/Internal.lean#L333-L340),
existing [`Diagnostic.code?` / `data?`](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Data/Lsp/Diagnostics.lean#L122-L170),
and the lost parameter in
[`handleStaleDependency`](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Server/FileWorker.lean#L616-L634).
This is source evidence, not a fresh downstream reproduction or an upstream patch.

## Acceptance and scope

Publish a stable code and structured stale URI, retaining the human warning.
Test serialized diagnostics and normal replacement/clearing on worker restart
or document closure. The enclosing publication already identifies the importer
and document version; avoid duplicating state and lifecycle machinery.
Save/build policy and `needsSave` remain client decisions.

## Beam workaround and removal

Replace stale-warning text matching in
[SyncSaveSupport](../../../../Beam/Broker/SyncSaveSupport.lean) and URI guessing
in [StaleDirectDeps](../../../../Beam/Broker/StaleDirectDeps.lean).
Broker history may still enrich the authoritative URI with `needsSave`;
do not claim all history disappears. Preserve public stale-dependency and
recovery-plan tests. The Beam fallback question is
[BUC-0001](../BUC-0001-stale-import-dependency-reporting/README.md).

## Next action

Prepare a reduced diagnostic example and agree the stable code/data shape with
Lean maintainers. No focused upstream issue or implementation is linked yet.
Apply the support-window migration rule in the [index](../../README.md#migration-and-ownership).
