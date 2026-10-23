/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lake

open Lean System Lake

/-! Run directly with a target SDK: this reader deliberately has no Beam dependency. -/

def main (args : List String) : IO Unit := do
  let [directory] := args | throw <| IO.userError "expected trace fixture directory"
  let root := FilePath.mk directory
  let spec ← IO.ofExcept <| Json.parse (← IO.FS.readFile (root / "spec.json"))
  let metadata ← IO.ofExcept <| BuildMetadata.parse (← IO.FS.readFile (root / "Saved.trace"))
  let some outputs := metadata.outputs? | throw <| IO.userError "trace has no outputs"
  let decoded ← IO.ofExcept <| fromJson? (α := ModuleOutputDescrs) outputs
  unless (toJson decoded).compress == outputs.compress do
    throw <| IO.userError "target Lake changed output descriptors while decoding"
  let descr := fun field ext => do
    let path : FilePath ← IO.ofExcept <| spec.getObjValAs? FilePath field
    return toJson (artifactWithExt (← computeHash path) ext)
  let expected := Json.mkObj [
    ("m", toJson true),
    ("o", toJson (#[← descr "oleanPath" "olean", ← descr "oleanServerPath" "olean.server",
      ← descr "oleanPrivatePath" "olean.private"] : Array Json)),
    ("i", ← descr "ileanPath" "ilean"), ("c", ← descr "cPath" "c"),
    ("r", ← descr "irPath" "ir"), ("rs", ← descr "irSigPath" "ir.sig"),
    ("b", ← descr "bcPath" "bc")
  ]
  unless outputs.compress == expected.compress do
    throw <| IO.userError s!"broker trace hashes differ from target Lake: {outputs.compress}"
  let prepared ← IO.ofExcept <| spec.getObjVal? "traceMetadata"
  unless (toJson metadata).compress == (prepared.setObjVal! "outputs" expected).compress do
    throw <| IO.userError "broker trace changed prepared dependency metadata"
  IO.println "broker trace matches target Lake metadata and artifact hashes"
