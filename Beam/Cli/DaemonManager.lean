/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Broker.Transport
import Beam.Cli.DaemonConfig
import Beam.Cli.Args
import Beam.Cli.Lock
import Beam.Daemon.Debug
import Beam.Daemon.Paths
import Beam.Daemon.Registry
import Beam.Daemon.Startup
import Beam.StderrCapture
import Beam.ProcessJob
import Beam.System

open Lean

namespace Beam.Cli

open Beam.Broker
open Beam.Daemon

/-- Private broker workspace used by the one-project daemon managed by the CLI. -/
def projectDaemonWorkspaceId : WorkspaceId :=
  "beam-cli-project"

private def defaultProjectControlLockTimeoutMs : Nat :=
  60000

private def projectControlLockTimeoutMs : IO Nat := do
  match ← IO.getEnv "BEAM_CONTROL_LOCK_TIMEOUT_MS" with
  | none =>
      pure defaultProjectControlLockTimeoutMs
  | some raw =>
      let some timeoutMs := raw.toNat?
        | throw <| IO.userError
            s!"invalid BEAM_CONTROL_LOCK_TIMEOUT_MS value '{raw}': expected milliseconds"
      if timeoutMs == 0 then
        throw <| IO.userError
          "invalid BEAM_CONTROL_LOCK_TIMEOUT_MS value '0': expected a positive timeout"
      pure timeoutMs

/-- Paths for a project's daemon control directory and registry record. -/
private structure ProjectControl where
  dir : System.FilePath
  registry : System.FilePath

private def projectControl
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO ProjectControl := do
  let dir ← controlDirFor root explicitControlDir?
  pure { dir, registry := dir / "beam-daemon.json" }

private def rejectControlDirObservation
    (dir : System.FilePath)
    (observation : Beam.PrivateDirObservation) : IO Unit := do
  Beam.requirePrivateDir "Beam session directory" dir observation

/-- Validate an existing session selection without creating it; absence remains observable. -/
private def validateControlDirForObservation (dir : System.FilePath) : IO Unit := do
  match ← Beam.observePrivateDir dir with
  | .absent | .privateDir => pure ()
  | observation => rejectControlDirObservation dir observation

/-- Recognize absence without creating a session directory or accepting an unsafe existing leaf. -/
private def sessionDescriptorAbsent (control : ProjectControl) : IO Bool := do
  match ← Beam.observePrivateDir control.dir with
  | .absent => pure true
  | .privateDir =>
      match ← readRegistryAt control.registry with
      | .absent => pure true
      | .invalid _ | .current _ => pure false
  | .symlink | .nonPrivate _ | .notDirectory => pure false

/--
Create a missing dedicated control leaf as private, or validate an existing path without mutating
it. The directory is ready before Beam creates its lock or any capability-bearing descriptor.
-/
private def preparePrivateControlDir (dir : System.FilePath) : IO Unit := do
  Beam.ensurePrivateDir "Beam session directory" dir

/-- Supply project registry mutation only while holding the project control lock, with a bounded
wait for acquisition. -/
private def withProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO α)
    (explicitControlDir? : Option System.FilePath := none) : IO α := do
  let control ← projectControl root explicitControlDir?
  preparePrivateControlDir control.dir
  withLockTimeout (control.dir / "lock") (← projectControlLockTimeoutMs) do
    act control

/--
Run teardown under the project lock without recreating a control directory that disappeared with
its project root.
-/
private def withExistingProjectControl
    (root : System.FilePath)
    (act : ProjectControl → IO Unit)
    (explicitControlDir? : Option System.FilePath := none) : IO Unit := do
  let control ← projectControl root explicitControlDir?
  match ← Beam.observePrivateDir control.dir with
  | .privateDir => pure ()
  | .absent | .symlink | .nonPrivate _ | .notDirectory => return
  try
    withExistingLockTimeout (control.dir / "lock") (← projectControlLockTimeoutMs) do
      act control
  catch
  | .noFileOrDirectory .. => pure ()
  | err => throw err

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat ('0'.toNat + n)
  else
    Char.ofNat ('a'.toNat + n - 10)

private def byteHex (byte : UInt8) : List Char :=
  [hexDigit (byte.toNat / 16), hexDigit (byte.toNat % 16)]

private def newPrivateTempPath
    (dir : System.FilePath)
    (stem : String) : IO System.FilePath := do
  let nonce := String.ofList <| (← IO.getRandomBytes 16).toList.flatMap byteHex
  pure <| dir / s!"{stem}-{nonce}.tmp"

/-- Create one private temporary inode and retain its already-open handle. -/
private def createPrivateTempFile
    (dir : System.FilePath)
    (stem : String) : IO (System.FilePath × IO.FS.Handle) := do
  let tmp ← newPrivateTempPath dir stem
  try
    let handle ← IO.FS.Handle.mk tmp .writeNew
    -- The private parent protects the inode from its creation. Mode 0600 remains defense in
    -- depth if parent permissions drift after publication.
    IO.setAccessRights tmp {
      user := { read := true, write := true }
    }
    pure (tmp, handle)
  catch err =>
    try
      if ← tmp.pathExists then
        IO.FS.removeFile tmp
    catch _ =>
      pure ()
    throw err

/-- Write one private child file through a random exclusive inode, then publish it atomically. -/
private def writePrivateFileAtomically
    (dir : System.FilePath)
    (leaf stem contents : String) : IO Unit := do
  let tmp ← newPrivateTempPath dir stem
  try
    -- Unlike the startup-log acquisition below, ordinary publication does not retain a handle
    -- across rename. The scoped handle is closed before the temporary inode is published.
    IO.FS.withFile tmp .writeNew fun handle => do
      IO.setAccessRights tmp {
        user := { read := true, write := true }
      }
      handle.putStr contents
      handle.flush
    IO.FS.rename tmp (dir / leaf)
  catch err =>
    try
      if ← tmp.pathExists then
        IO.FS.removeFile tmp
    catch _ =>
      pure ()
    throw err

/-- Publish one private empty child file while retaining its exact open handle for later writes. -/
private def openPrivateFileAtomically
    (dir : System.FilePath)
    (leaf stem : String) : IO IO.FS.Handle := do
  if System.Platform.isWindows then
    -- CRT handles cannot be renamed while open. Owner admission holds the control lock and the
    -- parent has a private DACL; replace the old log, then create its new inode exclusively.
    -- Retain that exact handle so later writes never reopen or follow a replaced path.
    let path := dir / leaf
    if ← path.pathExists then IO.FS.removeFile path
    let handle ← IO.FS.Handle.mk path .writeNew
    IO.setAccessRights path { user := { read := true, write := true } }
    return handle
  let (tmp, handle) ← createPrivateTempFile dir stem
  try
    IO.FS.rename tmp (dir / leaf)
    pure handle
  catch err =>
    try
      if ← tmp.pathExists then
        IO.FS.removeFile tmp
    catch _ =>
      pure ()
    throw err

private def writeRegistry (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  writePrivateFileAtomically control.dir "beam-daemon.json" "beam-daemon"
    ((toJson entry).pretty ++ "\n")

private def writeExistingRegistry (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  -- Teardown must not create a path while the project tree is being removed. Rewrite through an
  -- already existing file handle; if the registry was concurrently unlinked, this updates only the
  -- unlinked inode and cannot recreate the project or control directory.
  requireRegularRegistryLeaf control.registry
  IO.FS.withFile control.registry .readWrite fun handle => do
    handle.rewind
    handle.putStr ((toJson entry).pretty ++ "\n")
    handle.flush
    handle.truncate

private def removeRegistry (control : ProjectControl) : IO Unit := do
  if ← control.registry.pathExists then
    IO.FS.removeFile control.registry

private def sameRegistryGeneration (left right : SessionDescriptor) : Bool :=
  left.daemonId == right.daemonId && left.capability == right.capability

/-- Remove a registry entry only when it still names the observed daemon generation. -/
private def removeRegistryGeneration (control : ProjectControl) (entry : SessionDescriptor) : IO Unit := do
  match ← readRegistryAt control.registry with
  | .current current =>
      if sameRegistryGeneration current entry then
        removeRegistry control
  | .absent | .invalid _ => pure ()

private def daemonShutdownRequestTimeoutMs : Nat :=
  30000

/-- Ask a daemon to shut down without allowing the complete request to hold CLI control forever. -/
def requestDaemonShutdown
    (endpoint : Transport.Endpoint)
    (identity : DaemonIdentity)
    (capability : String)
    (requestTimeoutMs : Nat := daemonShutdownRequestTimeoutMs) :
    IO (Except BrokerClientFailure Response) := do
  sendRequestWithStreamTimeoutResult endpoint {
      payload := .shutdown
      daemonCapability? := some capability
    }
    requestTimeoutMs (fun _ => pure ()) (.wrapper identity)

/-- A failed endpoint probe never establishes producer settlement. Only connection establishment
failure before delivery began retains the existing independent-operator recovery path. -/
inductive ProbeFailureDisposition where
  | manualRecoveryRequired
  | unresponsive
  deriving BEq, Repr

def probeFailureDisposition (failure : BrokerClientFailure) : ProbeFailureDisposition :=
  match failure.cause, failure.delivery with
  | .transport .connect _, .notSent => .manualRecoveryRequired
  | _, _ => .unresponsive

inductive RegistryUnsafeReason where
  | endpointProbeFailed (failure : BrokerClientFailure)
  | wrongEndpointRoot (daemonRoot : String)
  | wrongGeneration (daemonRoot : String)
  | shutdownUnconfirmed
  deriving Repr

inductive RegistryBlocker where
  | invalid (problem : RegistryProblem)
  | unusable (entry : SessionDescriptor) (reason : RegistryUnsafeReason)

inductive RegistryObservation where
  | absent
  | live (entry : SessionDescriptor)
  | selectorMismatch (entry : SessionDescriptor)
  | recoveryRequired (blocker : RegistryBlocker)
  /-- The endpoint did not validate; this includes incomplete or malformed replies. -/
  | unresponsive (entry : SessionDescriptor) (failure : BrokerClientFailure)

/-- Descriptor selection without a separate endpoint probe. Ordinary project calls use this
read-only boundary, verify the generation through the request connection's greeting, and then send
their capability-bound operation on that same connection. -/
private inductive RegistrySelection where
  | absent
  | selected (entry : SessionDescriptor)
  | draining (entry : SessionDescriptor)
  | selectorMismatch (entry : SessionDescriptor)
  | invalid (problem : RegistryProblem)

private def selectProjectRegistryAt
    (root registry : System.FilePath) : IO RegistrySelection := do
  match ← readRegistryAt registry with
  | .absent => pure .absent
  | .invalid problem => pure <| .invalid problem
  | .current entry =>
      unless ← entry.matchesRoot root do
        return .selectorMismatch entry
      if entry.lifecycle == .draining then
        return .draining entry
      pure <| .selected entry

private def observeProjectRegistryAt
    (root registry : System.FilePath)
    (admitControl : SessionDescriptor → IO Unit := fun _ => pure ()) : IO RegistryObservation := do
  match ← selectProjectRegistryAt root registry with
  | .absent => pure .absent
  | .invalid problem => pure <| .recoveryRequired (.invalid problem)
  | .draining entry =>
      admitControl entry
      pure <| .recoveryRequired (.unusable entry .shutdownUnconfirmed)
  | .selectorMismatch entry => pure <| .selectorMismatch entry
  | .selected entry =>
      admitControl entry
      let endpoint := registryEndpoint entry
      match ← daemonGenerationStatus endpoint entry.workspace.workspaceId root
          entry.identity entry.capability with
      | .exact => pure <| .live entry
      | .probeFailed failure =>
          pure <| match probeFailureDisposition failure with
          | .manualRecoveryRequired => .recoveryRequired (.unusable entry (.endpointProbeFailed failure))
          | .unresponsive => .unresponsive entry failure
      | .wrongRoot daemonRoot =>
          pure <| .recoveryRequired (.unusable entry (.wrongEndpointRoot daemonRoot))
      | .wrongGeneration daemonRoot =>
          pure <| .recoveryRequired (.unusable entry (.wrongGeneration daemonRoot))

private def observeProjectControl
    (root : System.FilePath)
    (control : ProjectControl) : IO RegistryObservation := do
  validateControlDirForObservation control.dir
  observeProjectRegistryAt root control.registry

private def selectProjectControl
    (root : System.FilePath)
    (control : ProjectControl) : IO RegistrySelection := do
  validateControlDirForObservation control.dir
  selectProjectRegistryAt root control.registry

def observeProjectRegistry
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO RegistryObservation := do
  observeProjectControl root (← projectControl root explicitControlDir?)

private def daemonFailureIncidentRetainCount : Nat :=
  50

private def pruneDaemonFailureIncidents
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO Unit := do
  let entries ← Beam.Daemon.daemonFailureIncidentEntries root explicitControlDir?
  let keep := min daemonFailureIncidentRetainCount entries.size
  let deleteCount := entries.size - keep
  for entry in entries.toList.take deleteCount do
    try
      IO.FS.removeFile entry.path
    catch _ =>
      pure ()

private def appendMaybeSection (msg : String) : Option String → String
  | none => msg
  | some context => msg ++ "\n" ++ context

private structure DaemonFailureIncident where
  schemaVersion : Nat
  kind : String
  detail : String
  observedAt : String
  root : String
  controlDir : String
  registryPath : String
  registry : Option Json := none
  registryEndpoint : Option String := none
  startupLogPath : Option String := none
  startupLogTail : Option String := none
  deriving ToJson

private def daemonFailureIncidentSchemaVersion : Nat :=
  1

private def daemonFailureIncidentKind? (failure : BrokerClientFailure) : Option String :=
  match failure.cause with
  | .transport _ _ => some "brokerTransportFailure"
  | .invalidResponse _ => some "invalidBrokerResponse"
  | .streamCallback _ => none
  | .requestTimeout _ => some "brokerRequestTimeout"
  | .interrupted => none

private def daemonFailureIncidentTimestampLabel (timestamp : String) : String :=
  (timestamp.replace "-" "").replace ":" ""

private def daemonFailureIncidentPath
    (root : System.FilePath)
    (kind observedAt : String)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  let dir ← daemonFailureIncidentDirFor root explicitControlDir?
  let pid ← IO.Process.getPID
  let unique ← IO.monoNanosNow
  let stamp := daemonFailureIncidentTimestampLabel observedAt
  pure (dir / s!"incident-{stamp}-{pid}-{unique}-{kind}.json")

private def writeDaemonFailureIncident?
    (root : System.FilePath)
    (kind detail : String)
    (logTail? : Option (System.FilePath × String))
    (explicitControlDir? : Option System.FilePath := none) : IO (Option System.FilePath) := do
  try
    let control ← controlDirFor root explicitControlDir?
    unless (← Beam.observePrivateDir control) == .privateDir do
      return none
    let dir ← daemonFailureIncidentDirFor root explicitControlDir?
    -- Create only one private leaf: a deleted control directory or project must stay deleted.
    Beam.requirePrivateDir "Beam daemon incident directory" dir
      (← Beam.preparePrivateDirLeaf dir)
    let registryFile ← registryPathFor root explicitControlDir?
    let registryRead ← readRegistryAt registryFile
    let registry := registryRead.entry?
    let endpoint := registry.map registryEndpointSummary
    let observedAt ← Beam.utcTimestamp
    let incident : DaemonFailureIncident := {
      schemaVersion := daemonFailureIncidentSchemaVersion
      kind
      detail
      observedAt
      root := root.toString
      controlDir := control.toString
      registryPath := registryFile.toString
      registry := registry.map fun entry =>
        entry.redactedJson
      registryEndpoint := endpoint
      startupLogPath := logTail?.map (fun (path, _) => path.toString)
      startupLogTail := logTail?.map (fun (_, tail) => tail)
    }
    let path ← daemonFailureIncidentPath root kind observedAt explicitControlDir?
    let some leaf := path.fileName
      | return none
    writePrivateFileAtomically dir leaf "incident" ((toJson incident).pretty ++ "\n")
    try
      pruneDaemonFailureIncidents root explicitControlDir?
    catch _ =>
      pure ()
    pure (some path)
  catch _ =>
    pure none

def daemonFailureMessage
    (root : System.FilePath)
    (failure : BrokerClientFailure)
    (explicitControlDir? : Option System.FilePath := none) : IO String := do
  let detail := failure.detail
  match daemonFailureIncidentKind? failure with
  | none =>
    pure detail
  | some kind =>
    let msg := appendMaybeSection detail (← daemonRegistryContext? root explicitControlDir?)
    let logTail? ← startupLogTail? root explicitControlDir?
    let msg :=
      match logTail? with
      | none => msg
      | some (logPath, logTail) => msg ++ s!"\nBeam daemon log tail ({logPath}):\n{logTail}"
    let incidentPath? ← writeDaemonFailureIncident? root kind detail logTail? explicitControlDir?
    pure <| appendMaybeSection msg <|
      incidentPath?.map fun path => s!"Beam daemon incident: {path}"

private def daemonStartupFailure
    (logPath : System.FilePath)
    (detail : String) : IO String := do
  let msg := if detail.isEmpty then
    "failed to start Beam daemon"
  else
    s!"failed to start Beam daemon\n{detail}"
  if ← logPath.pathExists then
    let logText := Beam.trimLine (← IO.FS.readFile logPath)
    if logText.isEmpty then
      pure msg
    else
      pure <| msg ++ s!"\nstartup log ({logPath}):\n{logText}"
  else
    pure msg

private abbrev daemonStdio : IO.Process.StdioConfig where
  stdin := .piped
  stdout := .piped
  stderr := .piped

private abbrev detachedDaemonStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .piped
  stderr := .piped

private structure StartedDaemon where
  child : IO.Process.Child detachedDaemonStdio
  ownerPipe : IO.Ref (Option IO.FS.Handle)
  stderrCapture : Beam.StderrCapture

private partial def waitForDaemonChildExit
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (tries : Nat := 20) : IO (Option UInt32) := do
  match ← child.tryWait with
  | some exitCode => pure <| some exitCode
  | none =>
      if tries == 0 then
        pure none
      else
        IO.sleep 100
        waitForDaemonChildExit child (tries - 1)

private def terminateDaemonChild
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg) : IO Bool := do
  try
    match ← child.tryWait with
    | some _ => pure true
    | none =>
        Beam.ProcessJob.Internal.requestTermination child
        pure (← waitForDaemonChildExit child).isSome
  catch _ =>
    pure false

private def finishDaemonLogDrain
    (capture : Beam.StderrCapture)
    (leaderReaped : Bool) : IO Beam.StderrCaptureOutcome := do
  if leaderReaped then
    capture.awaitCompletion
  else
    pure .pipeStillOpen

private def terminateStartedDaemon (started : StartedDaemon) : IO Unit := do
  started.ownerPipe.set none
  let leaderReaped ← terminateDaemonChild started.child
  discard <| finishDaemonLogDrain started.stderrCapture leaderReaped

private def daemonStderrTailLimit : Nat :=
  16 * 1024

private def daemonStartupLogLimit : Nat :=
  64 * 1024

private def validateDaemonStartupLog (logPath : System.FilePath) : IO Unit := do
  try
    let metadata ← logPath.symlinkMetadata
    match metadata.type with
    | .file => pure ()
    | .symlink =>
        throw <| IO.userError <|
          s!"unsafe Beam daemon startup log {logPath}: symbolic links are not accepted"
    | .dir | .other =>
        throw <| IO.userError <|
          s!"unsafe Beam daemon startup log {logPath}: expected a regular file"
  catch
  | .noFileOrDirectory .. => pure ()
  | err => throw err

private def startDaemon
    (desired : DesiredConfig)
    (logPath : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String) : IO StartedDaemon := do
  let args : Array String := #[
    "--root", desired.root.toString,
    "--workspace-id", projectDaemonWorkspaceId,
    "--daemon-id", identity.daemonId,
    "--config-hash", identity.configHash,
    "--session-owner-stdin",
    "--port", "0"
  ]
  let some logDir := logPath.parent
    | throw <| IO.userError s!"Beam daemon startup log has no parent directory: {logPath}"
  let some logLeaf := logPath.fileName
    | throw <| IO.userError s!"Beam daemon startup log has no file name: {logPath}"
  validateDaemonStartupLog logPath
  let logHandle ← openPrivateFileAtomically logDir logLeaf "beam-daemon-startup"
  let ownerPipe ← IO.mkRef (none : Option IO.FS.Handle)
  let (stdin, child) ← (← IO.Process.spawn {
    toStdioConfig := daemonStdio
    cmd := desired.runtime.daemonBin.toString
    args
    cwd := some desired.root
    setsid := true
  }).takeStdin
  ownerPipe.set (some stdin)
  let stderrCapture ←
    try
      let written ← IO.mkRef 0
      let sink : Beam.StderrSink := fun chunk => do
        let count ← written.get
        let remaining := daemonStartupLogLimit - min daemonStartupLogLimit count
        let keep := min remaining chunk.size
        if keep > 0 then
          logHandle.write (chunk.extract 0 keep)
          logHandle.flush
          written.set (count + keep)
        pure (count + keep < daemonStartupLogLimit)
      Beam.StderrCapture.start child.stderr daemonStderrTailLimit (some sink)
    catch err =>
      discard <| terminateDaemonChild child
      throw err
  let started : StartedDaemon := { child, ownerPipe, stderrCapture }
  try
    stdin.putStrLn capability
    stdin.flush
    pure started
  catch err =>
    -- Once spawned, the retained child handle owns the whole setsid process group. Do not leak
    -- that acquisition when publishing the capability through the owner pipe fails.
    terminateStartedDaemon started
    throw err

private def daemonStartupTimeoutMs : Nat :=
  30000

private partial def waitForDaemonReadyUntil
    (started : StartedDaemon)
    (identity : DaemonIdentity)
    (readyTask : Task (Except IO.Error String))
    (deadlineNanos : Nat) : IO (Except String Transport.Endpoint) := do
  if ← IO.hasFinished readyTask then
    let result ← IO.wait readyTask
    match result with
    | .ok line => pure <| Beam.Daemon.StartupReady.decodeLine identity line
    | .error err => pure <| .error s!"could not read Beam daemon readiness: {err}"
  else if (← started.child.tryWait).isSome then
    pure <| .error "Beam daemon process exited before reporting readiness"
  else if (← IO.monoNanosNow) >= deadlineNanos then
    pure <| .error "Beam daemon did not report readiness before timeout"
  else
    IO.sleep 50
    waitForDaemonReadyUntil started identity readyTask deadlineNanos

private def waitForDaemonReady
    (started : StartedDaemon)
    (identity : DaemonIdentity) : IO (Except String Transport.Endpoint) := do
  let readyTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    Beam.Daemon.StartupReady.readLine started.child.stdout
  let deadlineNanos := (← IO.monoNanosNow) + daemonStartupTimeoutMs * 1000000
  try
    let result ← waitForDaemonReadyUntil started identity readyTask deadlineNanos
    let sinkFailure? ← started.stderrCapture.disableSinkAndAwaitCurrentWrite
    match result, sinkFailure? with
    | .ok _, some err =>
        discard <| terminateDaemonChild started.child
        pure <| .error s!"Beam daemon startup log capture failed: {err}"
    | .ok _, none => pure result
    | .error detail, sinkFailure? =>
        -- End the writer before joining the readiness reader. This guarantees pipe EOF even on a
        -- platform where cancelling the dedicated task does not interrupt a blocking handle read.
        discard <| terminateDaemonChild started.child
        pure <| .error <| match sinkFailure? with
          | some err => detail ++ s!"\nBeam daemon startup log capture also failed: {err}"
          | none => detail
  finally
    -- An unexpected readiness-path exception must still close the pipe writer before settling its
    -- synchronous reader. Normal result branches above have either completed the reader or already
    -- terminated the child; even after reaping, keep the final wait bounded in case of inheritance.
    if ← IO.hasFinished readyTask then
      discard <| IO.wait readyTask
    else
      let leaderReaped ← terminateDaemonChild started.child
      if leaderReaped then
        discard <| Beam.waitTaskWithTimeout readyTask 1000

private def newDaemonGenerationId (configHash : String) : IO String := do
  let startedMonoNanos ← IO.monoNanosNow
  let nonce := ByteArray.toUInt64LE! (← IO.getRandomBytes 8)
  pure s!"{configHash.take 12}-{startedMonoNanos}-{nonce}"

private def newDaemonCapability : IO String := do
  let bytes ← IO.getRandomBytes 32
  pure <| String.ofList <| bytes.toList.flatMap byteHex

private def registryEntryFor
    (desired : DesiredConfig)
    (identity : DaemonIdentity)
    (capability : String)
    (pid : Nat)
    (endpoint : Transport.Endpoint) : IO SessionDescriptor := do
  let port :=
    match endpoint with
    | .tcp port => port
  let ownerPid ← IO.Process.getPID
  pure {
    schemaVersion := registrySchemaVersion
    lifecycle := .live
    daemonId := identity.daemonId
    capability
    pid
    ownerPid := ownerPid.toNat
    port
    workspace := RuntimeDescription.toWorkspaceBinding desired.runtime projectDaemonWorkspaceId desired.root
    configHash := identity.configHash
    daemonBin := desired.runtime.daemonBin.toString
    installationRoot := desired.runtime.identity.installation.toString
    startedAt := ← Beam.utcTimestamp
  }

private def startDaemonEntry
    (desired : DesiredConfig)
    (controlDir : System.FilePath) : IO (SessionDescriptor × StartedDaemon) := do
  let logPath ← daemonStartupLogPathFor desired.root (some controlDir)
  let configHash := desired.configHash
  let daemonId ← newDaemonGenerationId configHash
  let identity : DaemonIdentity := { daemonId, configHash }
  let capability ← newDaemonCapability
  let started ← startDaemon desired logPath identity capability
  let readiness : Except String SessionDescriptor ←
    try
      match ← waitForDaemonReady started identity with
      | .ok endpoint =>
          if (← started.child.tryWait).isSome then
            pure <| Except.error "Beam daemon exited immediately after reporting readiness"
          else
            let entry ← registryEntryFor desired identity capability (Beam.processChildPid started.child).toNat endpoint
            pure (Except.ok entry)
      | .error detail => pure (Except.error detail)
    catch err =>
      terminateStartedDaemon started
      throw err
  match readiness with
  | .ok entry =>
      pure (entry, started)
  | .error detail =>
      terminateStartedDaemon started
      throw <| IO.userError (← daemonStartupFailure logPath detail)

structure ProjectDaemonClient where
  endpoint : Transport.Endpoint
  identity : DaemonIdentity
  capability : String
  workspaceId : WorkspaceId
  controlDir : System.FilePath

/-- Bind a request to the capability and workspace selected from one live wrapper session. -/
def ProjectDaemonClient.sealRequest
    (client : ProjectDaemonClient)
    (request : Request) : Request :=
  let request :=
    match request.op.workspaceScope with
    | .none => request
    | .optional | .required => { request with workspaceId? := some client.workspaceId }
  { request with daemonCapability? := some client.capability }

/-- Construct a client from a descriptor and its already selected workspace binding. -/
def ProjectDaemonClient.ofSessionDescriptor
    (entry : SessionDescriptor)
    (controlDir : System.FilePath) : ProjectDaemonClient := {
    endpoint := registryEndpoint entry
    identity := entry.identity
    capability := entry.capability
    workspaceId := entry.workspace.workspaceId
    controlDir
  }

def RegistryUnsafeReason.message : RegistryUnsafeReason → String
  | .endpointProbeFailed failure =>
      match failure.cause with
      | .transport .connect _ =>
          s!"the recorded daemon endpoint is unavailable: {failure.detail}"
      | .transport .send _ | .transport .receive _ | .invalidResponse _ | .streamCallback _
      | .requestTimeout _ | .interrupted =>
          s!"the recorded endpoint did not validate as the expected Beam generation: {failure.detail}"
  | .wrongEndpointRoot daemonRoot => s!"the recorded endpoint serves another root: {daemonRoot}"
  | .wrongGeneration daemonRoot =>
      s!"the recorded endpoint serves another Beam generation for {daemonRoot}"
  | .shutdownUnconfirmed => "shutdown was requested, but its completion is unconfirmed"

private def existingSessionFailure (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) (requestedConfigHash : String) : CliFailure :=
  let mismatch := if entry.configHash == requestedConfigHash then "" else
    s!" Its recorded configuration {entry.configHash} differs from requested configuration {requestedConfigHash}."
  (CliFailure.setup <|
    s!"An existing Beam session descriptor for {root} prevents starting another owner.{mismatch} " ++
    "Inspect the recorded session:").withRemedy (wrapperSessionCommand root sessionDir .status)
      [("generation", toJson entry.daemonId), ("recordedConfigHash", toJson entry.configHash),
        ("requestedConfigHash", toJson requestedConfigHash)]

private def configMismatchMessage
    (root : System.FilePath)
    (sessionDir : System.FilePath)
    (entry : SessionDescriptor)
    (expectedHash : String) : String :=
  s!"the live Beam session for {root} uses configuration {entry.configHash}, " ++
    s!"but this command requires {expectedHash}; the current owner was preserved. " ++
    "Interrupt its foreground owner, then start a new one with the desired configuration:\n" ++
    wrapperSessionCommand root sessionDir .serve

def sessionSelectorMismatchMessage
    (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) : String :=
  let recordedRoot := entry.workspace.root
  s!"sessionSelectorMismatch: selected workspace {root}, but Beam session {entry.daemonId} " ++
    s!"in {sessionDir} belongs to workspace {recordedRoot}. Use the recorded exact selector:\n" ++
    wrapperSessionCommand (System.FilePath.mk recordedRoot) sessionDir .status

private def registryRecoveryMessage
    (root : System.FilePath)
    (detail : String) : String :=
  s!"Beam cannot safely use or replace the daemon registry for {root}: {detail}. " ++
    "The session remains fenced; preserve its descriptor and use explicit recovery with the same " ++
    "--root and --session-dir selection after independently stopping the matching owner, daemon, " ++
    "and all other producers"

private def generationRecoveryMessage
    (root : System.FilePath)
    (sessionDir : System.FilePath)
    (entry : SessionDescriptor)
    (reason : RegistryUnsafeReason) : String :=
  let message := registryRecoveryMessage root reason.message
  let recovery := wrapperSessionCommand root sessionDir
    (.recoverGeneration entry.daemonId)
  message ++ s!"; when recovery is safe, run:\n{recovery}"

private def registryReadRecoveryMessage
    (root : System.FilePath)
    (_sessionDir : System.FilePath)
    (problem : RegistryProblem) : String :=
  registryRecoveryMessage root problem.detail ++
    "; installation ownership cannot be established for this descriptor. Preserve it for diagnosis; " ++
    "after independently stopping its original owner, archive it explicitly as an operator"

def RegistryBlocker.message
    (root sessionDir : System.FilePath) : RegistryBlocker → String
  | .invalid problem => registryReadRecoveryMessage root sessionDir problem
  | .unusable entry reason => generationRecoveryMessage root sessionDir entry reason

def RegistryBlocker.statusDetail : RegistryBlocker → String
  | .invalid problem => problem.detail
  | .unusable _ reason => reason.message

def RegistryBlocker.generation? : RegistryBlocker → Option String
  | .unusable entry _ => some entry.daemonId
  | .invalid _ => none

/-- Failure to validate an endpoint is not authority to replace its generation. -/
def unresponsiveSessionFailure (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) (failure : BrokerClientFailure)
    (diagnostics? : Option String := none) : CliFailure :=
  let message := s!"Beam session {entry.daemonId} for {root} did not validate as the expected generation; " ++
    "its descriptor was preserved. Resume or inspect the original owner and daemon before retrying."
  let data := [("generation", toJson entry.daemonId), ("detail", toJson failure.detail),
    ("root", toJson root.toString), ("sessionDir", toJson sessionDir.toString)] ++
    diagnostics?.toList.map (fun diagnostics => ("diagnostics", toJson diagnostics))
  { CliFailure.make "sessionUnresponsive" message with
    failure.error.data? := some <| Json.mkObj data }

/-- Recovery guidance is conditional: a failed probe does not establish owner death. -/
def RegistryBlocker.cliFailure (root sessionDir : System.FilePath)
    (blocker : RegistryBlocker) (diagnostics? : Option String := none) : CliFailure := Id.run do
  if let .unusable entry (.endpointProbeFailed failure) := blocker then
    if probeFailureDisposition failure == .unresponsive then
      return unresponsiveSessionFailure root sessionDir entry failure diagnostics?
  let precondition := "Independently verify that the matching owner, daemon, and all other producers have stopped " ++
    "before recovery; an unavailable endpoint does not establish this."
  let summary := match blocker with
    | .unusable _ (.endpointProbeFailed _) => "the recorded endpoint could not confirm this generation"
    | _ => blocker.statusDetail
  let failure := CliFailure.make "sessionRecoveryRequired"
    s!"Beam session for {root} requires recovery: {summary}. {precondition}"
  let data := [("detail", toJson blocker.statusDetail), ("recoveryPrecondition", toJson precondition)] ++
    diagnostics?.toList.map (fun diagnostics => ("diagnostics", toJson diagnostics))
  return match blocker with
  | .unusable entry _ =>
      failure.withRemedy (wrapperSessionCommand root sessionDir (.recoverGeneration entry.daemonId))
        (("generation", toJson entry.daemonId) :: data)
  | .invalid _ =>
      { failure with
        failure.error.message := blocker.message root sessionDir
        failure.error.data? := some <| Json.mkObj data }

def selectorMismatchFailure (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) : CliFailure :=
  (CliFailure.setup (sessionSelectorMismatchMessage root sessionDir entry)).withRemedy
    (wrapperSessionCommand (System.FilePath.mk entry.workspace.root) sessionDir .status)

private def configMismatchFailure (root sessionDir : System.FilePath)
    (entry : SessionDescriptor) (expected : String) : CliFailure :=
  (CliFailure.setup (configMismatchMessage root sessionDir entry expected)).withRemedy
    (wrapperSessionCommand root sessionDir .serve)

private inductive RegistryDrainTransition where
  | committed
  | alreadyDraining
  | changedUnderfoot

private def markRegistryDraining
    (control : ProjectControl)
    (entry : SessionDescriptor) : IO RegistryDrainTransition := do
  match ← readRegistryAt control.registry with
  | .current current =>
      if !sameRegistryGeneration current entry then
        pure .changedUnderfoot
      else if current.lifecycle == .draining then
        pure .alreadyDraining
      else
        writeExistingRegistry control { current with lifecycle := .draining }
        pure .committed
  | .absent | .invalid _ => pure .changedUnderfoot

private inductive ShutdownPlan where
  | none
  | committed (entry : SessionDescriptor)

/-- Delivery of the authenticated shutdown request after the draining fence was committed. -/
inductive ProjectDaemonStopDelivery where
  | acknowledged
  | rejected (failure : ResponseFailure)
  | failed (failure : BrokerClientFailure)

/-- An explicit shutdown request result; acknowledgement does not establish cleanup completion. -/
inductive ProjectDaemonStopResult where
  | absent
  | stopping (delivery : ProjectDaemonStopDelivery)

/-- Fence and request shutdown of the exact wrapper-owned generation without PID signalling. -/
def shutdownRegisteredProjectDaemon
    (admitControl : SessionDescriptor → IO Unit)
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) :
    CliM ProjectDaemonStopResult := do
  let selected ← projectControl root explicitControlDir?
  if ← sessionDescriptorAbsent selected then
    return .absent
  let plan : ShutdownPlan ← ExceptT.mk <| withProjectControl root
      (explicitControlDir? := explicitControlDir?) fun control => (do
    match ← observeProjectRegistryAt root control.registry admitControl with
    | .absent => pure ShutdownPlan.none
    | .live entry =>
        match ← markRegistryDraining control entry with
        | .committed => pure <| ShutdownPlan.committed entry
        | .alreadyDraining =>
            throw <| (RegistryBlocker.unusable entry .shutdownUnconfirmed).cliFailure root control.dir
        | .changedUnderfoot =>
            throw <| CliFailure.setup <|
              "Beam session descriptor changed while committing its draining fence; " ++
                "the shutdown request was not sent"
    | .selectorMismatch entry =>
        throw <| selectorMismatchFailure root control.dir entry
    | .recoveryRequired blocker =>
        throw <| blocker.cliFailure root control.dir
    | .unresponsive entry failure =>
        throw <| unresponsiveSessionFailure root control.dir entry failure
    : CliM ShutdownPlan).run
  match plan with
  | .none => pure .absent
  | .committed entry =>
      let delivery ←
        match ← requestDaemonShutdown (registryEndpoint entry) entry.identity entry.capability with
        | .ok (.successResult ..) => pure .acknowledged
        | .ok (.errorResult failure) => pure <| .rejected failure
        | .error failure => pure <| .failed failure
      pure <| .stopping delivery

inductive RecoveryResult where
  | absent
  | recoveredGeneration (generation : String) (quarantinedPath : System.FilePath)

private def quarantineRegistry (control : ProjectControl)
    (entry : SessionDescriptor) : CliM System.FilePath := do
  let changed := CliFailure.setup
    "Beam session descriptor changed while recovery checked its endpoint; the descriptor was preserved"
  let .current current ← readRegistryAt control.registry | throw changed
  unless current == entry do throw changed
  let nonce ← IO.monoNanosNow
  let quarantine := control.dir / s!"beam-daemon.recovered-{nonce}.json"
  IO.FS.rename control.registry quarantine
  pure quarantine

private def registeredGenerationStatus
    (root : System.FilePath)
    (entry : SessionDescriptor) : IO DaemonGenerationStatus := do
  let endpoint := registryEndpoint entry
  daemonGenerationStatus endpoint entry.workspace.workspaceId root entry.identity entry.capability

/--
Explicitly quarantine one unusable session descriptor without treating persisted PIDs as signal
capabilities. Only typed descriptors with admitted installation ownership can be recovered.
-/
def recoverProjectDaemon
    (admitControl : SessionDescriptor → IO Unit)
    (root : System.FilePath)
    (generation : String)
    (explicitControlDir? : Option System.FilePath := none) : CliM RecoveryResult := do
  let selected ← projectControl root explicitControlDir?
  if ← sessionDescriptorAbsent selected then
    return .absent
  ExceptT.mk <| withProjectControl root (explicitControlDir? := explicitControlDir?) fun control => (do
    match ← readRegistryAt control.registry with
    | .absent =>
        pure .absent
    | .current entry =>
        admitControl entry
        unless generation == entry.daemonId do
          throw <| CliFailure.argument "generation" generation
            (fun preview => s!"recovery generation '{preview}' does not match recorded generation '{entry.daemonId}'")
            (data := [("generation", toJson entry.daemonId)])
        unless ← entry.matchesRoot root do
          throw <| CliFailure.setup <|
            s!"selected root {root} is not the workspace in session {entry.daemonId}; " ++
            s!"recorded workspace root: {entry.workspace.root}"
        match ← registeredGenerationStatus root entry with
        | .exact =>
            throw <| CliFailure.setup <|
              s!"Beam session {entry.daemonId} still responds. Let its original owner finish cleanup, " ++
                "or use its supervisor to stop the original generation. Independently verify that " ++
                "the owner, daemon, and all other producers have stopped before manual recovery"
        | .wrongRoot daemonRoot =>
            throw <| CliFailure.setup <|
              s!"Beam session {entry.daemonId} has an authenticated endpoint that serves another root " ++
              s!"({daemonRoot}); recovery preserved the descriptor"
        | .wrongGeneration daemonRoot =>
            throw <| CliFailure.setup <|
              s!"Beam session {entry.daemonId} has an authenticated endpoint that serves another " ++
              s!"generation for {daemonRoot}; recovery preserved the descriptor"
        | .probeFailed failure =>
            if probeFailureDisposition failure == .unresponsive then
              throw <| unresponsiveSessionFailure root control.dir entry failure
            -- This is still explicit operator recovery, not a proof that producers have stopped.
            let quarantine ← quarantineRegistry control entry
            pure <| .recoveredGeneration entry.daemonId quarantine
    | .invalid (.unsafeLeaf detail) =>
        throw <| CliFailure.setup detail
    | .invalid problem =>
        throw <| CliFailure.setup <| registryReadRecoveryMessage root control.dir problem
    : CliM RecoveryResult).run

private structure OwnedProjectDaemon where
  client : ProjectDaemonClient
  entry : SessionDescriptor
  started : StartedDaemon

structure ProjectDaemonOwner where
  client : ProjectDaemonClient
  private entry : SessionDescriptor
  private child : IO.Process.Child detachedDaemonStdio
  private exitCodeRef : IO.Ref (Option UInt32)
  private stderrCapture : Beam.StderrCapture

def ProjectDaemonOwner.exitCode? (owner : ProjectDaemonOwner) : IO (Option UInt32) := do
  match ← owner.exitCodeRef.get with
  | some exitCode => pure (some exitCode)
  | none =>
      let exitCode? ← owner.child.tryWait
      if let some exitCode := exitCode? then
        owner.exitCodeRef.set (some exitCode)
      pure exitCode?

def ProjectDaemonOwner.generation (owner : ProjectDaemonOwner) : String :=
  owner.entry.daemonId

/-- The bounded daemon stderr tail retained for abnormal-exit diagnostics. -/
def ProjectDaemonOwner.stderrTail (owner : ProjectDaemonOwner) : IO String :=
  owner.stderrCapture.snapshot

/-- Whether this owner generation is still the one published for its project. -/
def ProjectDaemonOwner.registered (owner : ProjectDaemonOwner) : IO Bool := do
  match ← readRegistryAt (owner.client.controlDir / "beam-daemon.json") with
  | .current current =>
      pure (sameRegistryGeneration current owner.entry && current.lifecycle == .live)
  | .absent | .invalid _ => pure false

private def missingOwnerMessage
    (root sessionDir : System.FilePath) : String :=
  let command := wrapperSessionCommand root sessionDir .serve
  s!"no live Beam session owner is registered for {root}; " ++
    s!"start this foreground owner and keep it running while using wrapper commands:\n{command}"

private def publishOwnedProjectDaemon
    (control : ProjectControl) (desired : DesiredConfig) : IO OwnedProjectDaemon := do
  let (entry, started) ← startDaemonEntry desired control.dir
  try
    writeRegistry control entry
  catch err =>
    terminateStartedDaemon started
    throw err
  pure {
    client := .ofSessionDescriptor entry control.dir
    entry
    started
  }

private def startOwnedProjectDaemon
    (control : ProjectControl)
    (desired : DesiredConfig) : CliM OwnedProjectDaemon := do
  -- Any existing descriptor fences startup; endpoint responsiveness cannot change that decision.
  match ← selectProjectRegistryAt desired.root control.registry with
  | .absent => pure ()
  | .selected entry =>
      throw <| existingSessionFailure desired.root control.dir entry desired.configHash
  | .draining entry =>
      throw <| (RegistryBlocker.unusable entry .shutdownUnconfirmed).cliFailure desired.root control.dir
  | .selectorMismatch entry =>
      throw <| selectorMismatchFailure desired.root control.dir entry
  | .invalid problem =>
      throw <| (RegistryBlocker.invalid problem).cliFailure desired.root control.dir
  publishOwnedProjectDaemon control desired

private def waitForOwnedDaemonExit
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (exitCodeRef : IO.Ref (Option UInt32))
    (tries : Nat) : IO Unit := do
  if (← exitCodeRef.get).isNone then
    if let some exitCode ← waitForDaemonChildExit child tries then
      exitCodeRef.set (some exitCode)

private def removeOwnedRegistry
    (root controlDir : System.FilePath)
    (entry : SessionDescriptor) : IO Unit := do
  try
    withExistingProjectControl root (explicitControlDir? := some controlDir) fun control =>
      removeRegistryGeneration control entry
  catch _ =>
    pure ()

private def attemptCleanup (act : IO Unit) : IO Unit := do
  try
    act
  catch _ =>
    pure ()

private inductive OwnedDaemonProcessOutcome where
  | exitedCleanly
  | forcedReaped
  | exitedAbnormally (exitCode : UInt32)
  | unreaped

private structure OwnedDaemonFinish where
  process : OwnedDaemonProcessOutcome
  stderr : Beam.StderrCaptureOutcome

private def classifyOwnedDaemonExit (exitCode : UInt32) : OwnedDaemonProcessOutcome :=
  if exitCode == 0 then .exitedCleanly else .exitedAbnormally exitCode

private def OwnedDaemonProcessOutcome.leaderReaped : OwnedDaemonProcessOutcome → Bool
  | .unreaped => false
  | .exitedCleanly | .forcedReaped | .exitedAbnormally _ => true

private def forceOwnedDaemonChild
    {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO OwnedDaemonProcessOutcome := do
  let killSent ←
    try
      Beam.ProcessJob.Internal.requestTermination child
      pure true
    catch _ =>
      pure false
  attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 20
  -- A blocked diagnostic consumer must not prevent termination or exit collection.
  attemptCleanup <| IO.eprintln "beam: forcing daemon termination during owner cleanup"
  match ← exitCodeRef.get with
  | some exitCode =>
      if killSent then pure .forcedReaped else pure <| classifyOwnedDaemonExit exitCode
  | none => pure .unreaped

private def finishOwnedDaemonChild
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO OwnedDaemonFinish := do
  let process ←
    if let some exitCode ← exitCodeRef.get then
      pure <| classifyOwnedDaemonExit exitCode
    else
      try
        -- Every published child handle has null stdin. Clearing the single shared writer sends
        -- EOF even while `owned` and the foreground owner's observation handle remain alive.
        owned.started.ownerPipe.set none
        let child := owned.started.child
        attemptCleanup <| waitForOwnedDaemonExit child exitCodeRef 100
        match ← exitCodeRef.get with
        | some exitCode => pure <| classifyOwnedDaemonExit exitCode
        | none =>
            -- The native signalling operation retains process-group termination after stdin was
            -- detached; the detached Lean handle is still used for bounded exit collection.
            forceOwnedDaemonChild child exitCodeRef
      catch _ =>
        forceOwnedDaemonChild owned.started.child exitCodeRef
  let stderr ← finishDaemonLogDrain owned.started.stderrCapture process.leaderReaped
  pure { process, stderr }

private def markOwnedRegistryDraining
    (root controlDir : System.FilePath)
    (entry : SessionDescriptor) : IO Unit := do
  try
    withExistingProjectControl root (explicitControlDir? := some controlDir) fun control =>
      discard <| markRegistryDraining control entry
  catch _ =>
    pure ()

private def finishOwnedProjectDaemon
    (root : System.FilePath)
    (controlDir : System.FilePath)
    (owned : OwnedProjectDaemon)
    (exitCodeRef : IO.Ref (Option UInt32)) : IO Unit := do
  let exitedBeforeOwnerCleanup ←
    match ← exitCodeRef.get with
    | some _ => pure true
    | none =>
        match ← owned.started.child.tryWait with
        | some exitCode =>
            exitCodeRef.set (some exitCode)
            pure true
        | none => pure false
  let registryWasDraining ←
    match ← readRegistryAt (controlDir / "beam-daemon.json") with
    | .current current =>
        pure (sameRegistryGeneration current owned.entry && current.lifecycle == .draining)
    | .absent | .invalid _ => pure false
  if exitedBeforeOwnerCleanup && !registryWasDraining then
    -- An unexpected daemon exit is not evidence that its complete process tree disappeared. Keep
    -- the exact live generation fenced so observation projects it to recovery-required state.
    let outcome ← finishDaemonLogDrain owned.started.stderrCapture true
    match outcome with
    | .drained => pure ()
    | .sourceFailed err =>
        IO.eprintln s!"Beam daemon stderr source failed after abnormal exit: {err}"
    | .pipeStillOpen =>
        IO.eprintln "Beam daemon stderr remained open after its leader exited"
  else
    markOwnedRegistryDraining root controlDir owned.entry
    let finish ← finishOwnedDaemonChild owned exitCodeRef
    match finish.stderr with
    | .sourceFailed err =>
        IO.eprintln s!"Beam daemon stderr source failed during cleanup: {err}"
    | .pipeStillOpen =>
        let tail := (← owned.started.stderrCapture.snapshot).trimAscii.toString
        unless tail.isEmpty do
          IO.eprintln s!"Beam daemon could not be fully reaped; stderr tail:\n{tail}"
        pure ()
    | .drained =>
        match finish.process with
        | .exitedCleanly | .forcedReaped =>
            removeOwnedRegistry root controlDir owned.entry
        | .exitedAbnormally _ | .unreaped =>
            -- Failed or incomplete cleanup leaves the shutdown fence unchanged for explicit
            -- recovery. Never make a generation attachable again after shutdown begins.
            pure ()

def withProjectDaemonOwner
    (resolve : System.FilePath → CliM DesiredConfig)
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none)
    (act : ProjectDaemonOwner → CliM α) : CliM α := do
  let controlDir ← controlDirFor root explicitControlDir?
  -- Reject unsafe existing state before runtime selection, without creating session state for
  -- a rejected target. Acquisition below creates or revalidates the private directory.
  validateControlDirForObservation controlDir
  let desired ← resolve root
  -- Allocate all fallible owner bookkeeping before the child and registry generation exist.
  let exitCodeRef ← IO.mkRef (none : Option UInt32)
  let acquire : IO (Except CliFailure OwnedProjectDaemon) :=
    withProjectControl root (explicitControlDir? := some controlDir) fun control =>
      (startOwnedProjectDaemon control desired).run
  let owned ← ExceptT.mk acquire
  try
    act {
      client := owned.client
      entry := owned.entry
      child := owned.started.child
      exitCodeRef := exitCodeRef
      stderrCapture := owned.started.stderrCapture
    }
  finally
    finishOwnedProjectDaemon root controlDir owned exitCodeRef

private def lookupProjectDaemon
    (requirement : System.FilePath → CliM String)
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : CliM ProjectDaemonClient := do
  let control ← projectControl root explicitControlDir?
  match ← selectProjectControl root control with
  | .selected entry =>
      let expected ← requirement root
      unless entry.configHash == expected do
        throw <| configMismatchFailure root control.dir entry expected
      pure <| .ofSessionDescriptor entry control.dir
  | .absent =>
      throw <| (CliFailure.make "noLiveSession" (missingOwnerMessage root control.dir) 3).withRemedy
        (wrapperSessionCommand root control.dir .serve)
  | .draining entry =>
      throw <| (RegistryBlocker.unusable entry .shutdownUnconfirmed).cliFailure root control.dir
  | .selectorMismatch entry =>
      throw <| selectorMismatchFailure root control.dir entry
  | .invalid problem =>
      throw <| (RegistryBlocker.invalid problem).cliFailure root control.dir

def withProjectDaemon
    (requirement : System.FilePath → CliM String)
    (root : System.FilePath)
    (act : ProjectDaemonClient → CliM α)
    (explicitControlDir? : Option System.FilePath := none) : CliM α := do
  act (← lookupProjectDaemon requirement root explicitControlDir?)
end Beam.Cli
