/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Communication
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Lean.Data.Lsp.Internal
import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.SyncSaveSupport
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream

namespace Beam.Broker

structure PendingResult where
  result : Json
  progress? : Option SyncFileProgress := none
  diagnostics : Array Diagnostic := #[]
  diagnosticsSeen : Bool := false

structure PendingRequest where
  cancelRef? : Option (IO.Ref Bool) := none
  promise : IO.Promise (Except ResponseFailure PendingResult)
  tracked? : Option (DocumentUri × Nat) := none
  progressRef : IO.Ref (Option SyncFileProgress)
  diagnosticsRef : IO.Ref (Array Diagnostic)
  diagnosticsSeenRef : IO.Ref Bool
  emitProgress? : Option (SyncFileProgress → IO Unit) := none
  diagnosticScope : DiagnosticScope := .errors
  seenDiagnosticKeysRef : IO.Ref (Std.TreeSet String compare)
  emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none

abbrev PendingRequestStore := Std.Mutex (Std.TreeMap RequestID PendingRequest)

namespace PendingRequestStore

def create : BaseIO PendingRequestStore :=
  Std.Mutex.new ({} : Std.TreeMap RequestID PendingRequest)

def insert (store : PendingRequestStore) (id : RequestID) (pending : PendingRequest) : IO Unit := do
  store.atomically do
    modify (·.insert id pending)

def remove (store : PendingRequestStore) (id : RequestID) : IO (Option PendingRequest) := do
  store.atomically do
    let pending? := (← get).get? id
    modify (·.erase id)
    pure pending?

def snapshot (store : PendingRequestStore) : IO (Array PendingRequest) := do
  store.atomically do
    pure <| (← get).toList.map Prod.snd |>.toArray

def snapshotEntries (store : PendingRequestStore) : IO (Array (RequestID × PendingRequest)) := do
  store.atomically do
    pure <| (← get).toList.toArray

def clear (store : PendingRequestStore) : IO (Array PendingRequest) := do
  store.atomically do
    let pending := (← get).toList.map Prod.snd |>.toArray
    set ({} : Std.TreeMap RequestID PendingRequest)
    pure pending

end PendingRequestStore

namespace PendingRequest

def resolveResponse (pending : PendingRequest) (result : Json) : IO Unit := do
  let progress? ← pending.progressRef.get
  let diagnostics ← pending.diagnosticsRef.get
  let diagnosticsSeen ← pending.diagnosticsSeenRef.get
  try
    pending.promise.resolve (.ok { result, progress?, diagnostics, diagnosticsSeen })
  catch _ =>
    pure ()

def resolveError
    (pending : PendingRequest)
    (code : ErrorCode)
    (message : String)
    (data? : Option Json := none) : IO Unit := do
  let progress? ← pending.progressRef.get
  let failure :=
    (backendResponseFailure code message data?).withOptionalFileProgress progress?
  try
    pending.promise.resolve (.error failure)
  catch _ =>
    pure ()

/-- Give an already-marked broker cancellation precedence over a concurrent backend failure. -/
private def failureRespectingCancellation
    (cancelRef? : Option (IO.Ref Bool))
    (fallback : ResponseFailure) : IO ResponseFailure := do
  let cancelled ←
    match cancelRef? with
    | some cancelRef => cancelRef.get
    | none => pure false
  if cancelled then
    pure <|
      (responseFailureFor .requestCancelled
        "request was cancelled before its backend failure was observed")
      |>.withOptionalFileProgress fallback.fileProgress?
  else
    pure fallback

/--
Await the pending request, giving its already-marked cancellation identity precedence over a
concurrent backend failure while preserving observations attached to that failure. A completed
backend success remains successful.
-/
def awaitOutcome (pending : PendingRequest) : IO (Except ResponseFailure PendingResult) := do
  let some outcome ← IO.wait pending.promise.result?
    | throw <| IO.userError "pending broker request promise dropped"
  match outcome with
  | .ok result => pure (.ok result)
  | .error failure =>
      pure (.error (← failureRespectingCancellation pending.cancelRef? failure))

private def normalizePublishDiagnostics (params : PublishDiagnosticsParams) :
    PublishDiagnosticsParams := {
  params with
  diagnostics :=
    let diagnostics := Beam.LSP.Lib.userVisibleDiagnostics params.diagnostics
    let sorted := diagnostics.toList.mergeSort fun d1 d2 =>
      compare d1.fullRange d2.fullRange |>.then (compare d1.message d2.message) |>.isLE
    sorted.toArray
}

private structure FileProgressRangeInfo where
  rangeStartLine : Nat
  rangeEndLine : Nat

private def fileProgressRangeEndLine (range : Range) : Nat :=
  let endPos := range.«end»
  if endPos.line > 0 && endPos.character == 0 then
    endPos.line
  else
    endPos.line + 1

private def mergeFileProgressRangeInfo
    (info? : Option FileProgressRangeInfo)
    (range : Range) : Option FileProgressRangeInfo :=
  let rangeStartLine := range.start.line + 1
  let rangeEndLine := fileProgressRangeEndLine range
  match info? with
  | none => some { rangeStartLine, rangeEndLine }
  | some info =>
      some {
        rangeStartLine := Nat.min info.rangeStartLine rangeStartLine
        rangeEndLine := Nat.max info.rangeEndLine rangeEndLine
      }

private def fileProgressRangeInfo? (params : LeanFileProgressParams) :
    Option FileProgressRangeInfo :=
  params.processing.foldl
    (init := none)
    (fun info? processing => mergeFileProgressRangeInfo info? processing.range)

private def updateSyncFileProgress (progress : SyncFileProgress) (params : LeanFileProgressParams) :
    SyncFileProgress :=
  let processing := params.processing.size
  let rangeInfo? := fileProgressRangeInfo? params
  let done := processing == 0
  let rangeEndLine? := rangeInfo?.map (·.rangeEndLine) |>.or progress.rangeEndLine?
  let rangeStartLine? :=
    match rangeInfo? with
    | some info => some info.rangeStartLine
    | none => if done then none else progress.rangeStartLine?
  {
    updates := progress.updates + 1
    done
    rangeStartLine?
    rangeEndLine?
  }

private def matchesSyncFileProgress
    (uri : DocumentUri)
    (version : Nat)
    (params : LeanFileProgressParams) : Bool :=
  let matchesUri := params.textDocument.uri == uri
  let matchesVersion := params.textDocument.version?.map (fun progressVersion =>
    decide (version <= progressVersion)) |>.getD true
  matchesUri && matchesVersion

private def observeSyncFileProgress
    [ToJson α]
    (tracked : Option (DocumentUri × Nat))
    (progress? : Option SyncFileProgress)
    (param : α) : Option SyncFileProgress :=
  match tracked, progress?, fromJson? (toJson param) with
  | some (uri, version), some progress, .ok (progressParam : LeanFileProgressParams) =>
      if matchesSyncFileProgress uri version progressParam then
        some <| updateSyncFileProgress progress progressParam
      else
        some progress
  | _, _, _ =>
      progress?

private def trackedPublishDiagnosticsParam?
    (tracked? : Option (DocumentUri × Nat))
    (diagnosticParam : PublishDiagnosticsParams) : Option PublishDiagnosticsParams :=
  match tracked? with
  | some (uri, version) =>
      let diagnosticParam := normalizePublishDiagnostics diagnosticParam
      if diagnosticParam.uri == uri &&
          diagnosticParam.version?.all (· == Int.ofNat version) then
        some diagnosticParam
      else
        none
  | none =>
      none

private def diagnosticStreamKey
    (snapshot? : Option SnapshotRef) (diagnostic : Diagnostic) : String :=
  (toJson (snapshot?, diagnostic)).compress

private def emitNewTrackedDiagnostics
    (root : System.FilePath)
    (sessionToken : String)
    (seen : Std.TreeSet String compare)
    (diagnosticParam : PublishDiagnosticsParams)
    (diagnosticScope : DiagnosticScope)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Std.TreeSet String compare) := do
  let snapshot? := diagnosticParam.version?.bind fun version =>
    if version > 0 then some { session := sessionToken, revision := version.toNat }
    else none
  let mut seen := seen
  let diagnostics := filterSyncDiagnostics diagnosticScope diagnosticParam.diagnostics
  for diagnostic in diagnostics do
    let key := diagnosticStreamKey snapshot? diagnostic
    if !seen.contains key then
      seen := seen.insert key
      match emitDiagnostic? with
      | some emitDiagnostic =>
          try
            emitDiagnostic <|
              streamDiagnosticOfDiagnostic root diagnosticParam.uri snapshot? diagnostic
          catch _ =>
            pure ()
      | none =>
          pure ()
  pure seen

def observeProgress
    [ToJson α]
    (pending : PendingRequest)
    (param : α) : IO Unit := do
  let progress? ← pending.progressRef.get
  let nextProgress? := observeSyncFileProgress pending.tracked? progress? param
  if nextProgress? != progress? then
    pending.progressRef.set nextProgress?
    match pending.emitProgress?, nextProgress? with
    | some emitProgress, some progress =>
        try
          emitProgress progress
        catch _ =>
          pure ()
    | _, _ =>
        pure ()

def observePublishDiagnostics
    (root : System.FilePath)
    (sessionToken : String)
    (pending : PendingRequest)
    (diagnosticParam : PublishDiagnosticsParams) : IO Unit := do
  match trackedPublishDiagnosticsParam? pending.tracked? diagnosticParam with
  | none =>
      pure ()
  | some diagnosticParam =>
      pending.diagnosticsSeenRef.set true
      pending.diagnosticsRef.set diagnosticParam.diagnostics
      let seen ← pending.seenDiagnosticKeysRef.get
      let seen ←
        emitNewTrackedDiagnostics root sessionToken seen diagnosticParam pending.diagnosticScope pending.emitDiagnostic?
      pending.seenDiagnosticKeysRef.set seen

end PendingRequest

namespace PendingRequestStore

def failAll (store : PendingRequestStore) (failure : ResponseFailure) : IO Unit := do
  let pending ← clear store
  for req in pending do
    let progress? ← req.progressRef.get
    let failure := failure.withOptionalFileProgress progress?
    try
      req.promise.resolve (.error failure)
    catch _ =>
      pure ()

def sendCancelNotification (stdin : IO.FS.Stream) (id : RequestID) : IO Unit := do
  writeLspNotification stdin ({
    method := "$/cancelRequest"
    param := toJson ({ id } : CancelParams)
    : Lean.JsonRpc.Notification Json
  })

def matchesCancellation
    (pending : PendingRequest)
    (cancelRef : IO.Ref Bool) : IO Bool := do
  match pending.cancelRef? with
  | none => pure false
  | some pendingCancelRef => pendingCancelRef.ptrEq cancelRef

def cancelMatching
    (store : PendingRequestStore)
    (stdin : IO.FS.Stream)
    (cancelRef : IO.Ref Bool) : IO Nat := do
  let entries ← snapshotEntries store
  let mut cancelled := 0
  for (requestId, pending) in entries do
    if ← matchesCancellation pending cancelRef then
      sendCancelNotification stdin requestId
      cancelled := cancelled + 1
  pure cancelled

def propagateCancellation
    (store : PendingRequestStore)
    (stdin : IO.FS.Stream)
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  match cancelRef? with
  | some cancelRef =>
      if ← cancelRef.get then
        discard <| cancelMatching store stdin cancelRef
  | none =>
      pure ()

end PendingRequestStore

private structure ActiveRequestKey where
  workspaceId? : Option WorkspaceId
  clientRequestId : String
deriving BEq, Ord

structure ActiveRequest where
  workspaceId? : Option WorkspaceId
  clientRequestId? : Option String
  token : Nat
  cancelRef : IO.Ref Bool

private structure ActiveRequestRegistryState where
  nextToken : Nat := 1
  accepting : Bool := true
  requests : Std.TreeMap ActiveRequestKey ActiveRequest := {}
  anonymousRequests : Std.TreeMap Nat ActiveRequest := {}
  drainedSignaled : Bool := false

structure ActiveRequestRegistry where
  private mutex : Std.Mutex ActiveRequestRegistryState
  private drained : IO.Promise Unit

namespace ActiveRequestRegistry

def create : BaseIO ActiveRequestRegistry := do
  pure {
    mutex := ← Std.Mutex.new {}
    drained := ← IO.Promise.new
  }

private def activeRequestCount
    (state : ActiveRequestRegistryState) : Nat :=
  state.requests.size + state.anonymousRequests.size

private def markDrainedIfReady
    (state : ActiveRequestRegistryState) : ActiveRequestRegistryState × Bool :=
  if !state.accepting && activeRequestCount state == 0 && !state.drainedSignaled then
    ({ state with drainedSignaled := true }, true)
  else
    (state, false)

private def resolveDrainedIfNeeded
    (registry : ActiveRequestRegistry)
    (shouldResolve : Bool) : IO Unit := do
  if shouldResolve then
    registry.drained.resolve ()

def register
    (registry : ActiveRequestRegistry)
    (workspaceId? : Option WorkspaceId)
    (clientRequestId? : Option String) : IO (Except BrokerFailure ActiveRequest) := do
  let cancelRef ← IO.mkRef false
  registry.mutex.atomically do
    let state ← get
    unless state.accepting do
      return .error {
        code := .requestCancelled
        message := "Beam session owner is closing"
      }
    match clientRequestId? with
    | none =>
        let active : ActiveRequest := {
          workspaceId?, clientRequestId?, token := state.nextToken, cancelRef
        }
        set { state with
          nextToken := state.nextToken + 1
          anonymousRequests := state.anonymousRequests.insert active.token active
        }
        pure <| .ok active
    | some clientRequestId =>
        let key : ActiveRequestKey := { workspaceId?, clientRequestId }
        if state.requests.contains key then
          pure <| .error {
            code := .invalidParams
            message := s!"clientRequestId '{clientRequestId}' is already active in this workspace"
          }
        else
          let active : ActiveRequest := {
            workspaceId?, clientRequestId?, token := state.nextToken, cancelRef
          }
          set { state with
            nextToken := state.nextToken + 1
            requests := state.requests.insert key active
          }
          pure <| .ok active

def unregister
    (registry : ActiveRequestRegistry)
    (active? : Option ActiveRequest) : IO Unit := do
  match active? with
  | none => pure ()
  | some active =>
      let shouldResolve ← registry.mutex.atomically do
        let state ← get
        let state :=
          match active.clientRequestId? with
          | some clientRequestId =>
              let key : ActiveRequestKey := { workspaceId? := active.workspaceId?, clientRequestId }
              match state.requests.get? key with
              | some current =>
                  if current.token == active.token then
                    { state with requests := state.requests.erase key }
                  else
                    state
              | none => state
          | none =>
              match state.anonymousRequests.get? active.token with
              | some current =>
                  if current.token == active.token then
                    { state with anonymousRequests := state.anonymousRequests.erase active.token }
                  else
                    state
              | none => state
        let (state, shouldResolve) := markDrainedIfReady state
        set state
        pure shouldResolve
      resolveDrainedIfNeeded registry shouldResolve

def count (registry : ActiveRequestRegistry) : IO Nat := do
  registry.mutex.atomically do
    pure (activeRequestCount (← get))

/-- Atomically close request admission and mark every admitted request for cancellation. -/
def closeAdmission (registry : ActiveRequestRegistry) : IO Unit := do
  let (active, shouldResolve) ← registry.mutex.atomically do
    let state : ActiveRequestRegistryState ← get
    if !state.accepting then
      pure (#[], false)
    else
      let (state, shouldResolve) := markDrainedIfReady { state with accepting := false }
      set state
      let named := state.requests.toList.map Prod.snd |>.toArray
      let anonymous := state.anonymousRequests.toList.map Prod.snd |>.toArray
      pure (named ++ anonymous, shouldResolve)
  for request in active do
    request.cancelRef.set true
  resolveDrainedIfNeeded registry shouldResolve

/-- Wait until admission is closed and every request admitted before closure has unregistered. -/
def awaitDrained (registry : ActiveRequestRegistry) : IO Unit := do
  let some _ ← IO.wait registry.drained.result?
    | throw <| IO.userError "active request registry drain promise dropped"
  pure ()

def markCancelled
    (registry : ActiveRequestRegistry)
    (workspaceId? : Option WorkspaceId)
    (clientRequestId : String) : IO (Option ActiveRequest) := do
  registry.mutex.atomically do
    let key : ActiveRequestKey := { workspaceId?, clientRequestId }
    let active? := (← get).requests.get? key
    match active? with
    | none =>
        pure none
    | some active =>
        active.cancelRef.set true
        pure (some active)

def markCancelledActive
    (registry : ActiveRequestRegistry)
    (active : ActiveRequest) : IO (Option ActiveRequest) := do
  registry.mutex.atomically do
    let state ← get
    let current? :=
      match active.clientRequestId? with
      | some clientRequestId =>
          state.requests.get? { workspaceId? := active.workspaceId?, clientRequestId }
      | none => state.anonymousRequests.get? active.token
    match current? with
    | none => pure none
    | some current =>
        if current.token == active.token then
          current.cancelRef.set true
          pure (some current)
        else
          pure none

end ActiveRequestRegistry

def ensureRequestNotCancelled
    (cancelRef? : Option (IO.Ref Bool)) : IO (Except ResponseFailure Unit) := do
  match cancelRef? with
  | none => pure (.ok ())
  | some cancelRef =>
      if ← cancelRef.get then
        pure <| .error <| BrokerFailure.toResponseFailure {
          code := .requestCancelled
          message := "client requested cancellation"
        }
      else
        pure (.ok ())

end Beam.Broker
