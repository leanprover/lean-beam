import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "What is connected, and what remains trusted?" =>
%%%
tag := "guide-connections"
%%%

The most useful question for review is not “does the proof compile?” alone. Ask:
*which definition does the theorem concern, which code executes it, and what
connects that decision to its effects?*

:::group "model-correspondence"
The proved, partial relationship between the two abstract request models.
:::

:::definition "settlement-projection" (parent := "model-correspondence") (lean := "BeamModel.RequestSettlement.observation") (uses := "settlement-state, backend-observation")
*Between abstract models.* Project one request's settlement state to a fixed
backend incarnation, channel admission, and pending membership. Handler claims,
writer phase, and raw result are erased.
:::

:::theorem "settlement-reply-correspondence" (parent := "model-correspondence") (lean := "BeamModel.RequestSettlement.reply_claim_matches_observation") (uses := "settlement-projection")
*Partial abstract correspondence.* For a pending request, response removal emits
the coarse model's response-settlement effect and creates the detailed model's
reader claim with that raw outcome.
:::

:::theorem "settlement-close-correspondence" (parent := "model-correspondence") (lean := "BeamModel.RequestSettlement.close_claim_matches_observation") (uses := "settlement-projection")
*Partial abstract correspondence.* For a pending request, local closure emits
the coarse model's channel-failure effect and creates the detailed model's closer
claim with the retained cause.
:::

Those laws do not give a full simulation. Writer detachment has no corresponding
event in the coarse model. Nor do they connect either abstract model to every
production handler. Adding more graph edges would not close that gap.

# Three levels of evidence
%%%
tag := "guide-evidence"
%%%

1. *Direct production laws:* admission theorems import the component the broker
   actually uses. Call ordering, enclosing lifetime, and mutex behavior still need
   justification outside that pure component.
2. *Abstract laws:* closing, publication, protocol, and settlement theorems apply
   to their own transition systems. Their assumptions and refinement gaps matter.
3. *Runtime evidence:* gated/fault-injection tests exercise selected schedules
   involving real stores, promises, filesystem operations, and transport adapters.
   Passing those tests is not a proof of all schedules.

# Trusted boundaries
%%%
tag := "guide-trusted-boundaries"
%%%

* Mutex operations must serialize and expose the state changes the adapter relies
  on. A pure state transition alone supplies no memory-ordering theorem.
* {InlineLean.name IO.Promise.resolve}`IO.Promise.resolve` has first-wins behavior. Keeping a promise reference and
  invoking resolution on every required path are Beam's obligations, not a gift
  from that primitive.
* Request IDs and owner incarnations must identify the intended request. A local
  numeric ID does not survive arbitrary owner replacement by itself.
* A typed private-producer acknowledgement must be constructed after owned work
  finishes. A generic LSP success or cancellation error cannot substitute for it.
* Filesystem operations have individual outcomes. The abstract atomic promotion
  step must not grant multi-file atomic visibility or crash recovery to production.
* Successful writing does not establish that a client received or consumed a reply.

These are documented assumptions and adapter obligations, not new Lean axioms.
A future theorem parameterized by runtime laws will still depend on those laws;
axiom inspection alone would not list all such explicit hypotheses.

# The next connection should reduce duplication
%%%
tag := "guide-next-connection"
%%%

The bounded next step is to extract the pending store's pure registration,
removal, and closure decisions and have the runtime execute those definitions.
Prove first-failure retention, rejection after closure, and exact removal/draining
there. Keep mutexes and promise resolution in a thin adapter. Preserve the writer's
retained reference and first-wins behavior rather than adding a custody registry
just to mirror this Blueprint.

{tech}[Publication authority] is a later slice. Its meaningful proof must cover the
interval from validated identity and source through an installed claim to allowed
filesystem effects, not merely token allocation. The current higher-level models
remain specifications against which such production cores can be checked.

# What we deliberately do not promise
%%%
tag := "guide-limits"
%%%

These safety proofs do not establish Lean conformance, correct elaboration,
artifact-family atomicity, crash recovery, cross-process writer coordination,
producer termination, fairness, bounded cancellation, bounded shutdown, or client
delivery. A simpler contract can legitimately remove a theorem or an abstraction.
The purpose is to understand and justify useful guarantees, not accumulate models.
