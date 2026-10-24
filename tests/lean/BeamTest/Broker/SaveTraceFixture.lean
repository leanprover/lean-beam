/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.LakeSave
import BeamTest.Broker.JsonAssert

open Lean System Beam.Broker BeamTest.Broker.JsonAssert

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
  writePrivateSaveTrace spec
  let original ← IO.FS.readBinFile spec.tracePath
  let unsupported := { spec with
    tracePath := root / "unsupported-schema.trace.candidate"
    traceMetadata :=
      spec.traceMetadata.setObjVal! "schemaVersion" (toJson ("unknown trace format" : String)) }
  let rejected ← try writePrivateSaveTrace unsupported *> pure false catch
    | .userError .. => pure true
    | error => throw error
  require "unknown target trace schema is rejected" rejected
  require "unsupported schema does not create a candidate" (!(← unsupported.tracePath.pathExists))
  require "unsupported schema preserves the prior trace"
    ((← IO.FS.readBinFile spec.tracePath) == original)
  let occupied ← try writePrivateSaveTrace spec *> pure false catch
    | .alreadyExists .. => pure true
    | error => throw error
  require "trace preparation rejects an occupied candidate" occupied
  require "occupied candidate is not overwritten" ((← IO.FS.readBinFile spec.tracePath) == original)
  let missingParent := root / "missing-private-parent"
  let missing := { spec with tracePath := missingParent / "Saved.trace.candidate" }
  let rejected ← try writePrivateSaveTrace missing *> pure false catch
    | .noFileOrDirectory .. => pure true
    | error => throw error
  require "trace preparation rejects a missing parent" rejected
  require "trace preparation does not recreate its parent" (!(← missingParent.pathExists))
  let contents ← IO.FS.readBinFile spec.cPath
  IO.FS.removeFile spec.cPath
  try
    let missingOutput := { spec with tracePath := root / "missing-output.trace.candidate" }
    let rejected ← try writePrivateSaveTrace missingOutput *> pure false catch
      | .noFileOrDirectory .. => pure true
      | error => throw error
    require "missing C output rejects trace preparation" rejected
    require "missing C output does not create a trace" (!(← missingOutput.tracePath.pathExists))
    require "preparation failures preserve the prior trace"
      ((← IO.FS.readBinFile spec.tracePath) == original)
  finally
    IO.FS.writeBinFile spec.cPath contents

/-- Reuse prepared inputs so the caller can impose an I/O failure only on finalization. -/
def writePrepared (root : FilePath) : IO Unit := do
  let spec ← IO.ofExcept <| Json.parse (← IO.FS.readFile (root / "spec.json")) >>= fromJson?
  writePrivateSaveTrace spec

end BeamTest.Broker.SaveTraceFixture
