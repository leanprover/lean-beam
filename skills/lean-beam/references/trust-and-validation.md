# Trust and proof confirmation

Beam supports non-adversarial Lean development. It provides feedback from the running Lean
server and saves development checkpoints; it is neither an independent proof validator nor an
OS security sandbox. Do not run untrusted Lean metaprograms through Beam as a security check.
Lean IO uses the actual CLI owner or MCP server's OS permissions. Sandboxing an attaching CLI
command does not constrain an existing owner launched outside it. A sandbox on agent shell commands
does not automatically constrain a separately launched MCP server. See
[sandbox permissions](setup-and-recovery.md#sandbox-permissions) for launch and local-network requirements.

## What the results establish

| Evidence | Meaning |
| --- | --- |
| Successful CLI/MCP request | The operation completed; inspect its semantic result and diagnostics. |
| Successful probe | The speculative execution succeeded in its selected elaboration context; inspect messages and the resulting state. |
| Empty goals alone | Neither semantic success nor declaration acceptance: failed or aborted probes can also leave no goals. |
| `save_ready` (CLI and MCP) | The snapshot is eligible for checkpointing. Warnings, including `sorry`, can remain. |
| Successful save | Beam wrote the accepted server snapshot after checking its recorded import basis. The conservative check has limits described below; batch elaboration was not rerun. |
| Successful clean `lake build` | Batch-build evidence for the selected targets and build inputs, subject to the project's cache policy. |

Elaboration and kernel checking use the selected imports, definitions, options, and axioms.
Checkpoint freshness and Lake's reuse decisions are separate from independent proof confirmation.
Neither refresh nor cache removal supplies the latter.

Coordinate edits through `update`/`sync` before dependent Beam work. Stop all affected CLI owners
and drop any affected MCP workspaces, confirming their cleanup, before external builds or
configuration changes; recreate sessions afterward. Unreported edits/builds while affected state
is retained, and uncoordinated writers using different session roots, are outside this workflow. Beam does not promise to discover
or reconcile them automatically.

## Reading a tactic result

For wrapper probes, inspect `result.success` and `result.proof_state.goals` when returned. For MCP,
first require `isError` to be absent or false, then inspect `structuredContent.success` and
`structuredContent.proof_state.goals`. The success field describes execution, so an agent must also
consider the remaining obligations and the tactic it supplied:

Use the proof state returned by the speculative attempt. A separate `goals` query inspects the
saved document's state; it does not continue that attempt.

Closing the selected goals does not establish that the real edit elaborates or passes declaration
termination checking. Confirm with a real edit and `sync`; see
[position semantics](workflow-details.md#position-semantics) for the limits of goal-only probes.

| Successful tactic attempt | Possible result | Interpretation |
| --- | --- | --- |
| `skip` on an open goal | `success: true`, a remaining goal | The tactic ran; the proof is unfinished. |
| `sorry` | `success: true`, empty goals | The goal was admitted. Empty goals do not make this an admission-free proof. |
| `omega` on a goal it solves | `success: true`, empty goals | The tactic closed the selected goals; independent confirmation is still separate. |

Saved source containing `sorry` can also sync with checkpoint readiness true and a warning count.
Readiness does not reject every admission. For MCP, `diagnostic_scope: "all"` with
`diagnostics_in_result: true` on `lean_sync` requests warning details in the result; it does not
change readiness or the proof. These checks belong to interpreting development feedback, without
running an external checker after every speculative attempt.

## External builds and retained state

An external rebuild while Beam retains affected importers is unsupported. `save` and `close-save`
now check the worker's recorded import basis and refuse with `saveImportsChanged` when they observe
a changed or unresolved workspace import trace. Use `refresh` to reload imports, then save again.
This temporary safeguard can require conservative refreshes and cannot detect an external rebuild
that races the worker's import load. See the
[checkpoint contract](https://github.com/leanprover/lean-beam/blob/main/docs/SYNC_AND_DIAGNOSTICS.md#command-model).
A successful incremental build does not independently establish that a checkpoint used the intended
imports.

Stop/drop the owning session and wait for cleanup before rebuilding, then recreate it. If the
external rebuild already happened, recreate the session before continuing; refreshing every affected
importer renews those document states but does not repair artifacts already published. Check results
with a fresh source build that does not reuse the affected artifacts or cached copies, or with kernel
replay (`lake check` on the versions below). These checks do not replace trusted challenge matching
when independent confirmation of the intended statement is required.

## Independent confirmation

For an independent proof-confirmation claim, follow Lean's
[proof validation guidance](https://lean-lang.org/doc/reference/latest/ValidatingProofs/): use
comparator with a trusted challenge and external checkers. Review the intended statement, referenced
definitions, and permitted axioms in a trusted environment. This is a separate acceptance step,
not an extra command after every Beam probe or save.

`#print axioms` helps audit assumptions; it does not establish that a statement means what was
intended. Kernel replay adds evidence; replay that directly loads `.olean` files trusts their
structural integrity. Neither replaces challenge matching and isolation for the stronger
confirmation above.
Remaining trust includes the logic, challenge and definitions, comparator implementation, sandbox,
and absence of a bug shared by every checker.

## Commands and availability

Lean 4.35.0 and 4.36.0-rc1 provide integrated `lake check` and `lake comparator`. On Linux, with
`bubblewrap` available, a solution project containing `lake-manifest.json`, and a reviewed challenge
configuration at an absolute trusted path, run in the solution project. Prepare a clean checking
environment and authenticate the challenge module and its referenced definitions before executing
untrusted code. An external JSON path alone does not authenticate modules resolved from the
workspace. Follow the official challenge setup guidance linked below.

```bash
lake comparator --config=/absolute/trusted/comparator.json --paranoid
```

The configuration selects the challenge, solution, theorem names and allowed axioms. `--paranoid`
adds the distributed external checkers. Require successful completion; a missing sandbox or checker
is not acceptance. Do not disable the sandbox to work around platform/setup failures. See the
[Lake checker contract and configuration](https://lean-lang.org/doc/reference/latest/Build-Tools-and-Distribution/Lake/#lake-comparator).

`lake check --paranoid` checks the project's default targets and standard axioms, but does not match
a trusted challenge. It therefore answers a different question from `lake comparator`.

The supported Lean 4.34.1 toolchain does not provide these integrated commands. Beam does
not supply an equivalent command for them: arrange a separately qualified checking environment or
report independent confirmation as unavailable. The former standalone
[comparator repository](https://github.com/leanprover/comparator) is archived; its old installation
instructions are not the current integrated workflow.
