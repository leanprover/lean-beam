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
  /-- Saved source text without line-ending normalization; controls versions and freshness. -/
  rawSourceHash : UInt64
  /-- Hash of the backend's document text; Lean normalizes CRLF to LF. -/
  documentHash : UInt64
  /-- Lake's source trace hash; `Lake.Hash.ofText` normalizes CRLF independently. -/
  lakeTraceHash : Lake.Hash
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
  /-- Latest raw source hash observed by a successful sync/save for this module. -/
  lastRawSourceHash? : Option UInt64 := none
  /-- Broker event sequence of the latest observed source text change after the initial baseline. -/
  lastTextChangeEventSeq : Nat := 0

namespace DocumentState

abbrev Docs := Std.TreeMap String DocState

abbrev ModuleHistories := Std.TreeMap String ModuleHistory

structure FileSnapshot where
  /-- Saved source text without line-ending normalization. -/
  rawSourceHash : UInt64
  /-- Text accepted by the backend, normalized to LF for Lean. -/
  documentHash : UInt64
  /-- Lake's normalized source trace hash. -/
  lakeTraceHash : Lake.Hash
  textMTime : Lake.MTime
  /-- Zero means in-session sync with no cross-request ordering token. -/
  readSeq : Nat := 0
  moduleName? : Option String := none

/--
Capture the three hash representations from one source text before synchronizing the document.

Raw source identity controls versions and disk freshness. The document identity matches the
backend's text contract: normalize CRLF to LF for Lean and keep the supplied text for Rocq. Lake
uses that same normalized text through its own `Hash.ofText` contract, including its hash mixing.
Keep the Lake result instead of reconstructing it from the worker hash; the LSP worker does not
need to depend on Lake's hash representation. LF/CRLF changes can therefore advance the source
version while retaining both the Lean document identity and Lake source trace identity.
-/
def FileSnapshot.ofText
    (backend : Backend)
    (text : String)
    (textMTime : Lake.MTime)
    (readSeq : Nat := 0)
    (moduleName? : Option String := none) : FileSnapshot := {
  rawSourceHash := hash text
  documentHash := hash (if backend == .lean then text.crlfToLf else text)
  lakeTraceHash := Lake.Hash.ofText text
  textMTime
  readSeq
  moduleName?
}

inductive SyncFileAction where
  | open
  | change
  | unchanged
  deriving Inhabited, BEq, Repr

structure SyncFileDecision where
  action : SyncFileAction
  version : Nat
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

/-- Initialize tracked state by copying all hash representations from the same snapshot. -/
def FileSnapshot.toDocState (snapshot : FileSnapshot) (version : Nat) : DocState := {
  version
  rawSourceHash := snapshot.rawSourceHash
  documentHash := snapshot.documentHash
  lakeTraceHash := snapshot.lakeTraceHash
  textMTime := snapshot.textMTime
  syncSnapshotSeq := snapshot.readSeq
  moduleName? := snapshot.moduleName?
}

/--
Decide how a freshly read file snapshot should update the broker's LSP document
mirror.

Request handlers reserve nonzero `readSeq` values before reading the filesystem.
If an older read finishes after a newer read has already been applied, the older
snapshot is ignored here. The LSP server only sees the ordered notifications the
broker sends, so this broker-side check prevents stale disk reads from becoming
newer LSP document versions.
-/
def syncFileDecision
    (docs : Docs)
    (uri : DocumentUri)
    (snapshot : FileSnapshot) : SyncFileDecision :=
  match docs.get? uri with
  | none =>
      let version := 1
      {
        action := .open
        version
        docs := docs.insert uri (snapshot.toDocState version)
      }
  | some docState =>
      if snapshot.readSeq != 0 && snapshot.readSeq < docState.syncSnapshotSeq then
        {
          action := .unchanged
          version := docState.version
          docs
        }
      else if docState.rawSourceHash == snapshot.rawSourceHash then
        {
          action := .unchanged
          version := docState.version
          docs := docs.insert uri {
            docState with
            documentHash := snapshot.documentHash
            lakeTraceHash := snapshot.lakeTraceHash
            textMTime := snapshot.textMTime
            syncSnapshotSeq := nextSnapshotSeq docState snapshot
            moduleName? := snapshot.moduleName?
          }
        }
      else
        let version := docState.version + 1
        {
          action := .change
          version
          docs := docs.insert uri {
            (snapshot.toDocState version) with
            checkpointedVersion? := none
            fileProgress? := none
            lastSyncEventSeq := docState.lastSyncEventSeq
          }
        }

def updateModuleHistorySync
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (rawSourceHash : UInt64)
    (eventSeq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  let textChanged :=
    match history.lastRawSourceHash? with
    | some lastRawSourceHash => lastRawSourceHash != rawSourceHash
    | none => false
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncEventSeq := eventSeq
    lastRawSourceHash? := some rawSourceHash
    lastTextChangeEventSeq :=
      if textChanged then eventSeq else history.lastTextChangeEventSeq
  }

def updateModuleHistorySave
    (moduleHistory : ModuleHistories)
    (moduleName path : String)
    (rawSourceHash : UInt64)
    (eventSeq : Nat) : ModuleHistories :=
  let history := (moduleHistory.get? moduleName).getD { path }
  moduleHistory.insert moduleName {
    history with
    path
    lastSyncEventSeq := eventSeq
    lastSaveEventSeq := eventSeq
    lastRawSourceHash? := some rawSourceHash
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
              updateModuleHistorySync moduleHistory moduleName path docState.rawSourceHash eventSeq
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
              updateModuleHistorySave moduleHistory moduleName path docState.rawSourceHash eventSeq
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
