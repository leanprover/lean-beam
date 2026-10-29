# Exclusive close-save: model and implementation

For a conceptual introduction to admission, publication, protocol observations, and request
settlement, start with the [guided Blueprint](../model/blueprint/README.md). This note is the
detailed implementation and evidence reference.

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

The worker receives per-attempt private destinations. The worker validates duplicate
paths and module companion shape before writing. A temporary directory adapts `Lean.writeModule`'s
fixed companion names to independently supplied paths; its cleanup finishes before the terminal
handler acknowledgement. Serialization writes directly into the private destinations, so a failed
or cancelled attempt may leave a partial family. The broker alone owns canonical publication.
Every private output candidate ends in `.candidate`, including `.ilean` candidates, so Lean's recursive
`.ilean` extension scan does not index retained preparation as canonical output.

The internal artifact request omits the caller's cancellation reference. Cancellation is recorded
by the public request registry but is not forwarded to the worker; the broker awaits its typed
terminal completion before disposing acknowledged private paths. A cancellation check then rejects
the save before starting trace preparation. The broker writes and flushes a fresh private trace
candidate locally, then checks cancellation before claiming canonical publication. Local finalization
has no outstanding producer when it returns, including on failure. Worker/channel failure does not
establish producer settlement and may retain the attempt's directories and claims.

`Plan.ready` checks its phase, not producer completion. The sequencing obligation belongs to
`saveOleanCore`: accept a successful typed worker result and validate its version/text hash, check
caller cancellation, successfully finalize the private trace locally, then call `Plan.ready`.
Only afterward may the final owner/basis/cancellation guard claim promotion. The publication
model's `workerComplete` and `traceComplete` actions represent these successful preparation
boundaries. A typed worker failure establishes settlement for cleanup but does not authorize trace
preparation or readiness. This correspondence is tested runtime sequencing, not a theorem about
handler and filesystem I/O.

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
| Successful worker preparation precedes trace completion and readiness | Abstract `Publication.trace_requires_worker_completion`, `run_valid` | `saveOleanCore`: accepted worker result → local trace finalization → `Plan.ready` | CI Fast: `SaveOwnerTest` post-serialization cancellation, prelaunch cases; `PublicationTest` missing trace | Worker acknowledgement establishes producer settlement; local trace completion follows this runtime order. `Plan.ready` alone does not prove it. |
| Abandoned private work cannot regain canonical authority | Abstract `Publication.abandoned_run`, `not_ready_cannot_publish` | `Plan.ready`/`promote` phase guards and `dispose`; final captured owner/basis check | CI Fast: `beam-publication-test`, save owner-loss cases; opt-in: `test-private-save-publication.py` | Private attempts receive disjoint paths; no cross-process writer or crash model. |
| Final owner/basis/cancellation validation claims publication before filesystem effects; affected owner changes wait | Abstract `Publication.stale_owner_cannot_publish` covers stale authority only; waiting is unmodeled | `withDocumentPublication`, `withPublicationAvailable`, release/signalling in `finally` | CI Fast: `PublicationClaimTest` real-rename gate, cancellation, teardown, and failure schedules | All affected mutations join the claim; no mutex/wait/liveness theorem. |
| Canonical failure attempts recovery; successful rollback restores beforeimages; committed cleanup retains success | Filesystem behavior is unmodeled | `Publication.promote` backup transaction, exact hash invalidation, trace-last install, rollback/retention | CI Fast/native: `beam-publication-test`; CI Slow: installed checkpoint hash/replay tests | Filesystem rename/hard-link behavior, continued process execution, and no independent Beam/Lake writers. |
| Known commit survives later finalization failure | Abstract `Closing.run_preserves_commit`, `finish_requires_ownership` | `SaveOleanCompleted` after promotion; `finalizeSavedResponse` preserves `saved` | CI Fast: `ClosingTest`; save finalization uncertain-close/receipt cases | A commit must first become known; the model does not recover receipts after process or delivery failure. |
| Detached pending requests retain settlement responsibility; resolved outcomes remain stable | Abstract `RequestSettlement.unresolved_has_custodian`, `run_preserves_result`, `run_preserves_first_failure`; partial abstract correspondence in `SettlementCorrespondence` | `PendingRequestStore.remove`/`close`, reader resolution, retained send-failure reference, `IO.Promise.resolve` | CI Fast: `PendingTest.checkDetachedPendingSettlement`, closed-admission/close-race cases; `ProtocolTest.checkLateWriteFailure`; model settlement schedules | First-wins promise contract and handler-reference retention. No full runtime refinement, eventual resolution, or dispatch-result theorem. |
| Execution cleanup, accepted output, and physical delivery are distinct | Not modeled; [stdio coordinator](../Beam/Mcp/StdioServer.lean), [output writer](../Beam/Mcp/StdioOutput.lean) | `finishExecution` → `finishRequest`/`Slot.respond` → `deliveryTask`/`finishDelivery` | CI Fast: [McpRuntimeLifetimeTest](../tests/lean/BeamTest/Broker/McpRuntimeLifetimeTest.lean), `McpOutputTest`; CI Slow: [blocked-stdout close-save/drop/reopen](../tests/test-mcp-stdio.py) (`run_blocked_stdout_eof_cleanup`, live drop) | Bounded frame acceptance is not delivery; writer completion is not proof the client read the receipt. No model refinement or universal delivery guarantee. |


[test-save-finalization.py](../tests/test-save-finalization.py) gates Lake-helper preparation and
worker artifact completion to check prompt conflict rejection, another document's admission, and
release after preparation failure or cancellation. The native
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
every private directory and claim. These checks do not prove cleanup after arbitrary daemon
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

## Connecting the model to the backend protocol

The next verification boundary is the broker's interaction with an abstract Lean peer. It does
not require a model of elaboration, the watchdog implementation, or Lean's internal task scheduler.
Treat semantic results as opaque payloads. Prove when Beam may accept them and which effects they
authorize, rather than assuming that a successful response proves the underlying Lean theorem.

### Events, observations, and effects

Keep three accounts separate:

1. **Peer events:** reception of a complete request, worker failure, backend failure, and completion
   of private work. These can happen without the broker learning about them.
2. **Broker observations:** a correlated response, a typed completion acknowledgement, EOF, a write
   failure, or confirmed process termination. Each provides different evidence.
3. **Broker decisions and effects:** reject admission, remove a pending entry, authorize promise
   settlement, revoke publication authority, or request backend cleanup.

A backend crash is not an immediate `failAll` event. Buffered replies can remain readable after
process exit; descendants can retain pipes; a file-worker crash can leave the backend alive and
requests unanswered. An explicit local channel closure stops admission and transfers responsibility
for settling outstanding callers. It does not prove that remote work or descendant writes stopped.
Cancellation is a request for cooperation, not a channel closure or evidence of producer settlement.

[BackendProtocol](../model/BeamModel/BackendProtocol.lean) is an initial executable specification of
this **observation boundary**, not a model of all LSP behavior. It separates an unobserved crash from
local closure and proves that cancellation does not settle pending work, local closure rejects later
registration, repeated closure emits no additional settlement effects, and replies from a different
incarnation are ignored. Its settlement effects express responsibility, not completed IO. It does
not yet preserve the first typed failure, represent send uncertainty, prove all reachable-state
uniqueness properties, or establish correspondence with the implementation.

### The abstract Lean peer

An eventual executable peer should expose nondeterministic choices through explicit events supplied
by a scheduler. The same event vocabulary can drive small Lean traces and a controlled fake backend.
Start with these distinctions:

| Boundary | Permitted behavior and required limit |
| --- | --- |
| Input framing | Complete messages are received in serialized stream order. Partial writes can leave delivery uncertain; successful writing alone does not prove processing. |
| Execution | Requests may overlap and finish out of order. Input order alone does not imply elaboration or reference-index readiness. |
| Document updates | Accepted document revisions and backend incarnations are distinct. Only a documented Beam/Lean barrier justifies readiness for a specific operation. |
| Responses | Correlate by request ID within the owning backend incarnation. A different incarnation can reuse a numeric ID without owning the old request. |
| Notifications | Progress and diagnostics may arrive late and interleave with responses. Their URI/version association is weaker than a universal request-completion acknowledgement. |
| Worker failure | One document worker may fail while other documents continue. A response to every affected request is not assumed. |
| Backend failure | Further execution may stop without immediate EOF. Already-buffered messages can still be observed. Descendant settlement requires separate evidence. |
| Cancellation | May be delayed, ignored, or race with completion. A cancellation error alone does not certify the end of private writes. |
| Restart | Creates a fresh owner incarnation. Old observations cannot acquire authority in that new owner. This is internal identity, not a new public token API. |

FIFO reception is an assumption about the serialized transport adapter, not a global scheduler law.
The model must distinguish ordinary LSP responses from Beam-specific terminal acknowledgements:
only the latter's handler contract can certify that the relevant private producer has finished.
Likewise, #399's reference-index readiness barrier must not be generalized into a claim that any
response means all Lean subsystems are ready.

### The first production connection

`Beam.Broker.Pending` is a bounded starting point. Its store already serializes registration,
removal, and closure under one mutex. `Server.startRequestJsonTrackedDetailed` registers before
writing; `Server.sessionReaderLoop` removes a correlated entry before resolving it; store closure
records a terminal failure and drains entries before resolving their promises outside the mutex.

The critical interval is **after removal, before promise resolution**. An empty pending map is not
proof that all callers have settled. Map removal transfers responsibility to a handler, but it does
not revoke every other reference to the promise. In particular, the send-failure path retains the
original `PendingRequest`, discards the result of map removal, and can resolve that promise after
another handler has taken it. Lean's `IO.Promise.resolve` contract says only the first call has an
effect. Exactly one call to `resolve` is therefore **not** the current implementation invariant.

[RequestSettlement](../model/BeamModel/RequestSettlement.lean) now models one allocated request's
local lifecycle, including the detached interval and competing reader/writer resolution attempts.
Its [laws](../model/BeamModel/RequestSettlementLaws.lean) prove that reachable unresolved registrations
retain a custodian, established results cannot change, and the first channel failure remains retained.
A custodian is the pending map, the writer's active send/failure continuation, or a handler with a
settlement claim. This is abstract proof bookkeeping, not a proposed runtime ownership registry.
The model does not promise that a custodian runs, finishes, or survives a broker crash.

Response removal and channel closure may race for the pending entry. The winner transfers that
entry to its own handler; a later close cannot steal a detached response. Independently, a send
failure can leave the writer responsible for the same promise. The writer's removal and subsequent
read of the retained channel failure are separate transitions: closure between them changes the
selected failure; closure after selection does not retroactively change that selection. Either
reader or writer may resolve first. Once one succeeds, a later attempt cannot replace the result.
A channel can thus retain a failure while an already-detached request still resolves successfully.

The production [PendingTest](../tests/lean/BeamTest/Broker/PendingTest.lean)
`checkDetachedPendingSettlement` exercises both resolution orders with actual store operations and
promises, without sleeps or timing-dependent scheduling. It also checks that closing the store settles
unrelated pending work while leaving the detached promise unresolved. Existing
`checkPendingStoreClosedAdmission` and `checkPendingStoreCloseRace` cover retained failure and
registration/closure; `ProtocolTest.checkLateWriteFailure` covers the actual send-failure adapter.
These are integration evidence, not proofs that all adapter schedules follow the model.

[SettlementCorrespondence](../model/BeamModel/SettlementCorrespondence.lean) proves a **partial
abstract correspondence** with the earlier `BackendProtocol` model: response removal and closure
have the same projected state, and their emitted settlement effects match the corresponding handler
claims; promise resolution and writer failure selection leave that projected state unchanged. Writer
detachment has no matching event in the earlier model, so these laws do not constitute a complete
simulation. Registration before send still differs from LSP receipt. This
explicit gap is preferable to claiming the models already compose end to end.

The settlement model uses the following boundaries:

| Boundary | Treatment and remaining obligation |
| --- | --- |
| `IO.Promise.resolve` | First-wins is encoded in the abstract transition, based on `Init/System/Promise.lean` in the inspected Lean 4.36.0-rc1 SDK. It is a runtime assumption, not proved by this model. |
| Map operations | Register, remove, and drain are modeled as atomic local transitions. The production mutex supplies their serialization; resolution occurs afterward. |
| Local continuation lifetime | An unresolved registration retains a custodian in every modeled finite trace. The runtime must retain the corresponding reference and execute or transfer its responsibility; scheduling fairness and eventual completion are not assumed. |
| Send failure | Writer detachment and failure selection are separate, with the first observed channel cause preferred at selection time. The model makes no claim about whether bytes reached Lean. |
| Result versus presentation | `result` is the raw promise outcome. Caller cancellation can affect error presentation without changing that stored result; `PendingTest.checkPendingOutcomeCancellationPrecedence` and `checkPendingRawWorkerError` cover this separate production boundary. The send-failure adapter can also throw instead of returning the pending outcome; this model does not equate raw resolution with the caller-visible dispatch result. |
| Identity and scope | One allocated request in one fixed backend incarnation. Payloads and typed failure records are represented by distinct abstract atoms. Multi-request identity allocation, owner replacement, and global store refinement remain outside this model. |
| Peer failure | An unobserved peer crash does not settle local callers or stop admission. Observed local closure is a separate event. No event here proves that remote producers stopped. |

A production refinement milestone should contain:

- A pure pending-store transition used by the actual runtime, rather than a second implementation
  maintained solely for proofs. Parameterize request payloads, typed failures, and promise handles.
- An invariant over both pending entries and outstanding settlement obligations. Prove unique
  removal from the pending map, retention of unresolved responsibility, and preservation of a
  resolved result. Account for the writer's retained reference and harmless repeated resolution.
- A relation from runtime state to the abstract state, and an event mapping for each adapter call.
  Internal bookkeeping may correspond to no abstract step. Effectful intervals need explicit states.
- Named adapter assumptions: mutex serialization, request-ID freshness within an owner, correct
  framing/correlation, the first-wins promise primitive, and execution of returned settlement effects.
  Promise semantics alone do not prove that Beam invokes resolution on every path.
- Deterministic schedules for register/close, response/close, cancellation/reply, partial send,
  worker silence, and buffered replies after exit. Existing pending-store and backend-lifetime
  fixtures should be reused before adding fixtures. Source review identifies call order; regression
  tests exercise selected schedules; neither is a refinement proof.

Safety comes first: an arbitrarily delayed peer must not let stale work acquire current authority.
Any eventual-response or eventual-cleanup theorem needs separate fairness, scheduling, communication,
and process-settlement assumptions. No bounded cancellation or shutdown promise follows here.

### Revised proof work sequence

This is one proof lane. [#344](https://github.com/leanprover/lean-beam/pull/344) is the active
review entry point for the production admission laws, correspondence, and abstract protocol models.
[#359](https://github.com/leanprover/lean-beam/pull/359) remains a deferred draft preserving a
publication-core experiment. Resume it only against the accepted proof foundation and current
production code; it is not an independently evolving model or a prerequisite for this work.

1. **Direct admission laws and correspondence.** Preserve its direct production proofs;
   reconcile references with the current broker, local trace finalization, and execution/delivery
   separation. Keep it independently reviewable and free of runtime refactoring.
2. **Protocol observation specification, in the same proof-only PR.** Develop this initial boundary with send uncertainty,
   outstanding settlement obligations, and explicit peer traces. Label all its laws abstract until
   the implementation relation exists. Use it to decide the smallest useful production extraction.
3. **Production pending-store core and adapter.** Extract authoritative decisions only after the
   specification exposes a concrete obligation and the runtime change improves clarity. This is a
   separate PR from move-only `Broker.Server` module splits; update mappings after those splits.
4. **#359: publication authority.** Keep the saved extraction available, but reconsider its scope
   against the current publication path. Proving token allocation and exact release is useful but
   does not prove the owner/basis checks authorize the subsequent filesystem effects. The next
   meaningful milestone must relate the claim interval and effect authorization to those checks.

The existing publication and closing specifications remain higher-level contracts. Connect them
through explicit owner and completion evidence; do not merge them with transport delivery into one
large state machine. A shared vocabulary and a few composition invariants should earn their cost
before adding a generic protocol framework or modeling more Lean internals.

### LSP clause provenance

`BeamModel.LspRequests` is our formalization of a **subset** of LSP 3.17, not an official standard
model or a complete conformance checker. The source is pinned to the Microsoft specification
repository at commit `112d978951f2223a962bf19516637862f587bf55`, file
[`_specifications/lsp/3.17/specification.md`](https://github.com/microsoft/language-server-protocol/blob/112d978951f2223a962bf19516637862f587bf55/_specifications/lsp/3.17/specification.md).
Pinning this specification does not assert that every supported Lean version implements every
LSP 3.17 feature. The initial slice applies to one request direction on one initialized connection;
server-to-client requests need their own ledger, even when they reuse client-to-server IDs.

| Source clause | Formalization | Classification and remaining obligation |
| --- | --- | --- |
| `requestMessage`, `responseMessage` | Request creates an outstanding ID; matching response consumes it | Safety projection of correlation. A response may be success, null success, or error; these payloads are erased. Eventual response is not proved by finite-prefix safety. |
| `responseMessage`: response identifies the request | Unknown or duplicate response rejects the trace | Interpretation for well-formed, correlated exchanges. Parse-error responses with null ID and malformed input are outside this subset; rejection is a specification verdict, not prescribed Beam error handling. |
| Request-ID correlation | Simultaneously outstanding IDs are unique | Explicit modeling discipline needed for unambiguous correlation. IDs are interned atoms; integer/string wire encoding must be injective. Lifetime freshness is not assumed: reuse after completion is allowed here. |
| `notificationMessage` | Ordinary notification leaves the response ledger unchanged | Does not imply that notifications have no document or server effects. Those effects are abstracted away. |
| `dollarRequests`, `cancelRequest` | Cancellation leaves the response obligation unchanged | Cancellation can be ignored. The specification still requires a response to a cancelled request; it does not promise immediate interruption or stopped producers. |
| `messageOrdering` | Responses can consume any outstanding ID | Overapproximation for correlation safety. Method-specific correctness constrains permissible reordering; the ledger does not establish it. |

The normative response obligation is intentionally separate from the failure model. A finite trace
ending with outstanding work can be a prefix of a valid execution. An infinite healthy execution
that never responds would violate the response obligation; our finite-prefix laws do not certify
it. A crashed or hung peer must nevertheless remain a permitted environment for Beam's safety
proofs. Do not assume eventual replies to prove failure containment.

The two current models have different observation points. `LspRequests.request` records a complete
request in the protocol history; `BackendProtocol.register` is local registration **before** send.
They cannot be equated: a write can fail or remain partial after registration. Likewise,
`LspRequests.response` records a protocol response, whereas `BackendProtocol.closeChannel` emits
local settlement obligations without inventing any response from Lean. A transport model must
bridge these histories through buffering, delivery, and failure events. That bridge is not yet
implemented or proved.

A future Lean peer contract should provide named hypotheses for the applicable LSP clauses and
separate hypotheses for Lean/Beam extensions. In particular, document-basis readiness, reference
index readiness, and private-producer completion require their own contracts. A generic successful
LSP response cannot supply these facts. Beam-specific completion ordering belongs to the handler
implementation, not to an axiom about LSP or promises.

The checked laws in `LspRequests` establish cancellation/notification preservation, response
consumption, duplicate rejection, and preservation of unique outstanding IDs over accepted finite traces. The existing
`beam-closing-model-test` runner now also runs ten protocol-boundary checks, including out-of-order
responses, late cancellation, ID reuse, and the distinction between unobserved crash and local
closure. This runner is already in the fast suite. These checks do not establish Lean conformance,
transport refinement, or runtime settlement. Initialization, shutdown, document synchronization,
capability negotiation, and method semantics remain explicitly outside this first slice.
