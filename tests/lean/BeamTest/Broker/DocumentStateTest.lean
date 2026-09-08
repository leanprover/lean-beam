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
  textHash := 0
  textTraceHash := default
  textMTime := default
  moduleName?
}

private def checkTrackedModuleName : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  require "lean module path"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.lean") .lean == some "Foo.Bar")
  require "non-lean backend has no module"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.lean") .rocq == none)
  require "non-lean file has no module"
    (DocumentState.trackedModuleName? root (root / "Foo" / "Bar.v") .lean == none)
  require "outside root has no module"
    (DocumentState.trackedModuleName? root (System.FilePath.mk "/other/Foo.lean") .lean == none)

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
    (textHash : UInt64)
    (moduleName? : Option String := some "Foo") : DocumentState.FileSnapshot := {
  textHash
  textTraceHash := default
  textMTime := default
  moduleName?
}

private def checkSyncFileDecisionOpen : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let decision := DocumentState.syncFileDecision {} uri
    (mkSnapshot 10) 17
  require "syncFileDecision opens unknown doc" (decision.action == .open)
  require "open consumes the session allocator" (decision.version == 17 && decision.nextVersion == 18)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision open did not insert doc"
  require "syncFileDecision open records hash" (doc.textHash == 10)
  require "syncFileDecision open records module" (doc.moduleName? == some "Foo")

private def checkSyncFileDecisionUnchanged : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let docs : DocumentState.Docs :=
    Std.TreeMap.empty.insert uri {
      (mkDoc 5 (some "OldFoo")) with
      textHash := 10
      checkpointedVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncEventSeq := 8
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 10 (some "Foo")) 11
  require "unchanged preserves the allocator" (decision.nextVersion == 11)
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
      textHash := 10
      checkpointedVersion? := some 5
      fileProgress? := some { updates := 2, done := true }
      lastSyncEventSeq := 8
    }
  let decision := DocumentState.syncFileDecision docs uri (mkSnapshot 11 (some "Foo")) 11
  require "syncFileDecision changed emits change action" (decision.action == .change)
  require "change consumes the session allocator" (decision.version == 11 && decision.nextVersion == 12)
  let some doc := decision.docs.get? uri
    | throw <| IO.userError "syncFileDecision changed erased doc"
  require "syncFileDecision changed records hash" (doc.textHash == 11)
  require "syncFileDecision changed records module" (doc.moduleName? == some "Foo")
  require "syncFileDecision changed clears checkpointed version" (doc.checkpointedVersion?.isNone)
  require "syncFileDecision changed clears progress" (doc.fileProgress?.isNone)
  require "syncFileDecision changed preserves sync event seq" (doc.lastSyncEventSeq == 8)

private def checkInterleavedDocumentRevisions : IO Unit := do
  let a := "file:///workspace/A.lean"
  let b := "file:///workspace/B.lean"
  let openedA := DocumentState.syncFileDecision {} a { mkSnapshot 10 with readSeq := 1 } 1
  let openedB := DocumentState.syncFileDecision openedA.docs b
    { mkSnapshot 10 with readSeq := 2 } openedA.nextVersion
  let changedA := DocumentState.syncFileDecision openedB.docs a
    { mkSnapshot 20 with readSeq := 3 } openedB.nextVersion
  require "files share one revision allocator"
    ([openedA.version, openedB.version, changedA.version] == [1, 2, 3])
  let superseded := DocumentState.syncFileDecision changedA.docs a
    { mkSnapshot 10 with readSeq := 1 } changedA.nextVersion
  require "an older read neither rolls back source nor consumes a revision"
    (superseded.action == .unchanged && superseded.version == changedA.version &&
      superseded.nextVersion == changedA.nextVersion &&
      (superseded.docs.get? a).any (fun doc => doc.textHash == 20 && doc.syncSnapshotSeq == 3))
  let unchanged := DocumentState.syncFileDecision superseded.docs b
    { mkSnapshot 10 with readSeq := 4 } superseded.nextVersion
  require "another file's unchanged read preserves its token and the allocator"
    (unchanged.version == openedB.version && unchanged.nextVersion == changedA.nextVersion)
  let reopened := DocumentState.syncFileDecision (unchanged.docs.erase a) a
    { mkSnapshot 20 with readSeq := 5 } unchanged.nextVersion
  require "closing and reopening does not reuse a document revision"
    (reopened.version == 4 && reopened.nextVersion == 5)

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
  require "markSyncedVersion records baseline text hash" (history.lastTextHash? == some 0)
  require "markSyncedVersion does not count initial text as a change"
    (history.lastTextChangeEventSeq == 0)

  let changedDocs := result.docs.insert uri {
    (mkDoc 4 (some "Foo")) with
    textHash := 11
  }
  let changed := DocumentState.markSyncedVersion changedDocs result.moduleHistory uri 4 "Foo.lean" 8
  require "markSyncedVersion applies changed version" changed.applied
  let some changedHistory := changed.moduleHistory.get? "Foo"
    | throw <| IO.userError "changed markSyncedVersion did not update module history"
  require "markSyncedVersion records changed text hash"
    (changedHistory.lastTextHash? == some 11)
  require "markSyncedVersion records text change event seq"
    (changedHistory.lastTextChangeEventSeq == 8)

  let unchangedDocs := changed.docs.insert uri {
    (mkDoc 5 (some "Foo")) with
    textHash := 11
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
  require "markSavedVersion records text hash" (history.lastTextHash? == some 0)
  require "markSavedVersion leaves text change event seq untouched"
    (history.lastTextChangeEventSeq == 0)

  let stale := DocumentState.markSavedVersion result.docs result.moduleHistory uri 3 "Foo.lean" 10
  require "markSavedVersion rejects stale version" (!stale.applied)
  let some staleDoc := stale.docs.get? uri
    | throw <| IO.userError "stale markSavedVersion erased existing doc"
  require "stale markSavedVersion keeps sync event seq" (staleDoc.lastSyncEventSeq == 9)

def main : IO Unit := do
  checkTrackedModuleName
  checkRecordFileProgress
  checkSyncFileDecisionOpen
  checkSyncFileDecisionUnchanged
  checkSyncFileDecisionChange
  checkInterleavedDocumentRevisions
  checkMarkSyncedVersion
  checkMarkSavedVersion

end BeamTest.Broker.DocumentStateTest

def main := BeamTest.Broker.DocumentStateTest.main
