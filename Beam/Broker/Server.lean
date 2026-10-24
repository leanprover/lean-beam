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
import Lean.Parser.Module
import Lean.Server.CodeActions
import Beam.Broker.BackendProcess
import Beam.Broker.Config
import Beam.Broker.DocumentState
import Beam.Broker.DocumentAdmission
import Beam.Broker.Errors
import Beam.Broker.Metrics
import Beam.Broker.OpenDocs
import Beam.Broker.Output
import Beam.Broker.Pending
import Beam.Broker.Protocol
import Beam.Broker.Publication
import Beam.Broker.Transport
import Beam.Broker.Lean
import Beam.Broker.LakeSave
import Beam.Broker.Readiness
import Beam.Broker.SyncResult
import Beam.Daemon.Startup
import Beam.LSP.Save
import Beam.Path
import Beam.StderrCapture
import Beam.System
import Std.Sync.Mutex

open Lean
open Lean.JsonRpc
open Lean.Lsp
open IO.FS.Stream

namespace Beam.Broker

abbrev brokerStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  -- Keep backend stderr away from MCP stdio while retaining a bounded tail for
  -- startup and worker-exit diagnostics. The blocking drain runs on a dedicated
  -- task so it cannot starve regular Lean tasks.
  stderr := .piped

private def backendStderrTailLimit : Nat :=
  16 * 1024

abbrev BackendStderrCapture := Beam.StderrCapture

def startBackendStderrCapture (stderr : IO.FS.Handle) : IO BackendStderrCapture := do
  Beam.StderrCapture.start stderr backendStderrTailLimit

structure Session where
  workspaceId : WorkspaceId
  workspaceGeneration : Nat
  root : System.FilePath
  epoch : Nat
  sessionToken : String
  proc : BackendProcess
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  stderrCapture : BackendStderrCapture
  pending : PendingRequestStore
  nextId : Nat := 1
  nextEventSeq : Nat := 1
  moduleHistory : Std.TreeMap String ModuleHistory := {}
  /-- Event sequence of each module's last artifact publication, recorded whether or not its
  document stays tracked. Temporary with the import basis check (issue #370). -/
  publishedModules : Std.TreeMap String Nat := {}
  docs : Std.TreeMap String DocState := {}

structure SessionState where
  nextEpoch : Nat := 1
  session? : Option Session := none

structure WorkspaceState where
  generation : Nat
  config : BrokerConfig
  nextFileSnapshotSeq : Nat := 1
  documents : DocumentAdmission.State := .empty
  lean : SessionState := {}
  metrics : WorkspaceMetrics := {}

private structure PublicationClaim where
  token : Nat
  workspaceId : WorkspaceId
  done : IO.Promise Unit

structure State where
  bootstrapConfig : BrokerConfig
  startMonoNanos : Nat := 0
  nextWorkspaceGeneration : Nat := 2
  workspaces : Std.TreeMap WorkspaceId WorkspaceState := {}
  streamSink? : Option (StreamMessage → IO Unit) := none
  currentClientRequestId? : Option String := none
  private nextPublicationToken : Nat := 1
  private publication? : Option PublicationClaim := none

abbrev M := StateRefT State IO

private abbrev HandlerM := ExceptT ResponseFailure IO

private def liftHandlerIO (act : IO α) : HandlerM α :=
  ExceptT.mk do
    let value ← act
    pure (.ok value)

private def liftFailureIO (act : IO (Except ResponseFailure α)) : HandlerM α :=
  ExceptT.mk act

private def throwBrokerFailure (failure : BrokerFailure) : HandlerM α :=
  throw failure.toResponseFailure

private def liftBrokerFailureIO (act : IO (Except BrokerFailure α)) : HandlerM α :=
  liftFailureIO do
    match ← act with
    | .ok value => pure <| .ok value
    | .error failure => pure <| .error failure.toResponseFailure

private def withFailureProgress
    (fileProgress? : Option SyncFileProgress)
    (act : HandlerM α) : HandlerM α :=
  ExceptT.mk do
    try
      match ← act.run with
      | .ok value => pure (.ok value)
      | .error failure =>
          pure (.error <| failure.withOptionalFileProgress fileProgress?)
    catch e =>
      pure (.error <|
        (responseFailureFor .internalError e.toString).withOptionalFileProgress fileProgress?)

private def requestArg (arg : Except ResponseFailure α) : HandlerM α :=
  match arg with
  | .ok value => pure value
  | .error failure => throw failure

private def runHandler (act : HandlerM Response) : IO Response := do
  try
    match ← act.run with
    | .ok result => pure result
    | .error failure => pure failure.toResponse
  catch e =>
    pure <| errorResponseFor .internalError e.toString

private def mkSessionToken : IO String := do
  let pid ← IO.Process.getPID
  let now ← IO.monoNanosNow
  pure s!"{pid}-{now}"

private def resolveRoot (root : System.FilePath) : IO System.FilePath :=
  Beam.resolveExistingPath root

/-- Closing and dead-session cleanup must remain possible after the source path disappears. -/
private def resolveDocumentPath (root : System.FilePath) (path : System.FilePath) :
    IO System.FilePath :=
  Beam.resolvePathForCreation <| if path.isAbsolute then path else root / path

private def documentBoundaryFailure (root path : System.FilePath) : ResponseFailure :=
  responseFailureFor .invalidParams
    s!"document '{path}' resolves outside workspace root '{root}'; select a workspace containing the document"

private def unresolvedSourceFailure (root path : System.FilePath) : ResponseFailure :=
  responseFailureFor .invalidParams
    s!"document path '{path}' cannot be resolved in workspace '{root}'"

/-- Only ordinary failures of observing a supplied source path are input errors. -/
private def sourceObservationFailure?
    (root path : System.FilePath) : IO.Error → Option ResponseFailure
  | .noFileOrDirectory .. => some <| responseFailureFor .invalidParams
      s!"document '{path}' does not exist in workspace '{root}'"
  | .inappropriateType .. => some <| responseFailureFor .invalidParams
      s!"document '{path}' is not a regular source file in workspace '{root}'"
  | _ => none

/-- Invalid arguments are classified here only for filesystem path resolution, not arbitrary I/O. -/
private def sourceResolutionFailure?
    (root path : System.FilePath) (error : IO.Error) : Option ResponseFailure :=
  match error with
  | .invalidArgument .. => some <| unresolvedSourceFailure root path
  | _ => sourceObservationFailure? root path error

/-- Capture an existing regular Lean source; missing-suffix lookup never authorizes an open. -/
private def resolveSourceDocumentPath
    (root requested : System.FilePath) : IO (Except ResponseFailure System.FilePath) := do
  let path := if requested.isAbsolute then requested else root / requested
  let resolved : Except IO.Error System.FilePath ←
    try pure <| .ok <| ← Beam.resolveExistingPath path
    catch error => pure <| .error error
  let path ← match resolved with
    | .ok path => pure path
    | .error error =>
        if let .noFileOrDirectory .. := error then
          -- Preserve containment errors for missing external paths, without collapsing an absent
          -- intermediate directory into a successful source lookup (for example missing/../A.lean).
          let missingPath? ← try
              some <$> resolveDocumentPath root requested
            catch
            | .invalidArgument .. =>
                -- The creation helper has no leaf for a missing `..` component. This optional
                -- diagnostic refinement must not replace the original missing-source failure.
                pure none
            | failure => throw failure
          if let some missingPath := missingPath? then
            unless Beam.isCanonicalPathWithinRoot root missingPath do
              return .error <| documentBoundaryFailure root missingPath
        -- realPath can report missing input for cycles or inaccessible ancestors too. A stat
        -- after failed resolution preserves the typed cause; it never authorizes an open.
        let observed : Except IO.Error IO.FS.Metadata ← match error with
          | .noFileOrDirectory .. => path.metadata.toBaseIO
          | _ => pure (.error error)
        match observed with
        | .ok _ => return .error <| unresolvedSourceFailure root path
        | .error cause =>
            match sourceResolutionFailure? root path cause with
            | some failure => return .error failure
            | none => throw cause
  unless Beam.isCanonicalPathWithinRoot root path do
    return .error <| documentBoundaryFailure root path
  let metadata : Except ResponseFailure IO.FS.Metadata ←
    try pure <| .ok <| ← path.metadata
    catch error =>
      match sourceObservationFailure? root path error with
      | some failure => pure <| .error failure
      | none => throw error
  let metadata ← match metadata with
    | .ok metadata => pure metadata
    | .error failure => return .error failure
  unless metadata.type == .file do
    return .error <| responseFailureFor .invalidParams
      s!"document '{path}' is not a regular source file in workspace '{root}'"
  unless path.toString.endsWith ".lean" do
    return .error <| responseFailureFor .invalidParams
      s!"document '{path}' is not a .lean source file in workspace '{root}'"
  return .ok path

def sessionUri (path : System.FilePath) : String :=
  (System.Uri.pathToUri path : String)

private def BackendStderrCapture.snapshot (capture : BackendStderrCapture) : IO String := do
  Beam.StderrCapture.snapshot capture

private def backendFailureMessage
    (phase cause : String)
    (capture : BackendStderrCapture) : IO String := do
  let stderr := (← capture.snapshot).trimAscii.toString
  let stderr := if stderr.isEmpty then "<empty>" else stderr
  pure <| String.intercalate "\n" [
    s!"Lean backend failed {phase}: {cause}",
    s!"backend stderr tail (last {backendStderrTailLimit} bytes):",
    stderr
  ]

private def sessionShutdownReplyTimeoutMs : Nat :=
  1000

/-- Render process facts only at the session's diagnostic boundary. -/
private def backendTerminationMessage : BackendTermination → String
  | .exited code => s!"backend process exited with code {code}"
  | .unconfirmed waitError? signalError? =>
      String.intercalate "\n" <|
        ["backend process exit was not confirmed"] ++
        (waitError?.toList.map fun error => s!"backend process exit observation failed: {error}") ++
        (signalError?.toList.map fun error => s!"backend process termination signal failed: {error}")

/-- All teardown callers use the same success policy, independently of their original failure. -/
private def backendCleanupFailure?
    (termination : BackendTermination)
    (stderr? : Option Beam.StderrCaptureOutcome) : Option IO.Error :=
  let processFailures := match termination with
    | .exited _ => []
    | .unconfirmed .. => [backendTerminationMessage termination]
  let stderrFailures := match stderr? with
    | some (.sourceFailed error) => [s!"backend stderr source failed while draining: {error}"]
    | _ => []
  match processFailures ++ stderrFailures with
  | [] => none
  | failures => some <| IO.userError <| String.intercalate "\n" failures

private def startBackendStderrCaptureOrTerminate
    (proc : BackendProcess) (stderr : IO.FS.Handle) : IO BackendStderrCapture := do
  try
    startBackendStderrCapture stderr
  catch err =>
    let termination ← proc.terminate sessionShutdownReplyTimeoutMs
    let cleanupFailure? := backendCleanupFailure? termination none
    throw <| IO.userError <|
      s!"Lean backend failed during startup before stderr capture: {err}" ++
        (cleanupFailure?.map (fun error => s!"\n{error}")).getD ""

private def terminateBackendFailure
    (phase cause : String)
    (proc : BackendProcess)
    (capture : BackendStderrCapture) : IO (String × BackendTermination) := do
  let termination ← proc.terminate sessionShutdownReplyTimeoutMs
  let captureOutcome ← capture.awaitCompletion
  let message ← backendFailureMessage phase cause capture
  let message := message ++
    ((backendCleanupFailure? termination (some captureOutcome)).map (fun error => s!"\n{error}")).getD ""
  let message := match captureOutcome with
    | .drained | .sourceFailed _ => message
    | .pipeStillOpen =>
        message ++ "\nbackend stderr pipe remained open; its bounded capture remains active"
  pure (message, termination)

private def mkWorkspaceState
    (config : BrokerConfig)
    (generation : Nat) : WorkspaceState := { config, generation }

private def mkInitialState
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (startMonoNanos : Nat) : State := {
  bootstrapConfig := config
  startMonoNanos
  workspaces := Std.TreeMap.empty.insert workspaceId (mkWorkspaceState config 1)
}

private def validWorkspaceId (workspaceId : WorkspaceId) : Bool :=
  Beam.Workspace.validWorkspaceId workspaceId

private def getWorkspace? (state : State) (workspaceId : WorkspaceId) : Option WorkspaceState :=
  state.workspaces.get? workspaceId

private def setWorkspace
    (state : State)
    (workspaceId : WorkspaceId)
    (workspace : WorkspaceState) : State :=
  { state with workspaces := state.workspaces.insert workspaceId workspace }

private def setFreshWorkspace
    (state : State)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig) : State :=
  let generation := state.nextWorkspaceGeneration
  {
    state with
    nextWorkspaceGeneration := generation + 1
    workspaces := state.workspaces.insert workspaceId (mkWorkspaceState config generation)
  }

private def detachBackendSession
    (sessionState : SessionState) : SessionState × Option Session :=
  match sessionState.session? with
  | none => (sessionState, none)
  | some session =>
      ({ sessionState with session? := none, nextEpoch := sessionState.nextEpoch + 1 }, some session)

private def recordSessionSpawn (workspaceId : WorkspaceId) (restart : Bool) : M Unit := do
  modify fun state =>
    match getWorkspace? state workspaceId with
    | none => state
    | some workspace =>
        let metrics := workspace.metrics
        let metrics := {
          metrics with
          sessionStarts := metrics.sessionStarts + 1
          sessionRestarts := metrics.sessionRestarts + (if restart then 1 else 0)
        }
        setWorkspace state workspaceId { workspace with metrics }

private def recordRequestMetrics
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (op : String)
    (ok : Bool)
    (errorCode? : Option String)
    (latencyMs : Nat) : M Unit := do
  modify fun state =>
    match getWorkspace? state workspaceId with
    | none => state
    | some workspace =>
        if workspace.generation != workspaceGeneration then
          state
        else
          let metrics := workspace.metrics
          let opStats := (metrics.ops.get? op).getD {}
          let opStats := opStats.record ok errorCode? latencyMs
          let metrics := {
            metrics with
            requestCount := metrics.requestCount + 1
            successCount := metrics.successCount + (if ok then 1 else 0)
            errorCount := metrics.errorCount + (if ok then 0 else 1)
            cancelledCount := metrics.cancelledCount + (if isCancelledCode errorCode? then 1 else 0)
            workerExitedCount := metrics.workerExitedCount + (if isWorkerExitedCode errorCode? then 1 else 0)
            invalidParamsCount := metrics.invalidParamsCount + (if isInvalidParamsCode errorCode? then 1 else 0)
            ops := metrics.ops.insert op opStats
          }
          setWorkspace state workspaceId { workspace with metrics }

private def sessionSnapshotJson (session? : Option Session) : Json :=
  match session? with
  | none => Json.mkObj [("active", toJson false)]
  | some session =>
      Json.mkObj [
        ("active", toJson true),
        ("epoch", toJson session.epoch),
        ("openDocCount", toJson session.docs.toList.length)
      ]

private def workspaceStatsJson (workspaceId : WorkspaceId) (workspace : WorkspaceState) : Json :=
  Json.mkObj [
    ("id", toJson workspaceId),
    ("root", toJson workspace.config.root.toString),
    ("session", sessionSnapshotJson workspace.lean.session?),
    ("metrics", workspaceMetricsJson workspace.metrics)
  ]

private def statsPayload (workspaceId? : Option WorkspaceId := none) : M Json := do
  let state ← get
  let now ← IO.monoNanosNow
  let uptimeMs := (now - state.startMonoNanos) / 1000000
  match workspaceId? with
  | some workspaceId =>
      match getWorkspace? state workspaceId with
      | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
      | some workspace =>
          pure <| (workspaceStatsJson workspaceId workspace).setObjVal! "uptimeMs" (toJson uptimeMs)
  | none =>
      let workspaceFields := state.workspaces.toList.map fun (workspaceId, workspace) =>
        (workspaceId, workspaceStatsJson workspaceId workspace)
      pure <| Json.mkObj [
        ("uptimeMs", toJson uptimeMs),
        ("workspaces", Json.mkObj workspaceFields)
      ]

private def traceEnabled (envName : String) : IO Bool := do
  match ← IO.getEnv envName with
  | some value => pure (!value.isEmpty && value != "0")
  | none => pure false

private def emitBrokerTrace (message : String) : IO Unit := do
  let now ← IO.monoNanosNow
  IO.eprintln s!"beam-broker trace {now}: {message}"

private def traceBroker (message : String) : IO Unit := do
  if ← traceEnabled "LEAN_BEAM_BROKER_TRACE" then
    emitBrokerTrace message

private def optionLabel (value? : Option String) : String :=
  value?.getD "<none>"

private def waitDiagnosticsWatchdogMs? : IO (Option Nat) := do
  match ← IO.getEnv "LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS" with
  | none => pure none
  | some value =>
      if value.isEmpty || value == "0" then
        pure none
      else
        match value.toNat? with
        | some ms => pure (some ms)
        | none =>
            emitBrokerTrace
              s!"invalid LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS={value}; watchdog disabled"
            pure none

private def startWaitDiagnosticsWatchdog
    (label : String)
    (doneRef : IO.Ref Bool) : IO Unit := do
  match ← waitDiagnosticsWatchdogMs? with
  | none => pure ()
  | some timeoutMs =>
      let _ ← IO.asTask (prio := Task.Priority.dedicated) do
        IO.sleep timeoutMs.toUInt32
        unless (← doneRef.get) do
          emitBrokerTrace
            s!"waitForDiagnostics watchdog after {timeoutMs}ms: {label}"
      pure ()

private def awaitPending (pending : PendingRequest) : HandlerM PendingResult := do
  requestArg (← liftHandlerIO pending.awaitOutcome)

private def awaitWaitForDiagnosticsBarrier
    (label : String)
    (await : IO (Except ResponseFailure PendingResult)) : HandlerM PendingResult := do
  let doneRef ← liftHandlerIO <| IO.mkRef false
  liftHandlerIO <| startWaitDiagnosticsWatchdog label doneRef
  let outcome ← liftHandlerIO <| do
    try
      let outcome ← await
      doneRef.set true
      pure outcome
    catch e =>
      doneRef.set true
      throw e
  requestArg outcome

private def nextRequestId (session : Session) : Session × RequestID :=
  let id : RequestID := session.nextId
  ({ session with nextId := session.nextId + 1 }, id)

partial def sessionReaderLoop (session : Session) : IO Unit := do
  try
    let msg ← session.stdout.readLspMessage
    match msg with
    | .response id result =>
        let pending? ← PendingRequestStore.remove session.pending id
        traceBroker s!"lsp response id={id} matched={pending?.isSome}"
        if let some pending := pending? then
          PendingRequest.resolveResponse pending result
    | .responseError id code message data? =>
        let pending? ← PendingRequestStore.remove session.pending id
        traceBroker s!"lsp responseError id={id} matched={pending?.isSome} code={(toJson code).compress} message={message}"
        if let some pending := pending? then
          PendingRequest.resolveError pending code message data?
    | .notification "$/lean/fileProgress" (some param) =>
        let pending ← PendingRequestStore.snapshot session.pending
        traceBroker s!"lsp fileProgress pending={pending.size} params={(toJson param).compress}"
        for req in pending do
          PendingRequest.observeProgress req param
    | .notification "textDocument/publishDiagnostics" (some param) =>
        match (fromJson? (toJson param) : Except String PublishDiagnosticsParams) with
        | .ok diagnosticParam =>
            let pending ← PendingRequestStore.snapshot session.pending
            traceBroker s!"lsp publishDiagnostics pending={pending.size} params={(toJson param).compress}"
            for req in pending do
              PendingRequest.observePublishDiagnostics session.root req diagnosticParam
        | .error _ =>
            pure ()
    | _ =>
        pure ()
    sessionReaderLoop session
  catch e =>
    let (message, termination) ←
      terminateBackendFailure "after startup" e.toString
        session.proc session.stderrCapture
    let exitConfirmed := match termination with
      | .exited _ => true
      | .unconfirmed .. => false
    let message :=
      if !exitConfirmed then
        message ++ "\nRecovery: drop this workspace or restart the owning session. " ++
          "For wrapper sessions, run `lean-beam --root <workspace-root> stop`, then start a new " ++
          "`lean-beam --root <workspace-root> serve` owner before retrying."
      else message
    PendingRequestStore.close session.pending <| BrokerFailure.toResponseFailure {
      code := .workerExited
      message
      data? := some <| workerRecoveryData (if exitConfirmed then .newBackend else .restartWorkspace)
    }

private def startRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    IO (Session × PendingRequest) := do
  let (session, id) := nextRequestId session
  let progressRef ← IO.mkRef (initialProgress? <|> tracked.map (fun _ => {}))
  let diagnosticsRef ← IO.mkRef #[]
  let diagnosticsSeenRef ← IO.mkRef false
  let seenDiagnosticKeysRef ← IO.mkRef ({} : Std.TreeSet String compare)
  let promise ← IO.Promise.new
  let pending : PendingRequest := {
      cancelRef? := cancelRef?
      promise := promise
      tracked? := tracked
      progressRef := progressRef
      diagnosticsRef := diagnosticsRef
      diagnosticsSeenRef := diagnosticsSeenRef
      emitProgress? := emitProgress?
      diagnosticScope := diagnosticScope
      seenDiagnosticKeysRef := seenDiagnosticKeysRef
      emitDiagnostic? := emitDiagnostic?
      : PendingRequest
    }
  unless ← PendingRequestStore.register session.pending id pending do
    return (session, pending)
  traceBroker
    s!"lsp request inserted id={id} method={method} clientRequestId={optionLabel clientRequestId?} tracked={tracked.isSome}"
  try
    writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
    traceBroker s!"lsp request sent id={id} method={method}"
    pure (session, pending)
  catch e =>
    discard <| PendingRequestStore.remove session.pending id
    traceBroker s!"lsp request send failed id={id} method={method} error={e.toString}"
    if let some failure ← PendingRequestStore.failure? session.pending then
      -- Removal can precede closure's drain; settle explicitly with its retained typed cause.
      pending.resolveFailure failure
      return (session, pending)
    try
      promise.resolve (.error (responseFailureFor .internalError e.toString))
    catch _ =>
      pure ()
    throw e

/-- Send `exit` only after a successful shutdown reply; failure ends the graceful attempt. -/
private def requestSessionShutdown (session : Session) : IO Bool := do
  try
    let (_, pending) ←
      startRequestJsonTrackedDetailed session "shutdown" Json.null
    match ← Beam.waitTaskWithTimeout pending.promise.result? sessionShutdownReplyTimeoutMs with
    | some (some (.ok _)) =>
        writeLspNotification session.stdin
          ({ method := "exit", param := Json.null : Lean.JsonRpc.Notification Json })
        pure true
    | _ => pure false
  catch _ =>
    pure false

private def settleSessionTermination (session : Session) (termination : BackendTermination) : IO Unit := do
  -- A reader can remain blocked on an inherited stdout pipe after the leader exits. Settle any
  -- remaining requests here instead of depending on reader EOF or the graceful-handshake timeout.
  PendingRequestStore.close session.pending <| BrokerFailure.toResponseFailure {
    code := .workerExited
    message := backendTerminationMessage termination
  }
  let captureOutcome ← session.stderrCapture.awaitCompletion
  if let .pipeStillOpen := captureOutcome then
    -- A descendant can retain the pipe after the backend leader is reaped. This is an explicit
    -- bounded resource outcome, not a reason to make an otherwise completed shutdown fail.
    traceBroker "backend stderr drain did not finish within its shutdown bound"
  if let some error := backendCleanupFailure? termination (some captureOutcome) then
    throw error

private def shutdownSession (session : Session) : IO Unit := do
  let termination ← match ← session.proc.observe with
    | some exit => pure exit.toTermination
    | none => do
        let exit? ←
          if ← requestSessionShutdown session then
            session.proc.waitForExit sessionShutdownReplyTimeoutMs
          else pure none
        match exit? with
        | some exit => pure exit.toTermination
        | none => session.proc.terminate sessionShutdownReplyTimeoutMs
  settleSessionTermination session termination

/-- Uncertain writes cannot be followed by a graceful protocol exchange on the same pipe. -/
private def terminateSession (session : Session) : IO Unit := do
  settleSessionTermination session (← session.proc.terminate sessionShutdownReplyTimeoutMs)

def sendRequestJsonTrackedDetailed
    (session : Session)
    (method : String)
    (param : Json)
    (clientRequestId? : Option String := none)
    (tracked : Option (DocumentUri × Nat) := none)
    (initialProgress? : Option SyncFileProgress := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    IO (Except ResponseFailure (Session × Json × Option SyncFileProgress × Array Diagnostic)) := do
  let (session, pending) ←
    startRequestJsonTrackedDetailed session method param clientRequestId? tracked initialProgress?
      emitProgress? diagnosticScope emitDiagnostic?
  match ← pending.awaitOutcome with
  | .ok pending => pure <| .ok (session, pending.result, pending.progress?, pending.diagnostics)
  | .error failure => pure <| .error failure

private partial def awaitInitializeResponse (stdout : IO.FS.Stream) : IO Unit := do
  let msg ← stdout.readLspMessage
  match msg with
  | .response id _ =>
      if id == 0 then
        pure ()
      else
        throw <| IO.userError s!"unexpected response id {id} before initialize completed"
  | .responseError id _code message _ =>
      if id == 0 then
        throw <| IO.userError s!"initialize failed: {message}"
      else
        throw <| IO.userError
          s!"unexpected response error id {id} before initialize completed: {message}"
  | .notification .. =>
      awaitInitializeResponse stdout
  | .request .. =>
      throw <| IO.userError "unexpected server request before initialize completed"

private def requestHelperControl
    (cancelRef? : Option (IO.Ref Bool))
    (output? : Option Beam.WorkspaceOutput.Buffer) : IO LakeHelperControl := do
  let publisher? ← match output? with
    | some output => output.borrow
    | none => pure none
  return { cancelRef?, output? := publisher? }

private def backendInitializeTimeoutMs : Nat :=
  30000

/--
Acquire a fully initialized backend session or attempt termination before failing, reporting any
unconfirmed exit alongside the original startup failure.

The caller adopts the returned session into broker state. No child ownership escapes this function
until the initialization response and `initialized` notification have both completed.
-/
private def acquireBackendSession
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (config : BrokerConfig)
    (epoch : Nat)
    (cancelRef? : Option (IO.Ref Bool))
    (output? : Option Beam.WorkspaceOutput.Buffer) : IO (Except BrokerFailure Session) := do
  let root := config.root
  let (cmd, args, env) ← match ← leanCommand config (← requestHelperControl cancelRef? output?) with
    | .error failure => return .error failure
    | .ok command => pure command
  let child ← IO.Process.spawn {
    toStdioConfig := brokerStdio
    cmd := cmd
    args := args
    env := env
    cwd := root.toString
  }
  let proc ← BackendProcess.create (Beam.processChildPid child) child.tryWait child.kill
  let stderrCapture ← startBackendStderrCaptureOrTerminate proc child.stderr
  let (session, initializeTask) ←
    try
      let stdin := IO.FS.Stream.ofHandle child.stdin
      let stdout := IO.FS.Stream.ofHandle child.stdout
      let pending ← PendingRequestStore.create
      let sessionToken ← mkSessionToken
      let session : Session := {
        workspaceId
        workspaceGeneration
        root
        epoch
        sessionToken
        proc
        stdin
        stdout
        stderrCapture
        pending
      }
      writeLspRequest stdin
        ({ id := 0, method := "initialize", param := initializeParams root
          : Lean.JsonRpc.Request Json })
      let initializeTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        awaitInitializeResponse stdout
      pure (session, initializeTask)
    catch err =>
      let (message, _) ← terminateBackendFailure "during startup" err.toString proc stderrCapture
      throw <| IO.userError message
  try
    match ← Beam.waitTaskWithTimeout initializeTask backendInitializeTimeoutMs with
    | some (.ok ()) => pure ()
    | some (.error err) => throw err
    | none =>
        throw <| IO.userError <|
          s!"backend initialize timed out after {backendInitializeTimeoutMs} ms"
    writeLspNotification session.stdin
      ({ method := "initialized", param := Json.mkObj [] : Lean.JsonRpc.Notification Json })
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      try
        sessionReaderLoop session
      catch e =>
        IO.eprintln s!"broker session reader task failed: {e.toString}"
    pure <| .ok session
  catch err =>
    IO.cancel initializeTask
    let (message, _) ←
      terminateBackendFailure "during startup" err.toString proc stderrCapture
    discard <| Beam.waitTaskWithTimeout initializeTask sessionShutdownReplyTimeoutMs
    throw <| IO.userError message

private def ensureSession (workspaceId : WorkspaceId)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (output? : Option Beam.WorkspaceOutput.Buffer := none) : M (Except ResponseFailure Session) := do
  let state ← get
  let workspace ←
    match getWorkspace? state workspaceId with
    | some workspace => pure workspace
    | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
  let config := workspace.config
  let sessionState := workspace.lean
  match sessionState.session? with
  | some session => pure (.ok session)
  | none =>
      let acquired ← try
        acquireBackendSession workspaceId workspace.generation config sessionState.nextEpoch cancelRef? output?
      catch error => pure <| .error { code := .internalError, message := error.toString }
      let session ← match acquired with
        | .error failure => return .error failure.toResponseFailure
        | .ok session => pure session
      recordSessionSpawn workspaceId (sessionState.nextEpoch > 1)
      let sessionState := { sessionState with session? := some session }
      modify fun st =>
        match getWorkspace? st workspaceId with
        | some workspace => setWorkspace st workspaceId { workspace with lean := sessionState }
        | none => st
      pure (.ok session)

private def sendNotificationJson (session : Session) (method : String) (param : Json) : IO Session := do
  writeLspNotification session.stdin ({ method, param : Lean.JsonRpc.Notification Json })
  pure session

/-- Send a request whose reply the broker never reads. It registers no pending entry, so the
reader discards the reply like any unmatched response. -/
private def sendUntrackedRequestJson (session : Session) (method : String) (param : Json) :
    IO Session := do
  let (session, id) := nextRequestId session
  writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
  pure session

private def sendTextDocumentDidSave (session : Session) (uri : DocumentUri) : IO Session := do
  sendNotificationJson session "textDocument/didSave" (toJson ({
    textDocument := ({ uri := uri : TextDocumentIdentifier })
    text? := none
    : DidSaveTextDocumentParams
  }))

/--
An immutable view of a source file used to synchronize the LSP session.

The file contents and metadata are computed before the broker state mutex is
held. This keeps potentially slow filesystem work out of the critical section.
The workspace generation is captured before that read and checked before the
snapshot is applied, so a concurrent workspace reset cannot retarget it.
For request handlers that can race with each other, `readSeq` is reserved while
holding the mutex and is later used by `DocumentState.syncFileDecision` to
ignore stale snapshots that completed after a newer read was already applied.
-/
private structure FileSyncSnapshot where
  workspaceGeneration : Nat
  path : System.FilePath
  uri : DocumentUri
  text : String
  file : DocumentState.FileSnapshot

private structure SyncedFileSnapshot where
  session : Session
  uri : DocumentUri
  version : Nat
  changed : Bool

private def readFileSyncSnapshot
    (root path : System.FilePath)
    (workspaceGeneration : Nat)
    (readSeq : Nat)
    (readSource : System.FilePath → IO ByteArray) : IO (Except ResponseFailure FileSyncSnapshot) := do
  let contents : Except ResponseFailure (ByteArray × Lake.MTime) ← try
      pure <| .ok (← readSource path, ← Lake.getFileMTime path)
    catch error =>
      match sourceObservationFailure? root path error with
      | some failure => pure <| .error failure
      | none => throw error
  let (bytes, textMTime) ← match contents with
    | .ok contents => pure contents
    | .error failure => return .error failure
  let some text := String.fromUTF8? bytes
    | return .error <| responseFailureFor .invalidParams
        s!"document '{path}' is not valid UTF-8 source in workspace '{root}'"
  let uri := sessionUri path
  let moduleName? := DocumentState.trackedModuleName? root path
  pure <| .ok {
    workspaceGeneration
    path
    uri
    text
    file := DocumentState.FileSnapshot.ofText text textMTime readSeq moduleName?
  }

private def workspaceForSnapshot
    (workspaceId : WorkspaceId)
    (snapshot : FileSyncSnapshot) : M (Except ResponseFailure WorkspaceState) := do
  let state ← get
  match getWorkspace? state workspaceId with
  | some workspace =>
      if workspace.generation == snapshot.workspaceGeneration then
        pure (.ok workspace)
      else
        pure <| .error <| responseFailureFor .contentModified <|
          s!"workspace '{workspaceId}' changed while the request source file was being read; retry the request"
  | none =>
      pure <| .error <| responseFailureFor .contentModified <|
        s!"workspace '{workspaceId}' was removed while the request source file was being read; retry after initializing it"

private def withWorkspaceForSnapshot
    (workspaceId : WorkspaceId)
    (snapshot : FileSyncSnapshot)
    (act : WorkspaceState → M (Except ResponseFailure α)) :
    M (Except ResponseFailure α) := do
  match ← workspaceForSnapshot workspaceId snapshot with
  | .ok workspace => act workspace
  | .error failure => pure (.error failure)

private def withSessionForSnapshot
    (workspaceId : WorkspaceId)
    (snapshot : FileSyncSnapshot)
    (act : Session → M (Except ResponseFailure α))
    (cancelRef? : Option (IO.Ref Bool) := none)
    (output? : Option Beam.WorkspaceOutput.Buffer := none) :
    M (Except ResponseFailure α) :=
  withWorkspaceForSnapshot workspaceId snapshot fun _ => do
    match ← ensureSession workspaceId cancelRef? output? with
    | .error failure => pure (.error failure)
    | .ok session => act session

private def closeFile (session : Session) (uri : DocumentUri) : IO Session := do
  if session.docs.get? uri |>.isNone then
    pure session
  else
    let param := toJson ({ textDocument := { uri := uri } : DidCloseTextDocumentParams })
    let session ← sendNotificationJson session "textDocument/didClose" param
    pure { session with docs := session.docs.erase uri }

private def syncFileSnapshotDetailed
    (session : Session)
    (snapshot : FileSyncSnapshot) : IO SyncedFileSnapshot := do
  unless snapshot.file.readSeq > 0 do
    throw <| IO.userError "broker source snapshot has no reserved read sequence"
  let decision := DocumentState.syncFileDecision session.docs snapshot.uri snapshot.file
  let session ←
    match decision.action with
    | .open | .reopen =>
      let changedSource := decision.action == .reopen &&
        (session.docs.get? snapshot.uri).any (·.rawSourceHash != snapshot.file.rawSourceHash)
      let session ← if decision.action == .reopen then closeFile session snapshot.uri else pure session
      let param := toJson ({
        textDocument := {
          uri := snapshot.uri
          languageId := "lean"
          version := decision.version
          text := snapshot.text
        } : DidOpenTextDocumentParams
      })
      let session ← sendNotificationJson session "textDocument/didOpen" param
      -- An edited recovery invalidates importers just like an ordinary change. Reopening
      -- unchanged source must not make unrelated workers stale.
      if changedSource then sendTextDocumentDidSave session snapshot.uri else pure session
    | .change =>
        let param := toJson ({
          textDocument := { uri := snapshot.uri, version? := some decision.version }
          contentChanges := #[TextDocumentContentChangeEvent.fullChange snapshot.text]
          : DidChangeTextDocumentParams
        })
        let session ← sendNotificationJson session "textDocument/didChange" param
        sendTextDocumentDidSave session snapshot.uri
    | .unchanged =>
        pure session
  -- Fingerprint the imports as soon as the worker loads them; save later checks the checkpoint
  -- basis against this record. Nobody awaits the reply: a missing record makes save refuse.
  -- Temporary until the worker retains its loaded import artifacts (issue #370).
  let session ←
    if decision.action == .unchanged then
      pure session
    else
      sendUntrackedRequestJson session importBasisMethod <| toJson ({
        textDocument := { uri := snapshot.uri, version? := some decision.version }
        capture := true
        eventSeq := session.nextEventSeq
        : Beam.LSP.ImportBasis.Params
      })
  pure {
    session := { session with docs := decision.docs }
    uri := snapshot.uri
    version := decision.version
    changed := decision.action != .unchanged
  }

private def syncFileSnapshot (session : Session) (snapshot : FileSyncSnapshot) : IO Session := do
  let synced ← syncFileSnapshotDetailed session snapshot
  pure synced.session

private def requireDocState (session : Session) (uri : String) : IO DocState := do
  DocumentState.requireDocState session.docs uri

private def decodeResponseAs [FromJson α] (json : Json) : IO α := do
  match fromJson? json with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"invalid backend response payload: {err}\n{json.compress}"

private def trackedPathLabel (root : System.FilePath) (uri : DocumentUri) : String :=
  Beam.pathRelativeToRootOrUri root uri

private def applyVersionMarkResult
    (session : Session)
    (result : DocumentState.VersionMarkResult) : Session :=
  if result.applied then
    { session with
      nextEventSeq := session.nextEventSeq + 1
      docs := result.docs
      moduleHistory := result.moduleHistory
    }
  else
    session

private def markDocSyncedBasis (session : Session) (uri : DocumentUri) (basis : DocumentBasis) : Session :=
  let result := DocumentState.markSyncedBasis
    session.docs session.moduleHistory uri basis
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def markDocSavedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSavedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def openDocsSessionView (session : Session) : OpenDocs.SessionView := {
  root := session.root
  docs := session.docs
}

private def openDocsWorkspacePayload (workspace : WorkspaceState) : IO Json :=
  OpenDocs.payload workspace.config.root
    (workspace.lean.session?.map openDocsSessionView)

private def openDocsPayload (workspaceId? : Option WorkspaceId := none) : M Json := do
  let state ← get
  match workspaceId? with
  | some workspaceId =>
      match getWorkspace? state workspaceId with
      | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
      | some workspace =>
          pure <| (← openDocsWorkspacePayload workspace).setObjVal!
            "workspace_id" (toJson workspaceId)
  | none =>
      let workspaceFields ← state.workspaces.toList.mapM fun (workspaceId, workspace) => do
        pure (workspaceId, ← openDocsWorkspacePayload workspace)
      pure <| Json.mkObj [("workspaces", Json.mkObj workspaceFields)]

private def wrapHandle (session : Session) (raw : Json) : Json :=
  toJson ({
    workspaceId := session.workspaceId
    epoch := session.epoch
    session := session.sessionToken
    raw
    : Handle
  })

private def unwrapHandle (session : Session) (handle : Handle) : Except BrokerFailure Json := do
  if handle.workspaceId != session.workspaceId then
    throw { code := .invalidParams, message := "handle belongs to a different workspace" }
  if handle.epoch != session.epoch || handle.session != session.sessionToken then
    throw { code := .contentModified, message := "handle belongs to a stale backend session" }
  pure handle.raw

private def wrapResultHandle (session : Session) (result : Json) : Json :=
  match result.getObjVal? "handle" with
  | .ok raw =>
      result.setObjVal! "handle" (wrapHandle session raw)
  | .error _ =>
      result

private def updateSession (session : Session) : M Unit := do
  modify fun state =>
    match getWorkspace? state session.workspaceId with
    | none => state
    | some workspace =>
        if workspace.generation != session.workspaceGeneration then
          state
        else
          let sessionState := workspace.lean
          setWorkspace state session.workspaceId
            { workspace with lean := { sessionState with session? := some session } }

private def storedSession? (workspaceId : WorkspaceId) : M (Option Session) := do
  let state ← get
  let some workspace := getWorkspace? state workspaceId
    | pure none
  pure (workspace.lean).session?

private def resolveCurrentHandle
    (workspaceId : WorkspaceId)
    (handle : Handle) : M (Except ResponseFailure (Session × Json)) := do
  match ← storedSession? workspaceId with
  | none =>
      pure <| .error <| BrokerFailure.toResponseFailure {
        code := .contentModified
        message := "handle belongs to a stale backend session"
      }
  | some session =>
      match unwrapHandle session handle with
      | .ok raw => pure (.ok (session, raw))
      | .error failure => pure (.error failure.toResponseFailure)

private def sameSessionIdentity (left right : Session) : Bool :=
  left.workspaceId == right.workspaceId &&
    left.workspaceGeneration == right.workspaceGeneration &&
    left.root == right.root &&
    left.epoch == right.epoch &&
    left.sessionToken == right.sessionToken

private def modifyCurrentSessionIfMatching
    (session : Session)
    (f : Session → Session) : M Unit := do
  match ← storedSession? session.workspaceId with
  | some current =>
      if sameSessionIdentity current session then
        updateSession (f current)
      else
        pure ()
  | none =>
      pure ()

inductive ServerMode where
  /-- A separately managed broker, optionally carrying a public generation identity. -/
  | standalone (identity? : Option DaemonIdentity)
  /-- A wrapper-owned broker whose identity and request capability are inseparable. -/
  | wrapper (identity : DaemonIdentity) (capability : String)

def ServerMode.identity? : ServerMode → Option DaemonIdentity
  | .standalone identity? => identity?
  | .wrapper identity _ => some identity

private def ServerMode.wrapperIdentity? : ServerMode → Option DaemonIdentity
  | .standalone _ => none
  | .wrapper identity _ => some identity

private def ServerMode.validate : ServerMode → Except String Unit
  | .standalone none => pure ()
  | .standalone (some identity) => do
      unless !identity.daemonId.isEmpty && !identity.configHash.isEmpty do
        throw "daemon identity values must be non-empty"
  | .wrapper identity capability => do
      unless !identity.daemonId.isEmpty && !identity.configHash.isEmpty do
        throw "wrapper-owned daemon identity values must be non-empty"
      unless !capability.isEmpty do
        throw "wrapper-owned daemon capability must be non-empty"

/-- Application-owned local workspace admission; execution code does not interpret installations. -/
abbrev WorkspaceAdmission := System.FilePath → IO (Except ResponseFailure BrokerConfig)

structure ServerRuntime where
  state : Std.Mutex State
  private mode : ServerMode
  private admission? : Option WorkspaceAdmission
  /-- Source-byte observation, after admission and ordering; never called under the state mutex. -/
  private readSource : System.FilePath → IO ByteArray
  activeRequests : ActiveRequestRegistry
  private closeMutex : Std.Mutex Bool
  private closeDone : IO.Promise (Except IO.Error Unit)

/-- An accepted document bound to the runtime that owns its conditional transitions. -/
private structure DocumentRef where
  runtime : ServerRuntime
  session : Session
  uri : DocumentUri
  basis : DocumentBasis
  cancelRef? : Option (IO.Ref Bool)

private def DocumentRef.version (document : DocumentRef) : Nat :=
  document.basis.version

/-- Called inside synchronization's state transition, using its accepted session. -/
private def DocumentRef.capture
    (runtime : ServerRuntime) (session : Session) (uri : DocumentUri)
    (cancelRef? : Option (IO.Ref Bool)) : IO DocumentRef := do
  let doc ← requireDocState session uri
  pure { runtime, session, uri, basis := DocumentState.basis doc, cancelRef? }

/--
A cancellation capability bound to one active broker request admission.

The handle does not expose dispatch. It becomes inert after its broker-owned
dispatch scope exits, even if a later request reuses the same client request ID.
-/
structure RequestHandle where
  private runtime : ServerRuntime
  private active? : Option ActiveRequest

def ServerRuntime.withState (server : ServerRuntime) (act : M α) : IO α := do
  server.state.atomically do
    let state ← get
    let (a, state) ← act.run state
    set state
    pure a

private inductive PublicationAvailability (α : Type) where
  | done (value : α)
  | wait (completion : IO.Promise Unit)

/-- Wait outside the state mutex, then retry the original transition against current ownership.
`none` selects all workspaces for runtime teardown. Read-only state access does not use this gate. -/
private partial def ServerRuntime.withPublicationAvailable
    (server : ServerRuntime) (workspaceId? : Option WorkspaceId) (act : M α) : IO α := do
  let result : PublicationAvailability α ← server.withState do
    if let some claim := (← get).publication? then
      if workspaceId?.all (· == claim.workspaceId) then
        return .wait claim.done
    .done <$> act
  match result with
  | .done value => pure value
  | .wait completion =>
    let some () ← IO.wait completion.result?
      | throw <| IO.userError "publication completion promise dropped"
    server.withPublicationAvailable workspaceId? act

private inductive LiveSessionStateResult (α : Type) where
  | done (result : Except ResponseFailure α)
  | detached (session : Session)

private def detachExitedSession?
    (workspaceId : WorkspaceId) : M (Option Session) := do
  let state ← get
  let some workspace := getWorkspace? state workspaceId
    | pure none
  let sessionState := workspace.lean
  let some session := sessionState.session?
    | pure none
  let some _ ← session.proc.observe
    | return none
  let (sessionState, detached?) := detachBackendSession sessionState
  set <| setWorkspace state workspaceId {
    workspace with lean := sessionState, documents := workspace.documents.retire }
  pure detached?

/--
Run a session state action only while the caller's workspace generation remains current. Any
already-exited session is atomically detached and cleaned up outside the global broker state mutex
before retrying against that same generation. A failed reader whose process exit is unconfirmed
rejects reuse with its retained channel failure.
-/
private partial def ServerRuntime.withLiveSessionState
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (workspaceChangedFailure : ResponseFailure)
    (cancelRef? : Option (IO.Ref Bool))
    (act : M (Except ResponseFailure α)) : IO (Except ResponseFailure α) := do
  let result : LiveSessionStateResult α ← server.withPublicationAvailable (some workspaceId) do
    let state ← get
    match getWorkspace? state workspaceId with
    | none => pure <| .done (.error workspaceChangedFailure)
    | some workspace =>
        if workspace.generation != workspaceGeneration then
          pure <| .done (.error workspaceChangedFailure)
        else
          match ← detachExitedSession? workspaceId with
          | some session => pure <| .detached session
          | none =>
              if let some session := workspace.lean.session? then
                if let some failure ← PendingRequestStore.failure? session.pending then
                  return .done (.error (← RequestCancellation.backendFailure cancelRef? failure))
              .done <$> act
  match result with
  | .done result => pure result
  | .detached session =>
      shutdownSession session
      server.withLiveSessionState workspaceId workspaceGeneration workspaceChangedFailure cancelRef? act

/-- Return the canonical root currently owned by `workspaceId`, if that workspace exists. -/
def ServerRuntime.workspaceRoot?
    (server : ServerRuntime)
    (workspaceId : WorkspaceId) : IO (Option System.FilePath) := do
  server.withState do
    pure <| (getWorkspace? (← get) workspaceId).map (·.config.root)

private def ServerRuntime.statsResponse
    (server : ServerRuntime)
    (workspaceId? : Option WorkspaceId := none) : IO Response := do
  let payload ← server.withState <| statsPayload workspaceId?
  let payload :=
    match server.mode.identity? with
    | some identity => payload.setObjVal! "daemonIdentity" (toJson identity)
    | none => payload
  pure <| Response.success payload

def ServerRuntime.create
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (mode : ServerMode := .standalone none)
    (admission? : Option WorkspaceAdmission := none)
    (readSource : System.FilePath → IO ByteArray := IO.FS.readBinFile) : IO ServerRuntime := do
  unless validWorkspaceId workspaceId do
    throw <| IO.userError "workspace id must be non-empty"
  match mode.validate with
  | .ok () => pure ()
  | .error err => throw <| IO.userError err
  let startMonoNanos ← IO.monoNanosNow
  let state := mkInitialState config workspaceId startMonoNanos
  pure {
    state := ← Std.Mutex.new state
    mode
    admission?
    readSource
    activeRequests := ← ActiveRequestRegistry.create
    closeMutex := ← Std.Mutex.new false
    closeDone := ← IO.Promise.new
  }

private def detachRuntimeSessions (server : ServerRuntime) : IO (List Session) := do
  server.withPublicationAvailable none do
    let state ← get
    let (state, sessions) := state.workspaces.toList.foldl (init := (state, [])) fun
        (state, sessions) (workspaceId, workspace) =>
      let (lean, session?) := detachBackendSession workspace.lean
      let sessions := if let some session := session? then session :: sessions else sessions
      (setWorkspace state workspaceId { workspace with lean }, sessions)
    set state
    pure sessions.reverse

private def recordFirstCleanupError
    (firstError? : Option IO.Error)
    (phase : IO Unit) : IO (Option IO.Error) := do
  try
    phase
    pure firstError?
  catch err =>
    pure (firstError? <|> some err)

private def shutdownSessionsBestEffort :
    List Session → Option IO.Error → IO Unit
  | [], none => pure ()
  | [], some err => throw err
  | session :: sessions, firstError? => do
      let firstError? ← recordFirstCleanupError firstError? <| shutdownSession session
      shutdownSessionsBestEffort sessions firstError?

private def shutdownRuntimeSessions (server : ServerRuntime) : IO Unit := do
  shutdownSessionsBestEffort (← detachRuntimeSessions server) none

private def awaitRuntimeClose
    (promise : IO.Promise (Except IO.Error Unit)) : IO Unit := do
  let some outcome ← IO.wait promise.result?
    | throw <| IO.userError "broker runtime close promise dropped"
  match outcome with
  | .ok () => pure ()
  | .error err => throw err

private def ServerRuntime.closeStarted (server : ServerRuntime) : IO Bool :=
  server.closeMutex.atomically get

/--
Close broker admission, cancel admitted requests, shut down every backend session, and wait for
all admitted dispatch scopes to unregister. Concurrent and repeated callers wait for the same
close result.
-/
def ServerRuntime.close (server : ServerRuntime) : IO Unit := do
  let leadsClose ← server.closeMutex.atomically do
    if ← get then
      pure false
    else
      set true
      pure true
  if leadsClose then
    -- Retain the first failure but run every teardown phase. In particular, a failed first session
    -- sweep must not skip admission drain or the final sweep for sessions created during closure.
    let firstError? ← recordFirstCleanupError none <|
      ActiveRequestRegistry.closeAdmission server.activeRequests
    let firstError? ← recordFirstCleanupError firstError? <| shutdownRuntimeSessions server
    let firstError? ← recordFirstCleanupError firstError? <|
      ActiveRequestRegistry.awaitDrained server.activeRequests
    let firstError? ← recordFirstCleanupError firstError? <| shutdownRuntimeSessions server
    let outcome :=
      match firstError? with
      | none => .ok ()
      | some err => .error err
    server.closeDone.resolve outcome
    match outcome with
    | .ok () => pure ()
    | .error err => throw err
  else
    awaitRuntimeClose server.closeDone

private def workspaceInitResult
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (mode : Beam.Workspace.InitMode)
    (runtimeReused : Bool)
    (invalidatedHandles : Bool)
    (previousRoot? : Option System.FilePath := none) : Beam.Workspace.InitResult := {
  workspaceId
  root
  mode
  runtimeReused
  invalidatedHandles
  previousRoot?
}

private def duplicateRootWorkspace?
    (state : State)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig) : Option WorkspaceId :=
  state.workspaces.toList.findSome? fun (otherId, otherWorkspace) =>
    if otherId != workspaceId && otherWorkspace.config.root == config.root then
      some otherId
    else
      none

private structure WorkspaceTransition (α : Type) where
  state : State
  result : Except ResponseFailure α
  detachedSession? : Option Session := none

private def initWorkspaceTransition
    (state : State)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig)
    (mode? : Option Beam.Workspace.InitMode) : WorkspaceTransition Beam.Workspace.InitResult :=
  if !validWorkspaceId workspaceId then
    { state, result := .error <| responseFailureFor .invalidParams
        "workspace id must be non-empty" }
  else
    let mode := mode?.getD .set
    match getWorkspace? state workspaceId with
    | some current =>
        if mode == .reset then
          if let some otherId := duplicateRootWorkspace? state workspaceId config then
            { state, result := .error <| responseFailureFor .invalidParams <|
                s!"workspace root {config.root} is already owned by workspace '{otherId}'" }
          else
            {
              state := setFreshWorkspace state workspaceId config
              result := .ok <|
                workspaceInitResult workspaceId config.root mode false true
                  (some current.config.root)
              detachedSession? := current.lean.session?
            }
        else if current.config == config then
          { state, result := .ok <|
              workspaceInitResult workspaceId current.config.root mode true false }
        else
          { state, result := .error <| responseFailureFor .invalidParams <|
              s!"workspace '{workspaceId}' is already initialized for {current.config.root}; " ++
              s!"use workspaceMode=reset to switch it explicitly to {config.root}" }
    | none =>
        if mode == .verify then
          { state, result := .error <| responseFailureFor .invalidParams <|
              s!"workspace '{workspaceId}' is not initialized; use workspaceMode=set first" }
        else if let some otherId := duplicateRootWorkspace? state workspaceId config then
          { state, result := .error <| responseFailureFor .invalidParams <|
              s!"workspace root {config.root} is already owned by workspace '{otherId}'" }
        else
          {
            state := setFreshWorkspace state workspaceId config
            result := .ok <| workspaceInitResult workspaceId config.root mode false false
          }

private def dropWorkspaceTransition
    (state : State)
    (workspaceId : WorkspaceId) : WorkspaceTransition Beam.Workspace.DropResult :=
  if !validWorkspaceId workspaceId then
    { state, result := .error <| responseFailureFor .invalidParams
        "workspace id must be non-empty" }
  else
    match getWorkspace? state workspaceId with
    | none =>
        { state, result := .ok {
            workspaceId
            dropped := false
            reason? := some "notFound"
          } }
    | some workspace =>
        {
          state := { state with workspaces := state.workspaces.erase workspaceId }
          result := .ok {
            workspaceId
            dropped := true
            invalidatedHandles := true
          }
          detachedSession? := workspace.lean.session?
        }

private def ServerRuntime.runWorkspaceTransition
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (transition : State → WorkspaceTransition α) : IO (Except ResponseFailure α) := do
  let transition ← server.withPublicationAvailable (some workspaceId) do
    let transition := transition (← get)
    set transition.state
    pure transition
  if let some session := transition.detachedSession? then
    shutdownSession session
  pure transition.result

/--
Initialize, verify, or reset a workspace through a typed in-process boundary. Reset commits the new
workspace ownership atomically, then drains its detached session outside the state mutex.
An I/O exception from cleanup leaves the replacement workspace committed.
-/
def ServerRuntime.initWorkspaceWithConfig
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig)
    (mode? : Option Beam.Workspace.InitMode := none) :
    IO (Except ResponseFailure Beam.Workspace.InitResult) :=
  server.runWorkspaceTransition workspaceId fun state =>
    initWorkspaceTransition state workspaceId config mode?

private def workspaceListPayload (state : State) : Json :=
  toJson ({
    workspaces := state.workspaces.toList.toArray.map fun (workspaceId, workspace) => ({
      workspaceId
      root := workspace.config.root
      leanActive := workspace.lean.session?.isSome
    } : Beam.Workspace.ListEntry)
  } : Beam.Workspace.ListResult)

private def responseOfTypedResult [ToJson α] : Except ResponseFailure α → Response
  | .ok result => Response.success (toJson result)
  | .error failure => failure.toResponse

/--
Remove a workspace through a typed in-process boundary. The workspace is erased atomically before
its detached session is drained outside the state mutex.
An I/O exception from cleanup leaves the workspace removed.
-/
def ServerRuntime.dropWorkspace
    (server : ServerRuntime)
    (workspaceId : WorkspaceId) : IO (Except ResponseFailure Beam.Workspace.DropResult) :=
  server.runWorkspaceTransition workspaceId fun state => dropWorkspaceTransition state workspaceId

private def recordDispatchMetrics
    (server : ServerRuntime)
    (req : Request)
    (workspaceGeneration? : Option Nat)
    (resp : Response)
    (startedAt : Nat) : IO Unit := do
  if req.op.usesSession then
    let finishedAt ← IO.monoNanosNow
    let latencyMs := (finishedAt - startedAt) / 1000000
    if let some workspaceId := req.resolvedWorkspaceId? then
      let some workspaceGeneration := workspaceGeneration? | return
      server.withState do
        recordRequestMetrics workspaceId workspaceGeneration req.op.key resp.ok
          (resp.error?.map (·.code)) latencyMs

private def cancelRegisteredRequest
    (server : ServerRuntime)
    (markCancelled : IO (Option ActiveRequest)) : IO Bool := do
  match ← markCancelled with
  | some active =>
    let sessions ← server.withState do
      let state ← get
      pure <| state.workspaces.toList.filterMap fun (workspaceId, workspace) =>
        if active.workspaceId?.all (fun selected => selected == workspaceId) then
          workspace.lean.session?
        else
          none
    for session in sessions do
      discard <| PendingRequestStore.cancelMatching session.pending session.stdin active.cancelRef
    pure true
  | none => pure false

private def cancelActiveRequest
    (server : ServerRuntime)
    (workspaceId? : Option WorkspaceId)
    (clientRequestId : String) : IO Bool :=
  cancelRegisteredRequest server <|
    ActiveRequestRegistry.markCancelled server.activeRequests workspaceId? clientRequestId

/--
Cancel the exact active admission represented by `handle`.

Returns `false` when the request does not track cancellation or the handle is no
longer active.
-/
def RequestHandle.cancel (handle : RequestHandle) : IO Bool := do
  match handle.active? with
  | none => pure false
  | some active =>
      cancelRegisteredRequest handle.runtime <|
        ActiveRequestRegistry.markCancelledActive handle.runtime.activeRequests active

private def propagatePendingCancellation
    (session : Session)
    (pending : PendingRequest) : IO Unit := do
  PendingRequestStore.propagateCancellation session.pending session.stdin pending.cancelRef?

private structure ClientPermits where
  available : Std.Mutex Nat

private def ClientPermits.create (count : Nat) : BaseIO ClientPermits := do
  pure { available := ← Std.Mutex.new count }

private def ClientPermits.tryAcquire (permits : ClientPermits) : BaseIO Bool := do
  permits.available.atomically do
    let available ← get
    if available == 0 then
      pure false
    else
      set (available - 1)
      pure true

private def ClientPermits.release (permits : ClientPermits) : BaseIO Unit := do
  permits.available.atomically do
    modify (· + 1)

private structure DaemonTransport where
  endpoint : Transport.Endpoint
  listener : Transport.Listener
  stop : IO.Ref Bool
  clientPermits : ClientPermits

private def maxDaemonClients : Nat :=
  64

private def DaemonTransport.create (endpoint : Transport.Endpoint) : IO DaemonTransport := do
  let stop ← IO.mkRef false
  let listener ← Transport.bindAndListen endpoint 16
  try
    let endpoint ← Transport.listenerEndpoint listener
    let clientPermits ← ClientPermits.create maxDaemonClients
    pure { endpoint, listener, stop, clientPermits }
  catch err =>
    Transport.closeListener listener
    throw err

private def requestStop (transport : DaemonTransport) : IO Unit := do
  transport.stop.set true
  try
    -- Wake the blocking accept. Both ends are intentionally left to scope cleanup: performing a
    -- graceful TCP shutdown on the wake-up pair can wait for its peer and deadlock daemon exit.
    discard <| Transport.connect transport.endpoint
  catch _ =>
    pure ()

private def closeAndRequestStop
    (server : ServerRuntime)
    (transport : DaemonTransport) : IO Unit := do
  try
    server.close
  finally
    requestStop transport

private structure AdmittedDocument where
  path : System.FilePath
  permit : DocumentAdmission.Permit

private structure WorkspaceRequest where
  output? : Option Beam.WorkspaceOutput.Buffer := none
  workspaceId : WorkspaceId
  workspaceGeneration : Nat
  clientRequestId? : Option String
  cancelRef? : Option (IO.Ref Bool)
  document? : Option AdmittedDocument := none

private def documentAdmissionFailure (uri : String) : DocumentAdmission.Conflict → ResponseFailure
  | .closing => responseFailureFor .contentModified
      "document is closing; coordinate with the close-save owner before retrying"
      (some <| Json.mkObj [("reason", toJson "documentClosing"), ("uri", toJson uri)])
  | .stale => responseFailureFor .contentModified
      "document admission was invalidated by closure or backend replacement; start a new request"
      (some <| Json.mkObj [("reason", toJson "documentAdmissionExpired"), ("uri", toJson uri)])

private def requireRequestDocument (req : WorkspaceRequest) : IO AdmittedDocument := do
  let some document := req.document?
    | throw <| IO.userError "document operation has no admission"
  pure document

private def validateRequestWorkspace
    (server : ServerRuntime)
    (req : Request)
    (cancelRef? : Option (IO.Ref Bool))
    (output? : Option Beam.WorkspaceOutput.Buffer := none) : IO (Except ResponseFailure WorkspaceRequest) := do
  let workspaceId ←
    match req.requireWorkspaceId with
    | .ok workspaceId => pure workspaceId
    | .error err => return .error (responseFailureFor .invalidParams err)
  let workspace? ← server.withState do
    pure <| (← get).workspaces.get? workspaceId
  let some workspace := workspace?
    | return .error (responseFailureFor .invalidParams s!"unknown Beam workspace '{workspaceId}'")
  pure (.ok {
    workspaceId
    workspaceGeneration := workspace.generation
    output?
    clientRequestId? := req.clientRequestId?
    cancelRef?
  })

private def requestWorkspaceChangedFailure (req : WorkspaceRequest) : ResponseFailure :=
  responseFailureFor .contentModified <|
    s!"workspace '{req.workspaceId}' changed while the request was in flight; retry the request"

private def ServerRuntime.withRequestSessionState
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (act : M (Except ResponseFailure α)) : IO (Except ResponseFailure α) :=
  server.withLiveSessionState req.workspaceId req.workspaceGeneration
    (requestWorkspaceChangedFailure req) req.cancelRef? do
      if let some document := req.document? then
        let some workspace := getWorkspace? (← get) req.workspaceId
          | return .error <| requestWorkspaceChangedFailure req
        if let .error conflict := workspace.documents.check document.permit then
          return .error <| documentAdmissionFailure document.permit.uri conflict
      -- Retain completed state transitions even when subsequent backend delivery throws.
      try act catch error => pure <| .error <| responseFailureFor .internalError error.toString

/-- One bracket owns admission and cleanup across every document handler and asynchronous wait. -/
private def withDocumentAdmission (server : ServerRuntime) (req : WorkspaceRequest)
    (payload : RequestPayload)
    (act : WorkspaceRequest → IO Response) : IO Response := do
  let some path := payload.documentPath? | return ← act req
  match ← ensureRequestNotCancelled req.cancelRef? with
  | .error failure => return failure.toResponse
  | .ok () => pure ()
  let root? ← server.withState do
    pure <| (getWorkspace? (← get) req.workspaceId).map (·.config.root)
  let some root := root? | return (requestWorkspaceChangedFailure req).toResponse
  -- Plain close only cleans up tracked state, including after the source has disappeared.
  let cleanupOnly := match payload with
    | .close request => !request.saveArtifacts?.getD false
    | _ => false
  if path.isEmpty then
    return (responseFailureFor .invalidParams "document path must not be empty").toResponse
  let root ← if cleanupOnly then pure root else resolveRoot root
  let resolved ← if cleanupOnly then do
      try pure <| .ok <| ← resolveDocumentPath root path
      catch error =>
        match sourceResolutionFailure? root path error with
        | some failure => pure <| .error failure
        | none => throw error
    else resolveSourceDocumentPath root path
  let path ← match resolved with
    | .ok path => pure path
    | .error failure => return failure.toResponse
  let admitted ← server.withRequestSessionState req do
    let some workspace := getWorkspace? (← get) req.workspaceId
      | return .error <| requestWorkspaceChangedFailure req
    match workspace.documents.admit (sessionUri path) with
    | .error conflict => pure <| .error <| documentAdmissionFailure (sessionUri path) conflict
    | .ok (documents, permit) =>
      modify fun state => setWorkspace state req.workspaceId { workspace with documents }
      pure <| .ok { req with document? := some { path, permit } }
  let req ← match admitted with
    | .error failure => return failure.toResponse
    | .ok req => pure req
  try act req
  finally
    server.withState do
      if let some workspace := getWorkspace? (← get) req.workspaceId then
        if workspace.generation == req.workspaceGeneration then
          let document ← requireRequestDocument req
          modify fun state => setWorkspace state req.workspaceId {
            workspace with documents := workspace.documents.release document.permit }

private def fenceDocument (req : WorkspaceRequest) (reserve : Bool := false) :
    M (Except ResponseFailure Unit) := do
  let document ← requireRequestDocument req
  let some workspace := getWorkspace? (← get) req.workspaceId
    | return .error <| requestWorkspaceChangedFailure req
  let documents ←
    if reserve then
      match workspace.documents.reserve document.permit with
      | .error conflict => return .error <| documentAdmissionFailure document.permit.uri conflict
      | .ok documents => pure documents
    else pure <| workspace.documents.fence document.permit
  modify fun state => setWorkspace state req.workspaceId { workspace with documents }
  pure <| .ok ()

private def DocumentRef.recordProgress
    (document : DocumentRef)
    (fileProgress? : Option SyncFileProgress) : IO Unit := do
  document.runtime.withState do
    modifyCurrentSessionIfMatching document.session fun current =>
      let docs := DocumentState.recordFileProgressForBasis current.docs
        document.uri document.basis fileProgress?
      { current with docs }

/-- Observe only an explicit backend worker error, before per-caller cancellation presentation. -/
private def DocumentRef.recordWorkerFailure
    (document : DocumentRef) (failure : ResponseFailure) : IO Unit := do
  unless failure.error.code == errorCodeName .workerExited ||
      failure.error.code == errorCodeName .workerCrashed do return
  document.runtime.withState do
    let state ← get
    let some workspace := getWorkspace? state document.session.workspaceId | return
    let some current := workspace.lean.session? | return
    unless sameSessionIdentity current document.session do return
    let some docs := DocumentState.recordWorkerErrorForBasis current.docs
        document.uri document.basis failure.error | return
    set <| setWorkspace state document.session.workspaceId {
      workspace with
      lean := { workspace.lean with session? := some { current with docs } }
      documents := workspace.documents.revokeReading document.uri
    }

private def DocumentRef.awaitOutcome
    (document : DocumentRef) (pending : PendingRequest) : IO (Except ResponseFailure PendingResult) := do
  match ← pending.awaitRawOutcome with
  | .ok result => pure (.ok result)
  | .error failure =>
    document.recordWorkerFailure failure
    pure <| .error <| ← RequestCancellation.backendFailure pending.cancelRef? failure

/-- Fresh synchronization phases may reopen a failed worker using their captured admission.
Older source reads must not fence newer requests or close their document. Ordinary use rejects
recorded failures before reaching this path. -/
private def syncAdmittedFileSnapshot
    (req : WorkspaceRequest) (session : Session) (snapshot : FileSyncSnapshot) :
    M (Except ResponseFailure SyncedFileSnapshot) := do
  if let some doc := session.docs.get? snapshot.uri then
    if doc.workerError?.isSome then
      if snapshot.file.isSupersededBy doc then
        return .error <| responseFailureFor .contentModified
          "a newer source read was accepted before worker recovery; start a new sync/update request"
      if let .error failure ← fenceDocument req then return .error failure
  .ok <$> syncFileSnapshotDetailed session snapshot

private def withCurrentMatchingSession
    (server : ServerRuntime)
    (cancelRef? : Option (IO.Ref Bool))
    (session : Session)
    (k : Session → M α) : HandlerM α := do
  let sessionChangedFailure := BrokerFailure.toResponseFailure {
    code := .workerExited
    message := "broker backend session changed while request was in flight"
  }
  liftFailureIO <| server.withLiveSessionState session.workspaceId session.workspaceGeneration
      sessionChangedFailure cancelRef? do
    match ← storedSession? session.workspaceId with
    | some current =>
      if sameSessionIdentity current session then
          .ok <$> k current
      else
          pure <| .error <| BrokerFailure.toResponseFailure {
            code := .workerExited
            message := "broker backend session changed while request was in flight"
          }
    | none =>
        pure <| .error <| BrokerFailure.toResponseFailure {
          code := .workerExited
          message := "broker backend session exited while request was in flight"
        }

private def documentBasisMismatchFailure
    (uri : DocumentUri)
    (currentVersion? : Option Nat) : ResponseFailure :=
  responseFailureFor .contentModified
    s!"document changed or reopened while request was in flight: {uri}; retry after synchronizing"
    (some <| Json.mkObj <|
      [("reason", toJson "documentChanged"), ("uri", toJson uri)] ++
      currentVersion?.toList.map (fun version => ("currentVersion", toJson version)))

private def DocumentRef.withCurrentSession
    (document : DocumentRef) (k : Session → M α) : HandlerM α :=
  withCurrentMatchingSession document.runtime document.cancelRef? document.session k

private def DocumentRef.retireBackend (document : DocumentRef) : IO Unit := do
  document.runtime.withPublicationAvailable (some document.session.workspaceId) do
    let state ← get
    let some workspace := getWorkspace? state document.session.workspaceId | return
    let some current := workspace.lean.session? | return
    unless sameSessionIdentity current document.session do return
    let (lean, _) := detachBackendSession workspace.lean
    set <| setWorkspace state current.workspaceId {
      workspace with lean, documents := workspace.documents.retire }
  -- A concurrent drop may already have detached this backend. Its shared process owner still
  -- lets us settle the captured effect without touching a replacement session.
  terminateSession document.session

/-- Retire the captured owner if protected backend delivery remains uncertain. -/
private def DocumentRef.withSettledEffect (document : DocumentRef)
    (act : IO.Ref Bool → HandlerM α) : HandlerM α :=
  ExceptT.mk do
    let uncertain ← IO.mkRef false
    try (act uncertain).run
    finally
      if ← uncertain.get then document.retireBackend

private def DocumentRef.withCurrentDocument
    (document : DocumentRef)
    (k : Session → M (Except ResponseFailure α)) : HandlerM α := do
  let result ← document.withCurrentSession fun current => do
    match DocumentState.matchBasis current.docs document.uri document.basis with
    | .current =>
        let doc ← requireDocState current document.uri
        if let some error := doc.workerError? then pure (.error { error }) else k current
    | .superseded version? =>
        pure <| .error <| documentBasisMismatchFailure document.uri version?
  requestArg result

namespace Internal

/-- Claim publication with the exact captured owner and accepted basis. The successful final
cancellation check is the commit cutoff: cancellation cannot revoke the claimed filesystem work.
Only the promotion action runs outside state; all same-workspace ownership changes wait for it.

Once promotion starts, even if it fails, `module?` enters the session's publication record in the
same state update that releases the claim, whether or not its document is still tracked. -/
def withDocumentPublication
    (server : ServerRuntime) (session : Session) (uri : DocumentUri) (basis : DocumentBasis)
    (cancelRef? : Option (IO.Ref Bool)) (promote : IO α) (module? : Option String := none) :
    IO (Except ResponseFailure α) := do
  let completion ← IO.Promise.new
  let document : DocumentRef := { runtime := server, session, uri, basis, cancelRef? }
  let claimed ← (document.withCurrentDocument fun _ => do
    match ← ensureRequestNotCancelled cancelRef? with
    | .error failure => return .error failure
    | .ok () => pure ()
    let state ← get
    if state.publication?.isSome then
      return .error <| responseFailureFor .internalError "another save publication is already claimed"
    let claim : PublicationClaim := {
      token := state.nextPublicationToken, workspaceId := session.workspaceId, done := completion
    }
    set { state with
      nextPublicationToken := state.nextPublicationToken + 1, publication? := some claim }
    pure (.ok claim)).run
  let claim ← match claimed with
    | .error failure => return .error failure
    | .ok claim => pure claim
  try
    .ok <$> promote
  finally
    try
      server.withState do
        -- A later session reloads every import, so a replaced session needs no record.
        if let some module := module? then
          if let some current ← storedSession? session.workspaceId then
            if sameSessionIdentity current session then
              updateSession { current with
                nextEventSeq := current.nextEventSeq + 1
                publishedModules := current.publishedModules.insert module current.nextEventSeq }
        let state ← get
        if state.publication?.any (·.token == claim.token) then
          set { state with publication? := none }
    finally
      completion.resolve ()

end Internal

private def DocumentRef.recordCompletedSync (document : DocumentRef) : HandlerM Unit :=
  document.withCurrentSession fun current =>
    updateSession (markDocSyncedBasis current document.uri document.basis)

private structure StartedSyncedRequest where
  document : DocumentRef
  pending : PendingRequest

private def documentVersionMismatchFailure
    (expectedVersion acceptedVersion : Nat)
    (uri : DocumentUri)
    (observedDiskChange : Bool := false) : ResponseFailure :=
  responseFailureFor
    .contentModified
    (s!"document version mismatch for {uri}: requested version {expectedVersion}, accepted version {acceptedVersion}" ++
      if observedDiskChange then "; source changed on disk since its last synchronization" else "")
    (some <| documentVersionMismatchErrorData expectedVersion acceptedVersion
      (currentVersion? := some acceptedVersion)
      (uri? := some uri))

private def startSyncedDocumentRequest
    (server : ServerRuntime)
    (session : Session)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → Json)
    (expectedVersion? : Option Nat := none)
    (clientRequestId? : Option String := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (position? : Option Lsp.Position := none) :
    M (Except ResponseFailure StartedSyncedRequest) := do
  match ← workspaceForSnapshot session.workspaceId snapshot with
  | .error failure => return .error failure
  | .ok _ => pure ()
  if let some error := (session.docs.get? snapshot.uri).bind (·.workerError?) then
    return .error { error }
  let previous? := session.docs.get? snapshot.uri
  let synced ← syncFileSnapshotDetailed session snapshot
  let session := synced.session
  let uri := snapshot.uri
  let docState ← requireDocState session uri
  match expectedVersion? with
  | some expectedVersion =>
      if docState.version != expectedVersion then
        updateSession session
        return .error <| documentVersionMismatchFailure expectedVersion docState.version uri
          (observedDiskChange := synced.changed && previous?.any (·.rawSourceHash != docState.rawSourceHash))
  | none =>
      pure ()
  if let some position := position? then
    if let .error message := docState.positionBounds.validate position then
      updateSession session
      return .error <| responseFailureFor .invalidParams message
  let params := mkParams uri
  let (session, pending) ←
    startRequestJsonTrackedDetailed session method params
      (clientRequestId? := clientRequestId?)
      (tracked := some (uri, docState.version))
      (initialProgress? := docState.fileProgress?)
      (emitProgress? := emitProgress?)
      (diagnosticScope := diagnosticScope)
      (emitDiagnostic? := emitDiagnostic?)
      (cancelRef? := cancelRef?)
  updateSession session
  pure <| .ok {
    document := ← DocumentRef.capture server session uri cancelRef?
    pending
  }

private def startSyncedWorkspaceRequest
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → Json)
    (expectedVersion? : Option Nat := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (position? : Option Lsp.Position := none) :
    M (Except ResponseFailure StartedSyncedRequest) :=
  withSessionForSnapshot req.workspaceId snapshot (cancelRef? := req.cancelRef?) (output? := req.output?) fun session =>
    startSyncedDocumentRequest server session snapshot method mkParams expectedVersion?
      req.clientRequestId? emitProgress? diagnosticScope emitDiagnostic? req.cancelRef? position?

private def awaitSyncedDocumentRequest
    (started : StartedSyncedRequest) : HandlerM PendingResult := do
  liftHandlerIO <| propagatePendingCancellation started.document.session started.pending
  let pending ← liftFailureIO <| started.document.awaitOutcome started.pending
  withFailureProgress pending.progress? <|
    liftHandlerIO <| started.document.recordProgress pending.progress?
  withFailureProgress pending.progress? <|
    started.document.withCurrentSession fun _ => pure ()
  pure pending

private def readRequestSyncSnapshot
    (server : ServerRuntime)
    (req : WorkspaceRequest) : IO (Except ResponseFailure FileSyncSnapshot) := do
  let document ← requireRequestDocument req
  let readContext ← server.withRequestSessionState req do
    let state ← get
    let some workspace := getWorkspace? state req.workspaceId
      | return .error <| requestWorkspaceChangedFailure req
    let readSeq := workspace.nextFileSnapshotSeq
    set <| setWorkspace state req.workspaceId { workspace with nextFileSnapshotSeq := readSeq + 1 }
    pure <| .ok (workspace.config.root, readSeq)
  let (root, readSeq) ← match readContext with
    | .ok context => pure context
    | .error failure => return .error failure
  -- The scoped admission is captured before this read, and checked again before acceptance.
  readFileSyncSnapshot root document.path req.workspaceGeneration readSeq server.readSource

private structure StartedTrackedBarrier where
  document : DocumentRef
  leanConfig? : Option LeanBackendConfig
  documentHash : UInt64
  lakeTraceHash : Lake.Hash
  textMTime : Lake.MTime
  changed : Bool := false
  priorProgress? : Option SyncFileProgress := none
  pending : PendingRequest

private def startTrackedDiagnosticsBarrierIO
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (reserveClose : Bool := false)
    (refresh : Bool := false) :
    IO (Except ResponseFailure StartedTrackedBarrier) := do
  let snapshot ←
    match ← readRequestSyncSnapshot server req with
    | .ok snapshot => pure snapshot
    | .error failure => return .error failure
  server.withRequestSessionState req do
    withWorkspaceForSnapshot req.workspaceId snapshot fun workspace => do
      let session ← match ← ensureSession req.workspaceId req.cancelRef? req.output? with
        | .error failure => return .error failure
        | .ok session => pure session
      -- Closing or fencing first would discard the evidence that a newer read was accepted.
      let superseded := (session.docs.get? snapshot.uri).any snapshot.file.isSupersededBy
      let reopen := refresh && !superseded
      if reopen then
        if let .error failure ← fenceDocument req then return .error failure
      let session ← if reopen then closeFile session snapshot.uri else pure session
      let synced ← match ← syncAdmittedFileSnapshot req session snapshot with
        | .error failure => return .error failure
        | .ok synced => pure synced
      let session := synced.session
      let uri := synced.uri
      let docState ← requireDocState session uri
      updateSession session
      if reserveClose then
        if let .error failure ← fenceDocument req true then return .error failure
      let params := toJson (WaitForDiagnosticsParams.mk uri docState.version)
      let method := diagnosticsBarrierMethod
      let (session, pending) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := some (uri, docState.version))
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
          (diagnosticScope := diagnosticScope)
          (emitDiagnostic? := emitDiagnostic?)
          (cancelRef? := req.cancelRef?)
      updateSession session
      pure <| .ok {
        document := ← DocumentRef.capture server session uri req.cancelRef?
        leanConfig? := workspace.config.lean?
        documentHash := docState.documentHash
        lakeTraceHash := docState.lakeTraceHash
        textMTime := docState.textMTime
        changed := synced.changed
        priorProgress? := docState.fileProgress?
        pending
      }

private structure SaveOleanCompleted where
  document : DocumentRef
  result : SaveOleanResult
  fileProgress? : Option SyncFileProgress := none

private inductive SaveFinalizationOutcome where
  | applied
  | superseded (currentVersion? : Option Nat)

private def finalizeSavedDoc
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) (uncertain : IO.Ref Bool) : HandlerM SaveFinalizationOutcome :=
  saved.document.withCurrentSession fun current => do
    match DocumentState.matchBasis current.docs saved.document.uri saved.document.basis with
    | .superseded currentVersion? => pure <| .superseded currentVersion?
    | .current =>
      let current := markDocSavedVersion current saved.document.uri saved.document.basis.version
      let current ←
        if closeAfter then do
          uncertain.set true
          sendNotificationJson current "textDocument/didClose" (toJson ({
            textDocument := ({ uri := saved.document.uri : TextDocumentIdentifier })
            : DidCloseTextDocumentParams
          }))
        else
          pure current
      let current :=
        if closeAfter then { current with docs := current.docs.erase saved.document.uri } else current
      updateSession current
      uncertain.set false
      pure .applied

private def saveCompletedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : Response :=
  let result :=
    if closeAfter then
      toJson ({ saved := saved.result } : CloseSaveResult)
    else
      toJson saved.result
  Response.withOptionalFileProgress (Response.success result) saved.fileProgress?

/-- A successful trace is a committed checkpoint even if later document finalization fails. -/
private def finalizeSavedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : HandlerM Response :=
  ExceptT.mk do
    let outcome ← try
      (saved.document.withSettledEffect fun uncertain =>
        finalizeSavedDoc saved closeAfter uncertain).run
    catch error =>
      pure <| .error <| responseFailureFor .internalError error.toString
    match outcome with
    | .error failure =>
      -- Delivery may have failed after didClose was sent. Preserve the failure without claiming
      -- that closure did not happen; closed=false belongs only to a refused comparison below.
      let data : SaveFinalizationFailureData := {
        saved := saved.result, originalData? := failure.error.data?
      }
      pure <| .error {
        failure with
        error := { failure.error with data? := some (toJson data) }
        fileProgress? := failure.fileProgress? <|> saved.fileProgress?
      }
    | .ok (.superseded currentVersion?) =>
      if closeAfter then
        let data : SaveFinalizationStaleData := { saved := saved.result, currentVersion? }
        pure <| .error <| (responseFailureFor .contentModified
          "checkpoint saved, but the tracked document changed or was closed; this request did not close it"
          (some <| toJson data)).withOptionalFileProgress saved.fileProgress?
      else
        pure <| .ok <| saveCompletedResponse saved false
    | .ok .applied =>
      pure <| .ok <| saveCompletedResponse saved closeAfter

private def syncSaveReadinessOfBarrierResult
    (uri : DocumentUri)
    (expectedVersion : Nat)
    (expectedTextHash : UInt64)
    (barrierResult : DiagnosticsBarrierResult) : HandlerM SyncSaveReadiness := do
  let readiness := barrierResult.saveReadiness
  if readiness.version != expectedVersion then
    throwBrokerFailure {
      code := .contentModified
      message :=
        s!"diagnostics barrier save readiness reported version " ++
          s!"{readiness.version}, expected document version {expectedVersion}"
      data? := some <| documentVersionMismatchErrorData expectedVersion readiness.version
        (currentVersion? := some readiness.version)
        (uri? := some uri)
    }
  if readiness.textHash != expectedTextHash then
    throwBrokerFailure {
      code := .contentModified
      message :=
        s!"diagnostics barrier save readiness reported text hash " ++
          s!"{readiness.textHash}, expected synced hash {expectedTextHash}"
      data? := some <| Json.mkObj [
        ("expectedHash", toJson expectedTextHash),
        ("actualHash", toJson readiness.textHash),
        ("uri", toJson uri)
      ]
    }
  pure <| syncSaveReadinessOfResult readiness

private def DocumentRef.staleDirectDepHints
    (document : DocumentRef)
    (imports : Array String) : HandlerM (Array StaleDirectDepHint) := do
  document.withCurrentSession fun current => do
    match DocumentState.matchBasis current.docs document.uri document.basis with
    | .superseded _ => pure #[]
    | .current =>
        let docState ← requireDocState current document.uri
        pure <| collectStaleDirectDepHints imports docState.lastSyncEventSeq current.moduleHistory

private structure SyncBarrierOutcome where
  completionDiagnostics : Array Diagnostic := #[]
  hints : Array StaleDirectDepHint := #[]
  fileProgress? : Option SyncFileProgress := none
  incomplete : Bool := false

private def staleDirectDepsBlock
    (changed : Bool)
    (hints : Array StaleDirectDepHint) : Bool :=
  !hints.isEmpty && (!changed || hints.any (·.needsSave))

private def syncBarrierOutcome
    (started : StartedTrackedBarrier)
    (progress? : Option SyncFileProgress)
    (diagnosticsSeen : Bool)
    (hasFatalSnapshot : Bool)
    (observedDiagnostics : Array Diagnostic)
    (directImports : Array String)
    (currentDiagnostics : Array Diagnostic) : HandlerM SyncBarrierOutcome := do
  let completionDiagnostics :=
    if diagnosticsSeen then observedDiagnostics else currentDiagnostics
  let decision :=
    decideSyncBarrier started.document.uri started.document.version started.priorProgress? progress?
      hasFatalSnapshot completionDiagnostics
  let hints ← started.document.staleDirectDepHints directImports
  let staleDepsBlock := staleDirectDepsBlock started.changed hints
  let fileProgress? :=
    if staleDepsBlock then
      some <| incompleteBarrierProgress decision.fileProgress?
    else
      decision.fileProgress?
  pure {
    completionDiagnostics
    hints
    fileProgress?
    incomplete := decision.incomplete || staleDepsBlock
  }

private initialize savePublicationMutex : Std.Mutex Unit ← Std.Mutex.new ()

private def importsChangedFailure
    (relPath : String)
    (syncResult : SyncFileResult)
    (basis : Beam.LSP.ImportBasis.Result) : BrokerFailure :=
  let detail :=
    match basis.status with
    | .changed =>
        s!"its imports changed after the Lean worker loaded them: " ++
          String.intercalate ", " basis.changedImports.toList
    | _ =>
        if basis.unresolvedImports.isEmpty then
          "Beam has no record of the imports the Lean worker loaded for it"
        else
          "Beam could not locate the Lake traces of imports the Lean worker loaded: " ++
            String.intercalate ", " basis.unresolvedImports.toList
  {
    code := .saveImportsChanged
    message :=
      s!"lean-beam save cannot checkpoint {relPath}: {detail}. " ++
      "A checkpoint must match the imports it was elaborated against; " ++
      s!"run `lean-beam refresh \"{relPath}\"` to reload them, then save again."
    data? := some <| (syncResultErrorData syncResult)
      |>.setObjVal! "path" (toJson relPath)
      |>.setObjVal! "changedImports" (toJson basis.changedImports)
      |>.setObjVal! "unresolvedImports" (toJson basis.unresolvedImports)
      |>.setObjVal! "recoveryPlan" (toJson #[s!"lean-beam refresh \"{relPath}\""])
  }

/-- Refuse a checkpoint whose loaded imports no longer match those the worker loaded. -/
private def requireCurrentImportBasis
    (started : StartedTrackedBarrier)
    (relPath : String)
    (syncResult : SyncFileResult)
    (clientRequestId? : Option String) : HandlerM Unit := do
  let request ← started.document.withCurrentDocument fun current => do
    let savedModules := current.publishedModules.toArray.map fun (module, eventSeq) =>
      { module, eventSeq : Beam.LSP.ImportBasis.SavedModule }
    let param := toJson ({
      textDocument := { uri := started.document.uri, version? := some started.document.version }
      savedModules
      : Beam.LSP.ImportBasis.Params
    })
    let (current, request) ← startRequestJsonTrackedDetailed current importBasisMethod param
      (clientRequestId? := clientRequestId?) (cancelRef? := started.document.cancelRef?)
    updateSession current
    pure <| .ok request
  liftHandlerIO <| propagatePendingCancellation started.document.session request
  let pending ← requestArg (← liftHandlerIO <| started.document.awaitOutcome request)
  let basis : Beam.LSP.ImportBasis.Result ← liftHandlerIO <| decodeResponseAs pending.result
  unless basis.status == .current do
    throwBrokerFailure (importsChangedFailure relPath syncResult basis)

private def saveOleanCore
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (closeAfter : Bool := false) :
    HandlerM SaveOleanCompleted := do
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let started ← liftFailureIO <| startTrackedDiagnosticsBarrierIO server req diagnosticScope
    emitProgress? emitDiagnostic? (reserveClose := closeAfter)
  let some leanConfig := started.leanConfig?
    | throw <| responseFailureFor .invalidParams "Lean backend is not configured"
  liftHandlerIO <| propagatePendingCancellation started.document.session started.pending
  let barrier ← awaitWaitForDiagnosticsBarrier
    s!"save_olean sync barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.document.uri} version={started.document.version}"
    (started.document.awaitOutcome started.pending)
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress barrier.progress? <| liftHandlerIO <| decodeResponseAs barrier.result
  if barrierResult.version != started.document.version then
    throw <| (documentVersionMismatchFailure started.document.version barrierResult.version started.document.uri)
      |>.withOptionalFileProgress barrier.progress?
  withFailureProgress barrier.progress? <| liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let saveReadiness ←
    withFailureProgress barrier.progress? <|
      syncSaveReadinessOfBarrierResult started.document.uri started.document.version started.documentHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress barrier.progress? <|
    syncBarrierOutcome started barrier.progress? barrier.diagnosticsSeen barrierResult.hasFatalSnapshot
      barrier.diagnostics barrierResult.directImports currentDiagnostics
  let barrierProgress? := barrierOutcome.fileProgress?
  withFailureProgress barrierProgress? <|
    liftHandlerIO <| started.document.recordProgress barrierProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.document.session.root started.document.uri
    throw <| syncBarrierIncompleteFailure
      started.document.uri started.document.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics barrierProgress?
  let relPath := Beam.pathRelativeToRootOrSelf started.document.session.root path
  let syncResult := mkSyncFileResult relPath started.document.version currentDiagnostics saveReadiness
  -- Reject unsupported compilation before preparing outputs or invalidating the prior trace.
  if !saveReadiness.saveReady &&
      saveReadiness.saveReadyReason == Beam.LSP.Save.saveReadinessDeferredCompilationReason then
    withFailureProgress barrierProgress? <| throwBrokerFailure {
      code := .saveUnsupportedSetup
      message := saveReadiness.saveReadyMessage?.getD "Beam cannot save deferred compilation; use lake build instead."
      data? := some <| (syncResultErrorData syncResult)
        |>.setObjVal! "reason" (toJson saveReadiness.saveReadyReason)
        |>.setObjVal! "path" (toJson relPath)
    }
  let spec ← withFailureProgress barrierProgress? do
    match ← liftHandlerIO <|
        requestSaveSpecification leanConfig.lakeHelper started.document.session.root path
          { hash := started.lakeTraceHash, mtime := started.textMTime }
          (← requestHelperControl req.cancelRef? req.output?) with
    | .ok spec => pure spec
    | .error failure =>
      if failure.code != .saveUnsupportedSetup then throwBrokerFailure failure
      -- The helper owns setup validation; the broker retains the completed sync verdict.
      started.document.recordCompletedSync
      throwBrokerFailure {
        failure with
        data? := some <| (failure.data?.getD <| Json.mkObj [])
          |>.setObjVal! "sync" (toJson syncResult)
      }
  withFailureProgress barrierProgress? <|
    started.document.recordCompletedSync
  -- The helper read the dependency traces it will record before this check. If the loaded imports
  -- still match what the worker loaded, that trace describes the elaborated environment.
  withFailureProgress barrierProgress? <|
    requireCurrentImportBasis started relPath syncResult req.clientRequestId?
  let plan ← withFailureProgress barrierProgress? <| liftHandlerIO <|
    Publication.create spec.toLeanSaveOutputs
  let producersSettled ← liftHandlerIO <| IO.mkRef true
  try
    let privateSpec := { spec with toLeanSaveOutputs := plan.outputs }
    let method := saveArtifactsMethod
    let params := toJson ({
      textDocument := ({ uri := started.document.uri : TextDocumentIdentifier })
      expectedVersion := started.document.version
      expectedTextHash := started.documentHash
      oleanFile := privateSpec.oleanPath.toString
      moduleArtifacts? :=
        match privateSpec.oleanServerPath?, privateSpec.oleanPrivatePath?, privateSpec.irPath?, privateSpec.irSigPath? with
        | some oleanServerFile, some oleanPrivateFile, some irFile, some irSigFile =>
            some {
              oleanServerFile := oleanServerFile.toString
              oleanPrivateFile := oleanPrivateFile.toString
              irFile := irFile.toString
              irSigFile := irSigFile.toString
            }
        | _, _, _, _ => none
      ileanFile := privateSpec.ileanPath.toString
      cFile := privateSpec.cPath.toString
      bcFile? := privateSpec.bcPath?.map (fun bcPath => System.FilePath.toString bcPath)
      : Beam.LSP.Save.SaveArtifactsParams
    })
    -- A cancellation after readiness/spec computation must not invalidate a valid trace.
    withFailureProgress barrierProgress? <| liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
    let saveResult ← started.document.withSettledEffect fun uncertain => do
      let saveRequest ← withFailureProgress barrierProgress? <|
        started.document.withCurrentDocument fun current => do
          match ← ensureRequestNotCancelled req.cancelRef? with
          | .error failure => return .error failure
          | .ok () => pure ()
          -- Validate the producer's basis under the state lock. Canonical files and their
          -- trace remain untouched until completed preparation reaches broker promotion.
          producersSettled.set false
          -- Caller cancellation is deferred until private serialization acknowledges completion.
          -- A failed request write still leaves backend delivery uncertain for both save variants.
          uncertain.set true
          let (current, saveRequest) ← startRequestJsonTrackedDetailed current method params
            (clientRequestId? := req.clientRequestId?)
          updateSession current
          pure <| .ok saveRequest
      -- Successful delivery ends backend uncertainty. Missing or malformed completion can
      -- retain private candidates, but cannot authorize canonical publication.
      liftHandlerIO <| uncertain.set false
      let presentFailure := fun (failure : ResponseFailure) =>
        ({
          failure with
          error := {
            failure.error with
            data? :=
              if failure.error.code == "invalidParams" then
                some (syncResultErrorData syncResult)
              else
                failure.error.data?
          }
        }).withOptionalFileProgress barrierProgress?
      let pending ←
        match ← withFailureProgress barrierProgress? <|
            liftHandlerIO (started.document.awaitOutcome saveRequest) with
        | .ok pending => pure pending
        | .error failure =>
            let failure ← liftHandlerIO <| RequestCancellation.backendFailure req.cancelRef? failure
            throw <| presentFailure failure
      let completion : Beam.LSP.Save.SaveArtifactsCompletion ←
        withFailureProgress barrierProgress? <| liftHandlerIO <| decodeResponseAs pending.result
      -- Only this method's typed acknowledgement establishes that its owned task has finished.
      -- Bare errors, missing replies, or malformed payloads leave private producers unsettled.
      liftHandlerIO <| producersSettled.set true
      match completion with
      | .success result => pure result
      | .failure code message =>
          let failure := fileWorkerResponseFailure code message (some started.document.uri)
          let failure := failure.withOptionalFileProgress pending.progress?
          liftHandlerIO <| started.document.recordWorkerFailure failure
          let failure ← liftHandlerIO <| RequestCancellation.backendFailure req.cancelRef? failure
          throw <| presentFailure failure
    if saveResult.version != started.document.version then
      throw <| (responseFailureFor .internalError
        s!"save_olean saved version {saveResult.version}, expected document version {started.document.version}")
        |>.withOptionalFileProgress barrierProgress?
    if saveResult.textHash != started.documentHash then
      throw <| (responseFailureFor .internalError
        s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {started.documentHash}")
        |>.withOptionalFileProgress barrierProgress?
    withFailureProgress barrierProgress? <| liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
    -- Local finalization has no outstanding producer when it returns, including on failure.
    let traceResult ← liftHandlerIO <| (writePrivateSaveTrace privateSpec).toBaseIO
    withFailureProgress barrierProgress? <| liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
    withFailureProgress barrierProgress? <| liftHandlerIO <| IO.ofExcept traceResult
    liftHandlerIO plan.ready
    withFailureProgress barrierProgress? <| liftFailureIO <|
      Internal.withDocumentPublication server started.document.session started.document.uri
        started.document.basis req.cancelRef? plan.promote
        (module? := some spec.moduleName)
    pure {
      document := started.document
      result := leanSaveResult spec started.lakeTraceHash syncResult
      fileProgress? := barrierProgress?
    }
  finally
    liftHandlerIO <| plan.dispose (← producersSettled.get)

private def saveOlean
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (path : System.FilePath)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (closeAfter : Bool := false) :
    HandlerM SaveOleanCompleted :=
  savePublicationMutex.atomically do
    -- A cancelled save waiting behind another transaction must not start new sync or trace work.
    liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
    saveOleanCore server req path diagnosticScope emitProgress? emitDiagnostic? closeAfter

private def handleSyncFileOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : SyncFileRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (refresh : Bool := false) :
    HandlerM Response := do
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let diagnosticScope := request.diagnosticScope?.getD .errors
  let started ← liftFailureIO <| startTrackedDiagnosticsBarrierIO server req diagnosticScope
    emitProgress? emitDiagnostic? (refresh := refresh)
  liftHandlerIO <| traceBroker
    s!"sync_file await barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.document.uri} version={started.document.version}"
  liftHandlerIO <| propagatePendingCancellation started.document.session started.pending
  let pending ← awaitWaitForDiagnosticsBarrier
    s!"sync_file clientRequestId={optionLabel req.clientRequestId?} uri={started.document.uri} version={started.document.version}"
    (started.document.awaitOutcome started.pending)
  liftHandlerIO <| traceBroker
    s!"sync_file barrier completed clientRequestId={optionLabel req.clientRequestId?} progress={pending.progress?.isSome} diagnostics={pending.diagnostics.size} diagnosticsSeen={pending.diagnosticsSeen}"
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress pending.progress? <| liftHandlerIO <| decodeResponseAs pending.result
  if barrierResult.version != started.document.version then
    throw <| (documentVersionMismatchFailure started.document.version barrierResult.version started.document.uri)
      |>.withOptionalFileProgress pending.progress?
  let saveReadiness ←
    withFailureProgress pending.progress? <|
      syncSaveReadinessOfBarrierResult started.document.uri started.document.version started.documentHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress pending.progress? <|
    syncBarrierOutcome started pending.progress? pending.diagnosticsSeen barrierResult.hasFatalSnapshot
      pending.diagnostics barrierResult.directImports currentDiagnostics
  let fileProgress? := barrierOutcome.fileProgress?
  withFailureProgress fileProgress? <|
    liftHandlerIO <| started.document.recordProgress fileProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.document.session.root started.document.uri
    throw <| syncBarrierIncompleteFailure
      started.document.uri started.document.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics fileProgress?
  let replyDiagnostics? :=
    if request.diagnosticsInResult?.getD false then
      some <| streamDiagnosticsForReply started.document.session.root started.document.uri started.document.version
        (request.diagnosticScope?.getD .errors) currentDiagnostics
    else
      none
  let resultPath := trackedPathLabel started.document.session.root started.document.uri
  let syncResult :=
    mkSyncFileResult resultPath started.document.version currentDiagnostics saveReadiness replyDiagnostics?
  withFailureProgress fileProgress? <|
    started.document.recordCompletedSync
  liftHandlerIO <| traceBroker
    s!"sync_file response ready clientRequestId={optionLabel req.clientRequestId?} version={started.document.version} saveReady={saveReadiness.saveReady}"
  pure <| syncFileSuccessResponse syncResult fileProgress?

private def closeTrackedFileIfOpen
    (server : ServerRuntime)
    (req : WorkspaceRequest) : HandlerM Bool :=
  liftFailureIO <| server.withRequestSessionState req do
    if let .error failure ← fenceDocument req then return .error failure
    match ← storedSession? req.workspaceId with
    | some session =>
        let document ← requireRequestDocument req
        let closed := (session.docs.get? document.permit.uri).isSome
        let session ← closeFile session document.permit.uri
        updateSession session
        pure (.ok closed)
    | none => pure (.ok false)

private def handleUpdateFileOp
    (server : ServerRuntime)
    (req : WorkspaceRequest) :
    HandlerM Response := do
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <| readRequestSyncSnapshot server req
  let updated ← liftFailureIO <| server.withRequestSessionState req do
    withSessionForSnapshot req.workspaceId snapshot (cancelRef? := req.cancelRef?) (output? := req.output?) fun session => do
      let synced ← match ← syncAdmittedFileSnapshot req session snapshot with
        | .error failure => return .error failure
        | .ok synced => pure synced
      updateSession synced.session
      pure (.ok synced)
  pure <| Response.success (toJson ({
    version := updated.version
    changed := updated.changed
    : UpdateFileResult
  }))

private def handleCloseOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : CloseRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let path := (← liftHandlerIO <| requireRequestDocument req).path
  if request.saveArtifacts?.getD false then
    let saved ← saveOlean server req path (request.diagnosticScope?.getD .errors)
      emitProgress? emitDiagnostic? (closeAfter := true)
    finalizeSavedResponse saved true
  else
    let closed ← closeTrackedFileIfOpen server req
    pure <| Response.success (Json.mkObj [("closed", toJson closed)])

private def runAtSetupProgressEmitter?
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit)) :
    Option (StreamDiagnostic → IO Unit) :=
  emitDiagnostic?.map fun emitDiagnostic => fun diagnostic => do
    if isLakeSetupFileProgressStreamDiagnostic diagnostic then
      emitDiagnostic diagnostic

private def handleRunAtOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RunAtRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let method := runAtMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <| readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    startSyncedWorkspaceRequest server req snapshot method
      (fun uri => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some request.version : VersionedTextDocumentIdentifier }))
        , ("position", toJson ({ line := request.line, character := request.character : Lsp.Position }))
        , ("text", toJson request.text)
        ] ++
        match request.storeHandle? with
        | some b => [("storeHandle", toJson b)]
        | none => [])
      (expectedVersion? := some request.version)
      (emitProgress? := emitProgress?)
      (emitDiagnostic? := runAtSetupProgressEmitter? emitDiagnostic?)
  let pending ← awaitSyncedDocumentRequest started
  pure <|
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.document.session pending.result))
      pending.progress?

private def positionLspParams
    (request : RequestPosition)
    (uri : DocumentUri)
    (extraFields : List (String × Json) := []) : Json :=
  Json.mkObj <|
    [
      ("textDocument", toJson ({ uri := uri, version? := some request.version : VersionedTextDocumentIdentifier })),
      ("position", toJson ({ line := request.line, character := request.character : Lsp.Position }))
    ] ++ extraFields

private def handlePositionLspOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RequestPosition)
    (method : String)
    (extraFields : List (String × Json) := [])
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    startSyncedWorkspaceRequest server req snapshot method
      (fun uri => positionLspParams request uri extraFields)
      (expectedVersion? := some request.version)
      (position? := some { line := request.line, character := request.character })
      (emitProgress? := emitProgress?)
  let pending ← awaitSyncedDocumentRequest started
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleHoverOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RequestPosition)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := hoverMethod
  handlePositionLspOp server req request method
    (emitProgress? := emitProgress?)

private def handleSignatureHelpOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RequestPosition)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := signatureHelpMethod
  handlePositionLspOp server req request method
    (emitProgress? := emitProgress?)

private def handleDefinitionOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RequestPosition)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := definitionMethod
  handlePositionLspOp server req request method
    (emitProgress? := emitProgress?)

private def handleReferencesOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : ReferencesRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := referencesMethod
  handlePositionLspOp server req request.toRequestPosition method
    [("context", Json.mkObj [
      ("includeDeclaration", toJson (request.includeDeclaration?.getD true))
    ])]
    (emitProgress? := emitProgress?)

private def handleDocumentSymbolsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RequestVersionedFile)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := documentSymbolsMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    startSyncedWorkspaceRequest server req snapshot method
      (fun uri => Json.mkObj [
        ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
      ])
      (expectedVersion? := some request.version)
      (emitProgress? := emitProgress?)
  let pending ← awaitSyncedDocumentRequest started
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleWorkspaceSymbolsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : WorkspaceSymbolsRequest) :
    HandlerM Response := do
  let method := workspaceSymbolsMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let (session, pending) ← liftFailureIO <|
    server.withRequestSessionState req do
      let session ← match ← ensureSession req.workspaceId req.cancelRef? req.output? with
        | .error failure => return .error failure
        | .ok session => pure session
      let params := toJson ({ query := request.query : WorkspaceSymbolParams })
      let (session, pending) ← startRequestJsonTrackedDetailed session method params
        (clientRequestId? := req.clientRequestId?)
        (cancelRef? := req.cancelRef?)
      updateSession session
      pure (.ok (session, pending))
  liftHandlerIO <| propagatePendingCancellation session pending
  let result ← awaitPending pending
  withCurrentMatchingSession server req.cancelRef? session fun _ => pure ()
  pure <| Response.success result.result

private def codeActionResolveSourceUri
    (action : CodeAction) : Except ResponseFailure DocumentUri := do
  let some data := action.data?
    | throw <| responseFailureFor .invalidParams
        "code_action_resolve requires codeAction.data"
  let resolveData ←
    match (fromJson? data : Except String Lean.Server.CodeActionResolveData) with
    | .ok resolveData => pure resolveData
    | .error err =>
        throw <| responseFailureFor .invalidParams s!"invalid codeAction.data: {err}"
  pure resolveData.params.textDocument.uri

private def handleCodeActionResolveOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : CodeActionResolveRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := codeActionResolveMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let sourceUri ← requestArg <| codeActionResolveSourceUri request.codeAction
  if sourceUri != snapshot.uri then
    throw <| responseFailureFor .invalidParams
      s!"codeAction.data targets {sourceUri}, not requested document {snapshot.uri}"
  let started ← liftFailureIO <| server.withRequestSessionState req do
    startSyncedWorkspaceRequest server req snapshot method
      (fun _uri => toJson request.codeAction)
      (expectedVersion? := some request.version)
      (emitProgress? := emitProgress?)
  let pending ← awaitSyncedDocumentRequest started
  let resolved : CodeAction ← liftHandlerIO <| decodeResponseAs pending.result
  let payload : CodeActionResolveResult := {
    version := started.document.version
    codeAction := resolved
  }
  pure <| Response.withOptionalFileProgress (Response.success (toJson payload)) pending.progress?

private def handleSaveOleanOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : SaveOleanRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let path := (← liftHandlerIO <| requireRequestDocument req).path
  let saved ← saveOlean server req path (request.diagnosticScope?.getD .errors)
    emitProgress? emitDiagnostic?
  finalizeSavedResponse saved false

private def handleGoalsOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : GoalsRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := goalsMethod request.mode?
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    let position : Lsp.Position := { line := request.line, character := request.character }
    startSyncedWorkspaceRequest server req snapshot method
      (fun uri => Json.mkObj [
        ("textDocument", toJson ({ uri := uri, version? := some request.version : VersionedTextDocumentIdentifier })),
        ("position", toJson position)
      ])
      (expectedVersion? := some request.version)
      (emitProgress? := emitProgress?)
  let pending ← awaitSyncedDocumentRequest started
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleTodoOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : TodoRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := todoMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let range : Lsp.Range := {
    start := { line := request.line, character := request.character }
    «end» := { line := request.endLine, character := request.endCharacter }
  }
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    startSyncedWorkspaceRequest server req snapshot method
      (fun uri => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some request.version : VersionedTextDocumentIdentifier }))
        , ("range", toJson range)
        ] ++
        (match request.kinds? with
        | some kinds => [("kinds", toJson kinds)]
        | none => []) ++
        (match request.suggest? with
        | some suggest => [("suggest", toJson suggest)]
        | none => []))
      (expectedVersion? := some request.version)
      (emitProgress? := emitProgress?)
  let pending ← awaitSyncedDocumentRequest started
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleRunWithOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : RunWithRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := runWithMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    match ← resolveCurrentHandle req.workspaceId request.handle with
    | .error resp => pure (.error resp)
    | .ok (session, rawHandle) =>
        let startedResult ← startSyncedDocumentRequest server session snapshot method
          (fun uri => Json.mkObj <|
            [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
            , ("handle", rawHandle)
            , ("text", toJson request.text)
            ] ++ (match request.storeHandle? with
            | some b => [("storeHandle", toJson b)]
            | none => []) ++
            (match request.linear? with
            | some b => [("linear", toJson b)]
            | none => []))
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := req.cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest started
  pure <|
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.document.session pending.result))
      pending.progress?

private def handleReleaseOp
    (server : ServerRuntime)
    (req : WorkspaceRequest)
    (request : ReleaseRequest)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method := releaseMethod
  liftFailureIO <| ensureRequestNotCancelled req.cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req
  let started ← liftFailureIO <| server.withRequestSessionState req do
    match ← resolveCurrentHandle req.workspaceId request.handle with
    | .error resp => pure (.error resp)
    | .ok (session, rawHandle) =>
        let startedResult ← startSyncedDocumentRequest server session snapshot method
          (fun uri => Json.mkObj [
            ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
            ("handle", rawHandle)
          ])
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := req.cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest started
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def initWorkspaceConfigFromRequest
    (server : ServerRuntime)
    (request : InitWorkspaceRequest) : IO (Except ResponseFailure BrokerConfig) := do
  let root ←
    try
      resolveRoot (System.FilePath.mk request.root)
    catch e =>
      return .error (responseFailureFor .invalidParams e.toString)
  if let some admit := server.admission? then return ← admit root
  let bootstrap ← server.withState do pure (← get).bootstrapConfig
  if root == bootstrap.root then return .ok bootstrap
  pure <| .error <| responseFailureFor .invalidParams
    "workspace creation is not configured for this root"

private def admitWorkspaceUse (server : ServerRuntime) (req : WorkspaceRequest) :
    IO (Except ResponseFailure Unit) := do
  let some admit := server.admission? | return .ok ()
  let config? ← server.withState do pure <| (getWorkspace? (← get) req.workspaceId).map (·.config)
  let some retained := config? | return .error <| responseFailureFor .invalidParams "workspace was dropped"
  match ← admit retained.root with
  | .error failure => return .error failure
  | .ok current =>
      unless current == retained do
        return .error <| responseFailureFor .invalidParams
          "workspace target changed; drop and recreate the workspace before retrying"
      return .ok ()

private def handleRequestIO
    (server : ServerRuntime)
    (req : Request)
    (activeRequest? : Option ActiveRequest := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (output? : Option Beam.WorkspaceOutput.Buffer := none) : IO Response := do
  let cancelRef? := activeRequest?.map (·.cancelRef)
  match req.payload with
  | .shutdown =>
      server.close
      pure <| Response.success (Json.mkObj [("shutdown", toJson true)])
  | .stats =>
      match req.workspaceId? with
      | none => server.statsResponse
      | some _ =>
          match ← validateRequestWorkspace server req cancelRef? output? with
          | .error failure => pure failure.toResponse
          | .ok workspaceReq =>
              server.statsResponse (some workspaceReq.workspaceId)
  | .listWorkspaces =>
      let payload ← server.withState do
        pure <| workspaceListPayload (← get)
      pure <| Response.success payload
  | .openDocs =>
      match req.workspaceId? with
      | none => pure <| Response.success (← server.withState openDocsPayload)
      | some _ =>
          match ← validateRequestWorkspace server req cancelRef? output? with
          | .error failure => pure failure.toResponse
          | .ok workspaceReq =>
              pure <| Response.success
                (← server.withState <| openDocsPayload (some workspaceReq.workspaceId))
  | .initWorkspace request =>
      match req.requireWorkspaceId with
      | .error err => pure <| errorResponseFor .invalidParams err
      | .ok workspaceId =>
          match ← initWorkspaceConfigFromRequest server request with
          | .error failure => pure failure.toResponse
          | .ok config =>
              let result ← server.initWorkspaceWithConfig workspaceId config request.workspaceMode?
              pure <| responseOfTypedResult result
  | .dropWorkspace =>
      match req.requireWorkspaceId with
      | .error err => pure <| errorResponseFor .invalidParams err
      | .ok workspaceId =>
          let result ← server.dropWorkspace workspaceId
          pure <| responseOfTypedResult result
  | .cancel targetClientRequestId =>
      let cancelled ← cancelActiveRequest server req.resolvedWorkspaceId? targetClientRequestId
      pure <| Response.success (toJson ({ cancelled } : CancelResult))
  | payload =>
      match ← validateRequestWorkspace server req cancelRef? output? with
      | .error failure => pure failure.toResponse
      | .ok workspaceReq =>
          withDocumentAdmission server workspaceReq payload fun workspaceReq => do
            if payload.op.usesSession then
              match ← admitWorkspaceUse server workspaceReq with
              | .error failure => return failure.toResponse
              | .ok () => pure ()
            match payload with
            | .ensure =>
                let resp ←
                  try
                    let result ← server.withRequestSessionState workspaceReq do
                      let session ← match ← ensureSession workspaceReq.workspaceId workspaceReq.cancelRef? workspaceReq.output? with
                        | .error failure => return .error failure
                        | .ok session => pure session
                      let payload := Json.mkObj [
                        ("workspace_id", toJson workspaceReq.workspaceId),
                        ("root", toJson session.root.toString),
                        ("epoch", toJson session.epoch)
                      ]
                      pure <| .ok <| Response.success payload
                    match result with
                    | .error failure => pure failure.toResponse
                    | .ok response => pure response
                  catch e =>
                    pure <| errorResponseFor .internalError e.toString
                pure resp
            | .updateFile _ =>
                runHandler <| handleUpdateFileOp server workspaceReq
            | .syncFile request =>
                runHandler <|
                  handleSyncFileOp server workspaceReq request emitProgress? emitDiagnostic?
            | .refreshFile request =>
                runHandler <|
                  handleSyncFileOp server workspaceReq request emitProgress? emitDiagnostic?
                    (refresh := true)
            | .close request =>
                runHandler <|
                  handleCloseOp server workspaceReq request emitProgress? emitDiagnostic?
            | .runAt request =>
                runHandler <|
                  handleRunAtOp server workspaceReq request emitProgress? emitDiagnostic?
            | .hover request =>
                runHandler <| handleHoverOp server workspaceReq request emitProgress?
            | .signatureHelp request =>
                runHandler <|
                  handleSignatureHelpOp server workspaceReq request emitProgress?
            | .definition request =>
                runHandler <| handleDefinitionOp server workspaceReq request emitProgress?
            | .references request =>
                runHandler <| handleReferencesOp server workspaceReq request emitProgress?
            | .documentSymbols request =>
                runHandler <|
                  handleDocumentSymbolsOp server workspaceReq request emitProgress?
            | .workspaceSymbols request =>
                runHandler <| handleWorkspaceSymbolsOp server workspaceReq request
            | .codeActionResolve request =>
                runHandler <|
                  handleCodeActionResolveOp server workspaceReq request emitProgress?
            | .saveOlean request =>
                runHandler <|
                  handleSaveOleanOp server workspaceReq request emitProgress? emitDiagnostic?
            | .goals request =>
                runHandler <| handleGoalsOp server workspaceReq request emitProgress?
            | .todo request =>
                runHandler <| handleTodoOp server workspaceReq request emitProgress?
            | .runWith request =>
                runHandler <| handleRunWithOp server workspaceReq request emitProgress?
            | .release request =>
                runHandler <| handleReleaseOp server workspaceReq request emitProgress?
            | .openDocs | .stats | .shutdown
            | .cancel _ | .initWorkspace _ | .listWorkspaces | .dropWorkspace =>
                unreachable!

private def ServerRuntime.withRequestAdmission
    (server : ServerRuntime)
    (req : Request)
    (act : RequestHandle → IO Response) : IO Response := do
  let startedAt ← IO.monoNanosNow
  let workspaceGeneration? ←
    if req.op.usesSession then
      match req.resolvedWorkspaceId? with
      | some workspaceId => server.withState do
          pure <| (getWorkspace? (← get) workspaceId).map (·.generation)
      | none => pure none
    else pure none
  let recordMetrics := fun (resp : Response) =>
    recordDispatchMetrics server req workspaceGeneration? resp startedAt
  traceBroker
    s!"dispatch start op={req.op.key} clientRequestId={optionLabel req.clientRequestId?}"
  match server.mode with
  | .standalone _ => pure ()
  | .wrapper _ expected =>
      unless req.daemonCapability? == some expected do
        let resp := errorResponseFor .invalidParams "invalid Beam daemon capability"
        recordMetrics resp
        return resp
      if req.op == .initWorkspace || req.op == .listWorkspaces || req.op == .dropWorkspace then
        let resp := errorResponseFor .invalidParams
          s!"broker op '{req.op.key}' is unavailable in wrapper-owned daemon mode"
        recordMetrics resp
        return resp
  match req.validateFields with
  | .error err =>
      let resp := errorResponseFor .invalidParams err
      traceBroker
        s!"dispatch rejected op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} error={err}"
      recordMetrics resp
      return resp
  | .ok () => pure ()
  try
    let active? ←
      if req.op.tracksActiveRequest then
        match ← ActiveRequestRegistry.register
            server.activeRequests req.resolvedWorkspaceId? req.clientRequestId? with
        | .ok active => pure (some active)
        | .error failure =>
            let resp := BrokerFailure.toResponse failure
            recordMetrics resp
            return resp
      else
        pure none
    try
      let handle : RequestHandle := { runtime := server, active? }
      let resp ← act handle
      traceBroker
        s!"dispatch complete op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} ok={resp.ok}"
      recordMetrics resp
      pure resp
    finally
      ActiveRequestRegistry.unregister server.activeRequests active?
  catch e =>
    let resp := errorResponseFor .internalError e.toString
    traceBroker
      s!"dispatch exception op={req.op.key} clientRequestId={optionLabel req.clientRequestId?} error={e.toString}"
    recordMetrics resp
    pure resp

/--
Admit `req`, expose its exact cancellation handle to `beforeDispatch`, and
retain broker ownership of the one allowed dispatch.

When `beforeDispatch` returns `false`, the request is unregistered without
dispatch and receives a `requestCancelled` response. Registration cleanup also
runs if `beforeDispatch` or the request handler throws. Operation field-shape
errors are rejected before admission and do not invoke `beforeDispatch`.
-/
def ServerRuntime.dispatchRequestWithHandle
    (server : ServerRuntime)
    (req : Request)
    (beforeDispatch : RequestHandle → IO Bool)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (output? : Option Beam.WorkspaceOutput.Buffer := none) : IO Response := do
  server.withRequestAdmission req fun handle => do
    unless ← beforeDispatch handle do
      return BrokerFailure.toResponse {
        code := .requestCancelled
        message := "request was cancelled before broker dispatch"
      }
    handleRequestIO server req handle.active? emitProgress? emitDiagnostic? output?

def ServerRuntime.dispatchRequest
    (server : ServerRuntime)
    (req : Request)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (output? : Option Beam.WorkspaceOutput.Buffer := none) : IO Response := do
  server.dispatchRequestWithHandle req (fun _ => pure true) emitProgress? emitDiagnostic? output?

private def rootWatchPollMs : UInt32 :=
  250

/--
A standalone daemon cannot rely on its registry after the project directory disappears: the
default registry lives below that directory and is removed with it. Stop the broker proactively so
removing a git worktree does not strand either the daemon or its backend processes.
-/
private partial def watchRoot
    (server : ServerRuntime)
    (transport : DaemonTransport)
    (root : System.FilePath) : IO Unit := do
  if ← transport.stop.get then
    pure ()
  else
    let rootAvailable ←
      try
        root.isDir
      catch _ =>
        pure false
    if !rootAvailable then
      IO.eprintln s!"Beam daemon root is no longer available; shutting down: {root}"
      closeAndRequestStop server transport
    else
      IO.sleep rootWatchPollMs
      watchRoot server transport root

private def watchSessionOwnerStdin
    (server : ServerRuntime)
    (transport : DaemonTransport) : IO Unit := do
  try
    discard <| (← IO.getStdin).readToEnd
  catch _ =>
    pure ()
  unless ← transport.stop.get do
    closeAndRequestStop server transport

private def watchClientDisconnectUntil
    (client : Transport.Connection)
    (requestDone : IO Bool)
    (disconnect : IO Unit) : IO Unit := do
  try
    -- One request per connection. A second message is invalid too.
    match ← Transport.recvMsgInterruptibly client requestDone with
    | .completed _ => disconnect
    | .interrupted => pure ()
  catch _ =>
    unless ← requestDone do disconnect

private def handleClient
    (server : ServerRuntime)
    (transport : DaemonTransport)
    (client : Transport.Connection) : IO Unit := do
  let abandoned ← IO.mkRef false
  let outputStarted ← IO.mkRef false
  let clientRequestId ← IO.mkRef (none : Option String)
  let sendResponse (id? : Option String) (response : Response) : IO Unit := do
    outputStarted.set true
    Transport.sendMsg client (toJson (StreamMessage.response id? response)).compress
  try
    if let some identity := server.mode.wrapperIdentity? then
      outputStarted.set true
      Transport.sendMsg client (toJson (ServerHello.current identity)).compress
      outputStarted.set false
    let deadlineNanos := (← IO.monoNanosNow) + 5000 * 1000000
    let some msg ← Transport.recvMsgUntil client deadlineNanos
      | throw <| IO.userError "Beam daemon initial request timed out after 5000 ms"
    let request : Except ResponseFailure Request := do
      let json ← (Json.parse msg).mapError fun error =>
        responseFailureFor .invalidParams s!"invalid request json: {error}"
      (fromJson? json).mapError fun error =>
        responseFailureFor .invalidParams s!"invalid request payload: {error}"
    match request with
    | .error failure =>
        let id? := (Json.parse msg).toOption.bind fun json =>
          (json.getObjValAs? String "clientRequestId").toOption
        sendResponse id? failure.toResponse
    | .ok req =>
        clientRequestId.set req.clientRequestId?
        let text ← Beam.WorkspaceOutput.Buffer.create
        let output ← Output.Queue.create text
        let disconnected ← IO.mkRef false
        let requestDone ← IO.mkRef false
        let handleRef ← IO.mkRef (none : Option RequestHandle)
        let watcherRef ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
        let cancel : IO Unit := do
          disconnected.set true
          text.discard
          if let some handle ← handleRef.get then discard <| handle.cancel
        let execution ← IO.asTask (prio := Task.Priority.dedicated) do
          try
            server.dispatchRequestWithHandle req (fun handle => do
              handleRef.set (some handle)
              if ← disconnected.get then return false
              let watcher ← IO.asTask (prio := Task.Priority.dedicated) <|
                watchClientDisconnectUntil client requestDone.get cancel
              watcherRef.set (some watcher)
              pure true)
              (some (output.progress req.clientRequestId?))
              (some (output.diagnostic req.clientRequestId?)) (some text)
          finally
            -- Pending delivery retains no active broker admission handle.
            handleRef.set none
        try
          discard <| output.run execution some req.clientRequestId? fun message => do
            let frame := (toJson message).compress
            let stop := do return (← disconnected.get) || (← output.failed) || (← transport.stop.get)
            outputStarted.set true
            match ← Transport.sendMsgInterruptibly client frame stop with
            | .completed () => pure ()
            | .interrupted => throw <| IO.userError "broker output connection interrupted"
        finally
          -- Stop the exact execution before joining it; display must not own cleanup.
          try cancel
          finally
            discard <| IO.wait execution
            requestDone.set true
            if let some watcher ← watcherRef.get then discard <| IO.wait watcher
            if req.op == .shutdown && (← server.closeStarted) then requestStop transport
  catch error =>
    let reported ← if ← outputStarted.get then pure false else
      try
        sendResponse (← clientRequestId.get) (errorResponseFor .internalError error.toString)
        pure true
      catch _ => pure false
    unless reported do
      -- A send may have emitted a partial frame. Never append a replacement response.
      abandoned.set true
      Transport.abandonConnection client
  finally
    unless ← abandoned.get do Transport.closeConnection client

private partial def acceptLoop
    (server : ServerRuntime)
    (transport : DaemonTransport) : IO Unit := do
  if ← transport.stop.get then
    pure ()
  else
    let client ← Transport.accept transport.listener
    if ← transport.stop.get then
      Transport.closeConnection client
    else
      if ← transport.clientPermits.tryAcquire then
        let serve := do
          try
            handleClient server transport client
          catch e =>
            IO.eprintln s!"broker client task failed: {e.toString}"
        let _ ← IO.asTask (prio := Task.Priority.dedicated) do
          try
            serve
          finally
            transport.clientPermits.release
      else
        Transport.closeConnection client
      acceptLoop server transport

private structure CliOptions where
  endpoint : Transport.Endpoint := .tcp 8765
  root? : Option String := none
  workspaceId? : Option WorkspaceId := none
  daemonId? : Option String := none
  configHash? : Option String := none
  sessionOwnerStdin : Bool := false

private def parseNatArg (name value : String) : Except String Nat := do
  let some n := value.toNat?
    | throw s!"invalid {name} '{value}'"
  pure n

private def parsePortArg (value : String) : Except String UInt16 := do
  let port ← parseNatArg "port" value
  if port < UInt16.size then
    pure port.toUInt16
  else
    throw s!"port '{value}' is outside the supported range 0-65535"

private partial def parseCliOptions (opts : CliOptions) : List String → Except String CliOptions
  | [] => pure opts
  | "--port" :: port :: rest => do
      let port ← parsePortArg port
      parseCliOptions { opts with endpoint := .tcp port } rest
  | "--root" :: root :: rest =>
      parseCliOptions { opts with root? := some root } rest
  | "--workspace-id" :: workspaceId :: rest =>
      parseCliOptions { opts with workspaceId? := some workspaceId } rest
  | "--daemon-id" :: daemonId :: rest =>
      parseCliOptions { opts with daemonId? := some daemonId } rest
  | "--config-hash" :: configHash :: rest =>
      parseCliOptions { opts with configHash? := some configHash } rest
  | "--session-owner-stdin" :: rest =>
      parseCliOptions { opts with sessionOwnerStdin := true } rest
  | arg :: _ =>
      throw s!"unexpected Beam daemon argument '{arg}'"

private abbrev DaemonWatcherTask := Task (Except IO.Error Unit)

private structure DaemonResources where
  runtime : ServerRuntime
  transport : DaemonTransport
  rootWatcher : DaemonWatcherTask
  ownerWatcher? : Option DaemonWatcherTask

private def closeDaemonParts
    (runtime : ServerRuntime)
    (transport : DaemonTransport)
    (rootWatcher? ownerWatcher? : Option DaemonWatcherTask) : IO Unit := do
  let firstError? ← recordFirstCleanupError none <| transport.stop.set true
  let firstError? ← recordFirstCleanupError firstError? <|
    Transport.closeListener transport.listener
  let firstError? ←
    match ownerWatcher? with
    | none => pure firstError?
    | some ownerWatcher =>
        recordFirstCleanupError firstError? do
          try
            IO.cancel ownerWatcher
          finally
            discard <| IO.wait ownerWatcher
  let firstError? ←
    match rootWatcher? with
    | none => pure firstError?
    | some rootWatcher =>
        recordFirstCleanupError firstError? do
          discard <| IO.wait rootWatcher
  let firstError? ← recordFirstCleanupError firstError? runtime.close
  if let some err := firstError? then
    throw err

private def DaemonResources.close (resources : DaemonResources) : IO Unit :=
  closeDaemonParts resources.runtime resources.transport (some resources.rootWatcher)
    resources.ownerWatcher?

private def throwAfterBestEffortCleanup
    (err : IO.Error)
    (cleanup : IO Unit) : IO α := do
  try
    cleanup
  catch _ =>
    pure ()
  throw err

private def acquireDaemonResources
    (opts : CliOptions)
    (admission : WorkspaceAdmission)
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (mode : ServerMode)
    (root : System.FilePath) : IO DaemonResources := do
  let runtime ← ServerRuntime.create config workspaceId mode (some admission)
  let transport ←
    try
      DaemonTransport.create opts.endpoint
    catch err =>
      throwAfterBestEffortCleanup err runtime.close
  let rootWatcher ←
    try
      IO.asTask (prio := Task.Priority.dedicated) <| watchRoot runtime transport root
    catch err =>
      throwAfterBestEffortCleanup err <| closeDaemonParts runtime transport none none
  let ownerWatcher? ←
    try
      match mode with
      | .wrapper _ _ =>
          some <$> IO.asTask (prio := Task.Priority.dedicated)
            (watchSessionOwnerStdin runtime transport)
      | .standalone _ => pure none
    catch err =>
      throwAfterBestEffortCleanup err <|
        closeDaemonParts runtime transport (some rootWatcher) none
  pure { runtime, transport, rootWatcher, ownerWatcher? }

/-- Acquire the daemon runtime, listener, and watcher tasks for exactly the dynamic extent of `act`. -/
private def withDaemonResources
    (opts : CliOptions)
    (admission : WorkspaceAdmission)
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (mode : ServerMode)
    (root : System.FilePath)
    (act : DaemonResources → IO α) : IO α := do
  let resources ← acquireDaemonResources opts admission config workspaceId mode root
  try
    act resources
  finally
    resources.close

private def emitWrapperReady
    (transport : DaemonTransport)
    (identity : DaemonIdentity) : IO Unit := do
  let ready := Beam.Daemon.StartupReady.ofEndpoint transport.endpoint identity
  let stdout ← IO.getStdout
  stdout.putStrLn ready.encodeLine
  stdout.flush

/-- Shipped applications must supply installation admission; argv cannot select components. -/
def runDaemon (resolve : System.FilePath → IO (BrokerConfig × String))
    (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parseCliOptions {} args
  let some root := opts.root?
    | throw <| IO.userError "missing Beam daemon --root PATH"
  let some workspaceId := opts.workspaceId?
    | throw <| IO.userError "missing Beam daemon --workspace-id ID"
  unless validWorkspaceId workspaceId do
    throw <| IO.userError "workspace id must be non-empty"
  let root ← Beam.resolveExistingPath <| System.FilePath.mk root
  let (config, expectedHash) ← resolve root
  if let some suppliedHash := opts.configHash? then
    unless suppliedHash == expectedHash do
      throw <| IO.userError "daemon configuration does not belong to this installation and target"
  let admission : WorkspaceAdmission := fun selectedRoot => do
    try return .ok (← resolve selectedRoot).1
    catch error => return .error <| responseFailureFor .invalidParams error.toString
  let daemonIdentity? ←
    match opts.daemonId?, opts.configHash? with
    | none, none => pure none
    | some daemonId, some configHash =>
        if daemonId.isEmpty || configHash.isEmpty then
          throw <| IO.userError "daemon identity values must be non-empty"
        pure <| some { daemonId, configHash }
    | some _, none =>
        throw <| IO.userError "--daemon-id requires --config-hash"
    | none, some _ =>
        throw <| IO.userError "--config-hash requires --daemon-id"
  let mode : ServerMode ←
    if opts.sessionOwnerStdin then
      let some identity := daemonIdentity?
        | throw <| IO.userError
            "wrapper-owned Beam daemon identity and stdin capability must be supplied together"
      let capability := (← (← IO.getStdin).getLine).trimAscii.toString
      if capability.isEmpty then
        throw <| IO.userError "wrapper-owned Beam daemon received an empty capability"
      pure <| .wrapper identity capability
    else
      pure <| .standalone daemonIdentity?
  withDaemonResources opts admission config workspaceId mode root fun resources => do
    match mode with
    | .wrapper identity _ => emitWrapperReady resources.transport identity
    | .standalone _ => pure ()
    acceptLoop resources.runtime resources.transport

end Beam.Broker
