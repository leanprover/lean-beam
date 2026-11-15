/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Test.Runner
import Beam.LSP.RunAt
import Beam.LSP.Goals
import Beam.LSP.Todo
import Beam.LSP.Save
import Beam.LSP.Lib.Goal
import BeamTest.TestHarness

open Lean
open Lean.Lsp
open Lean.JsonRpc
open Lean.Lsp.Ipc

namespace BeamTest.LSP.TestRunner

open BeamTest.TestHarness

private structure PendingRequest where
  id : RequestID

private structure TransportError where
  code : String
  message : String
  deriving ToJson

private structure LoggedTransportError where
  error : TransportError
  deriving ToJson

private structure DirectiveInfo where
  pos : Lsp.Position
  method : String
  params : String

private inductive RequestOutcome where
  | response (result : Json)
  | error (code : ErrorCode) (message : String)

private structure State where
  runner : Lean.Server.Test.Runner.RunnerState
  pendingRequest? : Option PendingRequest := none
  queuedResponses : Std.TreeMap RequestID RequestOutcome := {}

private abbrev M := StateT State Ipc.IpcM

private def M.run (act : M α) (init : State) : Ipc.IpcM (α × State) :=
  StateT.run act init

private def runRunner (act : Lean.Server.Test.Runner.RunnerM α) : M α := do
  let s ← get
  let (a, runner) ← StateT.run (m := Ipc.IpcM) act s.runner
  set { s with runner }
  pure a

private def reset : M Unit := do
  runRunner Lean.Server.Test.Runner.reset
  modify fun s => { s with pendingRequest? := none, queuedResponses := {} }

private def parseDirective? (runner : Lean.Server.Test.Runner.RunnerState) (line : String) :
    Option DirectiveInfo := do
  let [ws, directive] := line.split "--" |>.toStringList
    | none
  let directiveTargetLineNo ←
    match directive.front with
    | '^' => some runner.lastActualLineNo
    | 'v' => some (runner.lineNo + 1)
    | _ => none
  let directive := directive.drop 1
  let colon := directive.find ':'
  let method := directive.sliceTo colon |>.trimAscii |>.copy
  let params :=
    if h : ¬ colon.IsAtEnd then
      directive.sliceFrom (colon.next h) |>.trimAscii.copy
    else
      "{}"
  let pos : Lsp.Position := {
    line := directiveTargetLineNo
    character := (ws.rawEndPos + "--").byteIdx
  }
  some { pos, method, params }

private def isCustomMethod (method : String) : Bool :=
  method == Beam.LSP.RunAt.method ||
    method == s!"{Beam.LSP.RunAt.method}/send" ||
    method == s!"{Beam.LSP.RunAt.method}/await" ||
    method == "sync" ||
    method == "collectDiagnostics" ||
    method == "waitForILeans" ||
    method == "waitFor"

private def setDirectiveContext (info : DirectiveInfo) : M Unit := do
  modify fun s => {
    s with
    runner := { s.runner with pos := info.pos, method := info.method, params := info.params }
  }

private def buildParams (runner : Lean.Server.Test.Runner.RunnerState) (paramsText : String) :
    IO Json := do
  let Except.ok params := Json.parse paramsText
    | throw <| IO.userError s!"failed to parse {paramsText}"
  let params := params.setObjVal! "textDocument" <|
    toJson (VersionedTextDocumentIdentifier.mk runner.uri (some (runner.versionNo - 1)))
  let params := params.setObjVal! "position" (toJson runner.pos)
  pure params

private def queueResponse (id : RequestID) (outcome : RequestOutcome) : M Unit := do
  modify fun s => { s with queuedResponses := s.queuedResponses.insert id outcome }

private def takeQueuedResponse? (id : RequestID) : M (Option RequestOutcome) := do
  let s ← get
  let outcome? := s.queuedResponses.get? id
  set { s with queuedResponses := s.queuedResponses.erase id }
  pure outcome?

private partial def waitForRequestOutcome (expectedID : RequestID) : M RequestOutcome := do
  if let some outcome ← takeQueuedResponse? expectedID then
    return outcome
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      if id == expectedID then
        pure <| .response result
      else
        queueResponse id (.response result)
        waitForRequestOutcome expectedID
  | .responseError id code message _ =>
      if id == expectedID then
        pure <| .error code message
      else
        queueResponse id (.error code message)
        waitForRequestOutcome expectedID
  | .notification .. =>
      waitForRequestOutcome expectedID
  | .request .. =>
      waitForRequestOutcome expectedID

private def sendRequest (method : String) (params : Json) : M RequestID := do
  let runner := (← get).runner
  let id : RequestID := runner.requestNo
  Ipc.writeRequest ⟨id, method, params⟩
  runRunner Lean.Server.Test.Runner.advanceRequestNo
  pure id

private partial def waitForDiagnostics (expectedID : RequestID)
    (lastDiag? : Option PublishDiagnosticsParams := none) : M (Option PublishDiagnosticsParams) := do
  if let some outcome ← takeQueuedResponse? expectedID then
    match outcome with
    | .response _ => return lastDiag?
    | .error _ msg => throw <| IO.userError s!"Waiting for diagnostics failed: {msg}"
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      if id == expectedID then
        return lastDiag?
      else
        queueResponse id (.response result)
        waitForDiagnostics expectedID lastDiag?
  | .responseError id code message _ =>
      if id == expectedID then
        throw <| IO.userError s!"Waiting for diagnostics failed: {message}"
      else
        queueResponse id (.error code message)
        waitForDiagnostics expectedID lastDiag?
  | .notification "textDocument/publishDiagnostics" (some param) =>
      let diagnosticParam ← decodePublishDiagnostics (toJson param)
      waitForDiagnostics expectedID (some diagnosticParam)
  | .notification .. =>
      waitForDiagnostics expectedID lastDiag?
  | .request .. =>
      waitForDiagnostics expectedID lastDiag?

private partial def waitForMessage (needle : String) : M Unit := do
  let msg ← Ipc.readMessage
  match msg with
  | .response id result =>
      queueResponse id (.response result)
      waitForMessage needle
  | .responseError id code message _ =>
      queueResponse id (.error code message)
      waitForMessage needle
  | .notification "textDocument/publishDiagnostics" (some param) =>
      let diagnosticParam ← decodePublishDiagnostics (toJson param)
      if diagnosticParam.diagnostics.any (·.message == needle) then
        pure ()
      else
        waitForMessage needle
  | .notification .. =>
      waitForMessage needle
  | .request .. =>
      waitForMessage needle

private def processSync (info : DirectiveInfo) : M Unit := do
  setDirectiveContext info
  let runner := (← get).runner
  let id ← sendRequest "textDocument/waitForDiagnostics" <|
    toJson <| WaitForDiagnosticsParams.mk runner.uri (runner.versionNo - 1)
  discard <| waitForDiagnostics id
  runRunner Lean.Server.Test.Runner.setSynced

private def processCollectDiagnostics (info : DirectiveInfo) : M Unit := do
  setDirectiveContext info
  let runner := (← get).runner
  let id ← sendRequest "textDocument/waitForDiagnostics" <|
    toJson <| WaitForDiagnosticsParams.mk runner.uri (runner.versionNo - 1)
  if let some diags ← waitForDiagnostics id then
    Lean.Server.Test.Runner.printOutputLn (toJson diags)
  runRunner Lean.Server.Test.Runner.setSynced

private def processWaitForILeans (info : DirectiveInfo) : M Unit := do
  setDirectiveContext info
  let runner := (← get).runner
  let id ← sendRequest "$/lean/waitForILeans" <|
    toJson { uri? := some runner.uri, version? := some (runner.versionNo - 1) : WaitForILeansParams }
  match ← waitForRequestOutcome id with
  | .response _ => pure ()
  | .error _ msg => throw <| IO.userError s!"Waiting for ILeans failed: {msg}"

private def processWaitFor (info : DirectiveInfo) : M Unit := do
  setDirectiveContext info
  waitForMessage info.params
  runRunner Lean.Server.Test.Runner.setSynced

private def logOutcome (outcome : RequestOutcome) : IO Unit :=
  match outcome with
  | .response result =>
      Lean.Server.Test.Runner.printOutputLn result
  | .error code message =>
      let payload : LoggedTransportError := {
        error := {
          code := errorCodeName code
          message
        }
      }
      Lean.Server.Test.Runner.printOutputLn <| toJson payload

private def ensureNoPendingRequest : M Unit := do
  if (← get).pendingRequest?.isSome then
    throw <| IO.userError "pending runAt request was not awaited"

private def processRunAtSync (info : DirectiveInfo) : M Unit := do
  ensureNoPendingRequest
  setDirectiveContext info
  let runner := (← get).runner
  let params ← buildParams runner info.params
  Lean.Server.Test.Runner.printOutputLn params
  let id ← sendRequest Beam.LSP.RunAt.method params
  let outcome ← waitForRequestOutcome id
  logOutcome outcome

private def processRunAtSend (info : DirectiveInfo) : M Unit := do
  ensureNoPendingRequest
  setDirectiveContext info
  let runner := (← get).runner
  let params ← buildParams runner info.params
  Lean.Server.Test.Runner.printOutputLn params
  let id ← sendRequest Beam.LSP.RunAt.method params
  modify fun s => { s with pendingRequest? := some { id } }

private def processRunAtAwait (info : DirectiveInfo) : M Unit := do
  setDirectiveContext info
  let some pending := (← get).pendingRequest?
    | throw <| IO.userError "no pending runAt request to await"
  modify fun s => { s with pendingRequest? := none }
  let outcome ← waitForRequestOutcome pending.id
  logOutcome outcome

private def processLine (line : String) : M Unit := do
  let runner := (← get).runner
  match parseDirective? runner line with
  | some info =>
      if isCustomMethod info.method then
        if info.method == Beam.LSP.RunAt.method then
          processRunAtSync info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == s!"{Beam.LSP.RunAt.method}/send" then
          processRunAtSend info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == s!"{Beam.LSP.RunAt.method}/await" then
          processRunAtAwait info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == "sync" then
          processSync info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == "collectDiagnostics" then
          processCollectDiagnostics info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == "waitForILeans" then
          processWaitForILeans info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else if info.method == "waitFor" then
          processWaitFor info
          runRunner Lean.Server.Test.Runner.skipLineWithDirective
        else
          unreachable!
      else
        runRunner <| Lean.Server.Test.Runner.processLine line
  | none =>
      runRunner <| Lean.Server.Test.Runner.processLine line

partial def main (args : List String) : IO Unit := do
  let args := args.toArray
  let some (path : String) := args[0]?
    | throw <| IO.userError "usage: lake exe beam-lsp-test <file>"
  let uri := s!"file:///{path}"
  let pluginArg := s!"--plugin={← BeamTest.TestHarness.pluginPath}"
  Ipc.runWith "lean" #["--server", pluginArg, "-DstderrAsMessages=false", "-Dexperimental.module=true"] do
    initializeServer
    let text ← IO.FS.readFile path
    let initRunner : Lean.Server.Test.Runner.RunnerState := {
      uri
      synced := true
      versionNo := 2
      rpcSessionId := none
      lineNo := 0
      lastActualLineNo := 0
      pos := ⟨0, 0⟩
      method := ""
      params := ""
      requestNo := 1
    }
    let init : State := { runner := initRunner }
    discard <| (do
      for text in text.split "-- RESET" do
        Ipc.writeNotification ⟨"textDocument/didOpen", {
          textDocument := { uri := uri, languageId := "lean", version := 1, text := text.copy } : DidOpenTextDocumentParams }⟩
        reset
        for line in text.split '\n' do
          processLine line.copy
        ensureNoPendingRequest
        let runner := (← get).runner
        let _ ← Ipc.collectDiagnostics runner.requestNo uri (runner.versionNo - 1)
        runRunner Lean.Server.Test.Runner.advanceRequestNo
        Ipc.writeNotification ⟨"textDocument/didClose", {
          textDocument := { uri } : DidCloseTextDocumentParams }⟩

      let runner := (← get).runner
      shutdownServer runner.requestNo
      : M Unit).run init

end BeamTest.LSP.TestRunner

def main := BeamTest.LSP.TestRunner.main
