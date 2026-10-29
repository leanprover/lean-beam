import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "What are we modeling?" =>
%%%
tag := "guide-overview"
%%%

Beam mediates between a caller, a Lean server, and checkpoint files. The central
question is: *which work still has authority to change which state?* A request
can be cancelled, its document can be replaced, and the server can crash while
messages or private writes are still in flight. The model helps us distinguish
those events instead of treating them all as “the request finished.”

# One example to keep in mind
%%%
tag := "guide-example"
%%%

An agent asks Beam to save and close `Main.lean`. Beam accepts a particular source
basis and reserves that document. Lean prepares private candidate files. Beam
checks that the captured owner and source are still current, claims publication,
installs the checkpoint, and closes the accepted document. The response may reach
the client later, or never.

The small models often use natural numbers as names for sources, identities, or
payloads. These numbers are abstract atoms, not a proposed wire format or a hash
scheme. Equality represents the distinction the argument needs; connecting it to
real source text and owner lifetimes is a separate obligation.

The operation crosses five boundaries:

1. {ref "guide-admission"}[Admission] prevents a delayed source read from reopening
   the document after closure.
2. {ref "guide-publication"}[Publication authority] prevents an abandoned producer
   from installing a checkpoint later.
3. {ref "guide-peer-crash"}[Failure observation] distinguishes a peer crash from
   a response, EOF, or other evidence available to Beam.
4. {ref "guide-settlement"}[Settlement] accounts for a handler that removed a
   pending entry but still owes promise resolution.
5. {ref "guide-raw-outcome"}[Response delivery] remains separate from execution
   and the broker knowing that a checkpoint committed.

# How to read a transition system
%%%
tag := "guide-transitions"
%%%

Each small model defines a state, events, and a `step` function. An {deftech}[event trace] is a list
of events applied in order. The step functions are deterministic; uncertainty
comes from which events the environment supplies and when. We quantify over
permitted traces rather than inventing a global scheduler for Lean.

A transition may return a new state and a result, reject the event, or emit an
effect obligation. An emitted obligation says what a handler must still do; it
is not evidence that the I/O already happened.

A {deftech}[safety invariant] says that a bad state cannot be reached through those steps.
It does not say that another step will ever happen. An arbitrarily delayed worker
is allowed. “Responsibility has not been lost” is weaker than “the caller will
soon receive a result.”

# The models are different views, not one verified machine
%%%
tag := "guide-model-map"
%%%

:::table +header
*
  * View
  * State it tracks
  * Evidence
*
  * {bpref "closing-state"}[Closing]
  * One document slot and close attempt
  * Abstract laws
*
  * {bpref "admission-state"}[Document admission]
  * In-flight permits in a workspace
  * Direct production laws
*
  * {bpref "publication-state"}[Publication]
  * One attempt's preparation and authority
  * Abstract laws
*
  * {bpref "lsp-ledger"}[LSP requests]
  * Outstanding response obligations
  * Protocol specification subset
*
  * {bpref "backend-observation"}[Backend observations]
  * Local registration and channel closure
  * Abstract laws
*
  * {bpref "settlement-state"}[Request settlement]
  * One promise and its responsible handlers
  * Abstract laws
:::

These states must not be identified just because they contain a request or a
completion flag. Local registration precedes sending. A protocol reply differs
from a promise resolution. A typed private-producer acknowledgement differs from
an ordinary successful LSP response. Only selected relationships have been proved.

# Reading the graph honestly
%%%
tag := "guide-graph"
%%%

The graph is a curated map of definitions and laws. Its view selector offers a
group overview and focused chapter groups; zoom or select a node for its details.
An edge records a mathematical dependency; a prose reference merely helps navigation. Each theorem states whether
it concerns the abstract specification or the production admission component.
A checked Lean association means that the cited declaration exists and is checked.
It does *not* turn an abstract theorem into a proof of the broker's I/O behavior.

The {ref "guide-connections"}[final chapter] describes runtime assumptions and
unproved bridges.
They are not added as axioms or disguised as completed theorem nodes. The detailed
implementation/test correspondence remains in the repository
[design note](https://github.com/leanprover/lean-beam/blob/8f7323d27f05e6dba98ae47b32b609e9fa60e4fe/docs/CLOSE_SAVE_MODEL.md)
(the linked proof-foundation snapshot); this Blueprint supplies the conceptual
reading path. Declaration previews are built from the current checkout.
