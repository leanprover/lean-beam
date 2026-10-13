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
import Beam.Broker.Config
import Beam.Broker.DocumentState
import Beam.Broker.Errors
import Beam.Broker.Metrics
import Beam.Broker.OpenDocs
import Beam.Broker.Pending
import Beam.Broker.Protocol
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
  backend : Backend
  root : System.FilePath
  epoch : Nat
  sessionToken : String
  proc : IO.Process.Child brokerStdio
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  stderrCapture : BackendStderrCapture
  pending : PendingRequestStore
  /-- Allocate fresh Lean/Rocq revisions across all document lifetimes in this session. -/
  nextDocumentVersion : Nat := 1
  nextId : Nat := 1
  nextEventSeq : Nat := 1
  moduleHistory : Std.TreeMap String ModuleHistory := {}
  docs : Std.TreeMap String DocState := {}

private def Session.snapshotRef (session : Session) (version : Nat) : SnapshotRef :=
  { session := session.sessionToken, revision := version }

structure BackendState where
  nextEpoch : Nat := 1
  session? : Option Session := none

structure WorkspaceState where
  generation : Nat
  config : BrokerConfig
  nextFileSnapshotSeq : Nat := 1
  lean : BackendState := {}
  rocq : BackendState := {}
  leanMetrics : BackendMetrics := {}
  rocqMetrics : BackendMetrics := {}

structure State where
  bootstrapConfig : BrokerConfig
  startMonoNanos : Nat := 0
  nextWorkspaceGeneration : Nat := 2
  workspaces : Std.TreeMap WorkspaceId WorkspaceState := {}
  streamSink? : Option (StreamMessage → IO Unit) := none
  currentClientRequestId? : Option String := none

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

private def requestMethod (method : Except String String) : HandlerM String :=
  match method with
  | .ok method => pure method
  | .error msg => throw <| responseFailureFor .invalidParams msg

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

private def resolvePath (root : System.FilePath) (path : System.FilePath) : IO System.FilePath :=
  Beam.resolvePathAgainstRoot root path

def sessionUri (path : System.FilePath) : String :=
  (System.Uri.pathToUri path : String)

private def backendName : Backend → String
  | .lean => "Lean"
  | .rocq => "Rocq"

private def BackendStderrCapture.snapshot (capture : BackendStderrCapture) : IO String := do
  Beam.StderrCapture.snapshot capture

private def backendFailureMessage
    (backend : Backend)
    (phase cause : String)
    (capture : BackendStderrCapture) : IO String := do
  let stderr := (← capture.snapshot).trimAscii.toString
  let stderr := if stderr.isEmpty then "<empty>" else stderr
  pure <| String.intercalate "\n" [
    s!"{backendName backend} backend failed {phase}: {cause}",
    s!"backend stderr tail (last {backendStderrTailLimit} bytes):",
    stderr
  ]

private def sessionShutdownReplyTimeoutMs : Nat :=
  1000

private def killCommand? : IO (Option System.FilePath) := do
  for candidate in [System.FilePath.mk "/bin/kill", System.FilePath.mk "/usr/bin/kill"] do
    if ← candidate.pathExists then
      return some candidate
  pure none

private partial def waitForProcessExitWithTimeout
    (proc : IO.Process.Child brokerStdio)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO Bool := do
  let rec loop (remainingMs : Nat) : IO Bool := do
    match ← (try
      proc.tryWait
    catch _ =>
      pure none) with
    | some _ => pure true
    | none =>
        if remainingMs == 0 then
          pure false
        else
          let sleepMs := min (max pollMs 1) remainingMs
          IO.sleep sleepMs.toUInt32
          loop (remainingMs - sleepMs)
  loop timeoutMs

private def terminateBackendProcess (proc : IO.Process.Child brokerStdio) : IO Bool := do
  let running ←
    try
      pure (← proc.tryWait).isNone
    catch _ =>
      pure true
  if running then
    try
      proc.kill
    catch _ =>
      pure ()
    unless ← waitForProcessExitWithTimeout proc sessionShutdownReplyTimeoutMs do
      try
        if let some kill := ← killCommand? then
          let _ ← IO.Process.output {
            cmd := kill.toString
            args := #["-9", toString proc.pid.toNat]
          }
          pure ()
      catch _ =>
        pure ()
      discard <| waitForProcessExitWithTimeout proc sessionShutdownReplyTimeoutMs
  try
    pure (← proc.tryWait).isSome
  catch _ =>
    pure false

private def finishBackendStderrCapture
    (capture : BackendStderrCapture)
    (leaderReaped : Bool) : IO Beam.StderrCaptureOutcome := do
  if leaderReaped then
    capture.finishAfterWriterExit
  else
    pure .pipeStillOpen

private def startBackendStderrCaptureOrTerminate
    (backend : Backend)
    (proc : IO.Process.Child brokerStdio) : IO BackendStderrCapture := do
  try
    startBackendStderrCapture proc.stderr
  catch err =>
    discard <| terminateBackendProcess proc
    throw <| IO.userError <|
      s!"{backendName backend} backend failed during startup before stderr capture: {err}"

private def terminateBackendFailure
    (backend : Backend)
    (phase cause : String)
    (proc : IO.Process.Child brokerStdio)
    (capture : BackendStderrCapture) : IO String := do
  let leaderReaped ← terminateBackendProcess proc
  let captureOutcome ← finishBackendStderrCapture capture leaderReaped
  let message ← backendFailureMessage backend phase cause capture
  pure <| match captureOutcome with
    | .drained => message
    | .sourceFailed err =>
        message ++ s!"\nbackend stderr source also failed while draining: {err}"
    | .pipeStillOpen =>
        message ++ "\nbackend stderr pipe remained open; its bounded capture remains active"

private def sessionExited (session : Session) : IO Bool := do
  try
    pure (← session.proc.tryWait).isSome
  catch _ =>
    pure true

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

private def getBackendState (workspace : WorkspaceState) (backend : Backend) : BackendState :=
  match backend with
  | .lean => workspace.lean
  | .rocq => workspace.rocq

private def setBackendState
    (workspace : WorkspaceState)
    (backend : Backend)
    (backendState : BackendState) : WorkspaceState :=
  match backend with
  | .lean => { workspace with lean := backendState }
  | .rocq => { workspace with rocq := backendState }

private def detachBackendSession
    (backend : BackendState) : BackendState × Option Session :=
  match backend.session? with
  | none => (backend, none)
  | some session =>
      ({ backend with session? := none, nextEpoch := backend.nextEpoch + 1 }, some session)

private def getBackendMetrics (workspace : WorkspaceState) (backend : Backend) : BackendMetrics :=
  match backend with
  | .lean => workspace.leanMetrics
  | .rocq => workspace.rocqMetrics

private def setBackendMetrics
    (workspace : WorkspaceState)
    (backend : Backend)
    (metrics : BackendMetrics) : WorkspaceState :=
  match backend with
  | .lean => { workspace with leanMetrics := metrics }
  | .rocq => { workspace with rocqMetrics := metrics }

private def recordSessionSpawn (workspaceId : WorkspaceId) (backend : Backend) (restart : Bool) : M Unit := do
  modify fun state =>
    match getWorkspace? state workspaceId with
    | none => state
    | some workspace =>
        let metrics := getBackendMetrics workspace backend
        let metrics := {
          metrics with
          sessionStarts := metrics.sessionStarts + 1
          sessionRestarts := metrics.sessionRestarts + (if restart then 1 else 0)
        }
        setWorkspace state workspaceId (setBackendMetrics workspace backend metrics)

private def recordRequestMetrics
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (backend : Backend)
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
          let metrics := getBackendMetrics workspace backend
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
          setWorkspace state workspaceId (setBackendMetrics workspace backend metrics)

private def sessionSnapshotJson (session? : Option Session) : Json :=
  match session? with
  | none => Json.mkObj [("active", toJson false)]
  | some session =>
      Json.mkObj [
        ("active", toJson true),
        ("workspaceId", toJson session.workspaceId),
        ("root", toJson session.root.toString),
        ("epoch", toJson session.epoch),
        ("openDocCount", toJson session.docs.toList.length)
      ]

private def workspaceStatsJson (workspaceId : WorkspaceId) (workspace : WorkspaceState) : Json :=
  Json.mkObj [
    ("id", toJson workspaceId),
    ("root", toJson workspace.config.root.toString),
    ("sessions", Json.mkObj [
      ("lean", sessionSnapshotJson workspace.lean.session?),
      ("rocq", sessionSnapshotJson workspace.rocq.session?)
    ]),
    ("byBackend", Json.mkObj [
      ("lean", backendMetricsJson workspace.leanMetrics),
      ("rocq", backendMetricsJson workspace.rocqMetrics)
    ])
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
    (pending : PendingRequest) : HandlerM PendingResult := do
  let doneRef ← liftHandlerIO <| IO.mkRef false
  liftHandlerIO <| startWaitDiagnosticsWatchdog label doneRef
  let outcome ← liftHandlerIO <| do
    try
      let outcome ← pending.awaitOutcome
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
              PendingRequest.observePublishDiagnostics session.root session.sessionToken req diagnosticParam
        | .error _ =>
            pure ()
    | _ =>
        pure ()
    sessionReaderLoop session
  catch e =>
    let message ←
      terminateBackendFailure session.backend "after startup" e.toString
        session.proc session.stderrCapture
    PendingRequestStore.failAll session.pending <| BrokerFailure.toResponseFailure {
      code := .workerExited
      message
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
  PendingRequestStore.insert session.pending id pending
  traceBroker
    s!"lsp request inserted id={id} method={method} clientRequestId={optionLabel clientRequestId?} tracked={tracked.isSome}"
  try
    writeLspRequest session.stdin ({ id, method, param : Lean.JsonRpc.Request Json })
    traceBroker s!"lsp request sent id={id} method={method}"
    pure (session, pending)
  catch e =>
    discard <| PendingRequestStore.remove session.pending id
    traceBroker s!"lsp request send failed id={id} method={method} error={e.toString}"
    try
      promise.resolve (.error (responseFailureFor .internalError e.toString))
    catch _ =>
      pure ()
    throw e

private def shutdownSession (session : Session) : IO Unit := do
  let session ←
    try
      let (session, pending) ←
        startRequestJsonTrackedDetailed session "shutdown" Json.null
      let task ← IO.asTask (prio := Task.Priority.dedicated) pending.awaitOutcome
      if (← Beam.waitTaskWithTimeout task sessionShutdownReplyTimeoutMs).isNone then
        PendingRequestStore.failAll session.pending <| BrokerFailure.toResponseFailure {
          code := .workerExited
          message := "backend session shutdown timed out"
        }
        discard <| Beam.waitTaskWithTimeout task sessionShutdownReplyTimeoutMs
      pure session
    catch _ =>
      pure session
  try
    writeLspNotification session.stdin
      ({ method := "exit", param := Json.null : Lean.JsonRpc.Notification Json })
  catch _ =>
    pure ()
  let leaderReaped ←
    if ← waitForProcessExitWithTimeout session.proc sessionShutdownReplyTimeoutMs then
      pure true
    else
      terminateBackendProcess session.proc
  match ← finishBackendStderrCapture session.stderrCapture leaderReaped with
  | .drained => pure ()
  | .sourceFailed err =>
      throw <| IO.userError s!"backend stderr source failed while draining: {err}"
  | .pipeStillOpen =>
      -- A descendant can retain the pipe after the backend leader is reaped. This is an explicit
      -- bounded resource outcome, not a reason to make an otherwise completed shutdown fail.
      traceBroker "backend stderr remained open after its leader exited"

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

private def backendInitializeTimeoutMs : Nat :=
  30000

/--
Acquire a fully initialized backend session or terminate the provisional child before failing.

The caller adopts the returned session into broker state. No child ownership escapes this function
until the initialization response and `initialized` notification have both completed.
-/
private def acquireBackendSession
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (backend : Backend)
    (config : BrokerConfig)
    (epoch : Nat) : IO Session := do
  let root := config.root
  let (cmd, args, env) ← backendCommand config backend
  let proc ← IO.Process.spawn {
    toStdioConfig := brokerStdio
    cmd := cmd
    args := args
    env := env
    cwd := root.toString
  }
  let stderrCapture ← startBackendStderrCaptureOrTerminate backend proc
  let (session, initializeTask) ←
    try
      let stdin := IO.FS.Stream.ofHandle proc.stdin
      let stdout := IO.FS.Stream.ofHandle proc.stdout
      let pending ← PendingRequestStore.create
      let sessionToken ← mkSessionToken
      let session : Session := {
        workspaceId
        workspaceGeneration
        backend
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
        ({ id := 0, method := "initialize", param := initializeParams backend root
          : Lean.JsonRpc.Request Json })
      let initializeTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        awaitInitializeResponse stdout
      pure (session, initializeTask)
    catch err =>
      throw <| IO.userError <| ←
        terminateBackendFailure backend "during startup" err.toString proc stderrCapture
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
    pure session
  catch err =>
    IO.cancel initializeTask
    let message ←
      terminateBackendFailure backend "during startup" err.toString proc stderrCapture
    discard <| Beam.waitTaskWithTimeout initializeTask sessionShutdownReplyTimeoutMs
    throw <| IO.userError message

private def ensureSession (workspaceId : WorkspaceId) (backend : Backend) : M Session := do
  let state ← get
  let workspace ←
    match getWorkspace? state workspaceId with
    | some workspace => pure workspace
    | none => throw <| IO.userError s!"unknown Beam workspace '{workspaceId}'"
  let config := workspace.config
  let backendState := getBackendState workspace backend
  match backendState.session? with
  | some session => pure session
  | none =>
      let session ←
        acquireBackendSession workspaceId workspace.generation backend config backendState.nextEpoch
      recordSessionSpawn workspaceId backend (backendState.nextEpoch > 1)
      let backendState := { backendState with session? := some session }
      modify fun st =>
        match getWorkspace? st workspaceId with
        | some workspace => setWorkspace st workspaceId (setBackendState workspace backend backendState)
        | none => st
      pure session

private def sendNotificationJson (session : Session) (method : String) (param : Json) : IO Session := do
  writeLspNotification session.stdin ({ method, param : Lean.JsonRpc.Notification Json })
  pure session

private def sendTextDocumentDidSave (session : Session) (uri : DocumentUri) : IO Session := do
  if session.backend != .lean then
    pure session
  else
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
    (backend : Backend)
    (workspaceGeneration : Nat)
    (readSeq : Nat := 0) : IO FileSyncSnapshot := do
  let path ← resolvePath root path
  let text ← IO.FS.readFile path
  let textMTime ← Lake.getFileMTime path
  let uri := sessionUri path
  let moduleName? := DocumentState.trackedModuleName? root path backend
  pure {
    workspaceGeneration
    path
    uri
    text
    file := {
      textHash := hash text
      textTraceHash := Lake.Hash.ofText text
      textMTime
      readSeq
      moduleName?
    }
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
    (backend : Backend)
    (snapshot : FileSyncSnapshot)
    (act : Session → M (Except ResponseFailure α)) :
    M (Except ResponseFailure α) :=
  withWorkspaceForSnapshot workspaceId snapshot fun _ => do
    let session ← ensureSession workspaceId backend
    act session

private def syncFileSnapshotDetailed
    (session : Session)
    (snapshot : FileSyncSnapshot) : IO SyncedFileSnapshot := do
  let decision := DocumentState.syncFileDecision session.docs snapshot.uri snapshot.file session.nextDocumentVersion
  let session ←
    match decision.action with
    | .open =>
      let param := toJson ({
        textDocument := {
          uri := snapshot.uri
          languageId := match session.backend with | .lean => "lean" | .rocq => "rocq"
          version := decision.version
          text := snapshot.text
        } : DidOpenTextDocumentParams
      })
      let session ← sendNotificationJson session "textDocument/didOpen" param
      pure session
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
  pure {
    session := { session with docs := decision.docs, nextDocumentVersion := decision.nextVersion }
    uri := snapshot.uri
    version := decision.version
    changed := decision.action != .unchanged
  }

private def syncFileSnapshot (session : Session) (snapshot : FileSyncSnapshot) : IO Session := do
  let synced ← syncFileSnapshotDetailed session snapshot
  pure synced.session

private def requireDocState (session : Session) (uri : String) : IO DocState := do
  DocumentState.requireDocState session.docs uri

private def closeFile (session : Session) (path : System.FilePath) : IO Session := do
  let path ← resolvePath session.root path
  let uri := sessionUri path
  if session.docs.get? uri |>.isNone then
    pure session
  else
    let param := toJson ({ textDocument := { uri := uri } : DidCloseTextDocumentParams })
    let session ← sendNotificationJson session "textDocument/didClose" param
    pure { session with docs := session.docs.erase uri }

private def recordFileProgress (session : Session) (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : Session :=
  { session with docs := DocumentState.recordFileProgress session.docs uri fileProgress? }

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

private def markDocSyncedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSyncedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def markDocSavedVersion (session : Session) (uri : DocumentUri) (version : Nat) : Session :=
  let result := DocumentState.markSavedVersion
    session.docs session.moduleHistory uri version
    (trackedPathLabel session.root uri) session.nextEventSeq
  applyVersionMarkResult session result

private def openDocsSessionView (session : Session) : OpenDocs.SessionView := {
  sessionToken := session.sessionToken
  root := session.root
  docs := session.docs
}

private def openDocsWorkspacePayload (workspace : WorkspaceState) : IO Json :=
  OpenDocs.payload workspace.config.root
    (workspace.lean.session?.map openDocsSessionView)
    (workspace.rocq.session?.map openDocsSessionView)

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
    backend := session.backend
    epoch := session.epoch
    session := session.sessionToken
    raw
    : Handle
  })

private def unwrapHandle (session : Session) (handle : Handle) : Except BrokerFailure Json := do
  if handle.workspaceId != session.workspaceId then
    throw { code := .invalidParams, message := "handle belongs to a different workspace" }
  if handle.backend != session.backend then
    throw { code := .invalidParams, message := "handle belongs to a different backend" }
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
          let backendState := getBackendState workspace session.backend
          setWorkspace state session.workspaceId
            (setBackendState workspace session.backend { backendState with session? := some session })

private def storedSession? (workspaceId : WorkspaceId) (backend : Backend) : M (Option Session) := do
  let state ← get
  let some workspace := getWorkspace? state workspaceId
    | pure none
  pure (getBackendState workspace backend).session?

private def resolveCurrentHandle
    (workspaceId : WorkspaceId)
    (handle : Handle) : M (Except ResponseFailure (Session × Json)) := do
  match ← storedSession? workspaceId handle.backend with
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
    left.backend == right.backend &&
    left.root == right.root &&
    left.epoch == right.epoch &&
    left.sessionToken == right.sessionToken

private def modifyCurrentSessionIfMatching
    (session : Session)
    (f : Session → Session) : M Unit := do
  match ← storedSession? session.workspaceId session.backend with
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

structure ServerRuntime where
  state : Std.Mutex State
  private mode : ServerMode
  activeRequests : ActiveRequestRegistry
  private closeMutex : Std.Mutex Bool
  private closeDone : IO.Promise (Except IO.Error Unit)

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

private inductive LiveBackendStateResult (α : Type) where
  | done (result : Except ResponseFailure α)
  | detached (session : Session)

private def detachExitedSession?
    (workspaceId : WorkspaceId)
    (backend : Backend) : M (Option Session) := do
  let state ← get
  let some workspace := getWorkspace? state workspaceId
    | pure none
  let backendState := getBackendState workspace backend
  let some session := backendState.session?
    | pure none
  unless ← sessionExited session do
    return none
  let (backendState, detached?) := detachBackendSession backendState
  set <| setWorkspace state workspaceId (setBackendState workspace backend backendState)
  pure detached?

/--
Run a backend state action only while the caller's workspace generation remains current. Any
already-exited session is atomically detached and cleaned up outside the global broker state mutex
before retrying against that same generation.
-/
private partial def ServerRuntime.withLiveBackendState
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (workspaceGeneration : Nat)
    (backend : Backend)
    (workspaceChangedFailure : ResponseFailure)
    (act : M (Except ResponseFailure α)) : IO (Except ResponseFailure α) := do
  let result : LiveBackendStateResult α ← server.withState do
    let state ← get
    match getWorkspace? state workspaceId with
    | none => pure <| .done (.error workspaceChangedFailure)
    | some workspace =>
        if workspace.generation != workspaceGeneration then
          pure <| .done (.error workspaceChangedFailure)
        else
          match ← detachExitedSession? workspaceId backend with
          | some session => pure <| .detached session
          | none => .done <$> act
  match result with
  | .done result => pure result
  | .detached session =>
      shutdownSession session
      server.withLiveBackendState workspaceId workspaceGeneration backend workspaceChangedFailure act

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
    (mode : ServerMode := .standalone none) : IO ServerRuntime := do
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
    activeRequests := ← ActiveRequestRegistry.create
    closeMutex := ← Std.Mutex.new false
    closeDone := ← IO.Promise.new
  }

private def collectSessions
    (left? right? : Option Session) : Array Session :=
  #[left?, right?].filterMap id

private def detachWorkspaceSessions
    (workspace : WorkspaceState) : WorkspaceState × Array Session :=
  let (lean, leanSession?) := detachBackendSession workspace.lean
  let (rocq, rocqSession?) := detachBackendSession workspace.rocq
  ({ workspace with lean, rocq }, collectSessions leanSession? rocqSession?)

private def detachRuntimeSessions (server : ServerRuntime) : IO (Array Session) := do
  server.withState do
    let state ← get
    let (state, sessions) := state.workspaces.toList.foldl (init := (state, [])) fun
        (state, sessions) (workspaceId, workspace) =>
      let (workspace, detached) := detachWorkspaceSessions workspace
      (setWorkspace state workspaceId workspace, detached.toList.reverse ++ sessions)
    set state
    pure sessions.reverse.toArray

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
  shutdownSessionsBestEffort (← detachRuntimeSessions server).toList none

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
  detachedSessions : Array Session := #[]

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
            let (_, detachedSessions) := detachWorkspaceSessions current
            {
              state := setFreshWorkspace state workspaceId config
              result := .ok <|
                workspaceInitResult workspaceId config.root mode false true
                  (some current.config.root)
              detachedSessions
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
        let (_, detachedSessions) := detachWorkspaceSessions workspace
        {
          state := { state with workspaces := state.workspaces.erase workspaceId }
          result := .ok {
            workspaceId
            dropped := true
            invalidatedHandles := true
          }
          detachedSessions
        }

private def ServerRuntime.runWorkspaceTransition
    (server : ServerRuntime)
    (transition : State → WorkspaceTransition α) : IO (Except ResponseFailure α) := do
  let transition ← server.withState do
    let transition := transition (← get)
    set transition.state
    pure transition
  shutdownSessionsBestEffort transition.detachedSessions.toList none
  pure transition.result

/--
Initialize, verify, or reset a workspace through a typed in-process boundary. Reset commits the new
workspace ownership atomically, then drains any detached backend sessions outside the state mutex.
-/
def ServerRuntime.initWorkspaceWithConfig
    (server : ServerRuntime)
    (workspaceId : WorkspaceId)
    (config : BrokerConfig)
    (mode? : Option Beam.Workspace.InitMode := none) :
    IO (Except ResponseFailure Beam.Workspace.InitResult) :=
  server.runWorkspaceTransition fun state =>
    initWorkspaceTransition state workspaceId config mode?

private def workspaceListPayload (state : State) : Json :=
  toJson ({
    workspaces := state.workspaces.toList.toArray.map fun (workspaceId, workspace) => ({
      workspaceId
      root := workspace.config.root
      leanActive := workspace.lean.session?.isSome
      rocqActive := workspace.rocq.session?.isSome
    } : Beam.Workspace.ListEntry)
  } : Beam.Workspace.ListResult)

private def responseOfTypedResult [ToJson α] : Except ResponseFailure α → Response
  | .ok result => Response.success (toJson result)
  | .error failure => failure.toResponse

/--
Remove a workspace through a typed in-process boundary. The workspace is erased atomically before
its detached backend sessions are drained outside the state mutex.
-/
def ServerRuntime.dropWorkspace
    (server : ServerRuntime)
    (workspaceId : WorkspaceId) : IO (Except ResponseFailure Beam.Workspace.DropResult) :=
  server.runWorkspaceTransition fun state => dropWorkspaceTransition state workspaceId

private def recordDispatchMetrics
    (server : ServerRuntime)
    (req : Request)
    (workspaceGeneration? : Option Nat)
    (resp : Response)
    (startedAt : Nat) : IO Unit := do
  if let some backend := req.payload.backend? then
    let finishedAt ← IO.monoNanosNow
    let latencyMs := (finishedAt - startedAt) / 1000000
    if let some workspaceId := req.resolvedWorkspaceId? then
      let some workspaceGeneration := workspaceGeneration? | return
      server.withState do
        recordRequestMetrics workspaceId workspaceGeneration backend req.op.key resp.ok
          (resp.error?.map (·.code)) latencyMs

private def cancelRegisteredRequest
    (server : ServerRuntime)
    (markCancelled : IO (Option ActiveRequest)) : IO Bool := do
  match ← markCancelled with
  | some active =>
    let sessions ← server.withState do
      let state ← get
      pure <| state.workspaces.toList.flatMap fun (workspaceId, workspace) =>
        if active.workspaceId?.all (fun selected => selected == workspaceId) then
          [workspace.lean.session?, workspace.rocq.session?]
        else
          []
    for session? in sessions do
      if let some session := session? then
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
    (cancelRef? : Option (IO.Ref Bool)) : IO Unit := do
  PendingRequestStore.propagateCancellation session.pending session.stdin cancelRef?

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

private structure WorkspaceRequest where
  workspaceId : WorkspaceId
  workspaceGeneration : Nat
  clientRequestId? : Option String := none

private structure BackendWorkspaceRequest extends WorkspaceRequest where
  backend : Backend

private def WorkspaceRequest.withBackend
    (request : WorkspaceRequest)
    (backend : Backend) : BackendWorkspaceRequest :=
  { toWorkspaceRequest := request, backend }

private def validateRequestWorkspace
    (server : ServerRuntime)
    (req : Request) : IO (Except ResponseFailure WorkspaceRequest) := do
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
    clientRequestId? := req.clientRequestId?
  })

private def requestWorkspaceChangedFailure (req : WorkspaceRequest) : ResponseFailure :=
  responseFailureFor .contentModified <|
    s!"workspace '{req.workspaceId}' changed while the request was in flight; retry the request"

private def ServerRuntime.withRequestBackendState
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (act : M (Except ResponseFailure α)) : IO (Except ResponseFailure α) :=
  server.withLiveBackendState req.workspaceId req.workspaceGeneration req.backend
    (requestWorkspaceChangedFailure req.toWorkspaceRequest) act

private def mergeFileProgressIfCurrent
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (fileProgress? : Option SyncFileProgress) : IO Unit := do
  server.withState do
    modifyCurrentSessionIfMatching session fun current =>
      match session.docs.get? uri, current.docs.get? uri with
      | some captured, some now =>
          if captured.version == now.version then recordFileProgress current uri fileProgress?
          else current
      | _, _ => current

private def withCurrentMatchingSession
    (server : ServerRuntime)
    (session : Session)
    (k : Session → M α) : HandlerM α := do
  let sessionChangedFailure := BrokerFailure.toResponseFailure {
    code := .workerExited
    message := "broker backend session changed while request was in flight"
  }
  liftFailureIO <| server.withLiveBackendState session.workspaceId session.workspaceGeneration
      session.backend sessionChangedFailure do
    match ← storedSession? session.workspaceId session.backend with
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

private structure StartedSyncedRequest where
  session : Session
  uri : DocumentUri
  version : Nat
  priorProgress? : Option SyncFileProgress := none
  tracked : Option (DocumentUri × Nat) := none
  pending : PendingRequest

private def trackedDocumentVersion (uri : DocumentUri) (docState : DocState) :
    Option (DocumentUri × Nat) :=
  some (uri, docState.version)

private def trackedLeanDocumentVersion
    (backend : Backend)
    (uri : DocumentUri)
    (docState : DocState) : Option (DocumentUri × Nat) :=
  if backend == .lean then
    trackedDocumentVersion uri docState
  else
    none

private def documentVersionMismatchFailure
    (expectedVersion acceptedVersion : Nat)
    (uri : DocumentUri) : ResponseFailure :=
  responseFailureFor
    .contentModified
    (s!"document version mismatch for {uri}: expected document version {expectedVersion}, got {acceptedVersion}")
    (some <| documentVersionMismatchErrorData expectedVersion acceptedVersion
      (currentVersion? := some acceptedVersion)
      (uri? := some uri))

private def snapshotMismatchFailure
    (expected : SnapshotRef)
    (current? : Option SnapshotRef)
    (uri : DocumentUri) : ResponseFailure :=
  responseFailureFor .contentModified
    s!"source snapshot changed for {uri}; read the source and resolve the intended target again before retrying"
    (some <| Json.mkObj <|
      [("reason", toJson "snapshotMismatch"), ("expectedSnapshot", toJson expected),
       ("uri", toJson uri)] ++
      (current?.toList.map fun current => ("currentSnapshot", toJson current)))

/-- Check document identity and apply a completion transition under the same state lock. -/
private def withCurrentMatchingDocument
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (k : Session → M α) : HandlerM α := do
  let result ← withCurrentMatchingSession server session fun current => do
    let expected := session.snapshotRef version
    let current? := (current.docs.get? uri).map fun doc => current.snapshotRef doc.version
    if current? != some expected then
      return .error <| snapshotMismatchFailure expected current? uri
    return .ok (← k current)
  requestArg result

private def recordCompletedSync
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat) : HandlerM Unit :=
  withCurrentMatchingDocument server session uri version fun current =>
    updateSession (markDocSyncedVersion current uri version)

private def startSyncedDocumentRequest
    (session : Session)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → DocState → Json)
    (trackedFor : DocumentUri → DocState → Option (DocumentUri × Nat))
    (expectedSnapshot? : Option SnapshotRef := none)
    (clientRequestId? : Option String := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    M (Except ResponseFailure StartedSyncedRequest) := do
  match ← workspaceForSnapshot session.workspaceId snapshot with
  | .error failure => return .error failure
  | .ok _ => pure ()
  let session ← syncFileSnapshot session snapshot
  let uri := snapshot.uri
  let docState ← requireDocState session uri
  match expectedSnapshot? with
  | some expectedSnapshot =>
      if session.snapshotRef docState.version != expectedSnapshot then
        updateSession session
        return .error <| snapshotMismatchFailure expectedSnapshot
          (some <| session.snapshotRef docState.version) uri
  | none =>
      pure ()
  let tracked := trackedFor uri docState
  let params := mkParams uri docState
  let (session, pending) ←
    startRequestJsonTrackedDetailed session method params
      (clientRequestId? := clientRequestId?)
      (tracked := tracked)
      (initialProgress? := docState.fileProgress?)
      (emitProgress? := emitProgress?)
      (diagnosticScope := diagnosticScope)
      (emitDiagnostic? := emitDiagnostic?)
      (cancelRef? := cancelRef?)
  updateSession session
  pure <| .ok {
    session
    uri
    version := docState.version
    priorProgress? := docState.fileProgress?
    tracked
    pending
  }

private def startSyncedWorkspaceRequest
    (workspaceId : WorkspaceId)
    (backend : Backend)
    (snapshot : FileSyncSnapshot)
    (method : String)
    (mkParams : DocumentUri → DocState → Json)
    (trackedFor : DocumentUri → DocState → Option (DocumentUri × Nat))
    (expectedSnapshot? : Option SnapshotRef := none)
    (clientRequestId? : Option String := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    M (Except ResponseFailure StartedSyncedRequest) :=
  withSessionForSnapshot workspaceId backend snapshot fun session =>
    startSyncedDocumentRequest session snapshot method mkParams trackedFor expectedSnapshot?
      clientRequestId? emitProgress? diagnosticScope emitDiagnostic? cancelRef?

private def awaitSyncedDocumentRequest
    (server : ServerRuntime)
    (started : StartedSyncedRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) : HandlerM PendingResult := do
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let pending ← awaitPending started.pending
  withFailureProgress pending.progress? <|
    withCurrentMatchingDocument server started.session started.uri started.version fun current => do
      if started.tracked.isSome then
        updateSession (recordFileProgress current started.uri pending.progress?)
  pure pending

private def readRequestSyncSnapshot
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (path : System.FilePath) : IO (Except ResponseFailure FileSyncSnapshot) := do
  let readContext : Except ResponseFailure (System.FilePath × Nat) ← server.withState do
    let state ← get
    match getWorkspace? state req.workspaceId with
    | none => pure <| .error <| requestWorkspaceChangedFailure req.toWorkspaceRequest
    | some workspace =>
        if workspace.generation != req.workspaceGeneration then
          pure <| .error <| requestWorkspaceChangedFailure req.toWorkspaceRequest
        else
          let readSeq := workspace.nextFileSnapshotSeq
          let workspace := { workspace with nextFileSnapshotSeq := readSeq + 1 }
          set <| setWorkspace state req.workspaceId workspace
          pure <| .ok (workspace.config.root, readSeq)
  let (root, readSeq) ←
    match readContext with
    | .ok context => pure context
    | .error failure => return .error failure
  -- Reserve the ordering token under the mutex, then do the slow file IO
  -- outside it.
  pure <| .ok <| ←
    readFileSyncSnapshot root path req.backend req.workspaceGeneration (readSeq := readSeq)

private structure StartedTrackedBarrier where
  session : Session
  leanConfig? : Option LeanBackendConfig
  uri : DocumentUri
  version : Nat
  textHash : UInt64
  textTraceHash : Lake.Hash
  textMTime : Lake.MTime
  changed : Bool := false
  priorProgress? : Option SyncFileProgress := none
  pending : PendingRequest

private def startTrackedDiagnosticsBarrierIO
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (path : System.FilePath)
    (diagnosticScope : DiagnosticScope := .errors)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    IO (Except ResponseFailure StartedTrackedBarrier) := do
  let snapshot ←
    match ← readRequestSyncSnapshot server req path with
    | .ok snapshot => pure snapshot
    | .error failure => return .error failure
  server.withRequestBackendState req do
    withWorkspaceForSnapshot req.workspaceId snapshot fun workspace => do
      let session ← ensureSession req.workspaceId req.backend
      let synced ← syncFileSnapshotDetailed session snapshot
      let session := synced.session
      let uri := synced.uri
      let docState ← requireDocState session uri
      let tracked := trackedDocumentVersion uri docState
      let params := toJson (WaitForDiagnosticsParams.mk uri docState.version)
      let method ← IO.ofExcept <| diagnosticsBarrierMethod session.backend
      let (session, pending) ←
        startRequestJsonTrackedDetailed session method params
          (clientRequestId? := req.clientRequestId?)
          (tracked := tracked)
          (initialProgress? := docState.fileProgress?)
          (emitProgress? := emitProgress?)
          (diagnosticScope := diagnosticScope)
          (emitDiagnostic? := emitDiagnostic?)
          (cancelRef? := cancelRef?)
      updateSession session
      pure <| .ok {
        session
        leanConfig? := workspace.config.lean?
        uri
        version := synced.version
        textHash := docState.textHash
        textTraceHash := docState.textTraceHash
        textMTime := docState.textMTime
        changed := synced.changed
        priorProgress? := docState.fileProgress?
        pending
      }

private def finalizeSavedDoc
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (closeAfter : Bool) : HandlerM Unit := do
  withCurrentMatchingSession server session fun current => do
    let current := markDocSavedVersion current uri version
    let current ←
      if closeAfter && current.docs.contains uri then
        sendNotificationJson current "textDocument/didClose" (toJson ({
          textDocument := ({ uri := uri : TextDocumentIdentifier })
          : DidCloseTextDocumentParams
        }))
      else
        pure current
    let current :=
      if closeAfter then
        { current with docs := current.docs.erase uri }
      else
        current
    updateSession current

private structure SaveOleanCompleted where
  session : Session
  uri : DocumentUri
  version : Nat
  spec : LeanSaveSpec
  result : SaveOleanResult
  fileProgress? : Option SyncFileProgress := none

private def saveCompletedResponse
    (saved : SaveOleanCompleted)
    (closeAfter : Bool) : Response :=
  let result :=
    if closeAfter then
      toJson ({ saved := saved.result } : CloseSaveResult)
    else
      toJson saved.result
  Response.withOptionalFileProgress (Response.success result) saved.fileProgress?

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

private def collectStaleDirectDepHintsForSession
    (server : ServerRuntime)
    (session : Session)
    (uri : DocumentUri)
    (version : Nat)
    (imports : Array String) : HandlerM (Array StaleDirectDepHint) := do
  if session.backend != .lean then
    pure #[]
  else
    withCurrentMatchingSession server session fun current => do
      match current.docs.get? uri with
      | some docState =>
          if docState.version == version then
            pure <| collectStaleDirectDepHints imports
              docState.lastSyncEventSeq current.moduleHistory
          else
            pure #[]
      | none =>
          pure #[]

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
    (server : ServerRuntime)
    (started : StartedTrackedBarrier)
    (progress? : Option SyncFileProgress)
    (diagnosticsSeen : Bool)
    (observedDiagnostics : Array Diagnostic)
    (directImports : Array String)
    (currentDiagnostics : Array Diagnostic) : HandlerM SyncBarrierOutcome := do
  let completionDiagnostics :=
    if diagnosticsSeen then observedDiagnostics else currentDiagnostics
  let decision :=
    decideSyncBarrier started.uri started.version started.priorProgress? progress? completionDiagnostics
  let hints ← collectStaleDirectDepHintsForSession server started.session started.uri started.version
    directImports
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

private def saveOleanCore
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (path : System.FilePath)
    (diagnosticScope : DiagnosticScope := .errors)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM SaveOleanCompleted := do
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let started ← liftFailureIO <| startTrackedDiagnosticsBarrierIO server req path diagnosticScope
    emitProgress? emitDiagnostic? (cancelRef? := cancelRef?)
  let some leanConfig := started.leanConfig?
    | throw <| responseFailureFor .invalidParams "Lean backend is not configured"
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let barrier ← awaitWaitForDiagnosticsBarrier
    s!"save_olean sync barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
    started.pending
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress barrier.progress? <| liftHandlerIO <| decodeResponseAs barrier.result
  if barrierResult.version != started.version then
    throw <| (documentVersionMismatchFailure started.version barrierResult.version started.uri)
      |>.withOptionalFileProgress barrier.progress?
  withFailureProgress barrier.progress? <| liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let saveReadiness ←
    withFailureProgress barrier.progress? <|
      syncSaveReadinessOfBarrierResult started.uri started.version started.textHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress barrier.progress? <|
    syncBarrierOutcome server started barrier.progress? barrier.diagnosticsSeen
      barrier.diagnostics barrierResult.directImports currentDiagnostics
  let barrierProgress? := barrierOutcome.fileProgress?
  withFailureProgress barrierProgress? <|
    liftHandlerIO <| mergeFileProgressIfCurrent server started.session started.uri barrierProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.session.root started.uri
    throw <| syncBarrierIncompleteFailure
      started.uri started.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics barrierProgress?
  let spec ← withFailureProgress barrierProgress? <| liftBrokerFailureIO <|
    mkLeanSaveSpec started.session.root path
      { hash := started.textTraceHash, mtime := started.textMTime }
      (some leanConfig.command) leanConfig.lakeHelper?
  let syncResult :=
    mkSyncFileResult spec.relPath (started.session.snapshotRef started.version) currentDiagnostics saveReadiness
  withFailureProgress barrierProgress? <|
    recordCompletedSync server started.session started.uri started.version
  if let some reason := spec.unsupportedSetupReason? then
    withFailureProgress barrierProgress? <| throwBrokerFailure {
      code := .saveUnsupportedSetup
      message :=
        s!"lean-beam save cannot reuse the Lean server snapshot for {spec.relPath}: {reason}. " ++
        "Move shared -D settings from moreLeanArgs to leanOptions so Lake applies them to both " ++
        "the language server and batch compilation. If the arguments are intentionally batch-only, " ++
        "run lake build for this module instead."
      data? :=
        some <| (syncResultErrorData syncResult)
          |>.setObjVal! "reason" (toJson reason)
          |>.setObjVal! "path" (toJson spec.relPath)
    }
  let method ← withFailureProgress barrierProgress? <|
    requestMethod <| saveArtifactsMethod started.session.backend
  let params := toJson ({
    textDocument := ({ uri := started.uri : TextDocumentIdentifier })
    expectedVersion := started.version
    expectedTextHash := started.textHash
    oleanFile := spec.oleanPath.toString
    moduleArtifacts? :=
      match spec.oleanServerPath?, spec.oleanPrivatePath?, spec.irPath? with
      | some oleanServerFile, some oleanPrivateFile, some irFile =>
          some {
            oleanServerFile := oleanServerFile.toString
            oleanPrivateFile := oleanPrivateFile.toString
            irFile := irFile.toString
          }
      | _, _, _ => none
    ileanFile := spec.ileanPath.toString
    cFile := spec.cPath.toString
    bcFile? := spec.bcPath?.map (fun bcPath => System.FilePath.toString bcPath)
    : Beam.LSP.Save.SaveArtifactsParams
  })
  -- A cancellation after readiness/spec computation must not invalidate a valid trace.
  withFailureProgress barrierProgress? <| liftFailureIO <| ensureRequestNotCancelled cancelRef?
  -- Once artifact publication can begin, an older trace must not remain visible: it may have the
  -- same dependency hash while describing a different in-server artifact family.
  withFailureProgress barrierProgress? <| liftHandlerIO <| invalidateLeanSaveTrace spec
  let (session, saveRequest) ← withFailureProgress barrierProgress? <|
    withCurrentMatchingSession server started.session fun current => do
      let (current, saveRequest) ← startRequestJsonTrackedDetailed current method params
        (clientRequestId? := req.clientRequestId?)
        (cancelRef? := cancelRef?)
      updateSession current
      pure (current, saveRequest)
  withFailureProgress barrierProgress? <|
    liftHandlerIO <| propagatePendingCancellation session cancelRef?
  let savePending ←
    match ← withFailureProgress barrierProgress? <|
        liftHandlerIO saveRequest.awaitOutcome with
    | .ok pending => pure pending
    | .error failure =>
        throw <| ({
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
  let saveResult : Beam.LSP.Save.SaveArtifactsResult ←
    withFailureProgress barrierProgress? <| liftHandlerIO <| decodeResponseAs savePending.result
  if saveResult.version != started.version then
    throw <| (responseFailureFor .internalError
      s!"save_olean saved version {saveResult.version}, expected document version {started.version}")
      |>.withOptionalFileProgress barrierProgress?
  if saveResult.textHash != started.textHash then
    throw <| (responseFailureFor .internalError
      s!"save_olean saved text hash {saveResult.textHash}, expected synced hash {started.textHash}")
      |>.withOptionalFileProgress barrierProgress?
  withFailureProgress barrierProgress? <| liftBrokerFailureIO <| writeLeanSaveTrace spec
  pure {
    session
    uri := started.uri
    version := started.version
    spec
    result := leanSaveResult spec started.textTraceHash syncResult
    fileProgress? := barrierProgress?
  }

private def saveOlean
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (path : System.FilePath)
    (diagnosticScope : DiagnosticScope := .errors)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM SaveOleanCompleted :=
  savePublicationMutex.atomically do
    -- A cancelled save waiting behind another transaction must not start new sync or trace work.
    liftFailureIO <| ensureRequestNotCancelled cancelRef?
    saveOleanCore server req path diagnosticScope cancelRef? emitProgress? emitDiagnostic?

private def handleSyncFileOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : SyncFileRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  if req.backend != .lean then
    throw <| responseFailureFor .invalidParams
      "sync_file diagnostics barrier is only supported for Lean"
  let path := System.FilePath.mk request.path
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let diagnosticScope := request.diagnosticScope?.getD .errors
  let started ← liftFailureIO <| startTrackedDiagnosticsBarrierIO server req path diagnosticScope
    emitProgress? emitDiagnostic? (cancelRef? := cancelRef?)
  liftHandlerIO <| traceBroker
    s!"sync_file await barrier clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
  liftHandlerIO <| propagatePendingCancellation started.session cancelRef?
  let pending ← awaitWaitForDiagnosticsBarrier
    s!"sync_file clientRequestId={optionLabel req.clientRequestId?} uri={started.uri} version={started.version}"
    started.pending
  liftHandlerIO <| traceBroker
    s!"sync_file barrier completed clientRequestId={optionLabel req.clientRequestId?} progress={pending.progress?.isSome} diagnostics={pending.diagnostics.size} diagnosticsSeen={pending.diagnosticsSeen}"
  let barrierResult : DiagnosticsBarrierResult ←
    withFailureProgress pending.progress? <| liftHandlerIO <| decodeResponseAs pending.result
  if barrierResult.version != started.version then
    throw <| (documentVersionMismatchFailure started.version barrierResult.version started.uri)
      |>.withOptionalFileProgress pending.progress?
  let saveReadiness ←
    withFailureProgress pending.progress? <|
      syncSaveReadinessOfBarrierResult started.uri started.version started.textHash barrierResult
  let currentDiagnostics := saveReadiness.currentDiagnostics
  let barrierOutcome ← withFailureProgress pending.progress? <|
    syncBarrierOutcome server started pending.progress? pending.diagnosticsSeen
      pending.diagnostics barrierResult.directImports currentDiagnostics
  let fileProgress? := barrierOutcome.fileProgress?
  withFailureProgress fileProgress? <|
    liftHandlerIO <| mergeFileProgressIfCurrent server started.session started.uri fileProgress?
  if barrierOutcome.incomplete then
    let targetPath := trackedPathLabel started.session.root started.uri
    throw <| syncBarrierIncompleteFailure
      started.uri started.version targetPath barrierOutcome.hints
      barrierOutcome.completionDiagnostics fileProgress?
  let replyDiagnostics? :=
    if request.diagnosticsInResult?.getD false then
      some <| streamDiagnosticsForReply started.session.root started.uri (started.session.snapshotRef started.version)
        (request.diagnosticScope?.getD .errors) currentDiagnostics
    else
      none
  let resultPath := trackedPathLabel started.session.root started.uri
  let syncResult :=
    mkSyncFileResult resultPath (started.session.snapshotRef started.version) currentDiagnostics saveReadiness replyDiagnostics?
  withFailureProgress fileProgress? <|
    recordCompletedSync server started.session started.uri started.version
  liftHandlerIO <| traceBroker
    s!"sync_file response ready clientRequestId={optionLabel req.clientRequestId?} version={started.version} saveReady={saveReadiness.saveReady}"
  pure <| syncFileSuccessResponse syncResult fileProgress?

private def closeTrackedFileIfOpen
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (path : System.FilePath) : HandlerM Unit :=
  liftFailureIO <| server.withRequestBackendState req do
    match ← storedSession? req.workspaceId req.backend with
    | some session =>
        let session ← closeFile session path
        updateSession session
        pure (.ok ())
    | none =>
        pure (.ok ())

private def handleRefreshFileOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : SyncFileRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let path := System.FilePath.mk request.path
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  closeTrackedFileIfOpen server req path
  handleSyncFileOp server req request cancelRef? emitProgress? emitDiagnostic?

private def handleUpdateFileOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestFile)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    HandlerM Response := do
  let path := System.FilePath.mk request.path
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <| readRequestSyncSnapshot server req path
  let updated ← liftFailureIO <| server.withRequestBackendState req do
    withSessionForSnapshot req.workspaceId req.backend snapshot fun session => do
      let synced ← syncFileSnapshotDetailed session snapshot
      updateSession synced.session
      pure (.ok synced)
  pure <| Response.success (toJson ({
    snapshot := updated.session.snapshotRef updated.version
    changed := updated.changed
    : UpdateFileResult
  }))

private def handleCloseOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : CloseRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let path := System.FilePath.mk request.path
  if request.saveArtifacts?.getD false then
    let saved ← saveOlean server req path (request.diagnosticScope?.getD .errors)
      cancelRef? emitProgress? emitDiagnostic?
    finalizeSavedDoc server saved.session saved.uri saved.version true
    pure <| saveCompletedResponse saved true
  else
    liftFailureIO <| server.withRequestBackendState req do
      match ← storedSession? req.workspaceId req.backend with
      | some session =>
          let session ← closeFile session path
          updateSession session
          pure <| .ok <| Response.success (Json.mkObj [("closed", toJson true)])
      | none =>
          pure <| .ok <| Response.success (Json.mkObj [("closed", toJson true)])

private def runAtSetupProgressEmitter?
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit)) :
    Option (StreamDiagnostic → IO Unit) :=
  emitDiagnostic?.map fun emitDiagnostic => fun diagnostic => do
    if isLakeSetupFileProgressStreamDiagnostic diagnostic then
      emitDiagnostic diagnostic

private def handleRunAtOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RunAtRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| runAtMethod request.backend
  let path := System.FilePath.mk request.path
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <| readRequestSyncSnapshot server req path
  let started ← liftFailureIO <| server.withRequestBackendState req do
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun uri docState => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier }))
        , ("position", toJson ({ line := request.line, character := request.character : Lsp.Position }))
        , ("text", toJson request.text)
        ] ++
        match request.storeHandle? with
        | some b => [("storeHandle", toJson b)]
        | none => [])
      trackedDocumentVersion
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (emitDiagnostic? := runAtSetupProgressEmitter? emitDiagnostic?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <|
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.session pending.result))
      pending.progress?

private def positionLspParams
    (request : RequestPosition)
    (uri : DocumentUri)
    (docState : DocState)
    (extraFields : List (String × Json) := []) : Json :=
  Json.mkObj <|
    [
      ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
      ("position", toJson ({ line := request.line, character := request.character : Lsp.Position }))
    ] ++ extraFields

private def handlePositionLspOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestPosition)
    (method : String)
    (extraFields : List (String × Json) := [])
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun uri docState => positionLspParams request uri docState extraFields)
      (trackedLeanDocumentVersion req.backend)
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleHoverOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestPosition)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| hoverMethod request.backend
  handlePositionLspOp server req request method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleSignatureHelpOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestPosition)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| signatureHelpMethod request.backend
  handlePositionLspOp server req request method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleDefinitionOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestPosition)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| definitionMethod request.backend
  handlePositionLspOp server req request method
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleReferencesOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : ReferencesRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| referencesMethod request.backend
  handlePositionLspOp server req request.toRequestPosition method
    [("context", Json.mkObj [
      ("includeDeclaration", toJson (request.includeDeclaration?.getD true))
    ])]
    (cancelRef? := cancelRef?) (emitProgress? := emitProgress?)

private def handleDocumentSymbolsOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RequestSnapshotFile)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| documentSymbolsMethod request.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun uri _ => Json.mkObj [
        ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
      ])
      (trackedLeanDocumentVersion req.backend)
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleWorkspaceSymbolsOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : WorkspaceSymbolsRequest)
    (cancelRef? : Option (IO.Ref Bool) := none) :
    HandlerM Response := do
  let method ← requestMethod <| workspaceSymbolsMethod request.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let (session, pending) ← liftFailureIO <|
    server.withRequestBackendState req do
      let session ← ensureSession req.workspaceId req.backend
      let params := toJson ({ query := request.query : WorkspaceSymbolParams })
      let (session, pending) ← startRequestJsonTrackedDetailed session method params
        (clientRequestId? := req.clientRequestId?)
        (cancelRef? := cancelRef?)
      updateSession session
      pure (.ok (session, pending))
  liftHandlerIO <| propagatePendingCancellation session cancelRef?
  let result ← awaitPending pending
  withCurrentMatchingSession server session fun _ => pure ()
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
    (req : BackendWorkspaceRequest)
    (request : CodeActionResolveRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| codeActionResolveMethod request.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let sourceUri ← requestArg <| codeActionResolveSourceUri request.codeAction
  if sourceUri != snapshot.uri then
    throw <| responseFailureFor .invalidParams
      s!"codeAction.data targets {sourceUri}, not requested document {snapshot.uri}"
  let started ← liftFailureIO <| server.withRequestBackendState req do
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun _uri _docState => toJson request.codeAction)
      (trackedLeanDocumentVersion req.backend)
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  let resolved : CodeAction ← liftHandlerIO <| decodeResponseAs pending.result
  let payload : CodeActionResolveResult := {
    snapshot := started.session.snapshotRef started.version
    codeAction := resolved
  }
  pure <| Response.withOptionalFileProgress (Response.success (toJson payload)) pending.progress?

private def handleSaveOleanOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : SaveOleanRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) :
    HandlerM Response := do
  let path := System.FilePath.mk request.path
  let saved ← saveOlean server req path (request.diagnosticScope?.getD .errors)
    cancelRef? emitProgress? emitDiagnostic?
  finalizeSavedDoc server saved.session saved.uri saved.version false
  pure <| saveCompletedResponse saved false

private def handleGoalsOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : GoalsRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| goalsMethod request.backend request.mode?
  if req.backend == .lean && request.text?.isSome then
    throw <| responseFailureFor .invalidParams
      "lean goals does not accept speculative text; use lean-beam run-at for execution"
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    let position : Lsp.Position := { line := request.line, character := request.character }
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun uri docState =>
        match req.backend with
        | .lean =>
            Json.mkObj [
              ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
              ("position", toJson position)
            ]
        | .rocq =>
            let fields :=
              [
                ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier })),
                ("position", toJson position),
                ("mode", toJson (Backend.Rocq.goalModeValue request.mode?)),
                ("compact", toJson (request.compact?.getD false)),
                ("pp_format", toJson (goalPpFormatValue request.ppFormat?))
              ] ++
              match request.text? with
              | some text => [("command", toJson text)]
              | none => []
            Json.mkObj fields)
      (trackedLeanDocumentVersion req.backend)
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleTodoOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : TodoRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| todoMethod request.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let range : Lsp.Range := {
    start := { line := request.line, character := request.character }
    «end» := { line := request.endLine, character := request.endCharacter }
  }
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    startSyncedWorkspaceRequest req.workspaceId req.backend snapshot method
      (fun uri docState => Json.mkObj <|
        [ ("textDocument", toJson ({ uri := uri, version? := some docState.version : VersionedTextDocumentIdentifier }))
        , ("range", toJson range)
        ] ++
        (match request.kinds? with
        | some kinds => [("kinds", toJson kinds)]
        | none => []) ++
        (match request.suggest? with
        | some suggest => [("suggest", toJson suggest)]
        | none => []))
      (trackedLeanDocumentVersion req.backend)
      (expectedSnapshot? := some request.snapshot)
      (clientRequestId? := req.clientRequestId?)
      (emitProgress? := emitProgress?)
      (cancelRef? := cancelRef?)
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def handleRunWithOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : RunWithRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| runWithMethod request.handle.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    match ← resolveCurrentHandle req.workspaceId request.handle with
    | .error resp => pure (.error resp)
    | .ok (session, rawHandle) =>
        let startedResult ← startSyncedDocumentRequest session snapshot method
          (fun uri _ => Json.mkObj <|
            [ ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier }))
            , ("handle", rawHandle)
            , ("text", toJson request.text)
            ] ++ (match request.storeHandle? with
            | some b => [("storeHandle", toJson b)]
            | none => []) ++
            (match request.linear? with
            | some b => [("linear", toJson b)]
            | none => []))
          trackedDocumentVersion
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <|
    Response.withOptionalFileProgress
      (Response.success (wrapResultHandle started.session pending.result))
      pending.progress?

private def handleReleaseOp
    (server : ServerRuntime)
    (req : BackendWorkspaceRequest)
    (request : ReleaseRequest)
    (cancelRef? : Option (IO.Ref Bool) := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none) :
    HandlerM Response := do
  let method ← requestMethod <| releaseMethod request.handle.backend
  liftFailureIO <| ensureRequestNotCancelled cancelRef?
  let snapshot ← liftFailureIO <|
    readRequestSyncSnapshot server req (System.FilePath.mk request.path)
  let started ← liftFailureIO <| server.withRequestBackendState req do
    match ← resolveCurrentHandle req.workspaceId request.handle with
    | .error resp => pure (.error resp)
    | .ok (session, rawHandle) =>
        let startedResult ← startSyncedDocumentRequest session snapshot method
          (fun uri _ => Json.mkObj [
            ("textDocument", toJson ({ uri := uri : TextDocumentIdentifier })),
            ("handle", rawHandle)
          ])
          trackedDocumentVersion
          (clientRequestId? := req.clientRequestId?)
          (emitProgress? := emitProgress?)
          (cancelRef? := cancelRef?)
        pure startedResult
  let pending ← awaitSyncedDocumentRequest server started cancelRef?
  pure <| Response.withOptionalFileProgress (Response.success pending.result) pending.progress?

private def initWorkspaceConfigFromRequest
    (server : ServerRuntime)
    (request : InitWorkspaceRequest) : IO (Except ResponseFailure BrokerConfig) := do
  let root ←
    try
      resolveRoot (System.FilePath.mk request.root)
    catch e =>
      return .error (responseFailureFor .invalidParams e.toString)
  let lean? ←
    match request.lean? with
    | none => pure none
    | some lean =>
        let plugin ←
          try
            Beam.resolveExistingPath <| System.FilePath.mk lean.plugin
          catch e =>
            return .error (responseFailureFor .invalidParams e.toString)
        pure <| some ({ command := lean.command, plugin } : LeanBackendConfig)
  if lean?.isNone && request.rocqCmd?.isNone then
    let bootstrapConfig ← server.withState do
      let state ← get
      pure state.bootstrapConfig
    if root == bootstrapConfig.root then
      return .ok bootstrapConfig
  pure <| .ok {
    root
    lean?
    rocq? := request.rocqCmd?.map fun command => { command }
  }

private def handleRequestIO
    (server : ServerRuntime)
    (req : Request)
    (activeRequest? : Option ActiveRequest := none)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO Response := do
  let cancelRef? := activeRequest?.map (·.cancelRef)
  match req.payload with
  | .shutdown =>
      server.close
      pure <| Response.success (Json.mkObj [("shutdown", toJson true)])
  | .stats =>
      match req.workspaceId? with
      | none => server.statsResponse
      | some _ =>
          match ← validateRequestWorkspace server req with
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
          match ← validateRequestWorkspace server req with
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
      match ← validateRequestWorkspace server req with
      | .error failure => pure failure.toResponse
      | .ok workspaceReqBase =>
          let some backend := payload.backend?
            | return errorResponseFor .internalError
                s!"broker operation '{payload.op.key}' reached backend dispatch without a backend"
          let workspaceReq := workspaceReqBase.withBackend backend
          match payload with
          | .ensure _ =>
              let resp ←
                try
                  let result ← server.withRequestBackendState workspaceReq do
                    let session ← ensureSession workspaceReq.workspaceId workspaceReq.backend
                    let payload := Json.mkObj [
                      ("workspace_id", toJson workspaceReq.workspaceId),
                      ("backend", toJson workspaceReq.backend),
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
          | .updateFile request =>
              runHandler <| handleUpdateFileOp server workspaceReq request cancelRef?
          | .syncFile request =>
              runHandler <|
                handleSyncFileOp server workspaceReq request cancelRef? emitProgress? emitDiagnostic?
          | .refreshFile request =>
              runHandler <|
                handleRefreshFileOp server workspaceReq request cancelRef? emitProgress? emitDiagnostic?
          | .close request =>
              runHandler <|
                handleCloseOp server workspaceReq request cancelRef? emitProgress? emitDiagnostic?
          | .runAt request =>
              runHandler <|
                handleRunAtOp server workspaceReq request cancelRef? emitProgress? emitDiagnostic?
          | .hover request =>
              runHandler <| handleHoverOp server workspaceReq request cancelRef? emitProgress?
          | .signatureHelp request =>
              runHandler <|
                handleSignatureHelpOp server workspaceReq request cancelRef? emitProgress?
          | .definition request =>
              runHandler <| handleDefinitionOp server workspaceReq request cancelRef? emitProgress?
          | .references request =>
              runHandler <| handleReferencesOp server workspaceReq request cancelRef? emitProgress?
          | .documentSymbols request =>
              runHandler <|
                handleDocumentSymbolsOp server workspaceReq request cancelRef? emitProgress?
          | .workspaceSymbols request =>
              runHandler <| handleWorkspaceSymbolsOp server workspaceReq request cancelRef?
          | .codeActionResolve request =>
              runHandler <|
                handleCodeActionResolveOp server workspaceReq request cancelRef? emitProgress?
          | .saveOlean request =>
              runHandler <|
                handleSaveOleanOp server workspaceReq request cancelRef? emitProgress? emitDiagnostic?
          | .goals request =>
              runHandler <| handleGoalsOp server workspaceReq request cancelRef? emitProgress?
          | .todo request =>
              runHandler <| handleTodoOp server workspaceReq request cancelRef? emitProgress?
          | .runWith request =>
              runHandler <| handleRunWithOp server workspaceReq request cancelRef? emitProgress?
          | .release request =>
              runHandler <| handleReleaseOp server workspaceReq request cancelRef? emitProgress?
          | .openDocs | .stats | .shutdown
          | .cancel _ | .initWorkspace _ | .listWorkspaces | .dropWorkspace =>
              unreachable!

private def ServerRuntime.withRequestAdmission
    (server : ServerRuntime)
    (req : Request)
    (act : RequestHandle → IO Response) : IO Response := do
  let startedAt ← IO.monoNanosNow
  let workspaceGeneration? ←
    match req.payload.backend?, req.resolvedWorkspaceId? with
    | some _, some workspaceId => server.withState do
        pure <| (getWorkspace? (← get) workspaceId).map (·.generation)
    | _, _ => pure none
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
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO Response := do
  server.withRequestAdmission req fun handle => do
    unless ← beforeDispatch handle do
      return BrokerFailure.toResponse {
        code := .requestCancelled
        message := "request was cancelled before broker dispatch"
      }
    handleRequestIO server req handle.active? emitProgress? emitDiagnostic?

def ServerRuntime.dispatchRequest
    (server : ServerRuntime)
    (req : Request)
    (emitProgress? : Option (SyncFileProgress → IO Unit) := none)
    (emitDiagnostic? : Option (StreamDiagnostic → IO Unit) := none) : IO Response := do
  server.dispatchRequestWithHandle req (fun _ => pure true) emitProgress? emitDiagnostic?

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
    (handle : RequestHandle)
    (requestDone : IO Bool) : IO Unit := do
  try
    -- The daemon transport accepts one request per connection. A second message is invalid and a
    -- disconnect cancels the exact admitted request. Normal request completion interrupts this
    -- receive so the watcher cannot outlive its connection handler.
    match ← Transport.recvMsgInterruptibly client requestDone with
    | .completed _ => discard <| handle.cancel
    | .interrupted => pure ()
  catch _ =>
    unless ← requestDone do
      discard <| handle.cancel

private def handleClient
    (server : ServerRuntime)
    (transport : DaemonTransport)
    (client : Transport.Connection) : IO Unit := do
  let clientRequestIdRef ← IO.mkRef (none : Option String)
  let terminalSentRef ← IO.mkRef false
  let sendResponse (clientRequestId? : Option String) (resp : Response) : IO Unit := do
    Transport.sendMsg client
      (toJson (StreamMessage.response clientRequestId? resp)).compress
    terminalSentRef.set true
  try
    if let some identity := server.mode.wrapperIdentity? then
      -- The greeting pins this connection to the descriptor-selected wrapper generation before
      -- the peer discloses its capability or semantic request contents.
      Transport.sendMsg client (toJson (ServerHello.current identity)).compress
    let initialRequestTimeoutMs := 5000
    let deadlineNanos := (← IO.monoNanosNow) + initialRequestTimeoutMs * 1000000
    let some msg ← Transport.recvMsgUntil client deadlineNanos
      | throw <| IO.userError s!"Beam daemon initial request timed out after {initialRequestTimeoutMs} ms"
    let request : Except ResponseFailure Request ←
      match Json.parse msg with
      | .error err =>
          pure <| Except.error <|
            responseFailureFor .invalidParams s!"invalid request json: {err}"
      | .ok json => do
          match json.getObjValAs? String "clientRequestId" with
          | .ok clientRequestId => clientRequestIdRef.set (some clientRequestId)
          | .error _ => pure ()
          match fromJson? json with
          | .ok req => pure <| Except.ok req
          | .error err =>
              pure <| Except.error <|
                responseFailureFor .invalidParams s!"invalid request payload: {err}"
    match request with
    | Except.error failure =>
        sendResponse (← clientRequestIdRef.get) failure.toResponse
    | Except.ok req =>
        let emitProgress : SyncFileProgress → IO Unit := fun progress =>
          Transport.sendMsg client
            (toJson (StreamMessage.fileProgress req.clientRequestId? progress)).compress
        let emitDiagnostic : StreamDiagnostic → IO Unit := fun diagnostic =>
          Transport.sendMsg client
            (toJson (StreamMessage.diagnostic req.clientRequestId? diagnostic)).compress
        let requestDone ← IO.mkRef false
        let watcherRef ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
        let resp ←
          try
            server.dispatchRequestWithHandle req (fun handle => do
              let watcher ← IO.asTask (prio := Task.Priority.dedicated) <|
                watchClientDisconnectUntil client handle requestDone.get
              watcherRef.set (some watcher)
              pure true) (some emitProgress) (some emitDiagnostic)
          finally
            requestDone.set true
            if let some watcher ← watcherRef.get then
              discard <| IO.wait watcher
        -- Request validation alone does not grant shutdown authority. Only stop the listener once
        -- dispatch has authenticated the capability and started runtime closure.
        let stopsTransport ←
          if req.op == .shutdown then server.closeStarted else pure false
        if stopsTransport then
          -- A successful send is the transport's flush boundary. Wake the listener only after the
          -- terminal response has been handed off, but do so even when the caller disconnected so
          -- a closed runtime cannot remain behind a live listener.
          try
            sendResponse req.clientRequestId? resp
          finally
            requestStop transport
        else
          sendResponse req.clientRequestId? resp
  catch e =>
    unless ← terminalSentRef.get do
      let clientRequestId? ← clientRequestIdRef.get
      let resp := errorResponseFor .internalError e.toString
      try
        sendResponse clientRequestId? resp
      catch _ =>
        pure ()
  finally
    Transport.closeConnection client

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
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  rocqCmd? : Option String := none

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
  | "--lean-cmd" :: leanCmd :: rest =>
      parseCliOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseCliOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--rocq-cmd" :: rocqCmd :: rest =>
      parseCliOptions { opts with rocqCmd? := some rocqCmd } rest
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
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (mode : ServerMode)
    (root : System.FilePath) : IO DaemonResources := do
  let runtime ← ServerRuntime.create config workspaceId mode
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
    (config : BrokerConfig)
    (workspaceId : WorkspaceId)
    (mode : ServerMode)
    (root : System.FilePath)
    (act : DaemonResources → IO α) : IO α := do
  let resources ← acquireDaemonResources opts config workspaceId mode root
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

def main (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parseCliOptions {} args
  let some root := opts.root?
    | throw <| IO.userError "missing Beam daemon --root PATH"
  let some workspaceId := opts.workspaceId?
    | throw <| IO.userError "missing Beam daemon --workspace-id ID"
  unless validWorkspaceId workspaceId do
    throw <| IO.userError "workspace id must be non-empty"
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
  let root ← Beam.resolveExistingPath <| System.FilePath.mk root
  let leanPlugin? ← opts.leanPlugin?.mapM fun path =>
    Beam.resolveExistingPath <| System.FilePath.mk path
  let config ← IO.ofExcept <| BrokerConfig.ofOptions root opts.leanCmd? leanPlugin?
    (rocqCommand? := opts.rocqCmd?)
  withDaemonResources opts config workspaceId mode root fun resources => do
    match mode with
    | .wrapper identity _ => emitWrapperReady resources.transport identity
    | .standalone _ => pure ()
    acceptLoop resources.runtime resources.transport

end Beam.Broker
