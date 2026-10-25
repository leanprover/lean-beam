# ULC-0013 Define standalone tactic completion and pending declarations

- Status: candidate
- Priority: high
- Origin: Lean term/declaration elaboration APIs; Beam #302
- Last reviewed: 2026-10-20
- Backlog owner: Beam integration coordinator
- Implementer: unassigned
- Issue: none linked
- PR: downstream evidence: https://github.com/leanprover/lean-beam/pull/302; no upstream implementation linked

## Problem and decision

Executing a tactic and observing no remaining goals is insufficient to establish
that all its work has completed. Synthetic terms may still need elaboration.
Local `let rec` definitions are stored for lifting, closure construction and
termination checking by the enclosing declaration pipeline. A standalone tactic
consumer has not run that pipeline.

The first upstream ask is a documented, testable completion boundary for tactic
consumers: what synthesis guarantees, which pending declaration obligations remain,
and how a caller can detect them before reporting a reusable result. Decide
whether existing operations are sufficient with better documentation or whether
a small typed inspection helper is warranted. This bounded slice does not
promise that arbitrary tactic fragments can finalize an enclosing declaration.
Discarding derived state isolates the document, but does not discharge these
semantic obligations. A general isolated finalization operation would be a
separate design after the required inputs and behavior for partial goals are
understood.

## Evidence and acceptance

Source inspection uses Lean 4.36.0-rc1 commit
`c9afcddf514a6772bd4d649f7cfc04eff0b9f15e`:
[Term state](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/Term/TermElabM.lean#L177-L209) retains pending synthesis
work; [getLetRecsToLift](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/Term/TermElabM.lean#L684-L687) exposes recursive
definitions awaiting lifting. The [enclosing declaration pipeline](https://github.com/leanprover/lean4/blob/c9afcddf514a6772bd4d649f7cfc04eff0b9f15e/src/Lean/Elab/MutualDef.lean#L1398-L1442)
performs synthesis, collects local recursion and constructs predefinitions before
final declaration checks. Reusing that pipeline needs more context than a tactic
fragment alone supplies.

Compare these fragments inside an ordinary theorem body:

```lean
-- Valid ordinary Lean; still needs the enclosing declaration to finish.
example (offset : Nat) : ∃ _f : Nat → Nat, True := by
  let rec count (n : Nat) : Nat :=
    match n with
    | 0 => offset
    | n + 1 => count n + 1
  exact ⟨count, trivial⟩

-- Invalid ordinary Lean: termination must fail even though the main goal closes.
example : ∃ _f : Nat → Nat, True := by
  let rec loop (n : Nat) : Nat := loop n
  exact ⟨loop, trivial⟩
```

Acceptance for the initial completion contract:

- State the exact ordering: elaborate the tactic, synthesize postponed work,
  then inspect pending declaration work. Inspecting before synthesis misses
  recursion created by postponed terms.
- Cover direct recursion, recursion inside `have`/`refine`, postponed terms,
  nontermination, and recursion in a backtracked branch that leaves no pending work.
- Preserve direct synthesis diagnostics. Fatal/internal errors and interruption
  must not be converted into a successful completed result.
- A consumer rejecting unsupported pending work can restore its original proof
  state and avoid minting reusable follow-up state. The helper need not own a
  public handle protocol or a document mutation policy.
- Complete command elaboration continues through Lean's normal finalization and
  termination checks; an isolated tactic's limitations must not weaken that path.

[AuxiliaryDeclarationTest](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/tests/lean/BeamTest/LSP/Requests/RunAt/AuxiliaryDeclarationTest.lean#L278-L393)
compares valid and invalid ordinary replacements, postponed recursion, failure
rollback and stored-handle behavior. Beam `7f7d0c1` passed the full pinned LSP
suite locally on Linux and in hosted Linux CI. Earlier local mutation checks
showed that inspecting recursion before synthesis accepts a postponed
nonterminating fragment. These are downstream controls; no new Lean-only
reproducer execution or upstream implementation is claimed here.

## Beam workaround and removal

[runTacticText](https://github.com/leanprover/lean-beam/blob/7f7d0c1b35c56c12fc95ee621f603f8a495578f9/Beam/LSP/RunAt.lean#L454-L494) currently synthesizes inside
its saved-state boundary and rejects nonempty `getLetRecsToLift` with a semantic
failure, original goals and no successor handle. The exact diagnostic is:

> Local recursive declarations are not supported in runAt tactics. Add the declaration to the document and sync before probing.

A documentation-only upstream result clarifies this guard but does not remove it.
A typed completion inspector could replace the direct pending-state inspection.
Only a complete, isolated finalization contract would justify removing the local
recursion restriction and its skill/tool documentation. Keep rollback, synthesis
diagnostics, command termination and request-isolation tests in every case.
Declaration scope reconstruction is a separate prerequisite described in
[ULC-0012](../ULC-0012-tactic-declaration-context/README.md).

## Next action

The coordinator should assign a small Lean-only example that contrasts tactic
execution/synthesis with full declaration elaboration, then agree the completion
contract and documentation with Lean maintainers. Targeted issue searches on
2026-10-20 found no matching focused completion API proposal; search related
`let rec` discussions before preparing an upstream write. Record the first
complete providing version and actual Beam deletion before resolving migration;
apply the [migration rule](../../README.md#migration-and-ownership). No support
floor change or upstream issue/PR write is authorized by this card.
