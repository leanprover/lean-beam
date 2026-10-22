/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Broker.Client
import Beam.Broker.Output
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

/-- Borrowed stop observation, valid during its enclosing watcher callback. -/
structure InterruptWatcher where
  interrupted : IO Bool
  awaitInterrupt : IO Unit

private def withSignalEvent
    (signum : Int32) (repeating : Bool) (act : Task (Option Int) → IO α) : IO α := do
  let signal ← Std.Internal.UV.Signal.mk signum repeating
  -- A failed start has no subscription to stop; dropping the object closes its native handle.
  let promise ← Std.Internal.UV.Signal.next signal
  try
    act promise.result?
  finally
    -- Every supported runtime drops its pending promise when the signal handler is stopped.
    Std.Internal.UV.Signal.stop signal

private def interruptWatcher
    (interrupt : Task (Option Int)) (others : List (Task (Option Int)) := []) : InterruptWatcher := {
  interrupted := (interrupt :: others).anyM fun event => IO.hasFinished event
  awaitInterrupt := do
    let some _ ← IO.waitAny (interrupt :: others)
      | throw <| IO.userError "interrupt watcher promise dropped"
    pure ()
}

/-- Observe the first SIGINT during a request; further SIGINTs retain default termination. -/
def withRequestInterruptWatcher (act : InterruptWatcher → IO α) : IO α :=
  withSignalEvent 2 false fun interrupt => act (interruptWatcher interrupt)

/-- Latch owner termination through cleanup: SIGINT everywhere, plus SIGTERM/SIGHUP on POSIX.
Repeated signals do not escalate. This is cooperative shutdown, including during synchronous I/O. -/
def withOwnerInterruptWatcher (act : InterruptWatcher → IO α) : IO α :=
  withSignalEvent 2 true fun interrupt => do
    if System.Platform.isWindows then
      act (interruptWatcher interrupt)
    else
      withSignalEvent 15 true fun terminate =>
        withSignalEvent 1 true fun hangup => act (interruptWatcher interrupt [terminate, hangup])

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
    (interruptWatcher : InterruptWatcher)
    (endpoint : Transport.Endpoint)
    (expectedIdentity : DaemonIdentity)
    (req : Request)
    (visibleClientRequestId? : Option String)
    (waitMessage? : Option (Nat → String))
    (formatProgress? : Option (SyncFileProgress → String) := none)
    (showDiagnostics : Bool := false)
    (startMessage? : Option String := none) :
    IO (Except BrokerClientFailure Response) := do
  let text ← Beam.WorkspaceOutput.Buffer.create
  let output ← Output.Queue.create text
  let some publisher ← text.borrow | throw <| IO.userError "new CLI output buffer was closed"
  let emit := fun msg => publisher.offer .stderr <|
    annotateRequestMessage visibleClientRequestId? msg ++ "\n"
  let stop ← IO.mkRef false
  let startedNanos ← IO.monoNanosNow
  let lastActivityNanos ← IO.mkRef startedNanos
  let observedOutput ← IO.mkRef (← text.activity)
  let interrupted : IO Bool := do
    let interrupted ← interruptWatcher.interrupted
    let interrupted := interrupted || (← stop.get) || (← output.failed) || (← IO.checkCanceled)
    if !interrupted then
      if let some waitMessage := waitMessage? then
        let now ← IO.monoNanosNow
        let activity ← text.activity
        if activity != (← observedOutput.get) then
          observedOutput.set activity
          lastActivityNanos.set now
        else if now >= (← lastActivityNanos.get) + 5000000000 then
          lastActivityNanos.set now
          emit <| waitMessage ((now - startedNanos) / 1000000000)
    pure interrupted
  let callbacks : StreamCallbacks := {
    output? := some publisher
    onFileProgress := fun progress => do
      if formatProgress?.isSome then
        lastActivityNanos.set (← IO.monoNanosNow)
        output.progress req.clientRequestId? progress
    onDiagnostic := fun diagnostic => do
      if showDiagnostics then
        lastActivityNanos.set (← IO.monoNanosNow)
        output.diagnostic req.clientRequestId? diagnostic
  }
  let completion : IO.Promise (Except IO.Error (Except BrokerClientFailure Response)) ← IO.Promise.new
  let execution := completion.result?.map fun
    | some result => result
    | none => .error <| IO.userError "CLI request completion was dropped"
  let stderr ← IO.getStderr
  let textFormat ← IO.mkRef ({} : WorkspaceOutputFormat)
  let renderer ← IO.asTask (prio := Task.Priority.dedicated) do
    try
      output.run execution Except.toOption req.clientRequestId? fun message => do
        match message with
        | .fileProgress _ progress =>
            if let some format := formatProgress? then
              stderr.putStrLn <| annotateRequestMessage visibleClientRequestId? (format progress)
              textFormat.modify fun state => { state with atLineStart := true }
        | .diagnostic _ diagnostic =>
            if showDiagnostics then
              stderr.putStrLn <| annotateRequestMessage visibleClientRequestId? (formatStreamDiagnostic diagnostic)
              textFormat.modify fun state => { state with atLineStart := true }
        | .workspaceOutput _ chunk =>
            let (state, rendered) := (← textFormat.get).render chunk
            textFormat.set state
            stderr.putStr rendered
        | .response .. => pure ()
        stderr.flush
    finally
      -- A broken renderer stops the caller's interruptible request independently.
      stop.set true
  let outcome : Except IO.Error (Except BrokerClientFailure Response) ←
    try
      if let some message := startMessage? then emit message
      -- Keep execution in the caller: IO.checkCanceled observes this task's cancellation.
      let result : Except BrokerClientFailure Response ←
        if ← interrupted then pure <| .error .interrupted
        else
          sendRequestWithCallbacksInterruptiblyResult endpoint req interrupted callbacks
            (.wrapper expectedIdentity)
      if let .error .interrupted := result then output.cancelOptional
      pure (.ok result)
    catch error => pure (.error error)
    finally publisher.retire
  completion.resolve outcome
  let result ← try
    IO.ofExcept (← IO.wait renderer)
  finally
    stop.set true
    output.cancelOptional
  if let .error .interrupted := result then
    IO.eprintln <| annotateRequestMessage visibleClientRequestId? "beam: interrupting broker request"
  pure result

private structure WrapperBrokerResponse where
  response : Response
  visibleClientRequestId? : Option String

private def requestBrokerResponseWithWatcher
    (watcher : InterruptWatcher)
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request)
    (waitMessage? : Option (Nat → String) := none) : IO WrapperBrokerResponse := do
  let wrapperReq ← prepareWrapperBrokerRequest client req
  let visibleClientRequestId? := wrapperReq.clientRequestId?
  let response ← withBrokerErrorContext root client do
    awaitBrokerResponseWithInterrupts watcher client.endpoint client.identity wrapperReq
      visibleClientRequestId? waitMessage?
  pure { response, visibleClientRequestId? }

private def requestBrokerResponse
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request) : IO WrapperBrokerResponse :=
  withRequestInterruptWatcher fun watcher =>
    requestBrokerResponseWithWatcher watcher root client req

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

/-- Prepare the owned session without printing its broker response as CLI readiness. -/
def ensureProjectSession
    (watcher : InterruptWatcher)
    (root : System.FilePath)
    (client : ProjectDaemonClient) : IO Unit := do
  let waitMessage? : Option (Nat → String) := if ← progressEnabled then
      some fun seconds => s!"beam: still preparing Lean workspace ({seconds}s)"
    else none
  let result ← requestBrokerResponseWithWatcher watcher root client Request.ensure waitMessage?
  failOnError result.response

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
      s!"beam: {completeLabel} complete for {path} (version {result.version}{suffix}{syncReadinessSuffix result})"
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

private def requestBrokerResponseWithProgress
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request)
    (spec : BrokerWaitSpec)
    (showProgress : Bool) : IO WrapperBrokerResponse := do
  let req ← prepareWrapperBrokerRequest client req
  let visibleClientRequestId? := req.clientRequestId?
  let formatProgress? := if showProgress then some spec.progressMsg else none
  let startMessage? := if showProgress then some spec.startMsg else none
  let waitMessage? := if showProgress then some spec.stillWaitingMsg else none
  let response ← withBrokerErrorContext root client do
    withRequestInterruptWatcher fun watcher => do
      awaitBrokerResponseWithInterrupts watcher client.endpoint client.identity req
        visibleClientRequestId? waitMessage? formatProgress? true startMessage?
  pure { response, visibleClientRequestId? }

def callBrokerWithProgress
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (req : Request)
    (spec : BrokerWaitSpec) : IO Unit := do
  let showProgress ← progressEnabled
  let result ← requestBrokerResponseWithProgress root client req spec showProgress
  let resp := result.response
  let visibleClientRequestId? := result.visibleClientRequestId?
  if showProgress then
    IO.eprintln <| annotateRequestMessage visibleClientRequestId? (spec.completeMsg resp)
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
