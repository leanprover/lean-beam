# Beam semantic models

`BeamModel` is a separate Lean library for executable specifications and their proofs.
The abstract closing specification depends only on `Std`. Implementation laws additionally
import the broker's pure `DocumentAdmission` component, which also depends only on `Std`;
they do not import the runtime or its test fixtures. Production code does not import this library.

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
  pure component actually used by the broker.
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
