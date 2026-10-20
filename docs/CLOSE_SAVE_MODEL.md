# Exclusive close-save: executable proposal

This is a small model for evaluating exclusive close-save admission. It does not change the
broker, CLI, or MCP behavior. Current behavior remains documented in
[sync and diagnostics](SYNC_AND_DIAGNOSTICS.md): close-save checkpoints a document and then
conditionally closes it if its accepted identity still matches.

The proposed contract gives an accepted close-save precedence over competing document work.
The caller coordinates its agents; Beam rejects conflicts rather than queuing, retrying, or
reordering their work.

## Proposed transitions

The model describes one canonical document slot within an owner lifetime. A slot can remain
addressable when no document is open. A **read permit** captures the owner and the slot's
admission fence before asynchronous work. The **fence** invalidates reads that started before a
close transition. A **lease** identifies one exclusive close attempt and its accepted document.
These are private model values, not proposed public request fields.

| Transition | Result |
| --- | --- |
| Begin a source read | Return a read permit, or reject if closing |
| Accept a read | Require a current permit and an open slot; accept the already ordered source |
| Reserve close-save | Accept source and acquire exclusive closure in one transition; advance the fence |
| Competing document operation | Reject while closing, including ordinary close and another close-save |
| Observe a committed checkpoint | Retain the receipt independently of the document's current lifetime |
| Finish closure | Require the same lease and a committed checkpoint; remove the document |
| Release the scope | Release only the matching lease, retaining its accepted document and any receipt |
| Ordinary close | Remove the document and advance the fence |
| Replace the owner | Invalidate permits and leases; retain historical checkpoint observations |

An unchanged read preserves the accepted document basis. A new close attempt receives a distinct
lease even when the source and basis are unchanged. Owner replacement may reuse local basis and
fence counters, but cannot reuse the owning identity.

Acceptance is the atomic reservation transition, not receipt of a transport request. A competing
update accepted before reservation can affect the source selected by close-save. After reservation,
the update receives a conflict rather than preventing closure.

## Why a closing flag is insufficient

An update can start a file read, pause, and reach document admission only after close-save has
finished. At that point a closing flag is absent. Unconditionally accepting the read would reopen
the file. The retained fence rejects that old permit; a fresh request can intentionally reopen it.

The fence must also survive failed closure: a delayed read from before reservation should not
silently resume after the caller receives a failure. The caller can issue a new request.

A lease distinguishes two attempts on the same basis. If attempt A fails, attempt B reserves the
unchanged document, and A's cleanup runs late, cleanup must not release B. Comparing only the
document basis does not establish cleanup ownership.

The model retains a fence in an absent slot for clarity. This is an implementation obligation,
not a requirement to retain an unbounded map of closed paths. An implementation may instead retire
captured admission capabilities, provided delayed work cannot reacquire a fresh capability.

## Scoped implementation boundary

The intended implementation shape is a bracket around a private lease:

```text
withClosingDocument(request, lease => {
  checkpoint = checkpointDocument(lease)
  finishClose(lease, checkpoint)
})
```

Acquisition and cleanup belong to this one scope, with pure lifecycle transitions under short
owner-state critical sections. Cleanup examines current state and releases only its own lease.
It does not restore a captured session, recreate a removed workspace, perform backend writes,
or roll back committed artifacts.

The scope must cover typed failures, exceptions, and cooperative cancellation. A cancellation
flag alone does not settle outstanding backend/helper effects: the owner must establish that
the operation has stopped, or retire its backend, before treating cancellation as completed.
The model's `release` represents that settled scope exit, not delivery of a cancellation request.

Likewise, successful `finish` abstracts successful close delivery plus broker removal.
Ambiguous notification delivery is not modeled as success or rollback. Integration must retain
the existing uncertain-close error behavior and reconcile or retire an uncertain backend before
admitting work that depends on its document state. Scoped cleanup does not solve blocked I/O,
process death, or lost acknowledgements.

## Proofs and examples

The specification and proofs form the independent [BeamModel library](../model/README.md).
The executable specification is [Closing.lean](../model/BeamModel/Closing.lean).
[ClosingLaws.lean](../model/BeamModel/ClosingLaws.lean) proves:

- Closing rejects new source-read initiation, acceptance, a second reservation, and ordinary close.
- Successful reservation advances the fence and installs exactly the returned lease.
- Foreign cleanup is inert, cleanup is idempotent, and cleanup after successful closure is inert.
- Successful closure requires both the exact lease and a committed checkpoint.
- Old reads remain invalid after release, closure, and owner replacement.
- Replacement rejects old finalization and cleanup.
- Every finite sequence of modeled transitions preserves previously observed commit receipts.
- Every finite sequence from the initial state keeps installed leases bound to the current owner
  and admission fence (`State.Valid`).

These are kernel-checked propositions, without `sorry` or added axioms. They are safety properties
of the model, not a refinement proof for the broker or a termination guarantee.

[ClosingTest.lean](../tests/lean/BeamTest/Model/ClosingTest.lean) runs eleven explicit schedules:
exclusive closure, delayed read versus intentional reopen, failure cleanup, retry on an unchanged
basis, replacement with reused local counters, commit observation after teardown, old reads after
replacement, postcommit cleanup without certifying a retry, ordinary close, source acceptance at
reservation, and duplicate finalization.

```sh
lake build BeamModel
lake build beam-closing-model-test
.lake/build/bin/beam-closing-model-test
```

The fast suite builds the proofs and runs the schedules.

## Mapping to the broker

Before changing the public behavior, translate the schedules into deterministic runtime tests:

| Model boundary | Integration obligation |
| --- | --- |
| Read permit | Capture before source reads and other asynchronous waits; retain it until admission |
| Source acceptance | Preserve the existing `readSeq` ordering and file-change checks |
| Reserve | Combine acceptance and reservation without an unlocked check/write gap |
| Owner and accepted basis | Use the private runtime-bound document reference, including workspace/backend lifetime |
| Competing operations | Cover implicit sync in semantic requests, explicit update/sync, refresh, save, and close |
| Commit observation | Preserve `SaveOleanCompleted` evidence after artifact and trace acknowledgement |
| Cleanup | Compare the lease against current owner state; no captured-state restoration |
| Owner replacement | Allow workspace drop and backend teardown to supersede closure |

Use sentinel gates before source acceptance, before trace completion, and before finalization.
Verify that competing work fails promptly, another document remains usable, cancellation/failure
releases ownership, and old cleanup cannot release a retry. A delayed read must fail after
successful closure while a newly initiated read can reopen the document.

Already-dispatched semantic requests are not represented here. They may finish under their
existing basis/lifetime guards, but must not reopen a closed document or acquire new work through
the closing document. Continuation-handle admission needs the same explicit audit.

## Scope and assumptions

This follows the pure-transition, theorem, and explicit-trace method used for the separate
workspace/document identity proposal. It does not adopt that proposal's public workspace
descriptor or version-allocation scheme. Public snapshot identity and stateless MCP adaptation
remain separate decisions.

The model assumes canonical paths, trusted internal permits/leases, and exact source equality.
Source-read ordering between ordinary updates is abstracted by requiring already ordered input;
the admission fence is additional to that ordering. Owner freshness abstracts the runtime,
workspace generation, and backend identity rather than prescribing their representation.

`observeCommit` is an external fact supplied by a completed publication, not an authorization
check. It deliberately allows a commit observation after owner loss. The append-only receipt
list is proof bookkeeping, not a proposal for a durable journal or unbounded production cache.
The model proves preservation of a known receipt, not that all real commits are acknowledged.

This model does not establish artifact-family coherence, coordination with other Beam processes
or Lake writers, dependency freshness, backend delivery, global-lock freedom, crash recovery,
fairness, or liveness. It models one document slot; runtime isolation across slots still requires
integration tests. No scheduler, public token, protocol downgrade, or publication-lock redesign
is part of this proposal.
