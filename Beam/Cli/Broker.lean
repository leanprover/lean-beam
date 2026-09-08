/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Broker.Client
import Beam.Broker.Transport
import Std.Internal.UV.Signal

namespace Beam.Cli

open Beam.Broker

private def withBrokerErrorContext
    {α}
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (action : IO (Except BrokerClientFailure α)) : IO α := do
  match ← action with
  | .ok value => pure value
  | .error failure =>
      throw <| IO.userError (← daemonFailureMessage root failure (some client.controlDir))

structure BrokerWaitSpec where
  action : String
  startMsg : String
  progressMsg : SyncFileProgress → String
  stillWaitingMsg : Nat → String
  completeMsg : Response → String
  failureBoundary : String := "before the request completed"
  responseNote? : Response → Option String := fun _ => none

structure InterruptWatcher where
  interrupted : IO Bool
  awaitInterrupt : IO Unit

private def closeInterruptSignal (signal : Std.Internal.UV.Signal) : IO Unit := do
  -- `Signal.stop` alone leaves an unresolved `next` promise and its waiter leaked. Cancel the
  -- pending wait first, then stop the underlying signal resource.
  try
    Std.Internal.UV.Signal.cancel signal
  finally
    Std.Internal.UV.Signal.stop signal

/-- Acquire one non-repeating SIGINT watcher and release its pending wait on every exit path. -/
def withInterruptWatcher (act : InterruptWatcher → IO α) : IO α := do
  let signal ← Std.Internal.UV.Signal.mk 2 false
  let promise ←
    try
      Std.Internal.UV.Signal.next signal
    catch err =>
      try
        Std.Internal.UV.Signal.stop signal
      catch _ =>
        pure ()
      throw err
  let event := promise.result?
  let watcher : InterruptWatcher := {
    interrupted := IO.hasFinished event
    awaitInterrupt := do
      let some _ ← IO.wait event
        | throw <| IO.userError "SIGINT watcher promise dropped"
      pure ()
  }
  try
    act watcher
  finally
    closeInterruptSignal signal

private def progressEnabled : IO Bool := do
  match ← envFlag? "BEAM_PROGRESS" with
  | some enabled =>
      pure enabled
  | none =>
      (← IO.getStderr).isTty

private def prepareWrapperBrokerRequest
    (client : ProjectDaemonClient)
    (req : Request) : IO Request := do
  withEnvClientRequestId <| client.sealRequest req

private def awaitBrokerResponseWithInterrupts
    (endpoint : Transport.Endpoint)
    (expectedIdentity : DaemonIdentity)
    (req : Request)
    (visibleClientRequestId? : Option String)
    (progressSpec? : Option BrokerWaitSpec)
    (callbacks : StreamCallbacks := {}) :
    IO (Except BrokerClientFailure Response) := do
  withInterruptWatcher fun interruptWatcher => do
    let emit := fun msg => IO.eprintln <| annotateRequestMessage visibleClientRequestId? msg
    if let some spec := progressSpec? then
      emit spec.startMsg
    let startedNanos ← IO.monoNanosNow
    let lastReportedSeconds ← IO.mkRef 0
    let interruptReported ← IO.mkRef false
    let interrupted : IO Bool := do
      let interrupted ← interruptWatcher.interrupted
      let interrupted := interrupted || (← IO.checkCanceled)
      if interrupted then
        unless ← interruptReported.get do
          interruptReported.set true
          emit "beam: interrupting broker request"
      else if let some spec := progressSpec? then
        let seconds := ((← IO.monoNanosNow) - startedNanos) / 1000000000
        let previous ← lastReportedSeconds.get
        if seconds > previous then
          lastReportedSeconds.set seconds
          emit <| spec.stillWaitingMsg seconds
      pure interrupted
    let result ← sendRequestWithCallbacksInterruptiblyResult endpoint req interrupted callbacks
      (.wrapper expectedIdentity)
    match result with
    | .ok response =>
        if let some spec := progressSpec? then
          emit <| spec.completeMsg response
        pure <| .ok response
    | .error failure => pure <| .error failure

private structure WrapperBrokerResponse where
  response : Response
  visibleClientRequestId? : Option String

private def requestBrokerResponse
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO WrapperBrokerResponse := do
  let wrapperReq ← prepareWrapperBrokerRequest client req
  let visibleClientRequestId? := wrapperReq.clientRequestId?
  let response ← withBrokerErrorContext root client do
    awaitBrokerResponseWithInterrupts client.endpoint client.identity wrapperReq
      visibleClientRequestId? none
  pure { response, visibleClientRequestId? }

/-- Send one wrapper request without printing or interpreting its response. -/
def requestBroker
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Response := do
  pure (← requestBrokerResponse root client req).response

def callBroker
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Unit := do
  let result ← requestBrokerResponse root client req
  printResponse result.response result.visibleClientRequestId?
  failOnError result.response

def callBrokerQuiet
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO Unit := do
  let resp ← requestBroker root client req
  failOnError resp

private def syncReadinessSuffix (result : SyncFileResult) : String :=
  let readiness := result.readiness
  if readiness.saveReady then
    ""
  else
    let errorCount := readiness.blockingErrorCount
    let reason := readiness.reason
    s!", saveReady=false ({reason}, " ++
      s!"blockingErrorCount={errorCount})"

private def syncLikeCompleteMsg (completeLabel path : String) (resp : Response) : String :=
  match decodeSyncFileResult? resp with
  | some result =>
      let suffix := syncFileProgressSuffix (responseFileProgress? resp)
      s!"beam: {completeLabel} complete for {path} (snapshot {result.snapshot}{suffix}{syncReadinessSuffix result})"
  | none =>
      s!"beam: {completeLabel} complete for {path}"

private def syncLikeWaitSpec
    (action path startMsg progressLabel stillWaitingLabel completeLabel : String) : BrokerWaitSpec :=
  {
    action
    startMsg
    progressMsg := fun progress => s!"beam: {progressLabel} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still {stillWaitingLabel} {path} ({seconds}s)"
    completeMsg := syncLikeCompleteMsg completeLabel path
    failureBoundary := "before a complete diagnostics barrier was available"
  }

def syncWaitSpec (path : String) (action : String := "sync") : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := action)
    (path := path)
    (startMsg := s!"beam: syncing {path} and waiting for Lean diagnostics")
    (progressLabel := "sync")
    (stillWaitingLabel := "syncing")
    (completeLabel := "sync")

def refreshWaitSpec (path : String) (action : String := "refresh") : BrokerWaitSpec :=
  syncLikeWaitSpec
    (action := action)
    (path := path)
    (startMsg := s!"beam: refreshing {path} by closing and resyncing")
    (progressLabel := "refresh")
    (stillWaitingLabel := "refreshing")
    (completeLabel := "refresh")

def leanRunAtWaitSpec (action path : String) (line character : Nat) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: snapshot progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for a ready Lean snapshot for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before probe execution"
    responseNote? := runAtPayloadSummary? action "probe"
  }

private def leanPositionNavigationWaitSpec
    (path : String)
    (line character : Nat)
    (action progressLabel noun : String) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {progressLabel} progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := s!"before {noun} data was available"
  }

def leanHoverWaitSpec (path : String) (line character : Nat) (action : String := "hover") :
    BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "hover" "hover"

def leanDefinitionWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "definition") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "definition" "definition"

def leanSignatureHelpWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "signature-help") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "signature-help" "signature help"

def leanReferencesWaitSpec
    (path : String)
    (line character : Nat)
    (action : String := "references") : BrokerWaitSpec :=
  leanPositionNavigationWaitSpec path line character action "references" "reference"

def leanDocumentSymbolsWaitSpec
    (path : String)
    (action : String := "document-symbols") : BrokerWaitSpec :=
  {
    action := action
    startMsg := s!"beam: querying {action} for {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: document-symbol progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before document symbols were available"
  }

def leanWorkspaceSymbolsWaitSpec
    (query : String)
    (action : String := "workspace-symbols") : BrokerWaitSpec :=
  {
    action := action
    startMsg := s!"beam: querying {action} for {query}"
    progressMsg := fun _ => s!"beam: workspace-symbol progress for query {query}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} query {query} ({seconds}s)"
    completeMsg := fun _ => s!"beam: {action} complete for query {query}"
    failureBoundary := "before workspace symbols were available"
  }

def leanGoalsWaitSpec
    (path : String)
    (line character : Nat)
    (mode : GoalMode)
    (action? : Option String := none) : BrokerWaitSpec :=
  let pos := s!"{path}:{line}:{character}"
  let action :=
    action?.getD <|
      match mode with
      | .before | .after => "goals"
  {
    action := action
    startMsg := s!"beam: running {action} on {pos} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: goals progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before goal inspection completed"
  }

def leanTodoWaitSpec
    (path : String)
    (startLine startCharacter endLine endCharacter : Nat)
    (action : String := "todo") : BrokerWaitSpec :=
  let pos := s!"{path}:{startLine}:{startCharacter}-{endLine}:{endCharacter}"
  {
    action := action
    startMsg := s!"beam: querying {action} for {pos} and waiting for Lean diagnostics"
    progressMsg := fun progress => s!"beam: todo progress for {pos}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {pos} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {pos}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before todo inspection completed"
  }

def leanRunWithWaitSpec
    (path : String)
    (linear : Bool := false)
    (action? : Option String := none) : BrokerWaitSpec :=
  let action := action?.getD <| if linear then "run-with-linear" else "run-with"
  {
    action := action
    startMsg := s!"beam: running {action} on {path} and waiting for a ready Lean snapshot"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds =>
      s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp =>
      s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before speculative continuation completed"
    responseNote? := runAtPayloadSummary? action "continuation"
  }

def leanSaveWaitSpec
    (path : String)
    (closeAfter : Bool := false)
    (action? : Option String := none) : BrokerWaitSpec :=
  let action := action?.getD <| if closeAfter then "close-save" else "save"
  let verb := if closeAfter then "closing and saving" else "saving"
  {
    action := action
    startMsg := s!"beam: {verb} {path} and waiting for Lean diagnostics/artifacts"
    progressMsg := fun progress => s!"beam: {action} progress for {path}{syncFileProgressSuffix (some progress)}"
    stillWaitingMsg := fun seconds => s!"beam: still waiting for {action} on {path} ({seconds}s)"
    completeMsg := fun resp => s!"beam: {action} complete for {path}{syncFileProgressSuffix (responseFileProgress? resp)}"
    failureBoundary := "before save artifacts were finalized"
  }

def callBrokerWithProgress
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit := do
  let wrapperReq ← prepareWrapperBrokerRequest client req
  let req := wrapperReq
  let visibleClientRequestId? := req.clientRequestId?
  let showProgress ← progressEnabled
  let callbacks : StreamCallbacks := {
    onFileProgress := fun progress => do
      if showProgress then
        IO.eprintln <| annotateRequestMessage visibleClientRequestId? (spec.progressMsg progress)
    onDiagnostic := fun diagnostic =>
      IO.eprintln <| annotateRequestMessage visibleClientRequestId? (formatStreamDiagnostic diagnostic)
  }
  let progressSpec? := if showProgress then some spec else none
  let resp ← withBrokerErrorContext root client do
    awaitBrokerResponseWithInterrupts client.endpoint client.identity req
      visibleClientRequestId? progressSpec? callbacks
  match responseErrorSummary? spec.action spec.failureBoundary resp with
  | some note =>
      IO.eprintln <| annotateRequestMessage visibleClientRequestId? note
  | none =>
      pure ()
  match responseRecoveryHint? resp with
  | some note =>
      IO.eprintln <| annotateRequestMessage visibleClientRequestId? note
  | none =>
      pure ()
  match spec.responseNote? resp with
  | some note =>
      IO.eprintln <| annotateRequestMessage visibleClientRequestId? note
  | none =>
      pure ()
  maybeEmitLiteralBackslashNewlineHint visibleClientRequestId? req resp
  printResponse resp visibleClientRequestId?
  failOnError resp

end Beam.Cli
