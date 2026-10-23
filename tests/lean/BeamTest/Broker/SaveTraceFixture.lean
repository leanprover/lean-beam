/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.LakeSave

open Lean System Beam.Broker

namespace BeamTest.Broker.SaveTraceFixture

/-- Produce a complete trace through the broker writer for independent target-Lake readers. -/
def write (root : FilePath) : IO Unit := do
  IO.FS.createDirAll root
  let spec : LeanSaveSpec := {
    moduleName := "Saved"
    oleanPath := root / "Saved.olean"
    oleanServerPath? := some (root / "Saved.olean.server")
    oleanPrivatePath? := some (root / "Saved.olean.private")
    ileanPath := root / "Saved.ilean"
    irPath? := some (root / "Saved.ir")
    irSigPath? := some (root / "Saved.ir.sig")
    cPath := root / "Saved.c"
    bcPath? := some (root / "Saved.bc")
    tracePath := root / "Saved.trace"
    traceMetadata := toJson (Lake.BuildMetadata.ofBuild
      (Lake.BuildTrace.ofHash (Lake.Hash.ofNat 73) "save inputs") Json.null {})
  }
  let paths := #[spec.oleanPath, spec.ileanPath, spec.cPath] ++
    #[spec.oleanServerPath?, spec.oleanPrivatePath?, spec.irPath?, spec.irSigPath?, spec.bcPath?].filterMap id
  for path in paths do
    -- Binary bytes and CRLF ensure the trace uses artifact hashing rather than text normalization.
    IO.FS.writeBinFile path <| (path.fileName.getD "").toUTF8 ++ ⟨#[0, 255, 13, 10]⟩
  IO.FS.writeFile (root / "spec.json") (toJson spec).pretty
  writeLeanSaveTrace spec

end BeamTest.Broker.SaveTraceFixture
