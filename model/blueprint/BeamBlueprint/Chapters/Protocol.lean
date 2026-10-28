import Verso
import VersoManual
import VersoBlueprint
import BeamModel

open Verso.Genre
open Verso.Genre.Manual
open Informal

#doc (Manual) "What can Beam assume about Lean?" =>

Lean is an abstract peer here. We do not model elaboration, the file worker's
implementation, or its scheduler. Semantic results are opaque payloads. The
questions are whether a result belongs to current work and what evidence it gives.

:::group "protocol-observations"
Protocol obligations and the broker's observations of an abstract Lean peer.
:::

:::definition "lsp-ledger" (parent := "protocol-observations") (lean := "BeamModel.LspRequests.State")
*Protocol specification subset.* A ledger records outstanding request IDs for
one direction of one initialized connection. A request adds an unused outstanding
ID; a matching response consumes it. Notifications and cancellation leave this
ledger unchanged. Initialization, shutdown, document semantics, and capability
negotiation are outside this slice.
:::

:::theorem "lsp-cancellation" (parent := "protocol-observations") (lean := "BeamModel.LspRequests.cancellation_preserves_obligation") (uses := "lsp-ledger")
*Abstract law.* Cancellation leaves the response obligation unchanged. The LSP
specification still requires a response to a cancelled request; it does not
promise immediate interruption or certify that private writes stopped.
:::

:::theorem "lsp-unique-ids" (parent := "protocol-observations") (lean := "BeamModel.LspRequests.run_preserves_unique") (uses := "lsp-ledger")
*Abstract law.* Accepted finite traces preserve uniqueness of outstanding IDs
when the initial ledger is unique. Reuse after response is allowed. This is not
a proof that every outstanding request eventually receives a response.
:::

:::definition "backend-observation" (parent := "protocol-observations") (lean := "BeamModel.BackendProtocol.State")
*Broker observation specification.* A local store has an incarnation, an
admission flag, and pending keys. Local registration happens before transport
writing, so a registered request need not have reached Lean. A response or local
channel closure removes entries and emits settlement obligations.
:::

:::theorem "backend-unobserved-crash" (parent := "protocol-observations") (lean := "BeamModel.BackendProtocol.crash_is_not_observation") (uses := "backend-observation")
*Abstract law.* A peer crash with no local observation leaves the broker state
unchanged. This deliberate no-op prevents the model from granting Beam knowledge
it does not yet possess.
:::

# Trace: the peer crashes

1. Beam registers a request, then sends it.
2. Lean crashes. A reply may already be buffered; a descendant may keep stdout
   open; one file worker may fail while the backend remains alive.
3. Beam has not yet observed a terminal channel event. The pending request remains.
4. A response can still be read, or a later local closure can transfer responsibility
   for settling pending callers. Neither proves all remote writers stopped.

FIFO applies to complete messages on a serialized stream. It does not imply FIFO
completion, elaboration readiness, or reference-index readiness. Request execution
may overlap where method semantics permit. Those readiness conditions require
separate Lean/Beam contracts.

# The specification is not a perfect-server assumption

The LSP subset is based on pinned
[LSP 3.17 clauses](https://github.com/microsoft/language-server-protocol/blob/112d978951f2223a962bf19516637862f587bf55/_specifications/lsp/3.17/specification.md).
The implementation correspondence records the selected clauses and interpretations. It is our formalization, not an official complete
LSP model. Beam's safety must tolerate an environment that crashes or never replies;
we cannot assume eventual response to prove failure containment.

There is currently no complete transport refinement between {bpref "lsp-ledger"}[]
and {bpref "backend-observation"}[]. Registration differs from complete receipt;
local closure does not invent a response from Lean. Framing, buffering, partial
delivery, and method-specific ordering are still an explicit bridge to construct.
