# Exclusive close-save: model and implementation

This is a small model for evaluating exclusive close-save admission, with a separate pure
admission component used by the broker. The public contract is documented in
[sync and diagnostics](SYNC_AND_DIAGNOSTICS.md): close-save reserves the accepted document,
checkpoints it, and closes it while retaining exact-identity guards.

The contract gives an accepted close-save precedence over competing document work.
The caller coordinates its agents; the close reservation rejects conflicting document admissions.
A separate publication claim defers same-workspace changes while canonical publication settles;
it does not retry rejected operations.

## Abstract transitions

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

The implementation uses a bracket around a private admission capability:

```text
withClosingDocument(request, lease => {
  checkpoint = checkpointDocument(lease)
  finishClose(lease, checkpoint)
})
```

This pseudocode describes the ownership scope. In the broker, `withDocumentAdmission` captures
one permit before workspace admission helpers, source reads, or queued saves. Source acceptance
and the transition to closing occur together under the state lock. The request scope releases
only its own permit in `finally`, guarded by the workspace generation.

The pure [DocumentAdmission](../Beam/Broker/DocumentAdmission.lean) component stores only in-flight
permits. Reservation revokes competing permits for the same canonical URI. Released requests
leave no entries; the workspace's monotone allocation counter prevents reuse while older scopes
remain alive. This implements the abstract fence without retaining a map of closed paths.

Acquisition and cleanup belong to this one scope, with pure lifecycle transitions under short
owner-state critical sections. Cleanup examines current state and releases only its own lease.
It does not restore a captured session, recreate a removed workspace, perform backend writes,
or roll back committed artifacts.

The scope must cover typed failures, exceptions, and cooperative cancellation. A cancellation
flag alone does not settle canonical publication or final close delivery. Private preparation may
outlive reservation release after abandonment: its unique retained paths carry no publication
authority. The model's `release` does not require those isolated private writes to have stopped;
claimed canonical publication must settle before affected owner changes.

Likewise, successful `finish` abstracts successful close delivery plus broker removal.
Ambiguous notification delivery is not modeled as success or rollback. Integration must retain
the existing uncertain-close error behavior and reconcile or retire an uncertain backend before
admitting work that depends on its document state. Scoped cleanup does not solve blocked I/O,
process death, or lost acknowledgements.

## Proofs and examples

The specification and proofs live in the separate [BeamModel library](../model/README.md).
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

[AdmissionLaws.lean](../model/BeamModel/AdmissionLaws.lean) additionally imports the production
pure component and proves that reservation rejects new admissions, release removes exactly its
own entry and is idempotent, and every transition preserves allocation bounds. Successful
admission allocates a capability different from all retained live or revoked capabilities.
These are implementation laws; they still do not establish the broker's I/O behavior.

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

The fast suite builds the proofs and runs the schedules, including
[AdmissionTest.lean](../tests/lean/BeamTest/Model/AdmissionTest.lean), which exercises the actual
pure component's retry, retirement, delayed-work, and bounded-state behavior.

## Separate publication model

[Publication.lean](../model/BeamModel/Publication.lean) and
[PublicationLaws.lean](../model/BeamModel/PublicationLaws.lean) model one private publication attempt:
worker completion precedes trace readiness, only a ready current attempt can commit, and abandoned
attempts cannot regain authority through late completion. Canonical commit is one atomic abstract
transition. Disjoint private paths are an allocation assumption.

This model does not represent filesystem renames, rollback, hash sidecars, mutexes, claim waiting,
other processes, or crash recovery. Neither it nor the Closing proofs establish the runtime's
filesystem or lock behavior. The runtime publication claim and cancellation cutoff are described in
[sync and diagnostics](SYNC_AND_DIAGNOSTICS.md).

## Mapping to the broker

The runtime maps the abstract boundaries as follows:

| Model boundary | Integration obligation |
| --- | --- |
| Read permit | Capture before source reads and other asynchronous waits; retain it until admission |
| Source acceptance | Preserve the existing `readSeq` ordering and file-change checks |
| Reserve | Combine acceptance and reservation without an unlocked check/write gap |
| Owner and accepted basis | Use the private runtime-bound document reference, including workspace/backend lifetime |
| Competing operations | Cover implicit sync in semantic requests, explicit update/sync, refresh, save, and close |
| Commit observation | Preserve `SaveOleanCompleted` evidence after artifact and trace acknowledgement |
| Cleanup | Compare the lease against current owner state; no captured-state restoration |
| Owner replacement | Allow drop and teardown to supersede preparation; settle claimed publication before owner changes |

[test-save-finalization.py](../tests/test-save-finalization.py) gates helper preparation and
trace completion to check prompt conflict rejection, another document's admission, and release
after helper failure or cancellation. The native
[SaveOwnerTest](../tests/lean/BeamTest/Broker/SaveOwnerTest.lean) pauses an admitted request before
source reading, then checks that it cannot reopen a closed document or disturb a fresh reopening.
It also injects failures after real artifact-request writes, flushes, immediate propagated
cancellation writes, and close writes, checking that the captured backend terminates before the
response and that a committed checkpoint receipt survives. Artifact-request and cancellation
write schedules cover both save variants. A worker readiness rejection must instead preserve the
prior artifact, open document, and unrelated handles,
then permit a repaired document to close-save on the same backend. Injected replies check that bare
`invalidParams`, `contentModified`, and `requestCancelled` errors and malformed success payloads
preserve a healthy backend, its accepted document, and unrelated continuations for both save
variants, while retaining every private directory and claim. Typed handler failures permit private
cleanup, including when local cancellation changes the public error. These are protocol-boundary
injections, not a live watchdog termination reproduction.

`DocumentRef.withSettledEffect` tracks uncertain backend delivery around artifact dispatch and its
immediate propagated cancellation write, and around final closure. A failed protected write forces
termination through the captured backend's shared owner; detachment revokes that backend's
outstanding admissions. Successful artifact-request and cancellation writes clear the guard before
awaiting or decoding the response. A concurrent workspace drop cannot make retirement target a
replacement backend. The internal `$/beam/saveArtifacts` response is a typed completion
acknowledgement carrying either success or a handler failure. It is constructed
after the handler task and staging cleanup finish; construction-time rejection is also acknowledged.
The broker decodes this result before allowing private-path disposal, then presents a handler
failure with the existing error, readiness, progress, and cancellation rules. Completion establishes
that owned work finished, not that no artifacts were written or that a checkpoint was committed.

Bare JSON-RPC errors, including watchdog owner-loss errors, do not acknowledge handler completion.
Lean's file worker can also replace the acknowledgement with `requestCancelled` after publication;
that response leaves private producer completion uncertain. Error codes never establish completion.
Missing or malformed acknowledgement retains the isolated private paths and claims without retiring
a healthy backend. The separate publication model's `abandoned_run` law covers arbitrary late
private writes and completions without canonical commits. The pending store keeps its ordinary
typed failures without save-specific reply provenance. General blocked-I/O and
unconfirmed-termination behavior remain lifecycle limitations, not properties proved by this model.

Already-dispatched semantic requests are not represented here. They may finish under their
existing basis/lifetime guards, but must not reopen a closed document or acquire new work through
the closing document. Continuation requests use the same admission scope; the runtime conflict
test covers both `run_with` and `release`.

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
is implied by the Closing proofs.
