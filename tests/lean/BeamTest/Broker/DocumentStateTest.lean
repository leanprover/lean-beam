/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.DocumentState
import Beam.Broker.DocumentAdmission
import BeamTest.Broker.JsonAssert
import BeamTest.Broker.DocumentFixture

open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.DocumentStateTest

/-- error: invalid {...} notation, constructor for `DocumentBasis` is marked as private -/
#guard_msgs in
example : DocumentBasis := { version := 1, acceptedSeq := 1 }

/-- error: invalid {...} notation, constructor for `DocState` is marked as private -/
#guard_msgs in
example (doc : DocState) : DocState := { doc with rawSourceHash := 0 }

private def mkDoc (version : Nat := 1) (moduleName? : Option String := none)
    (rawSourceHash : UInt64 := 0) : IO DocState :=
  DocumentFixture.accepted {
    rawSourceHash, documentHash := rawSourceHash, lakeTraceHash := default
    textMTime := default, moduleName?
  } version

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
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (← mkDoc)
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
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (← mkDoc 5 (some "OldFoo") 10)
  let docs := (DocumentState.markSavedVersion docs {} uri 5 "Foo.lean" 8).docs
  let docs := DocumentState.recordFileProgress docs uri (some { updates := 2, done := true })
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
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (← mkDoc 5 (some "OldFoo") 10)
  let docs := (DocumentState.markSavedVersion docs {} uri 5 "Foo.lean" 8).docs
  let docs := DocumentState.recordFileProgress docs uri (some { updates := 2, done := true })
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
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (← mkDoc 3 (some "Foo"))
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

  let changedDocs := result.docs.insert uri (← mkDoc 4 (some "Foo") 11)
  let changed := DocumentState.markSyncedVersion changedDocs result.moduleHistory uri 4 "Foo.lean" 8
  require "markSyncedVersion applies changed version" changed.applied
  let some changedHistory := changed.moduleHistory.get? "Foo"
    | throw <| IO.userError "changed markSyncedVersion did not update module history"
  require "markSyncedVersion records changed text hash"
    (changedHistory.lastRawSourceHash? == some 11)
  require "markSyncedVersion records text change event seq"
    (changedHistory.lastTextChangeEventSeq == 8)

  let unchangedDocs := changed.docs.insert uri (← mkDoc 5 (some "Foo") 11)
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
  let docs : DocumentState.Docs := Std.TreeMap.empty.insert uri (← mkDoc 4 (some "Foo"))
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
  require "open captures its accepted version" (originalBasis.version == 1)
  let unchanged := DocumentState.syncFileDecision opened.docs uri { mkSnapshot 10 with readSeq := 3 }
  let unchangedDoc ← DocumentState.requireDocState unchanged.docs uri
  require "unchanged read advances ordering without changing basis"
    (unchangedDoc.syncSnapshotSeq == 3 && DocumentState.basis unchangedDoc == originalBasis)
  let changed := DocumentState.syncFileDecision unchanged.docs uri { mkSnapshot 20 with readSeq := 5 }
  let changedDoc ← DocumentState.requireDocState changed.docs uri
  require "change renews accepted basis"
    (changedDoc.version == 2 && DocumentState.basis changedDoc != originalBasis)
  let superseded := DocumentState.syncFileDecision changed.docs uri { mkSnapshot 30 with readSeq := 4 }
  let supersededDoc ← DocumentState.requireDocState superseded.docs uri
  require "superseded read preserves actual accepted basis"
    (DocumentState.basis supersededDoc == DocumentState.basis changedDoc &&
     supersededDoc.rawSourceHash == 20)
  let reverted := DocumentState.syncFileDecision changed.docs uri { mkSnapshot 10 with readSeq := 6 }
  let revertedDoc ← DocumentState.requireDocState reverted.docs uri
  require "accepted A to B to A does not revive A's identity"
    (revertedDoc.rawSourceHash == original.rawSourceHash &&
     DocumentState.basis revertedDoc != originalBasis &&
     DocumentState.matchBasis reverted.docs uri originalBasis == .superseded (some 3))
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

private def checkWorkerFailure : IO Unit := do
  let uri := "file:///workspace/Foo.lean"
  let sibling := "file:///workspace/Other.lean"
  let snapshot := { (mkSnapshot 10) with readSeq := 10 }
  let opened := DocumentState.syncFileDecision {} uri snapshot
  let original ← DocumentState.requireDocState opened.docs uri
  let expected := DocumentState.basis original
  let docs := (DocumentState.markSavedVersion opened.docs {} uri original.version "Foo.lean" 5).docs
  let docs := DocumentState.recordFileProgress docs uri (some { updates := 3, done := true })
  let docs := docs.insert sibling (← mkDoc 2)
  let error : Error := { code := "workerCrashed", message := "fixture worker stopped" }
  let some failed := DocumentState.recordWorkerErrorForBasis docs uri expected error
    | throw <| IO.userError "first current worker failure was ignored"
  let doc ← DocumentState.requireDocState failed uri
  require "failure retains its original acceptance" (DocumentState.basis doc == expected)
  require "failure retains checkpoint and history"
    (doc.checkpointedVersion? == some original.version && doc.lastSyncEventSeq == 5)
  require "failure records its cause" (doc.workerError?.map (·.message) == some error.message)
  require "repeated failures do not establish another transition"
    (DocumentState.recordWorkerErrorForBasis failed uri expected
      { code := "workerExited", message := "later failure" }).isNone
  require "a late error cannot recreate a closed document"
    (DocumentState.recordWorkerErrorForBasis (failed.erase uri) uri expected error).isNone
  let older := DocumentState.syncFileDecision failed uri { snapshot with readSeq := 9 }
  let retained ← DocumentState.requireDocState older.docs uri
  require "an old read cannot recover a failed worker"
    (older.action == .unchanged && DocumentState.basis retained == expected && retained.workerError?.isSome)
  let recovered := DocumentState.syncFileDecision failed uri { snapshot with readSeq := 11 }
  let replacement ← DocumentState.requireDocState recovered.docs uri
  require "same-source recovery reopens without a version change"
    (recovered.action == .reopen && replacement.version == original.version)
  require "recovery has a fresh accepted identity"
    (DocumentState.basis replacement != expected)
  require "recovery preserves the unchanged source's checkpoint association"
    (replacement.checkpointedVersion? == some original.version && replacement.lastSyncEventSeq == 5)
  require "recovery clears obsolete worker progress and error"
    (replacement.workerError?.isNone && replacement.fileProgress?.isNone)
  require "a late old error cannot invalidate the replacement"
    (DocumentState.recordWorkerErrorForBasis recovered.docs uri expected error).isNone
  let changed := DocumentState.syncFileDecision failed uri
    { snapshot with rawSourceHash := 11, readSeq := 11 }
  let changedDoc ← DocumentState.requireDocState changed.docs uri
  require "changed-source recovery advances version and clears checkpoint"
    (changed.action == .reopen && changedDoc.version == original.version + 1 &&
     changedDoc.checkpointedVersion?.isNone)
  require "recovery preserves the sibling document"
    ((← DocumentState.requireDocState recovered.docs sibling).version == 2)

private def checkWorkerFailureAdmissions : IO Unit := do
  let accepted := fun {α : Type} (result : Except DocumentAdmission.Conflict α) =>
    IO.ofExcept <| result.mapError fun conflict => IO.userError s!"unexpected {repr conflict}"
  let allows := fun state permit =>
    match DocumentAdmission.State.check state permit with | .ok () => true | .error _ => false
  let (state, old) ← accepted <| DocumentAdmission.State.empty.admit "Main"
  let (state, sibling) ← accepted <| state.admit "Other"
  let state := state.revokeReading "Main"
  require "worker failure invalidates held reads" (!allows state old)
  require "worker failure preserves sibling reads" (allows state sibling)
  let (state, fresh) ← accepted <| state.admit "Main"
  require "a fresh request can recover the worker" (allows state fresh)
  let state ← accepted <| state.reserve fresh
  let state := state.revokeReading "Main"
  require "worker observation retains the closing owner's authority" (allows state fresh)
  let state := state.release fresh
  require "closing cleanup never restores the old read" (!allows state old)
  require "closing cleanup preserves the sibling" (allows state sibling)

def main : IO Unit := do
  checkWorkerFailure
  checkWorkerFailureAdmissions
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
