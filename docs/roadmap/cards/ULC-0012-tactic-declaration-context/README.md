# ULC-0012 Preserve declaration scope with a selected tactic context

- Status: candidate
- Priority: high
- Origin: Lean server, InfoTree and elaboration APIs; Beam #302
- Last reviewed: 2026-10-20
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: downstream evidence: https://github.com/leanprover/lean-beam/pull/302; no upstream implementation linked

## Problem and decision

A language-server consumer can obtain goals and metavariable assignments at a
position, yet that context does not contain every piece needed to elaborate a
new tactic in the enclosing declaration. Explicit universe binders can be legal
in the proof value without occurring in any goal or local declaration type.
Auxiliary declarations also require Lean's declaration-name generator to be
scoped, beyond setting `Term.Context.declName?`.

Agree a supported way to obtain the minimal declaration-scoped elaboration
context alongside the selected tactic basis, and to enter it using Lean's own
scoping operations. Possible placements include additional InfoTree scope
metadata or a helper returning that metadata; the card does not prescribe a
new public wire protocol or retain every elaborator state at every info node.
Record the intended auxiliary naming scope and universe scope together with
the selected before/after metavariable context.

The concrete smallest consumer is `runAt(pos, "tactic")`. Snapshot availability
is part of this contract: an already available body goal must not require the
rest of its enclosing declaration to finish. This is a declaration-context
slice, independent of the broad checkpoint readiness question in
[ULC-0002](../ULC-0002-backend-readiness-primitive/README.md).

## Evidence and acceptance

Source inspection uses Lean 4.36.0-rc1 commit
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:

- [ContextInfo](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/InfoTree/Types.lean#L21-L53) retains environment,
  metavariable context and the ordinary name generator, but no term universe scope.
  [runMetaM](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/InfoTree/Main.lean#L42-L58) reconstructs Core/Meta execution;
  it is not a complete tactic continuation API.
- [Term.withDeclName](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/Term/TermElabM.lean#L701-L710) also scopes auxiliary
  naming. [Core's generator](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/CoreM.lean#L143-L169) is stateful per elaboration branch.
- [HeaderProcessedSnapshot](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/DefView.lean#L58-L78) contains the missing
  declaration universe names. [Declaration elaboration](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/MutualDef.lean#L308-L324)
  publishes headers before body elaboration; [SnapshotTask.get?](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Language/Basic.lean#L163-L169)
  can inspect a finished result without waiting.

Reduced valid ordinary Lean control (synchronous elaboration is intentional):

```lean
set_option Elab.async false
theorem proofInUniverse.{u} (_ : Type u) : True := True.intro
theorem bodyUniverse.{v} : True := by
  exact proofInUniverse.{v} (ULift.{v} Nat)
```

At the `exact` tactic, the goal is `True`; `v` appears only in the proof value.
The same tactic submitted through the new context API must elaborate. Lean's
asynchronous unused-universe rejection remains an ordinary-language control,
not a requirement to accept an otherwise rejected declaration.

Acceptance must include:

- Body-only universe binders, ambient command universes, private declarations,
  nested proofs, mutual declarations and command-macro wrappers.
- Native Lean auxiliary-declaration tactics, with correct naming scope.
- A causal gate holding a later tactic: context lookup and the earlier tactic
  probe complete before the gate is released. Use observable synchronization,
  not elapsed-time thresholds as the success criterion.
- Separate requests and stored-state branches do not share derived elaboration
  state; document edits/cancellation preserve the server's existing request semantics.
  Paired probes are useful coverage but do not by themselves prove CPU overlap.

Existing public regression sources are
[HeaderUniverseTest](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/tests/lean/BeamTest/LSP/Requests/RunAt/HeaderUniverseTest.lean),
[AvailabilityTest](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/tests/lean/BeamTest/LSP/Requests/RunAt/AvailabilityTest.lean),
and [AuxiliaryDeclarationTest](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/tests/lean/BeamTest/LSP/Requests/RunAt/AuxiliaryDeclarationTest.lean).
Local Linux qualification of Beam `7f7d0c1` built/loaded its plugin and passed the
header, gated availability and paired-header probes on exact SDKs 4.33.1,
4.34.1, 4.35.0 and 4.36.0-rc1. The full pinned LSP suite passed locally and in
hosted Linux CI. These are downstream results, not proof that an upstream
replacement exists or a full cross-platform LSP qualification claim.

## Beam workaround and removal

A complete replacement could remove the implementation-specific
`finishedHeaderLevelNamesAt` traversal, the parsed-command lookup compatibility
adapter and the extra preceding-command scope lookup in
[RunAt](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/Beam/LSP/RunAt.lean#L239-L296), and reduce context reconstruction in
[ProofSnapshot.create](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/Beam/LSP/RunAt/ProofSnapshot.lean#L63-L91).
Keep the isolated request state, before/after position policy, semantic failures,
handle lifecycle and conformance tests. Do not delete goal universe collection
until the replacement demonstrably covers inferred parameters as well.

## Next action

The coordinator should assign a reduced Lean-only consumer and an API discussion
covering metadata placement, memory cost and the header-before-body availability
contract. Targeted issue searches on 2026-10-20 found no matching focused API
proposal; repeat issue/PR discovery before posting upstream. Record the first
version providing the complete contract, then apply the
[migration rule](../../README.md#migration-and-ownership). This card does not
raise Beam's supported Lean floor or authorize an upstream issue/PR write.
