import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "What are we modeling?" =>

Beam mediates between a caller, a Lean server, and checkpoint files. The central
question is: *which work still has authority to change which state?* A request
can be cancelled, its document can be replaced, and the server can crash while
messages or private writes are still in flight. The model helps us distinguish
those events instead of treating them all as “the request finished.”

# One example to keep in mind

An agent asks Beam to save and close `Main.lean`. Beam accepts a particular source
basis and reserves that document. Lean prepares private candidate files. Beam
checks that the captured owner and source are still current, claims publication,
installs the checkpoint, and closes the accepted document. The response may reach
the client later, or never.

The small models often use natural numbers as names for sources, identities, or
payloads. These numbers are abstract atoms, not a proposed wire format or a hash
scheme. Equality represents the distinction the argument needs; connecting it to
real source text and owner lifetimes is a separate obligation.

There are several different questions along this path:

1. Can a delayed source read reopen the document after closure? Admission and the
   closing specification address this.
2. Can a cancelled or abandoned producer publish later? The publication
   specification addresses authority, while private destinations enforce isolation.
3. Does a crashed server necessarily reply, or cause immediate EOF? No. The
   protocol models distinguish peer events from broker observations.
4. Does an empty pending map mean every caller has a result? No. A handler may
   already have removed an entry and still owe promise resolution.
5. Does a committed checkpoint imply that its receipt reached the client? No.
   Execution, knowledge of commit, and delivery are separate boundaries.

# How to read a transition system

Each small model defines a state, events, and a `step` function. A trace is a list
of events applied in order. The step functions are deterministic; uncertainty
comes from which events the environment supplies and when. We quantify over
permitted traces rather than inventing a global scheduler for Lean.

A transition may return a new state and a result, reject the event, or emit an
effect obligation. An emitted obligation says what a handler must still do; it
is not evidence that the I/O already happened.

A safety invariant says that a bad state cannot be reached through those steps.
It does not say that another step will ever happen. An arbitrarily delayed worker
is allowed. “Responsibility has not been lost” is weaker than “the caller will
soon receive a result.”

# The models are different views, not one verified machine

* `Closing` tracks one document slot and exclusive close attempt.
* `DocumentAdmission` is the actual pure production component; `AdmissionLaws`
  proves its behavior directly.
* `Publication` tracks one attempt's private preparation and canonical authority.
* `LspRequests` tracks response obligations in one direction of an initialized
  protocol connection.
* `BackendProtocol` tracks local registration and observed channel closure.
* `RequestSettlement` tracks one local promise and the handlers responsible for it.

These states must not be identified just because they contain a request or a
completion flag. Local registration precedes sending. A protocol reply differs
from a promise resolution. A typed private-producer acknowledgement differs from
an ordinary successful LSP response. Only selected relationships have been proved.

# Reading the graph honestly

The graph is a curated map of definitions and laws. Its view selector offers a
group overview and focused chapter groups; zoom or select a node for its details. An edge records a mathematical
dependency; a prose reference merely helps navigation. Each theorem states whether
it concerns the abstract specification or the production admission component.
A checked Lean association means that the cited declaration exists and is checked.
It does *not* turn an abstract theorem into a proof of the broker's I/O behavior.

Runtime assumptions and unproved bridges are described in the final chapter.
They are not added as axioms or disguised as completed theorem nodes. The detailed
implementation/test correspondence remains in the repository
[design note](https://github.com/leanprover/lean-beam/blob/8f7323d27f05e6dba98ae47b32b609e9fa60e4fe/docs/CLOSE_SAVE_MODEL.md)
(the linked proof-foundation snapshot); this Blueprint supplies the conceptual
reading path. Declaration previews are built from the current checkout.
