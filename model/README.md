# Beam semantic models

`BeamModel` is a separate Lean library for executable specifications and their proofs.
The abstract closing specification depends only on `Std`. Implementation laws additionally
import the broker's pure `DocumentAdmission` component, which also depends only on `Std`;
they do not import the runtime or its test fixtures. Production code does not import this library.

- [LspRequests](BeamModel/LspRequests.lean) formalizes a safety projection of the LSP 3.17
  request/response/cancellation contract. It is not a complete LSP conformance model; see
  [clause provenance](../docs/CLOSE_SAVE_MODEL.md#lsp-clause-provenance) for its sources and limits.
- [BackendProtocol](BeamModel/BackendProtocol.lean) specifies pending-request observations,
  distinguishing unobserved crashes, soft cancellation, and local channel closure. Its laws are
  abstract; settlement effects are obligations, not evidence of completed runtime IO.
- [RequestSettlement](BeamModel/RequestSettlement.lean) tracks one local request after map
  removal, including competing reader/writer promise resolutions. Its
  [laws](BeamModel/RequestSettlementLaws.lean) prove retained responsibility, stable results, and
  retention of the first channel failure. These are abstract laws under the first-wins promise
  contract, not a new production ownership registry or a progress guarantee.
- [SettlementCorrespondence](BeamModel/SettlementCorrespondence.lean) connects selected settlement
  transitions to the earlier backend-observation model. This partial abstract correspondence
  explicitly leaves writer detachment and the LSP delivery bridge unproved.
- [Closing](BeamModel/Closing.lean) describes the exclusive close-save transitions.
- [ClosingLaws](BeamModel/ClosingLaws.lean) proves safety and ownership properties.
- [Publication](BeamModel/Publication.lean) models one private preparation attempt and broker
  promotion authority. [PublicationLaws](BeamModel/PublicationLaws.lean) proves that abandonment
  survives all later actions, late completion cannot restore authority, reachable ready/committed
  states require worker and trace completion, and each attempt commits at most once. Distinct
  attempts are assumed to receive disjoint private paths; `current` abstracts successful broker
  identity/basis validation. Canonical commit is atomic only in this model: it does not prove
  filesystem rollback, crash atomicity, sidecar correctness, or exclusion of other processes.
- [AdmissionLaws](BeamModel/AdmissionLaws.lean) checks ownership and allocation laws of the
  pure component actually used by the broker, including fence/reservation cleanup and retirement
  invalidation, as well as allocation freshness.
- [The design note](../docs/CLOSE_SAVE_MODEL.md) defines assumptions, current implementation
  gaps, and the mapping to broker regression tests.

Check all model definitions and proofs:

```sh
lake build BeamModel
```

Concrete scenario runners belong in [the test tree](../tests/lean/BeamTest/Model), where they
import the model. The close-save runner is built and executed by the Beam fast suite:

```sh
lake build beam-closing-model-test
.lake/build/bin/beam-closing-model-test
```

A proved model property is not automatically a proved implementation property. Keep the
implementation correspondence, environment assumptions, and unmodeled effects explicit.

When a semantic change affects admission, ownership, cleanup, fencing, publication readiness/commit,
cancellation, or response acceptance/delivery, review the
[correspondence table](../docs/CLOSE_SAVE_MODEL.md#mapping-to-the-broker).
Update the relevant model, proof, test, or correspondence entry. If the existing abstraction and
evidence still apply, briefly explain why in the review. Routine refactors do not require a model
or documentation edit.
Keep abstract proofs, direct-production laws, runtime tests, and remaining assumptions distinct.
