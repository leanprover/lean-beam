/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean Elab Tactic

namespace BeamTest.LSP.Requests.RunAt.SuggestionSupport

private partial def suggestionEdits : InfoTree → Array Lsp.TextEdit
  | .context _ tree => suggestionEdits tree
  | .hole _ => #[]
  | .node info children => Id.run do
    let mut edits := #[]
    if let .ofCustomInfo info := info then
      if let some suggestion := info.value.get? Meta.Tactic.TryThis.TryThisInfo then
        edits := edits.push suggestion.edit
    for child in children do
      edits := edits ++ suggestionEdits child
    return edits

private def validBoundary (source : String) (pos : String.Pos.Raw) : Bool :=
  pos.byteIdx ≤ source.utf8ByteSize &&
    (pos.byteIdx == source.utf8ByteSize || source.toUTF8[pos.byteIdx]! &&& 0xc0 != 0x80)

/-- Inspect the actual typed suggestion edits before the public response renders message text. -/
elab "check_probe_suggestion " expectedPrefix:str " in " tac:tactic : tactic => do
  let map ← getFileMap
  unless map.source.startsWith expectedPrefix.getString do
    throwError "probe file map does not contain its speculative text"
  unless (← readThe Core.Context).fileName == "<runAt>" do
    throwError "probe file name differs from its parser input"
  let before := (← getInfoTrees).size
  evalTactic tac
  let trees := (← getInfoTrees).toArray
  let edits := (trees.extract before trees.size).foldl
    (fun edits tree => edits ++ suggestionEdits tree) #[]
  if edits.isEmpty then
    throwError "tactic produced no typed suggestion edits"
  let some expected := tac.raw.getRange? | throwError "tactic has no source range"
  unless validBoundary map.source expected.start && validBoundary map.source expected.stop do
    throwError "tactic range is not a valid UTF-8 range in the speculative source"
  for edit in edits do
    unless edit.range == map.utf8RangeToLspRange expected do
      throwError "suggestion range differs from its tactic range"
    let start := map.lspPosToUtf8Pos edit.range.start
    let stop := map.lspPosToUtf8Pos edit.range.end
    unless start == expected.start && stop == expected.stop &&
        validBoundary map.source start && validBoundary map.source stop do
      throwError "suggestion range does not round-trip through the speculative source"
    unless (String.Pos.Raw.extract map.source start stop).trimAscii.toString == "exact?" do
      throwError "suggestion range does not select its actual source tactic"

end BeamTest.LSP.Requests.RunAt.SuggestionSupport
