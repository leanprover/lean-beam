# Beam semantic models

`BeamModel` is a separate Lean library for executable specifications and their proofs.
It currently depends only on `Std`; neither the production broker nor its test fixtures are
dependencies. Production code does not import this library.

- [Closing](BeamModel/Closing.lean) describes the proposed exclusive close-save transitions.
- [ClosingLaws](BeamModel/ClosingLaws.lean) proves safety and ownership properties.
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
