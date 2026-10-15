/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Ipc
import Lean.Server.Utils
import Beam.LSP.RunAt
import Beam.LSP.Goals
import Beam.LSP.Todo
import Beam.LSP.Save
import Beam.LSP.DiagnosticsBarrier
import Beam.LSP.Lib.Goal
import BeamTest.TestHarness

open Lean
open Lean.Lsp
open Lean.JsonRpc
open Lean.Lsp.Ipc

namespace BeamTest.LSP.Scenario

open BeamTest.TestHarness

structure ChangeSpec where
  line : Nat
  character : Nat
  endLine? : Option Nat := none
  endCharacter? : Option Nat := none
  delete : String := ""
  insert : String := ""
  deriving Inhabited, Repr, ToJson

structure SendRunAtSpec where
  version? : Option Nat := none
  line : Nat
  character : Nat
  text : String
  storeHandle : Bool := false
  profile : Bool := false
  deriving Inhabited, Repr, ToJson

structure RunWithSpec where
  text : String
  storeHandle : Bool := false
  linear : Bool := false
  profile : Bool := false
  deriving Inhabited, Repr, ToJson

structure GoalsSpec where
  version? : Option Nat := none
  line : Nat
  character : Nat
  useAfter : Bool := true
  deriving Inhabited, Repr, ToJson

structure TodoSpec where
  version? : Option Nat := none
  startLine : Nat
  startCharacter : Nat
  endLine : Nat
  endCharacter : Nat
  kinds? : Option (Array Beam.LSP.Todo.TodoKind) := none
  suggest? : Option Beam.LSP.Todo.TodoSuggestMode := none
  deriving Inhabited, Repr, ToJson

structure SaveArtifactsSpec where
  expectedVersionOverride? : Option Nat := none
  expectedTextHashOverride? : Option UInt64 := none
  oleanFile : String
  moduleArtifacts? : Option Beam.LSP.Save.ModuleArtifactPaths := none
  ileanFile : String
  cFile : String
  bcFile? : Option String := none
  deriving Inhabited, Repr, ToJson

structure SaveReadinessSpec where
  expectedVersionOverride? : Option Nat := none
  expectedTextHashOverride? : Option UInt64 := none
  deriving Inhabited, Repr, ToJson

structure DiagnosticsBarrierSpec where
  version? : Option Nat := none
  deriving Inhabited, Repr, ToJson

instance : FromJson ChangeSpec where
  fromJson? j := do
    let line ← j.getObjValAs? Nat "line"
    let character ← j.getObjValAs? Nat "character"
    let endLine? :=
      match j.getObjValAs? Nat "endLine" with
      | .ok n => some n
      | .error _ => none
    let endCharacter? :=
      match j.getObjValAs? Nat "endCharacter" with
      | .ok n => some n
      | .error _ => none
    let delete :=
      match j.getObjValAs? String "delete" with
      | .ok s => s
      | .error _ => ""
    let insert :=
      match j.getObjValAs? String "insert" with
      | .ok s => s
      | .error _ => ""
    pure { line, character, endLine?, endCharacter?, delete, insert }

instance : FromJson SendRunAtSpec where
  fromJson? j := do
    let version? :=
      match j.getObjValAs? Nat "version" with
      | .ok n => some n
      | .error _ => none
    let line ← j.getObjValAs? Nat "line"
    let character ← j.getObjValAs? Nat "character"
    let text ← j.getObjValAs? String "text"
    let storeHandle :=
      match j.getObjValAs? Bool "storeHandle" with
      | .ok b => b
      | .error _ => false
    pure { version?, line, character, text, storeHandle }

instance : FromJson RunWithSpec where
  fromJson? j := do
    let text ← j.getObjValAs? String "text"
    let storeHandle :=
      match j.getObjValAs? Bool "storeHandle" with
      | .ok b => b
      | .error _ => false
    let linear :=
      match j.getObjValAs? Bool "linear" with
      | .ok b => b
      | .error _ => false
    pure { text, storeHandle, linear }

structure DocHandle where
  id : Nat
  deriving Inhabited, BEq, Ord, Repr

structure ReqHandle where
  id : Nat
  deriving Inhabited, BEq, Ord, Repr

private structure DocState where
  uri : DocumentUri
  versionNo : Nat := 2
  text : String

private structure ReqState where
  requestID : RequestID
  params : Json
  outcome? : Option RequestOutcome := none

private structure State where
  nextRequestNo : Nat := 1
  nextDocHandle : Nat := 0
  nextReqHandle : Nat := 0
  docs : Std.TreeMap Nat DocState := {}
  requests : Std.TreeMap Nat ReqState := {}
  queuedResponses : Std.TreeMap RequestID RequestOutcome := {}

abbrev ScenarioM := StateT State Ipc.IpcM

private def ScenarioM.run (act : ScenarioM α) (init : State) : Ipc.IpcM (α × State) :=
  StateT.run act init

private def getDocState (doc : DocHandle) : ScenarioM DocState := do
  let some docState := (← get).docs.get? doc.id
    | throw <| IO.userError s!"unknown document handle {doc.id}"
  pure docState

private def setDocState (doc : DocHandle) (docState : DocState) : ScenarioM Unit := do
  modify fun s => { s with docs := s.docs.insert doc.id docState }

private def eraseDocState (doc : DocHandle) : ScenarioM Unit := do
  modify fun s => { s with docs := s.docs.erase doc.id }

private def getReqState (req : ReqHandle) : ScenarioM ReqState := do
  let some reqState := (← get).requests.get? req.id
    | throw <| IO.userError s!"unknown request handle {req.id}"
  pure reqState

private def setReqState (req : ReqHandle) (reqState : ReqState) : ScenarioM Unit := do
  modify fun s => { s with requests := s.requests.insert req.id reqState }

private def queueResponse (id : RequestID) (outcome : RequestOutcome) : ScenarioM Unit := do
  modify fun s => { s with queuedResponses := s.queuedResponses.insert id outcome }

private def takeQueuedResponse? (id : RequestID) : ScenarioM (Option RequestOutcome) := do
  let s ← get
  let outcome? := s.queuedResponses.get? id
  set { s with queuedResponses := s.queuedResponses.erase id }
  pure outcome?

private def sendRequest (method : String) (params : Json) : ScenarioM RequestID := do
  let s ← get
  let id : RequestID := s.nextRequestNo
  Ipc.writeRequest ⟨id, method, params⟩
  modify fun s => { s with nextRequestNo := s.nextRequestNo + 1 }
  pure id

private def registerRequest (requestID : RequestID) (params : Json) : ScenarioM ReqHandle := do
  let s ← get
  let req : ReqHandle := { id := s.nextReqHandle }
  set {
    s with
    nextReqHandle := s.nextReqHandle + 1
    requests := s.requests.insert req.id {
      requestID
      params
    }
  }
  pure req

private partial def waitForRequestOutcome (expectedID : RequestID) : ScenarioM RequestOutcome := do
  if let some outcome ← takeQueuedResponse? expectedID then
    return outcome
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      let outcome := { result? := some result : RequestOutcome }
      if id == expectedID then
        pure outcome
      else
        queueResponse id outcome
        waitForRequestOutcome expectedID
  | .responseError id code message _ =>
      let outcome := {
        errorCode? := some (errorCodeName code)
        errorMessage := message
        : RequestOutcome
      }
      if id == expectedID then
        pure outcome
      else
        queueResponse id outcome
        waitForRequestOutcome expectedID
  | .notification .. =>
      waitForRequestOutcome expectedID
  | .request .. =>
      waitForRequestOutcome expectedID

private partial def waitForDiagnostics (expectedID : RequestID)
    (lastDiag? : Option PublishDiagnosticsParams := none) : ScenarioM (Option PublishDiagnosticsParams) := do
  if let some outcome ← takeQueuedResponse? expectedID then
    if outcome.errorCode?.isSome then
      throw <| IO.userError s!"waiting for diagnostics failed: {outcome.errorMessage}"
    else
      return lastDiag?
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      if id == expectedID then
        pure lastDiag?
      else
        queueResponse id { result? := some result }
        waitForDiagnostics expectedID lastDiag?
  | .responseError id code message _ =>
      if id == expectedID then
        throw <| IO.userError s!"waiting for diagnostics failed: {message}"
      else
        queueResponse id {
          errorCode? := some (errorCodeName code)
          errorMessage := message
        }
        waitForDiagnostics expectedID lastDiag?
  | .notification "textDocument/publishDiagnostics" (some param) =>
      let diagnosticParam ← decodePublishDiagnostics (toJson param)
      waitForDiagnostics expectedID (some diagnosticParam)
  | .notification .. =>
      waitForDiagnostics expectedID lastDiag?
  | .request .. =>
      waitForDiagnostics expectedID lastDiag?

private partial def waitForRequestOutcomeCollectDiagnostics
    (expectedID : RequestID)
    (lastDiag? : Option PublishDiagnosticsParams := none) :
    ScenarioM (RequestOutcome × Option PublishDiagnosticsParams) := do
  if let some outcome ← takeQueuedResponse? expectedID then
    return (outcome, lastDiag?)
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      let outcome := { result? := some result : RequestOutcome }
      if id == expectedID then
        pure (outcome, lastDiag?)
      else
        queueResponse id outcome
        waitForRequestOutcomeCollectDiagnostics expectedID lastDiag?
  | .responseError id code message _ =>
      let outcome := {
        errorCode? := some (errorCodeName code)
        errorMessage := message
        : RequestOutcome
      }
      if id == expectedID then
        pure (outcome, lastDiag?)
      else
        queueResponse id outcome
        waitForRequestOutcomeCollectDiagnostics expectedID lastDiag?
  | .notification "textDocument/publishDiagnostics" (some param) =>
      let diagnosticParam ← decodePublishDiagnostics (toJson param)
      waitForRequestOutcomeCollectDiagnostics expectedID (some diagnosticParam)
  | .notification .. =>
      waitForRequestOutcomeCollectDiagnostics expectedID lastDiag?
  | .request .. =>
      waitForRequestOutcomeCollectDiagnostics expectedID lastDiag?

private def mkRangeChange (spec : ChangeSpec) : TextDocumentContentChangeEvent :=
  let endLine := spec.endLine?.getD spec.line
  let endCharacter := spec.endCharacter?.getD (spec.character + spec.delete.length)
  TextDocumentContentChangeEvent.rangeChange {
    start := { line := spec.line, character := spec.character }
    «end» := {
      line := endLine
      character := endCharacter
    }
  } spec.insert

partial def jsonContains (actual expected : Json) : Bool :=
  match actual, expected with
  | .obj actual, .obj expected =>
      expected.foldl (init := true) fun ok key expectedVal =>
        ok &&
          match actual.get? key with
          | some actualVal => jsonContains actualVal expectedVal
          | none => false
  | _, _ =>
      actual == expected

def expectJsonContains (label : String) (actual expected : Json) : ScenarioM Unit := do
  unless jsonContains actual expected do
    throw <| IO.userError
      s!"{label} mismatch\nexpected subset: {expected.compress}\nactual: {actual.compress}"

def openDoc (path : System.FilePath) : ScenarioM DocHandle := do
  let resolved ← IO.FS.realPath path
  let text ← IO.FS.readFile resolved
  let uri := System.Uri.pathToUri resolved
  Ipc.writeNotification ⟨"textDocument/didOpen", {
    textDocument := {
      uri
      languageId := "lean"
      version := 1
      text
    } : DidOpenTextDocumentParams
  }⟩
  let s ← get
  let doc : DocHandle := { id := s.nextDocHandle }
  set {
    s with
    nextDocHandle := s.nextDocHandle + 1
    docs := s.docs.insert doc.id { uri, versionNo := 2, text }
  }
  pure doc

def changeDocBatch (doc : DocHandle) (specs : Array ChangeSpec) : ScenarioM Unit := do
  let docState ← getDocState doc
  let contentChanges := specs.map mkRangeChange
  let params : DidChangeTextDocumentParams := {
    textDocument := { uri := docState.uri, version? := docState.versionNo }
    contentChanges
  }
  Ipc.writeNotification ⟨"textDocument/didChange", params⟩
  let text := (Lean.Server.foldDocumentChanges contentChanges docState.text.toFileMap).source
  setDocState doc { docState with versionNo := docState.versionNo + 1, text }

def changeDoc (doc : DocHandle) (spec : ChangeSpec) : ScenarioM Unit :=
  changeDocBatch doc #[spec]

def collectDiagnostics? (doc : DocHandle) : ScenarioM (Option PublishDiagnosticsParams) := do
  let docState ← getDocState doc
  let requestID ← sendRequest "textDocument/waitForDiagnostics" <|
    toJson <| WaitForDiagnosticsParams.mk docState.uri (docState.versionNo - 1)
  waitForDiagnostics requestID

def collectDiagnostics (doc : DocHandle) : ScenarioM PublishDiagnosticsParams := do
  let some diagnostics ← collectDiagnostics? doc
    | throw <| IO.userError s!"expected publishDiagnostics notification for document handle {doc.id}"
  pure diagnostics

def waitForILeansDiagnostics? (doc : DocHandle) : ScenarioM (Option PublishDiagnosticsParams) := do
  let docState ← getDocState doc
  let requestID ← sendRequest "$/lean/waitForILeans" <|
    toJson { uri? := some docState.uri, version? := some (docState.versionNo - 1) : WaitForILeansParams }
  let (outcome, diagnostics?) ← waitForRequestOutcomeCollectDiagnostics requestID
  if outcome.errorCode?.isSome then
    let code := outcome.errorCode?.getD "unknown"
    throw <| IO.userError s!"waiting for ILeans failed with {code}: {outcome.errorMessage}"
  pure diagnostics?

def waitForILeansDiagnostics (doc : DocHandle) : ScenarioM PublishDiagnosticsParams := do
  let some diagnostics ← waitForILeansDiagnostics? doc
    | throw <| IO.userError s!"expected publishDiagnostics notification while waiting for ILeans on document handle {doc.id}"
  pure diagnostics

def waitForILeans (doc : DocHandle) : ScenarioM Unit := do
  discard <| waitForILeansDiagnostics? doc

def syncDoc (doc : DocHandle) : ScenarioM Unit := do
  discard <| collectDiagnostics? doc

def closeDoc (doc : DocHandle) : ScenarioM Unit := do
  let docState ← getDocState doc
  Ipc.writeNotification ⟨"textDocument/didClose", {
    textDocument := { uri := docState.uri } : DidCloseTextDocumentParams
  }⟩
  eraseDocState doc

def notifyWatchedFileChanged (path : System.FilePath)
    (changeType : FileChangeType := .Changed) : ScenarioM Unit := do
  let resolved ← IO.FS.realPath path
  let uri := System.Uri.pathToUri resolved
  let params : DidChangeWatchedFilesParams := {
    changes := #[{ uri, type := changeType }]
  }
  Ipc.writeNotification ⟨"workspace/didChangeWatchedFiles", params⟩

def sendRunAt (doc : DocHandle) (spec : SendRunAtSpec) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.RunAt.Params := {
    textDocument := {
      uri := docState.uri
      version? := some (spec.version?.getD (docState.versionNo - 1))
    }
    position := { line := spec.line, character := spec.character }
    text := spec.text
    storeHandle? := if spec.storeHandle then some true else none
    profile? := if spec.profile then some true else none
  }
  let requestID ← sendRequest Beam.LSP.RunAt.method (toJson params)
  registerRequest requestID (toJson params)

def runWithHandle (doc : DocHandle) (handle : Beam.LSP.RunAt.Handle) (spec : RunWithSpec) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.RunAt.RunWithParams := {
    textDocument := { uri := docState.uri }
    handle
    text := spec.text
    storeHandle? := if spec.storeHandle then some true else none
    linear? := if spec.linear then some true else none
    profile? := if spec.profile then some true else none
  }
  let requestID ← sendRequest Beam.LSP.RunAt.runWithMethod (toJson params)
  registerRequest requestID (toJson params)

def sendGoals (doc : DocHandle) (spec : GoalsSpec) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.Goals.Params := {
    textDocument := {
      uri := docState.uri
      version? := some (spec.version?.getD (docState.versionNo - 1))
    }
    position := { line := spec.line, character := spec.character }
  }
  let method := if spec.useAfter then Beam.LSP.Goals.afterMethod else Beam.LSP.Goals.prevMethod
  let requestID ← sendRequest method (toJson params)
  registerRequest requestID (toJson params)

def sendTodo (doc : DocHandle) (spec : TodoSpec) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.Todo.TodoParams := {
    textDocument := {
      uri := docState.uri
      version? := some (spec.version?.getD (docState.versionNo - 1))
    }
    range := {
      start := { line := spec.startLine, character := spec.startCharacter }
      «end» := { line := spec.endLine, character := spec.endCharacter }
    }
    kinds? := spec.kinds?
    suggest? := spec.suggest?
  }
  let requestID ← sendRequest Beam.LSP.Todo.method (toJson params)
  registerRequest requestID (toJson params)

def sendSaveArtifacts (doc : DocHandle) (spec : SaveArtifactsSpec) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.Save.SaveArtifactsParams := {
    textDocument := { uri := docState.uri }
    expectedVersion := spec.expectedVersionOverride?.getD (docState.versionNo - 1)
    expectedTextHash := spec.expectedTextHashOverride?.getD (hash docState.text)
    oleanFile := spec.oleanFile
    moduleArtifacts? := spec.moduleArtifacts?
    ileanFile := spec.ileanFile
    cFile := spec.cFile
    bcFile? := spec.bcFile?
  }
  let requestID ← sendRequest Beam.LSP.Save.saveArtifactsMethod (toJson params)
  registerRequest requestID (toJson params)

def sendSaveReadiness (doc : DocHandle) (spec : SaveReadinessSpec := {}) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.Save.SaveReadinessParams := {
    textDocument := { uri := docState.uri }
    expectedVersion := spec.expectedVersionOverride?.getD (docState.versionNo - 1)
    expectedTextHash := spec.expectedTextHashOverride?.getD (hash docState.text)
  }
  let requestID ← sendRequest Beam.LSP.Save.saveReadinessMethod (toJson params)
  registerRequest requestID (toJson params)

def sendDiagnosticsBarrier (doc : DocHandle) (spec : DiagnosticsBarrierSpec := {}) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params := WaitForDiagnosticsParams.mk docState.uri (spec.version?.getD (docState.versionNo - 1))
  let requestID ← sendRequest Beam.LSP.DiagnosticsBarrier.method (toJson params)
  registerRequest requestID (toJson params)

def sendReleaseHandle (doc : DocHandle) (handle : Beam.LSP.RunAt.Handle) : ScenarioM ReqHandle := do
  let docState ← getDocState doc
  let params : Beam.LSP.RunAt.ReleaseHandleParams := {
    textDocument := { uri := docState.uri }
    handle
  }
  let requestID ← sendRequest Beam.LSP.RunAt.releaseHandleMethod (toJson params)
  registerRequest requestID (toJson params)

def releaseHandle (doc : DocHandle) (handle : Beam.LSP.RunAt.Handle) : ScenarioM Unit := do
  let req ← sendReleaseHandle doc handle
  let reqState ← getReqState req
  let outcome ← waitForRequestOutcome reqState.requestID
  setReqState req { reqState with outcome? := some outcome }
  if outcome.errorCode?.isSome then
    let code := outcome.errorCode?.getD "unknown"
    throw <| IO.userError s!"releaseHandle failed with {code}: {outcome.errorMessage}"

def cancelReq (req : ReqHandle) : ScenarioM Unit := do
  let reqState ← getReqState req
  Ipc.writeNotification ⟨"$/cancelRequest", { id := reqState.requestID : CancelParams }⟩

def awaitReq (req : ReqHandle) : ScenarioM RequestOutcome := do
  let reqState ← getReqState req
  if let some outcome := reqState.outcome? then
    return outcome
  let outcome ← waitForRequestOutcome reqState.requestID
  setReqState req { reqState with outcome? := some outcome }
  pure outcome

def awaitResponseAs [FromJson α] (req : ReqHandle) : ScenarioM α := do
  let outcome ← awaitReq req
  let some actual := outcome.result?
    | throw <| IO.userError <|
        s!"request handle {req.id} returned transport error " ++
          s!"{outcome.errorCode?.getD "unknown"} instead of a response: {outcome.errorMessage}"
  match fromJson? actual with
  | .ok value => pure value
  | .error err =>
      throw <| IO.userError s!"failed to decode response for request {req.id}: {err}\njson: {actual.compress}"

def expectResponseContains (req : ReqHandle) (expected : Json) : ScenarioM Unit := do
  let outcome ← awaitReq req
  let some actual := outcome.result?
    | throw <| IO.userError
        s!"request handle {req.id} returned transport error {outcome.errorCode?.getD "unknown"} instead of a response"
  expectJsonContains s!"response for request {req.id}" actual expected

def expectErrorContains (req : ReqHandle) (expected : Json) : ScenarioM Unit := do
  let outcome ← awaitReq req
  let some code := outcome.errorCode?
    | throw <| IO.userError s!"request handle {req.id} returned a normal response instead of a transport error"
  let actual : Json := Json.mkObj [
    ("code", toJson code),
    ("message", toJson outcome.errorMessage)
  ]
  expectJsonContains s!"transport error for request {req.id}" actual expected

def ensureAllRequestsAwaited : ScenarioM Unit := do
  for (reqID, reqState) in (← get).requests do
    if reqState.outcome?.isNone then
      throw <| IO.userError s!"request handle {reqID} was never awaited or asserted"

def run (act : ScenarioM α) : IO α := do
  let pluginArg := s!"--plugin={← BeamTest.TestHarness.pluginPath}"
  Ipc.runWith "lean" #["--server", pluginArg, "-DstderrAsMessages=false", "-Dexperimental.module=true"] do
    initializeServer
    let init : State := {}
    let (result, state) ← (do
      let result ← act
      ensureAllRequestsAwaited
      pure result : ScenarioM α).run init
    shutdownServer state.nextRequestNo
    pure result

end BeamTest.LSP.Scenario
