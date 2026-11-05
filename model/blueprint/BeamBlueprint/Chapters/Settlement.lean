import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "Who still owes the caller a result?" =>
%%%
tag := "guide-settlement"
%%%

Removing a pending entry is a state transition. Resolving its promise is a later
effect. The interval between them matters: an empty pending map does not mean
all callers have settled.

:::group "request-settlement"
Responsibility for one request and stability of its raw result.
:::

:::definition "settlement-state" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.State")
*Abstract specification.* One allocated request records registration, pending-map
membership, writer phase, retained channel failure, handler claims, and raw promise
result. A {deftech}[settlement claim] records a handler's responsibility to attempt
resolution. It differs from a {tech}[publication claim], which permits canonical
filesystem effects. This
is proof bookkeeping, not a proposal for another production registry.
:::

:::definition "settlement-custodian" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.HasCustodian") (uses := "settlement-state")
An unresolved request has a {deftech}[custodian] if it is in the pending map, held by the
writer's active send/failure continuation, or held by a handler with a settlement
claim. A custodian may remain delayed indefinitely.
:::

:::definition "settlement-valid" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.Valid") (uses := "settlement-custodian")
Pending entries belong to an open channel. Every registered request is resolved
or has a custodian. A writer still sending also has pending membership, a handler
claim, or an established result, so finishing a successful write cannot orphan it.
:::

:::theorem "settlement-valid-traces" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.run_valid") (uses := "settlement-valid")
*Abstract law.* Every finite event trace preserves validity when started in a
valid state. Cancellation and unobserved peer crash do not discard responsibility.
:::

:::proof "settlement-valid-traces"
Check each transition, including removal before resolution and writer failure
before failure selection, then induct over the trace.
:::

:::theorem "settlement-retains-custody" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.unresolved_has_custodian") (uses := "settlement-custodian")
*Abstract law.* Every reachable registered request with no raw result retains a
custodian. This is a {tech (key := "safety invariant")}[safety property], not eventual resolution
or bounded shutdown.
:::

:::proof "settlement-retains-custody" (uses := "settlement-valid-traces")
Apply trace validity from the initial state. Since the request is registered and
has no result, the validity disjunction leaves the custodian case.
:::

:::theorem "settlement-first-result" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.run_preserves_result") (uses := "settlement-state")
*Abstract law under a runtime assumption.* Once a raw result is established,
every finite continuation preserves that same result. The transition encodes
Lean's documented first-wins promise contract; it does not prove the runtime
implementation of that primitive.
:::

:::proof "settlement-first-result"
Resolution keeps an existing result; all other events leave it unchanged.
Induction lifts the one-step property to a trace.
:::

# Trace: the reader and writer both hold the promise
%%%
tag := "guide-competing-handlers"
%%%

1. Registration inserts the request before sending. The writer retains its
   original reference.
2. The reader removes a correlated response from the map, then pauses before
   resolving the promise.
3. Channel closure drains unrelated entries. It cannot resolve this removed entry.
4. A send failure can still make the writer attempt resolution through its retained
   reference. The reader can also attempt resolution.
5. Whichever resolves first establishes the raw result. The second attempt cannot
   replace it. Exactly one call to {InlineLean.name BeamModel.RequestSettlement.resolve}`resolve` is not
   the implementation invariant.

The executable model makes both choices explicit. These booleans check that the
reader-first schedule retains response 17 and the writer-first schedule retains
failure 40. The schedules use the existing transition function, not a second
implementation of promise resolution.

```InlineLean.lean -keep (name := competingResolutions)
open BeamModel.RequestSettlement in
#eval
  let contested := run {} [.register, .reply (.response 17),
    .close 40, .writeFailed, .chooseWriteFailure 91]
  let readerFirst :=
    run contested [.resolve .reader, .resolve .writer]
  let writerFirst :=
    run contested [.resolve .writer, .resolve .reader]
  (readerFirst.result == some (.response 17),
   writerFirst.result == some (.failure 40))
```

```InlineLean.leanOutput competingResolutions
(true, true)
```

The real pending-store regression exercises both resolution orders without sleeps.
It also checks that unrelated pending requests settle on close while the removed
request remains unresolved. This is selected runtime evidence, not exhaustive
verification of the adapter.

:::theorem "settlement-first-channel-failure" (parent := "request-settlement") (lean := "BeamModel.RequestSettlement.run_preserves_first_failure") (uses := "settlement-state")
*Abstract law.* Once the store retains a channel failure, later events preserve
that cause. The writer chooses its failure separately from removing the request;
closure between those operations can affect the chosen cause.
:::

# Raw outcome is not the public response
%%%
tag := "guide-raw-outcome"
%%%

A caller's cancellation can change error presentation. A send-failure adapter can
throw instead of returning the pending result. Even a prepared response may never
be delivered. The raw result in {bpref "settlement-first-result"}[] must not be
confused with these later observations.
