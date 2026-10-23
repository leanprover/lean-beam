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
one permit after path resolution and before workspace admission helpers, source-content reads, or
queued saves. Request receipt and path validation do not themselves acquire a permit. Source acceptance
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
flag alone does not settle canonical publication or final close delivery. Caller cancellation waits
for the current private phase's acknowledgement. Genuine owner/channel loss may instead abandon
private preparation with writers still uncertain: its retained paths carry no publication authority.
The model's `release` does not require those isolated private writes to have stopped; claimed
canonical publication must settle before affected owner changes.

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
own entry and is idempotent, and every transition preserves allocation bounds. Fencing followed by
matching release leaves every same-URI permit stale; successful reservation followed by release
has the same property. Retirement makes every permit stale. These three laws need no allocation
validity, prior membership, or distinctness assumptions; reservation additionally requires its
successful result. Successful admission allocates a capability different from all retained live or
revoked capabilities under the existing allocation invariant. These are implementation laws;
they still do not establish the broker's I/O behavior.

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
filesystem or lock behavior. The implementation boundaries below complement the public
[sync and diagnostics contract](SYNC_AND_DIAGNOSTICS.md).

## Publication implementation

The worker and Lake helper receive per-attempt private destinations. The worker validates duplicate
paths and module companion shape before writing. A temporary directory adapts `Lean.writeModule`'s
fixed companion names to independently supplied paths; its cleanup finishes before the terminal
handler acknowledgement. Serialization writes directly into the private destinations, so a failed
or cancelled attempt may leave a partial family. The broker alone owns canonical publication.
Every private output candidate ends in `.candidate`, including `.ilean` candidates, so Lean's recursive
`.ilean` extension scan does not index retained preparation as canonical output.

The internal artifact request omits the caller's cancellation reference. Cancellation is recorded
by the public request registry but is not forwarded to the worker; the broker awaits its typed
terminal completion before disposing acknowledged private paths. A cancellation check then rejects
the save before starting trace preparation. The trace helper likewise runs without caller
cancellation during its existing 30-second response wait. Its acknowledged success permits cleanup;
the final publication guard still rejects a cancelled caller. Worker/channel failure or a helper
timeout does not establish producer settlement and may retain the attempt's directories and claims.

`Plan.ready` checks its phase, not producer completion. The sequencing obligation belongs to
`saveOleanCore`: accept a successful typed worker result and validate its version/text hash, check
caller cancellation, obtain successful private-trace helper completion, then call `Plan.ready`.
Only afterward may the final owner/basis/cancellation guard claim promotion. The publication
model's `workerComplete` and `traceComplete` actions represent these successful preparation
boundaries. A typed worker failure establishes settlement for cleanup but does not authorize trace
preparation or readiness. This correspondence is tested runtime sequencing, not a theorem about
handler/helper I/O.

Trace preparation completing does not establish that its dependency inputs match the imports
actually loaded by the worker. That binding is a separate implementation obligation; neither
`traceComplete` nor the abstract `current` predicate proves imported-artifact provenance.

After preparation completes, the broker validates the captured workspace generation, backend
owner, accepted document basis, and cancellation state, then claims publication. That final
cancellation check is the cutoff: later cancellation cannot revoke the claim. Same-workspace changes
and owner teardown wait outside the global state mutex, then revalidate their captured identities.
Unrelated workspace work, read-only state access, and cancellation marking remain reachable. The
claim is released and waiters signalled after commit or recovery; filesystem I/O has no fixed bound.

The broker prepares all backup links before changing canonical outputs. Preparation failure removes
only the attempt's backup paths. Canonical publication removes the old trace, invalidates hashes
for exactly the artifact outputs written, and installs the new trace last. On failure, the complete
prepared beforeimages restore pre-existing outputs and remove originally absent outputs; recovery
continues after an individual failure. Successful recovery leaves the trace absent, and never
reinstalls the old trace. A failed restoration retains its backup, while successful restoration removes a
backup left behind by a same-file rename. Recovery failures are reported with the original failure.
After commit, backup cleanup is best effort: failure preserves checkpoint success and retains the
attempt's paths as cleanup evidence. These steps provide neither cross-process coordination nor
crash recovery, and do not make the artifact family atomically visible.

## Mapping to the broker

The table separates laws of production code from abstract specifications and runtime evidence.
`Admission.*` names [direct-production laws](../model/BeamModel/AdmissionLaws.lean) of
`DocumentAdmission`; `Closing.*` and `Publication.*` name the abstract law libraries above. **CI**
means the named regression is wired into that suite, not that its I/O behavior is kernel-proved.
**Opt-in** means a separate directed run. Execution and delivery have separate lifetimes under the
[MCP transport contract](MCP_TRANSPORT_CONTRACT.md#2-execution-admission-and-delivery-have-different-lifetimes).

| Invariant | Theorem / proof scope | Production boundary | Regression / suite | Unproved bridge or assumption |
| --- | --- | --- | --- | --- |
| Delayed reads stay invalid after ordinary fence and matching cleanup | Production `Admission.fence_release_rejects_same_uri`; abstract `Closing.old_read_after_close` | `withDocumentAdmission`, `fenceDocument`, matching `finally` release | CI Fast: `AdmissionTest`, `SaveOwnerTest.delayedAdmission` | Permit capture follows path resolution and precedes source-content reads; `readSeq` orders acceptance. |
| Reservation excludes new work; older permits stay invalid after cleanup | Production `Admission.reserve_blocks_admission`, `reserve_release_rejects_same_uri`; abstract `Closing.old_read_after_release` | Source acceptance plus `fenceDocument(reserve := true)` in one state transition | CI Fast: `AdmissionTest`; `test-save-finalization.py` exclusive, failure, and cancellation cases | Every implicit/explicit document operation uses admission; the state transition remains atomic. |
| Cleanup cannot release a different request | Production `Admission.release_preserves_other_entry`, `release_idempotent`; abstract `Closing.foreign_release_unchanged` | `withDocumentAdmission` releases its captured permit only in the matching workspace generation | CI Fast: `AdmissionTest` retry/old cleanup; `SaveOwnerTest` replacement cases | Workspace generation and captured permit are retained across waits, not recaptured. |
| Retirement invalidates permits and old finalizers | Production `Admission.retire_rejects_permit`; abstract `Closing.old_lease_after_replacement` | Backend detach/retire, `DocumentRef.withCurrentDocument` and session identity checks | CI Fast: `AdmissionTest`; `SaveOwnerTest` backend/workspace replacement; `PublicationClaimTest` exited-owner schedule | Runtime owner freshness and exact basis checks implement the abstract owner identity. |
| Allocation does not reuse retained capabilities | Production `Admission.admission_is_fresh` and transition `*_valid` laws | `State.admit` monotone `nextId`; workspace lifetime guards | CI Fast: `AdmissionTest` freshness/bounded-state schedules | `Admission.Valid` holds initially and is preserved; workspace replacement supplies a distinct lifetime. |
| Successful worker preparation precedes trace completion and readiness | Abstract `Publication.trace_requires_worker_completion`, `run_valid` | `saveOleanCore`: accepted worker result → trace helper success → `Plan.ready` | CI Fast: `SaveOwnerTest` post-serialization cancellation, trace/prelaunch cases; `PublicationTest` missing trace | Typed acknowledgements establish settlement; phase changes follow this runtime order. `Plan.ready` alone does not prove it. |
| Abandoned private work cannot regain canonical authority | Abstract `Publication.abandoned_run`, `not_ready_cannot_publish` | `Plan.ready`/`promote` phase guards and `dispose`; final captured owner/basis check | CI Fast: `beam-publication-test`, save owner-loss cases; opt-in: `test-private-save-publication.py` | Private attempts receive disjoint paths; no cross-process writer or crash model. |
| Final owner/basis/cancellation validation claims publication before filesystem effects; affected owner changes wait | Abstract `Publication.stale_owner_cannot_publish` covers stale authority only; waiting is unmodeled | `withDocumentPublication`, `withPublicationAvailable`, release/signalling in `finally` | CI Fast: `PublicationClaimTest` real-rename gate, cancellation, teardown, and failure schedules | All affected mutations join the claim; no mutex/wait/liveness theorem. |
| Canonical failure attempts recovery; successful rollback restores beforeimages; committed cleanup retains success | Filesystem behavior is unmodeled | `Publication.promote` backup transaction, exact hash invalidation, trace-last install, rollback/retention | CI Fast/native: `beam-publication-test`; CI Slow: installed checkpoint hash/replay tests | Filesystem rename/hard-link behavior, continued process execution, and no independent Beam/Lake writers. |
| Known commit survives later finalization failure | Abstract `Closing.run_preserves_commit`, `finish_requires_ownership` | `SaveOleanCompleted` after promotion; `finalizeSavedResponse` preserves `saved` | CI Fast: `ClosingTest`; save finalization uncertain-close/receipt cases | A commit must first become known; the model does not recover receipts after process or delivery failure. |
| Execution cleanup, accepted output, and physical delivery are distinct | Not modeled; [stdio coordinator](../Beam/Mcp/StdioServer.lean), [output writer](../Beam/Mcp/StdioOutput.lean) | `finishExecution` → `finishRequest`/`Slot.respond` → `deliveryTask`/`finishDelivery` | CI Fast: [McpRuntimeLifetimeTest](../tests/lean/BeamTest/Broker/McpRuntimeLifetimeTest.lean), `McpOutputTest`; CI Slow: [blocked-stdout close-save/drop/reopen](../tests/test-mcp-stdio.py) (`run_blocked_stdout_eof_cleanup`, live drop) | Bounded frame acceptance is not delivery; writer completion is not proof the client read the receipt. No model refinement or universal delivery guarantee. |

[test-save-finalization.py](../tests/test-save-finalization.py) gates helper preparation and
trace completion to check prompt conflict rejection, another document's admission, and release
after helper failure or cancellation. The native
[SaveOwnerTest](../tests/lean/BeamTest/Broker/SaveOwnerTest.lean) pauses an admitted request before
source reading, then checks that it cannot reopen a closed document or disturb a fresh reopening.
It also injects failures after real artifact-request writes, flushes, and close writes, checking
that the captured backend terminates before the
response and that a committed checkpoint receipt survives. Artifact-request write and flush
schedules cover both save variants. A worker readiness rejection must instead preserve the
prior artifact, open document, and unrelated handles,
then permit a repaired document to close-save on the same backend. Injected replies check that bare
`invalidParams`, `contentModified`, and `requestCancelled` errors and malformed success payloads
preserve a healthy backend, its accepted document, and unrelated continuations for both save
variants, while retaining every private directory and claim. Typed handler failures permit private
cleanup, including when local cancellation changes the public error. These are protocol-boundary
injections, not a live watchdog termination reproduction.

`DocumentRef.withSettledEffect` tracks uncertain backend delivery around artifact dispatch and final
closure. A failed protected write forces
termination through the captured backend's shared owner; detachment revokes that backend's
outstanding admissions. Successful artifact-request delivery clears the guard before
awaiting or decoding the response. A concurrent workspace drop cannot make retirement target a
replacement backend. The internal `$/beam/saveArtifacts` response is a typed completion
acknowledgement carrying either success or a handler failure. It is constructed
after the handler task and module-adapter cleanup finish; construction-time rejection is also acknowledged.
The broker decodes this result before allowing private-path disposal, then presents a handler
failure with the existing error, readiness, progress, and cancellation rules. Completion establishes
that owned work finished, not that no artifacts were written or that a checkpoint was committed.

The four post-serialization cancellation schedules in `SaveOwnerTest` hold the real worker's reply,
accept public cancellation, and prove that close-save reservations remain held while a sibling
continuation progresses. On release, ordinary save and close-save, with and without module companions, must
report cancellation, preserve canonical bytes/mtimes/hash caches and the healthy owner, and remove
every private directory and claim. The trace-helper cancellation schedule similarly releases real
helper work before asserting cleanup. These checks do not prove cleanup after arbitrary daemon
shutdown or channel loss.

Bare JSON-RPC errors, including watchdog owner-loss errors, do not acknowledge handler completion.
Caller cancellation is not forwarded to this private request, while other worker invalidation can
still prevent its acknowledgement. Error codes never establish completion.
Missing or malformed acknowledgement retains the isolated private paths and claims without retiring
a healthy backend. The separate publication model's `abandoned_run` law covers arbitrary late
private writes and completions without canonical commits. The pending store keeps its ordinary
typed failures without save-specific reply provenance. General blocked-I/O and
unconfirmed-termination behavior remain lifecycle limitations, not properties proved by this model.
Abandoned preparation directories and their `.claim` files may be removed manually only after all
possible worker/helper writers have stopped; this implementation has no background reaper.
Retained beforeimages after a reported publication/recovery failure must be investigated and used
for recovery before deletion. Stopping writers alone does not make that recovery evidence disposable.

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
A known commit is broker evidence (`SaveOleanCompleted`) that canonical promotion succeeded.
Accepted output means a bounded terminal frame has entered the output
writer's in-memory state; it may be an output-limit error rather than the original rich response.
Physical delivery means that writer's frame write/flush completed, not that the client consumed it.
These are separate milestones: neither response acceptance nor delivery creates or rolls back a
checkpoint. The model proves preservation of a known receipt, not that every real commit becomes
known, fits an accepted response, or reaches a client. See the
[caller-facing delivery limitation](SYNC_AND_DIAGNOSTICS.md#command-model).

This model does not establish artifact-family coherence, coordination with other Beam processes
or Lake writers, dependency freshness, backend delivery, global-lock freedom, crash recovery,
fairness, or liveness. It models one document slot; runtime isolation across slots still requires
integration tests. No scheduler, public token, protocol downgrade, or publication-lock redesign
is implied by the Closing proofs.
