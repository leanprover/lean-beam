# ULC-0015 Explicit document admission before Lean LSP worker allocation

- Status: candidate
- Priority: medium
- Origin: Beam workspace document admission / Lean LSP; [Beam #338](https://github.com/leanprover/lean-beam/pull/338)
- Last reviewed: 2026-10-22
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and decision

Lean's language-server watchdog accepts a client's `textDocument/didOpen` URI and full text and
starts a file worker without a workspace-root admission check. Its protocol overview states that
`initialize.rootUri` is unused; the server process's working directory supplies context. A client
that inadvertently sends an external or unsuitable document can therefore allocate a substantial
Lean worker before file setup or parsing reports a problem.

Beam's path-based API reads a document from disk and implicitly opens it in Lean. Its chosen policy
requires document paths to resolve inside the selected workspace, before source reads or worker
creation. #338 implements that client policy. Lean LSP instead receives client-provided text;
external dependency buffers, untitled buffers and unsaved content are legitimate use cases.

Discuss a named pre-worker admission contract and, if supported consumers need it, an opt-in policy
hook. Do not change the permissive default or impose unconditional cwd/root containment without
reviewing editor and embedding use cases. The public shape of a hook or configuration has not been
selected. Document-kind admission and worker-count/resource limits are separate decisions.

## Evidence and acceptance

Source inspected in Lean 4.36.0-rc1, revision
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:

- [src/Lean/Server/Watchdog.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/Watchdog.lean): `handleDidOpen` passes the URI, version and client text directly to
  `startFileWorker`; `startFileWorker` spawns `lean --worker` before forwarding initialization/open.
- [src/Lean/Server/ProtocolOverview.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/ProtocolOverview.lean): the initialize description records unused `rootUri` and
  process-cwd context.
- [src/Lean/Server/Utils.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/Utils.lean): `moduleFromDocumentUri` assigns an external module name to non-Lean
  or out-of-search-path URIs, rather than rejecting them.
- [src/Lean/Server/FileWorker/SetupFile.lean](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/FileWorker/SetupFile.lean): `lake setup-file` runs after the worker exists.

Historical Beam field feedback reported roughly 480 MB workers for accidental document opens.
At Beam `7d164fb0526bf4c6e2a9484ca9263cee2183d416`, `tests/lean/BeamTest/SystemContractTest.lean`,
`tests/test-installed-mcp-smoke.py`, `tests/test-mcp-stdio.py` and
`tests/test-native-toolchain.py` cover client rejection, outside paths, traversal and escaping
aliases. The published #338 CI checks passed on that head. These Beam observations do not
establish a fresh isolated stock-Lean-LSP reproduction; the upstream finding here is based on
source inspection.

Reduced upstream reproduction to add: initialize a stock Lean server in owned project A, send
`didOpen` for an owned external URI in B with supplied Lean text, then issue a request for that URI.
Record worker allocation and response/setup diagnostics. Include an unsaved external buffer so the
test does not confuse disk-file existence with document admission.

Acceptance for a future admission mechanism:

- Rejected documents allocate no file worker; their subsequent requests settle promptly and do not
  remain queued waiting for an open that policy will refuse.
- Define observable rejection behavior. `didOpen` is a notification and cannot receive a JSON-RPC
  error response; diagnostics/status and request failures must respect that protocol fact.
- Preserve default behavior for external dependencies, untitled buffers and unsaved editor content.
- Define URI/path identity and the scope of any canonical containment policy, with traversal,
  symlink and platform tests. Do not claim an OS filesystem sandbox.

## Beam workaround and removal

#338's canonical source-read gate in `Beam/Broker/Server.lean` must remain while Beam reads files
before sending their contents to Lean. A server-side hook alone cannot undo an earlier client disk
read. Share an upstream validation primitive only if it provides the same client-side boundary;
otherwise the useful outcome is earlier, explicit server admission for embedders, with Beam's own
workspace policy retained.

This card is independent of #338 landing, Beam's in-root file-kind policy, and worker-death
recovery. It does not require a new supported Lean minimum or authorize an upstream implementation.

## Next action

The Beam integration coordinator should identify a reproduction/design owner and search existing
Lean issues and PRs before proposing an upstream change. First document the current contract and
add the reduced stock-LSP test, then decide whether a configurable pre-worker policy has a
concrete editor/embedding consumer.
No complete providing Lean version has been identified; any later migration must follow the roadmap's
[migration and ownership rule](../../README.md#migration-and-ownership).
