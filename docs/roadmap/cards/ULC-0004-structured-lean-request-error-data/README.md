# ULC-0004 Preserve RequestError data

- Status: open
- Priority: medium
- Origin: Lean request API
- Last reviewed: 2026-10-24
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: none linked

## Problem and smallest upstream change

`Lean.Server.RequestError` retains only code and message even though the lower
JSON-RPC response already supports optional JSON data. Add optional data and
preserve it through `toLspResponseError` and the actual response serializers.

## Evidence and acceptance

Source inspection at Lean `a946636`:
[Requests.lean](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Server/Requests.lean#L26-L63) and
[JSON-RPC response errors](https://github.com/leanprover/lean4/blob/a946636c3a682c2033a18d0357dd9c1f48f00046/src/Lean/Data/JsonRpc.lean#L190-L210).
Source rechecked in Lean 4.36.0-rc1, revision
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:
[`toLspResponseError`](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Server/Requests.lean#L60-L64)
explicitly returns `ResponseError Unit`. A defaulted field alone is insufficient:
adapt this result type and inspect its callers before claiming source compatibility.

Test the actual serialized response with no data, structured data, and explicit
JSON null. Preserve code/message, cancellation and stale-file classification,
and the existing no-data wire shape. Forward a machine-readable reason through
Beam without parsing rendered exception text. These are proposed acceptance
tests, not a fresh upstream runtime pass.

## Beam workaround and removal

[Version checks](../../../../Beam/LSP/Lib/Request.lean) could attach typed
version/hash mismatch facts at the request owner and forward them through the
ordinary error path. Broker preflight still protects session consistency and
must remain. This is a small typed-boundary improvement, not a claim that
broker validation or all stale-state enrichment can be deleted.

## Next action

Prepare the small Lean API patch and serialized-response regression after
agreeing ownership. No focused upstream issue/PR is linked yet. Follow the
[support-window migration rule](../../README.md#migration-and-ownership).
