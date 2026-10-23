# Trust and proof confirmation

Beam supports non-adversarial Lean development. It provides feedback from the running Lean
server and saves development checkpoints; it is neither an independent proof validator nor an
OS security sandbox. Do not run untrusted Lean metaprograms through Beam as a security check.

## What the results establish

| Evidence | Meaning |
| --- | --- |
| Successful CLI/MCP request | The operation completed; inspect its semantic result and diagnostics. |
| Successful probe | The speculative execution succeeded in its selected elaboration context; inspect messages and the resulting state. |
| Empty goals alone | Neither semantic success nor declaration acceptance: failed or aborted probes can also leave no goals. |
| `saveReady` (CLI) / `save_ready` (MCP) | The snapshot is eligible for checkpointing. Warnings, including `sorry`, can remain. |
| Successful save | Beam wrote the accepted server snapshot and its build record; batch elaboration was not rerun. |
| Successful clean `lake build` | Batch-build evidence for the selected targets and build inputs, subject to the project's cache policy. |

Elaboration and kernel checking use the selected imports, definitions, options, and axioms.
Checkpoint freshness and Lake's reuse decisions are separate from independent proof confirmation.
Neither refresh nor cache removal supplies the latter.

Coordinate edits through `update`/`sync` before dependent Beam work. Stop the CLI owner, or drop the
MCP workspace and wait for cleanup, before external builds or configuration changes; recreate the
session afterward. Unreported edits/builds while affected state is retained, and uncoordinated
writers using different session roots, are outside this workflow. Beam does not promise to discover
or reconcile them automatically.

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

The supported Lean 4.33.1 and 4.34.1 toolchains do not provide these integrated commands. Beam does
not supply an equivalent command for them: arrange a separately qualified checking environment or
report independent confirmation as unavailable. The former standalone
[comparator repository](https://github.com/leanprover/comparator) is archived; its old installation
instructions are not the current integrated workflow.
