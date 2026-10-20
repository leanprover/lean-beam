/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.DocumentState

namespace BeamTest.Broker.DocumentFixture

/-- Reach a requested fixture version through acceptance, ending at the supplied snapshot. -/
def accepted (snapshot : Beam.Broker.DocumentState.FileSnapshot) (version : Nat := 1) :
    IO Beam.Broker.DocState := do
  let uri := "file:///fixture.lean"
  let mut docs := {}
  for i in [:version] do
    let next := {
      snapshot with
      rawSourceHash := snapshot.rawSourceHash + (version - i - 1).toUInt64
      readSeq := i + 1
    }
    docs := (Beam.Broker.DocumentState.syncFileDecision docs uri next).docs
  Beam.Broker.DocumentState.requireDocState docs uri

end BeamTest.Broker.DocumentFixture
