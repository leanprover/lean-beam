/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.DocumentState
import BeamTest.Broker.JsonAssert

open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.DocumentStateTest

private def mkDoc (version : Nat := 1) (moduleName? : Option String := none) : DocState := {
  version
  rawSourceHash := 0
  documentHash := 0
  lakeTraceHash := default
  textMTime := default
  moduleName?
}

private def checkTrackedModuleName : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  require "lean module path"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.lean") == some "Foo.Bar")
  require "non-lean file has no module"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.v") == none)
  require "outside root has no module"
    (DocumentState.trackedModuleName? root (System.FilePath.mk "/other/Foo.lean") == none)

private def checkRecordFileProgress : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc)
  let docs := DocumentState.recordFileProgress docs uri (some { updates := 2, done := false })
  let some doc := docs.get? uri
    | throw <| IO.userError "recordFileProgress erased existing doc"
  require "recordFileProgress records existing doc progress"
    (doc.fileProgress? == some { updates := 2, done := false })
  let docs := DocumentState.recordFileProgress docs "file:///workspace/Missing.lean" (some {})
  require "recordFileProgress ignores unknown docs" (docs.toList.length == 1)

private def mkSnapshot
    (rawSourceHash : UInt64)
    (moduleName? : Option String := some "Foo") : DocumentState.FileSnapshot := {
  rawSourceHash
  documentHash := rawSourceHash
  lakeTraceHash := default
  textMTime := default
  moduleName?
}

private def checkSyncFileDecisionOpen : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let decision := DocumentState.syncFileDecision {} uri
    (mkSnapshot 10)
  require "syncFileDecision opens unknown doc" (decision.action == .open)
  require "syncFileDecision open starts at version 1" (decision.version == 1)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision open did not insert doc"
  require "syncFileDecision open records hash" (doc.rawSourceHash == 10)
  require "syncFileDecision open records module" (doc.moduleName? == some "Foo")

private def checkSyncFileDecisionUnchanged : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc 5 (some "OldFoo")) with
      rawSourceHash := 10
      checkpointedVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncEventSeq := 8
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 10 (some "Foo"))
  require "syncFileDecision unchanged has no LSP action" (decision.action == .unchanged)
  require "syncFileDecision unchanged preserves version" (decision.version == 5)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision unchanged erased doc"
  require "syncFileDecision unchanged preserves checkpointed version"
    (doc.checkpointedVersion? == some 5)
  require "syncFileDecision unchanged preserves progress" (doc.fileProgress? == some { updates := 2, done := true })
  require "syncFileDecision unchanged refreshes module" (doc.moduleName? == some "Foo")
  require "syncFileDecision unchanged preserves sync event seq" (doc.lastSyncEventSeq == 8)

private def checkSyncFileDecisionChange : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc 5 (some "OldFoo")) with
      rawSourceHash := 10
      checkpointedVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncEventSeq := 8
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 11 (some "Foo"))
  require "syncFileDecision changed emits change action" (decision.action == .change)
  require "syncFileDecision changed bumps version" (decision.version == 6)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision changed erased doc"
  require "syncFileDecision changed records hash" (doc.rawSourceHash == 11)
  require "syncFileDecision changed records module" (doc.moduleName? == some "Foo")
  require "syncFileDecision changed clears checkpointed version" (doc.checkpointedVersion?.isNone)
  require "syncFileDecision changed clears progress" (doc.fileProgress?.isNone)
  require "syncFileDecision changed preserves sync event seq" (doc.lastSyncEventSeq == 8)

private def checkMarkSyncedVersion : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc 3 (some "Foo"))
  let result := DocumentState.markSyncedVersion docs {} uri 3 "Foo.lean" 7
  require "markSyncedVersion applies matching version" result.applied
  let some doc := result.docs.get? uri
    | throw <| IO.userError "markSyncedVersion erased existing doc"
  require "markSyncedVersion updates document sync event seq" (doc.lastSyncEventSeq == 7)
  let some history := result.moduleHistory.get? "Foo"
    | throw <| IO.userError "markSyncedVersion did not update module history"
  require "markSyncedVersion updates module sync event seq" (history.lastSyncEventSeq == 7)
  require "markSyncedVersion leaves save event seq untouched" (history.lastSaveEventSeq == 0)
  require "markSyncedVersion records baseline text hash" (history.lastRawSourceHash? == some 0)
  require "markSyncedVersion does not count initial text as a change"
    (history.lastTextChangeEventSeq == 0)

  let changedDocs := result.docs.insert uri {
    (mkDoc 4 (some "Foo")) with
    rawSourceHash := 11
  }
  let changed := DocumentState.markSyncedVersion changedDocs result.moduleHistory uri 4 "Foo.lean" 8
  require "markSyncedVersion applies changed version" changed.applied
  let some changedHistory := changed.moduleHistory.get? "Foo"
    | throw <| IO.userError "changed markSyncedVersion did not update module history"
  require "markSyncedVersion records changed text hash"
    (changedHistory.lastRawSourceHash? == some 11)
  require "markSyncedVersion records text change event seq"
    (changedHistory.lastTextChangeEventSeq == 8)

  let unchangedDocs := changed.docs.insert uri {
    (mkDoc 5 (some "Foo")) with
    rawSourceHash := 11
  }
  let unchanged := DocumentState.markSyncedVersion unchangedDocs changed.moduleHistory uri 5 "Foo.lean" 9
  require "markSyncedVersion applies unchanged text version" unchanged.applied
  let some unchangedHistory := unchanged.moduleHistory.get? "Foo"
    | throw <| IO.userError "unchanged markSyncedVersion did not update module history"
  require "markSyncedVersion advances sync event on unchanged text"
    (unchangedHistory.lastSyncEventSeq == 9)
  require "markSyncedVersion keeps prior text change event seq for unchanged text"
    (unchangedHistory.lastTextChangeEventSeq == 8)

  let stale := DocumentState.markSyncedVersion result.docs result.moduleHistory uri 2 "Foo.lean" 8
  require "markSyncedVersion rejects stale version" (!stale.applied)
  let some staleDoc := stale.docs.get? uri
    | throw <| IO.userError "stale markSyncedVersion erased existing doc"
  require "stale markSyncedVersion keeps sync event seq" (staleDoc.lastSyncEventSeq == 7)

private def checkLineEndingVersion : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let lf := "def value := 1\n"
  let crlf := "def value := 1\r\n"
  let opened := DocumentState.syncFileDecision {} uri
    (DocumentState.FileSnapshot.ofText lf default (moduleName? := some "Foo"))
  let changed := DocumentState.syncFileDecision opened.docs uri
    (DocumentState.FileSnapshot.ofText crlf default (moduleName? := some "Foo"))
  require "line ending edits still advance the source version"
    (changed.action == .change && changed.version == 2)
  let some doc := changed.docs.get? uri
    | throw <| IO.userError "line ending edit erased document state"
  require "source hash retains saved bytes" (doc.rawSourceHash == hash crlf)
  require "worker hash matches Lean's normalized document" (doc.documentHash == hash lf)
  require "Lake trace hash normalizes CRLF" (doc.lakeTraceHash == Lake.Hash.ofText lf && Lake.Hash.ofText lf == Lake.Hash.ofText crlf)

private def checkMarkSavedVersion : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (mkDoc 4 (some "Foo"))
  let result := DocumentState.markSavedVersion docs {} uri 4 "Foo.lean" 9
  require "markSavedVersion applies matching version" result.applied
  let some doc := result.docs.get? uri
    | throw <| IO.userError "markSavedVersion erased existing doc"
  require "markSavedVersion records checkpointed version" (doc.checkpointedVersion? == some 4)
  require "markSavedVersion updates document sync event seq" (doc.lastSyncEventSeq == 9)
  let some history := result.moduleHistory.get? "Foo"
    | throw <| IO.userError "markSavedVersion did not update module history"
  require "markSavedVersion updates module sync event seq" (history.lastSyncEventSeq == 9)
  require "markSavedVersion updates module save event seq" (history.lastSaveEventSeq == 9)
  require "markSavedVersion records text hash" (history.lastRawSourceHash? == some 0)
  require "markSavedVersion leaves text change event seq untouched"
    (history.lastTextChangeEventSeq == 0)

  let stale := DocumentState.markSavedVersion result.docs result.moduleHistory uri 3 "Foo.lean" 10
  require "markSavedVersion rejects stale version" (!stale.applied)
  let some staleDoc := stale.docs.get? uri
    | throw <| IO.userError "stale markSavedVersion erased existing doc"
  require "stale markSavedVersion keeps sync event seq" (staleDoc.lastSyncEventSeq == 9)

private def checkAcceptedBasis : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let opened := DocumentState.syncFileDecision {} uri { mkSnapshot 10 with readSeq := 1 }
  let original ← DocumentState.requireDocState opened.docs uri
  let originalBasis := DocumentState.basis original
  require "open captures its acceptance sequence" (originalBasis == ⟨1, 1⟩)
  let unchanged := DocumentState.syncFileDecision opened.docs uri { mkSnapshot 10 with readSeq := 3 }
  let unchangedDoc ← DocumentState.requireDocState unchanged.docs uri
  require "unchanged read advances ordering without changing basis"
    (unchangedDoc.syncSnapshotSeq == 3 && DocumentState.basis unchangedDoc == originalBasis)
  let changed := DocumentState.syncFileDecision unchanged.docs uri { mkSnapshot 20 with readSeq := 5 }
  let changedDoc ← DocumentState.requireDocState changed.docs uri
  require "change renews accepted basis" (DocumentState.basis changedDoc == ⟨2, 5⟩)
  let superseded := DocumentState.syncFileDecision changed.docs uri { mkSnapshot 30 with readSeq := 4 }
  let supersededDoc ← DocumentState.requireDocState superseded.docs uri
  require "superseded read preserves actual accepted basis"
    (DocumentState.basis supersededDoc == ⟨2, 5⟩ && supersededDoc.rawSourceHash == 20)
  let reopened := DocumentState.syncFileDecision (superseded.docs.erase uri) uri
    { mkSnapshot 10 with readSeq := 7 }
  let reopenedDoc ← DocumentState.requireDocState reopened.docs uri
  require "identical-text reopen renews basis despite equal public version"
    (reopenedDoc.version == original.version && reopenedDoc.rawSourceHash == original.rawSourceHash &&
     DocumentState.basis reopenedDoc != originalBasis)
  require "matching basis is current"
    (DocumentState.matchBasis unchanged.docs uri originalBasis == .current)
  require "advanced basis is superseded"
    (DocumentState.matchBasis changed.docs uri originalBasis == .superseded (some 2))
  require "same-version reopened basis is superseded"
    (DocumentState.matchBasis reopened.docs uri originalBasis == .superseded (some 1))
  require "absent basis is superseded without a current version"
    (DocumentState.matchBasis {} uri originalBasis == .superseded none)
  let replacementProgress := some ({ updates := 17, done := false } : SyncFileProgress)
  for docs in [changed.docs, reopened.docs] do
    let docs := DocumentState.recordFileProgress docs uri replacementProgress
    let guarded := DocumentState.recordFileProgressForBasis docs uri originalBasis
      (some { updates := 99, done := true })
    let doc ← DocumentState.requireDocState guarded uri
    require "old completion preserves updated and same-version reopened progress"
      (doc.fileProgress? == replacementProgress)
    let before ← DocumentState.requireDocState docs uri
    require "refused progress leaves history marks unchanged"
      (doc.lastSyncEventSeq == before.lastSyncEventSeq &&
       doc.checkpointedVersion? == before.checkpointedVersion?)
    let history : DocumentState.ModuleHistories := Std.TreeMap.empty.insert "Foo" {
      path := "Foo.lean", lastSyncEventSeq := 11, lastSaveEventSeq := 9
      lastRawSourceHash? := some 42, lastTextChangeEventSeq := 10
    }
    let marked := DocumentState.markSyncedBasis docs history uri originalBasis "Foo.lean" 99
    require "late sync refuses updated and same-version replacement marks" (!marked.applied)
    let retained ← DocumentState.requireDocState marked.docs uri
    let some retainedHistory := marked.moduleHistory.get? "Foo"
      | throw <| IO.userError "refused late sync erased module history"
    require "late sync preserves replacement progress and history"
      (retained.fileProgress? == replacementProgress && retained.lastSyncEventSeq == before.lastSyncEventSeq &&
       retainedHistory.lastSyncEventSeq == 11 && retainedHistory.lastSaveEventSeq == 9 &&
       retainedHistory.lastRawSourceHash? == some 42 && retainedHistory.lastTextChangeEventSeq == 10)
  let marked := DocumentState.markSyncedBasis unchanged.docs {} uri originalBasis "Foo.lean" 21
  require "same acceptance still records a completed sync" marked.applied
  let matchingProgress := some ({ updates := 6, done := true } : SyncFileProgress)
  let progressed := DocumentState.recordFileProgressForBasis unchanged.docs uri originalBasis matchingProgress
  require "unchanged acceptance still records matching progress"
    ((← DocumentState.requireDocState progressed uri).fileProgress? == matchingProgress)

def main : IO Unit := do
  checkAcceptedBasis
  checkTrackedModuleName
  checkRecordFileProgress
  checkSyncFileDecisionOpen
  checkSyncFileDecisionUnchanged
  checkSyncFileDecisionChange
  checkLineEndingVersion
  checkMarkSyncedVersion
  checkMarkSavedVersion

end BeamTest.Broker.DocumentStateTest

def main := BeamTest.Broker.DocumentStateTest.main
