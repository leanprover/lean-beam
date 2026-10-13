/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake
import Lean
import Beam.Broker.Protocol
import Beam.Path

open Lean
open Lean.Lsp

namespace Beam.Broker

structure DocState where
  version : Nat
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  -- File contents may be read before the broker state mutex is held. This
  -- records the newest ordered request snapshot applied to the LSP document.
  syncSnapshotSeq : Nat := 0
  moduleName? : Option String := none
  /-- Version for which this daemon last completed a Beam checkpoint; not an artifact probe. -/
  checkpointedVersion? : Option Nat := none
  fileProgress? : Option SyncFileProgress := none
  /-- Broker event sequence of the latest successful sync barrier for this document. -/
  lastSyncEventSeq : Nat := 0

structure ModuleHistory where
  path : String
  /-- Broker event sequence of the latest successful sync barrier for this module. -/
  lastSyncEventSeq : Nat := 0
  /-- Broker event sequence of the latest successful save checkpoint for this module. -/
  lastSaveEventSeq : Nat := 0
  /-- Latest source hash observed by a successful sync/save for this module. -/
  lastTextHash? : Option UInt64 := none
  /-- Broker event sequence of the latest observed source text change after the initial baseline. -/
  lastTextChangeEventSeq : Nat := 0

namespace DocumentState

abbrev Docs := Std.TreeMap String DocState

abbrev ModuleHistories := Std.TreeMap String ModuleHistory

structure FileSnapshot where
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  /-- Zero means in-session sync with no cross-request ordering token. -/
  readSeq : Nat := 0
  moduleName? : Option String := none

inductive SyncFileAction where
  | open
  | change
  | unchanged
  deriving Inhabited, BEq, Repr

structure SyncFileDecision where
  action : SyncFileAction
  version : Nat
  nextVersion : Nat
  docs : Docs

structure VersionMarkResult where
  docs : Docs
  moduleHistory : ModuleHistories
  applied : Bool := false

def trackedModuleName? (root path : System.FilePath) (backend : Backend) : Option String := do
  guard (backend == .lean)
  Beam.leanModuleNameForPath? root path

def requireDocState (docs : Docs) (uri : String) : IO DocState := do
  match docs.get? uri with
  | some docState => pure docState
  | none => throw <| IO.userError s!"missing synced document state for {uri}"

def recordFileProgress
    (docs : Docs)
    (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Docs :=
  match docs.get? uri with
  | some docState =>
      docs.insert uri { docState with fileProgress? := fileProgress? }
  | none =>
      docs

private def nextSnapshotSeq (docState : DocState) (snapshot : FileSnapshot) : Nat :=
  if snapshot.readSeq == 0 then docState.syncSnapshotSeq else snapshot.readSeq

private def docStateOfSnapshot (version : Nat) (snapshot : FileSnapshot) : DocState := {
  version
  textHash := snapshot.textHash
  textTraceHash := snapshot.textTraceHash
  textMTime := snapshot.textMTime
  syncSnapshotSeq := snapshot.readSeq
  moduleName? := snapshot.moduleName?
}

/--
Decide how a freshly read file snapshot should update the broker's LSP document
mirror. `nextVersion` is the session-wide allocator, retained when documents close.
Only opens and source changes consume a revision; unchanged and superseded reads preserve it.

Request handlers reserve nonzero `readSeq` values before reading the filesystem.
If an older read finishes after a newer read has already been applied, the older
snapshot is ignored here. The LSP server only sees the ordered notifications the
broker sends, so this broker-side check prevents stale disk reads from becoming
newer LSP document versions.
-/
def syncFileDecision
    (docs : Docs)
    (uri : DocumentUri)
    (snapshot : FileSnapshot)
    (nextVersion : Nat) : SyncFileDecision :=
  match docs.get? uri with
  | none =>
      let version := nextVersion
      {
        action := .open
        version
        nextVersion := version + 1
        docs := docs.insert uri (docStateOfSnapshot version snapshot)
      }
  | some docState =>
      if snapshot.readSeq != 0 && snapshot.readSeq < docState.syncSnapshotSeq then
        {
          action := .unchanged
          version := docState.version
          nextVersion
          docs
        }
      else if docState.textHash == snapshot.textHash then
        {
          action := .unchanged
          version := docState.version
          nextVersion
          docs := docs.insert uri {
            docState with
            textTraceHash := snapshot.textTraceHash
            textMTime := snapshot.textMTime
            syncSnapshotSeq := nextSnapshotSeq docState snapshot
            moduleName? := snapshot.moduleName?
          }
        }
      else
        let version := nextVersion
        {
          action := .change
          version
          nextVersion := version + 1
          docs := docs.insert uri {
            (docStateOfSnapshot version snapshot) with
            checkpointedVersion? := none
            fileProgress? := none
            lastSyncEventSeq := docState.lastSyncEventSeq
          }
        }

def updateModuleHistorySync
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (textHash : UInt64)
    (eventSeq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  let textChanged :=
    match history.lastTextHash? with
    | some lastTextHash => lastTextHash != textHash
    | none => false
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncEventSeq := eventSeq
    lastTextHash? := some textHash
    lastTextChangeEventSeq :=
      if textChanged then eventSeq else history.lastTextChangeEventSeq
  }

def updateModuleHistorySave
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (textHash : UInt64)
    (eventSeq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncEventSeq := eventSeq
    lastSaveEventSeq := eventSeq
    lastTextHash? := some textHash
  }

def markSyncedVersion
    (docs : Docs)
    (moduleHistory : ModuleHistories)
    (uri : DocumentUri)
    (version : Nat)
    (path : String)
    (eventSeq : Nat) : VersionMarkResult :=
  match docs.get? uri with
  | some docState =>
      if docState.version == version then
        let moduleHistory :=
          match docState.moduleName? with
          | some moduleName =>
              updateModuleHistorySync moduleHistory moduleName path docState.textHash eventSeq
          | none => moduleHistory
        {
          docs := docs.insert uri {
            docState with
            lastSyncEventSeq := eventSeq
          }
          moduleHistory
          applied := true
        }
      else
        { docs, moduleHistory }
  | none =>
      { docs, moduleHistory }

def markSavedVersion
    (docs : Docs)
    (moduleHistory : ModuleHistories)
    (uri : DocumentUri)
    (version : Nat)
    (path : String)
    (eventSeq : Nat) : VersionMarkResult :=
  match docs.get? uri with
  | some docState =>
      if docState.version == version then
        let moduleHistory :=
          match docState.moduleName? with
          | some moduleName =>
              updateModuleHistorySave moduleHistory moduleName path docState.textHash eventSeq
          | none => moduleHistory
        {
          docs := docs.insert uri {
            docState with
            checkpointedVersion? := some version
            lastSyncEventSeq := eventSeq
          }
          moduleHistory
          applied := true
        }
      else
        { docs, moduleHistory }
  | none =>
      { docs, moduleHistory }

end DocumentState

end Beam.Broker
