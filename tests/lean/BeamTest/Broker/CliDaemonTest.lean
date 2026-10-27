/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.CompilerRevision
import Beam.Broker.Errors
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.ClientDoctor
import Beam.Cli.Info
import Beam.Cli.Installation
import Beam.Broker.Config
import Beam.Cli.LeanOperation
import Beam.Cli.Lock
import Beam.Daemon.Debug
import Beam.Daemon.Paths
import Beam.Path
import BeamTest.Broker.JsonAssert
import BeamTest.Broker.InterruptWatcherTest
import BeamTest.Broker.OutputTest
import BeamTest.PathBoundaryTest

open Lean
open BeamTest.Broker.JsonAssert (requireJsonNull requireJsonString requireFieldAbsent)

namespace BeamTest.Broker.CliDaemonTest

-- The native compiler-origin check must not accidentally become a loaded-runtime query.
elab "#check_beam_compiler_literal" : command => do
  let some (.defnInfo declaration) := (← Lean.getEnv).find? `Beam.compiledCompilerRevision
    | throwError "missing compiled Beam identity"
  match declaration.value with
  | Lean.Expr.lit (Lean.Literal.strVal revision) =>
      unless revision == Lean.githash do throwError "incorrect frozen compiler revision"
  | _ => throwError "Beam compiler revision must be an elaborated literal, independent of the loaded runtime"

  for (label, compiled, loaded, selected, expected) in [
      ("matching revisions", "a", "a", "a", true),
      ("stale compiled revision", "stale", "a", "a", false),
      ("foreign loaded runtime", "a", "foreign", "a", false),
      ("foreign selected compiler", "a", "a", "foreign", false),
      ("missing revisions", "", "", "", false)] do
    unless Beam.compilerRevisionsMatch compiled loaded selected == expected do
      throwError "compiler revision agreement failed for {label}; expected {expected}"

#check_beam_compiler_literal

private def require (label : String) (cond : Bool) : IO Unit := do
  unless cond do
    throw <| IO.userError label

private def cliValue (action : Beam.Cli.CliM α) : IO α := do
  match ← action.run with
  | .ok value => pure value
  | .error failure => throw <| IO.userError s!"unexpected CLI failure: {failure.failure.error.code}: {failure.failure.error.message}"

private def expectCliErrorMessage (label : String) (action : Beam.Cli.CliM α) : IO String := do
  match ← action.run with
  | .ok _ => throw <| IO.userError s!"{label}: expected CLI failure"
  | .error failure => pure <| failure.failure.error.message ++ failure.usage?.getD ""

private def expectUsageContains (label needle : String) (action : Beam.Cli.CliM α) : IO Unit := do
  match ← action.run with
  | .ok _ => throw <| IO.userError s!"{label}: expected usage failure"
  | .error failure =>
      require label (failure.exitCode == 2 && failure.failure.error.code == "invalidParams")
      require s!"{label}: missing {needle}"
        ((failure.failure.error.message ++ failure.usage?.getD "").contains needle)

private def projectDaemonClientForTest
    (endpoint : Beam.Broker.Transport.Endpoint)
    (controlDir : System.FilePath) : Beam.Cli.ProjectDaemonClient := {
  endpoint
  identity := { daemonId := "test-generation", configHash := "test-config" }
  capability := "test-capability"
  workspaceId := Beam.Cli.projectDaemonWorkspaceId
  controlDir
}

private def expectIoErrorMessage (label : String) (act : IO α) : IO String := do
  let result ←
    try
      pure <| Except.ok (← act)
    catch err =>
      pure <| Except.error err
  match result with
  | .ok _ =>
      throw <| IO.userError s!"{label}: expected IO error"
  | .error err =>
      pure err.toString

private def expectIoErrorContains (label needle : String) (act : IO α) : IO Unit := do
  let msg ← expectIoErrorMessage label act
  unless msg.contains needle do
    throw <| IO.userError s!"{label}: expected error containing {needle}, got {msg}"

private def requireSubstring (label needle haystack : String) : IO Unit := do
  require s!"{label}: expected '{needle}' in '{haystack}'" (Beam.Cli.hasSubstring haystack needle)

private def createSymlink
    (label : String) (target link : System.FilePath) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "ln"
    args := #["-s", target.toString, link.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to create {label} symlink\n{out.stderr}"

private def brokerTransportFailure (detail : String) : Beam.Broker.BrokerClientFailure :=
  { cause := .transport .receive (IO.userError detail) }

private def ensureTestControlDir (root : System.FilePath) : IO System.FilePath := do
  let control ← Beam.Daemon.controlDir root
  Beam.ensurePrivateDir "test Beam session directory" control
  pure control

private def checkLeanConfigLowering : IO Unit := do
  let root := System.FilePath.mk "/tmp/beam-backend-config-project"
  let daemonBin := System.FilePath.mk "/bundle/bin/beam-daemon"
  let lean : Beam.Runtime.Description := {
    command := "/toolchain/bin/lean"
    plugin := "/bundle/lib/libbeam_LSP.so"
    toolchain := "leanprover/lean4:v4.34.0"
    identity := ⟨"/bundle", "lean-bundle"⟩
    daemonBin
  }
  let leanOnly :=
    Beam.Cli.RuntimeDescription.toWorkspaceBinding lean
      Beam.Cli.projectDaemonWorkspaceId root
  require "Lean-only lowering should retain the complete Lean command"
    (leanOnly.leanCmd == lean.command)
  require "Lean-only lowering should retain the complete Lean plugin"
    (leanOnly.plugin == lean.plugin.toString)
  require "Lean-only lowering should retain the complete Lean toolchain"
    (leanOnly.toolchain == lean.toolchain)
  require "Lean-only lowering should retain its bundle identity"
    (leanOnly.bundleId == lean.identity.generation)
  let leanOnlyDesired : Beam.Cli.DesiredConfig := {
    root, runtime := lean
  }
  let differentPlugin : Beam.Cli.DesiredConfig := {
    leanOnlyDesired with runtime := { lean with plugin := "/other/plugin.so" }
  }
  require "configuration hashes should distinguish backend plugins"
    (leanOnlyDesired.configHash != differentPlugin.configHash)
  let replacement := { leanOnlyDesired with runtime := { lean with identity := { lean.identity with generation := "replacement" } } }
  require "generation changes at the same execution paths must invalidate session identity"
    (replacement.configHash != leanOnlyDesired.configHash)
  let independent := { lean with identity := { lean.identity with installation := "/independent" } }
  require "installation ownership participates in frozen configuration identity"
    (({ leanOnlyDesired with runtime := independent }).configHash != leanOnlyDesired.configHash)
  require "matching paths and generations cannot erase installation ownership"
    (!lean.sameRuntime independent)
  require "selector aliases do not change execution identity"
    (lean.sameRuntime { lean with toolchain := "alias" })

  let alias := { lean with toolchain := "different diagnostic alias" }
  require "selector aliases do not change the project configuration hash"
    (alias.configHash root == lean.configHash root)
  for changed in [{ lean with command := "/other/lean" },
      { lean with plugin := "/other/plugin" }, { lean with daemonBin := "/other/helper" },
      independent, { lean with identity := { lean.identity with generation := "new-generation" } }] do
    require "each execution or ownership field changes the runtime binding" (!lean.sameRuntime changed)
    require "each execution or ownership field changes the project configuration"
      (lean.configHash root != changed.configHash root)
  require "project root participates in the configuration hash"
    (lean.configHash root != lean.configHash "/another/project")
  require "CLI and daemon share the same configuration identity"
    (leanOnlyDesired.configHash == lean.configHash root)
  let lowered := Beam.Broker.BrokerConfig.ofRuntime root lean
  require "daemon lowering retains the same execution components"
    (lowered.lean?.any fun config => config.command == lean.command && config.plugin == lean.plugin &&
      config.lakeHelper == lean.daemonBin)

private def requireJsonNat (label field : String) (expected : Nat) (json : Json) : IO Unit := do
  let actual ← IO.ofExcept <| json.getObjValAs? Nat field
  require s!"{label}: expected {field}={expected}, got {actual}" (actual == expected)

private def requireJsonStringContains (label field needle : String) (json : Json) : IO Unit := do
  let actual ← IO.ofExcept <| json.getObjValAs? String field
  require s!"{label}: expected {field} to contain {needle}, got {actual}" (actual.contains needle)

private def sortedIncidentEntries (root : System.FilePath) : IO (Array IO.FS.DirEntry) := do
  let dir ← Beam.Daemon.daemonFailureIncidentDir root
  unless ← dir.pathExists do
    return #[]
  let entries ← dir.readDir
  pure <| (entries.filter (fun entry => entry.fileName.endsWith ".json")).qsort
    (fun a b => a.fileName < b.fileName)

private def readSingleDaemonFailureIncidentJson (root : System.FilePath) : IO Json := do
  let incidentDir ← Beam.Daemon.daemonFailureIncidentDir root
  require "daemon failure should write incident directory" (← incidentDir.pathExists)
  let incidentEntries ← sortedIncidentEntries root
  require s!"expected one daemon failure incident, got {incidentEntries.size}" (incidentEntries.size == 1)
  let some incidentEntry := incidentEntries[0]?
    | throw <| IO.userError "expected one daemon failure incident entry"
  let incidentText ← IO.FS.readFile incidentEntry.path
  IO.ofExcept <| Json.parse incidentText

private def closeAcceptedConnection (listener : Beam.Broker.Transport.Listener) : IO Unit := do
  let conn ← Beam.Broker.Transport.accept listener
  try
    Beam.Broker.Transport.sendMsg conn <| toJson (Beam.Broker.ServerHello.current {
      daemonId := "test-generation"
      configHash := "test-config"
    }) |>.compress
    -- Read the complete request before closing so the client failure is deterministically on the
    -- receive boundary. The operating system may still describe that close as EOF or ECONNRESET.
    discard <| Beam.Broker.Transport.recvMsg conn
  finally
    Beam.Broker.Transport.closeConnection conn

private def holdAcceptedConnection
    (listener : Beam.Broker.Transport.Listener)
    (release : IO.Promise Unit) : IO Unit := do
  let conn ← Beam.Broker.Transport.accept listener
  try
    let some _ ← IO.wait release.result?
      | throw <| IO.userError "silent endpoint release promise dropped"
    pure ()
  finally
    Beam.Broker.Transport.closeConnection conn

private def withBrokerListener
    (act : Beam.Broker.Transport.Listener → Beam.Broker.Transport.Endpoint → IO α)
    (backlog : UInt32 := 2) : IO α := do
  let listener ← Beam.Broker.Transport.bindAndListen (.tcp 0) backlog
  try
    let endpoint ← Beam.Broker.Transport.listenerEndpoint listener
    act listener endpoint
  finally
    Beam.Broker.Transport.closeListener listener

private def withClosingBrokerEndpoint
    (act : Beam.Broker.Transport.Endpoint → IO α) : IO α := do
  withBrokerListener (backlog := 1) fun listener endpoint => do
    let acceptTask ← IO.asTask (prio := Task.Priority.dedicated) <| closeAcceptedConnection listener
    try
      act endpoint
    finally
      -- Cancel a still-pending accept before joining it when `act` fails before connecting.
      Beam.Broker.Transport.closeListener listener
      discard <| IO.wait acceptTask

/-- Exercise the actual framing boundary: a greeting failure must not look like a lost reply. -/
private def checkRequestDeliveryEvidence : IO Unit := do
  let identity : Beam.Broker.DaemonIdentity := { daemonId := "delivery", configHash := "delivery" }
  let receipt := Beam.Broker.Response.success <| Json.mkObj [("fixtureReceipt", toJson true)]
  for mode in #["greeting", "lost", "invalid", "timeout", "callback"] do
    withBrokerListener fun listener endpoint => do
      let release ← IO.Promise.new
      let submitted ← IO.mkRef false
      let server ← IO.asTask (prio := Task.Priority.dedicated) do
        let conn ← Beam.Broker.Transport.accept listener
        try
          unless mode == "greeting" do
            Beam.Broker.Transport.sendMsg conn <| (toJson <| Beam.Broker.ServerHello.current identity).compress
            discard <| Beam.Broker.Transport.recvMsg conn
            submitted.set true
            if mode == "invalid" then Beam.Broker.Transport.sendMsg conn "invalid JSON"
            if mode == "callback" then
              Beam.Broker.Transport.sendMsg conn <| (toJson <| Beam.Broker.StreamMessage.response none receipt).compress
            if mode == "timeout" then discard <| IO.wait release.result?
        finally Beam.Broker.Transport.closeConnection conn
      try
        let outcome ← Beam.Broker.sendRequestWithStreamTimeoutResult endpoint
          { payload := .saveOlean { path := "Main.lean" } }
          2000
          (fun _ => if mode == "callback" then throw <| IO.userError "controlled terminal callback" else pure ())
          (.wrapper identity)
        let .error failure := outcome
          | throw <| IO.userError s!"{mode}: expected delivery failure"
        let expectedCause := match mode, failure.cause with
          | "greeting", .transport .receive _ | "lost", .transport .receive _
          | "invalid", .invalidResponse _ | "timeout", .requestTimeout _
          | "callback", .streamCallback _ => true
          | _, _ => false
        require s!"{mode}: preserve the original typed cause" expectedCause
        let cli := Beam.Cli.CliFailure.client failure failure.detail (some "delivery-id")
        require "delivery errors retain correlation" (cli.clientRequestId? == some "delivery-id")
        match failure.delivery with
        | .notSent =>
            require "only the greeting failed before submission" (mode == "greeting" && !(← submitted.get))
            require "greeting failure must not claim uncertainty" cli.failure.error.data?.isNone
        | .unconfirmed =>
            require "lost/invalid/timed out replies follow submission"
              ((mode == "lost" || mode == "invalid" || mode == "timeout") && (← submitted.get))
            let data := cli.failure.error.data?.getD Json.null
            require "post-send uncertainty is machine readable"
              ((data.getObjValAs? Bool "operationMayHaveCompleted").toOption == some true)
            requireSubstring "post-send uncertainty" "operation may have completed" cli.failure.error.message
        | .responseReceived response =>
            require "terminal callback failure retains its exact response"
              (mode == "callback" && (toJson response).compress == (toJson receipt).compress)
            let data := cli.failure.error.data?.getD Json.null
            require "known response is retained in CLI data"
              ((data.getObjVal? "operationResponse").toOption.map Json.compress == some (toJson receipt).compress)
            require "known response is not replaced by uncertainty"
              (data.getObjVal? "operationMayHaveCompleted").toOption.isNone
      finally
        release.resolve ()
        IO.ofExcept (← IO.wait server)

private def checkSilentEndpointProbeTimeout : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let release ← IO.Promise.new
    let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      holdAcceptedConnection listener release
    try
      let identity : Beam.Broker.DaemonIdentity := {
        daemonId := "silent-endpoint"
        configHash := "silent-endpoint"
      }
      match ← Beam.Daemon.daemonGenerationStatus endpoint
          Beam.Cli.projectDaemonWorkspaceId (System.FilePath.mk "/tmp") identity
          "test-capability" with
      | .probeFailed { cause := .requestTimeout timeoutMs, .. } =>
          require "silent endpoint should preserve its typed request timeout"
            (timeoutMs == 2000)
      | .probeFailed failure =>
          throw <| IO.userError s!"silent endpoint reported {repr failure}"
      | status =>
          throw <| IO.userError s!"silent endpoint was classified as {repr status}"
    finally
      release.resolve ()
      match ← IO.wait serverTask with
      | .ok () => pure ()
      | .error err => throw err

private def checkSilentShutdownTimeout : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let release ← IO.Promise.new
    let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      holdAcceptedConnection listener release
    try
      match ← Beam.Cli.requestDaemonShutdown endpoint
          { daemonId := "silent-endpoint", configHash := "silent-endpoint" }
          "test-capability" 50 with
      | .error { cause := .requestTimeout timeoutMs, .. } =>
          require "silent shutdown should preserve its typed request timeout" (timeoutMs == 50)
      | .error failure =>
          throw <| IO.userError s!"silent shutdown reported {repr failure}"
      | .ok response =>
          throw <| IO.userError s!"silent shutdown returned {toJson response}"
    finally
      release.resolve ()
      match ← IO.wait serverTask with
      | .ok () => pure ()
      | .error err => throw err

private def serveDisconnectCancelledPlainRequest
    (listener : Beam.Broker.Transport.Listener)
    (requestObserved : IO.Promise Unit) : IO Unit := do
  let requestConn ← Beam.Broker.Transport.accept listener
  try
    Beam.Broker.Transport.sendMsg requestConn <| toJson (Beam.Broker.ServerHello.current {
      daemonId := "test-generation"
      configHash := "test-config"
    }) |>.compress
    let requestText ← Beam.Broker.Transport.recvMsg requestConn
    let requestJson ← IO.ofExcept <| Json.parse requestText
    let _request : Beam.Broker.Request ← IO.ofExcept <| fromJson? requestJson
    requestObserved.resolve ()
    let disconnected ←
      try
        discard <| Beam.Broker.Transport.recvMsg requestConn
        pure false
      catch _ => pure true
    unless disconnected do
      throw <| IO.userError "interrupted wrapper request left its connection open"
  finally
    Beam.Broker.Transport.closeConnection requestConn

private def checkPlainBrokerTaskCancellation : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let requestObserved ← IO.Promise.new
    let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      serveDisconnectCancelledPlainRequest listener requestObserved
    let requestTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      (Beam.Cli.requestBroker (System.FilePath.mk "/tmp")
        (projectDaemonClientForTest endpoint (System.FilePath.mk "/tmp")) Beam.Broker.Request.stats).run
    let some _ ← IO.wait requestObserved.result?
      | throw <| IO.userError "plain wrapper request observation promise dropped"
    IO.cancel requestTask
    match ← IO.wait requestTask with
    | .ok (.error failure) =>
        require "plain wrapper cancellation must retain its code and exit status"
          (failure.failure.error.code == "requestCancelled" && failure.exitCode == 130)
    | .ok (.ok response) =>
        throw <| IO.userError s!"interrupted plain wrapper request returned {toJson response}"
    | .error err => throw err
    match ← IO.wait serverTask with
    | .ok () => pure ()
    | .error err => throw err

private def interruptionGateTimeoutMs : Nat := 20000

/-- Gate cancellation on an observed connection or request byte, never on elapsed time. -/
private def serveInterruptionGate
    (listener : Beam.Broker.Transport.Listener)
    (identity : Beam.Broker.DaemonIdentity)
    (submit : Bool)
    (entered release : IO.Promise Unit) : IO Unit := do
  let conn ← Beam.Broker.Transport.accept listener
  try
    if submit then
      Beam.Broker.Transport.sendMsg conn <|
        toJson (Beam.Broker.ServerHello.current identity) |>.compress
      let .tcp socket _ := conn
      let received ← Std.Internal.UV.TCP.Socket.recv? socket 1
      let received? ← try
          Beam.waitTaskWithTimeout received.result? interruptionGateTimeoutMs
        finally
          -- A timed-out native read must not remain attached to this socket.
          Std.Internal.UV.TCP.Socket.cancelRecv socket
      let some (some received) := received?
        | throw <| IO.userError "request-byte observation did not complete within its bound"
      let some bytes ← IO.ofExcept received
        | throw <| IO.userError "client disconnected before submitting its request"
      require "request submission must begin with a frame header"
        (bytes.size == 1 && bytes[0]! >= 48 && bytes[0]! <= 57)
      -- Leave the large request body unread so the transport can remain blocked.
    entered.resolve ()
    let some _ ← IO.wait release.result?
      | throw <| IO.userError "interruption gate release promise dropped"
    pure ()
  finally
    Beam.Broker.Transport.closeConnection conn

private def checkBrokerSendInterruption : IO Unit := do
  let largeText := String.ofList (List.replicate (8 * 1024 * 1024) 'x')
  for submit in [false, true] do
    withBrokerListener fun listener endpoint => do
      let identity : Beam.Broker.DaemonIdentity := {
        daemonId := "test-generation"
        configHash := "test-config"
      }
      let entered ← IO.Promise.new
      let release ← IO.Promise.new
      let interrupted ← IO.mkRef false
      let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        serveInterruptionGate listener identity submit entered release
      let clientTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        Beam.Broker.sendRequestWithCallbacksInterruptiblyResult endpoint {
          payload := .runAt {
            path := "Secret.lean"
            version := 1
            line := 0
            character := 0
            text := if submit then largeText else "#check Nat"
          }
          workspaceId? := some Beam.Cli.projectDaemonWorkspaceId
          clientRequestId? := some "interrupted-send"
          daemonCapability? := some "test-capability"
        } interrupted.get (server := .wrapper identity)
      let result? ← try
          let some (some _) ← Beam.waitTaskWithTimeout entered.result? interruptionGateTimeoutMs
            | throw <| IO.userError "client did not reach its interruption gate within the bound"
          interrupted.set true
          Beam.waitTaskWithTimeout clientTask 2000
        finally
          interrupted.set true
          release.resolve ()
      let serverResult ← IO.wait serverTask
      let some result := result?
        | throw <| IO.userError "interrupt did not release the Beam client"
      match result with
      | .ok (.error failure@{ cause := .interrupted, .. }) =>
          let cli := Beam.Cli.CliFailure.client failure failure.detail
          require "interruption preserves cancellation exit" (cli.exitCode == 130)
          if submit then
            require "observed request bytes establish unconfirmed delivery"
              (match failure.delivery with | .unconfirmed => true | _ => false)
            require "partial-send interruption retains uncertainty"
              (((cli.failure.error.data?.getD Json.null).getObjValAs? Bool "operationMayHaveCompleted").toOption == some true)
          else
            require "interruption before the greeting retains not-sent evidence"
              (match failure.delivery with | .notSent => true | _ => false)
            require "pre-send interruption must not claim an operation may have completed"
              cli.failure.error.data?.isNone
      | .ok (.error failure) =>
          throw <| IO.userError s!"client reported {repr failure} instead of interruption"
      | .ok (.ok response) =>
          throw <| IO.userError s!"interrupted client unexpectedly returned {toJson response}"
      | .error err => throw err
      IO.ofExcept serverResult

private def serveWrongDaemonGreeting
    (listener : Beam.Broker.Transport.Listener) : IO Bool := do
  let conn ← Beam.Broker.Transport.accept listener
  try
    Beam.Broker.Transport.sendMsg conn <| toJson (Beam.Broker.ServerHello.current {
      daemonId := "wrong-generation"
      configHash := "wrong-config"
    }) |>.compress
    let deadline := (← IO.monoNanosNow) + 500 * 1000000
    let requestSeen ←
      try
        pure (← Beam.Broker.Transport.recvMsgUntil conn deadline).isSome
      catch _ =>
        pure false
    pure requestSeen
  finally
    Beam.Broker.Transport.closeConnection conn

private def checkWrongGreetingProtectsRequest : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      serveWrongDaemonGreeting listener
    let msg ← expectCliErrorMessage "wrong daemon greeting" <|
      Beam.Cli.requestBroker (System.FilePath.mk "/tmp")
        (projectDaemonClientForTest endpoint (System.FilePath.mk "/tmp")) {
          payload := .runAt {
            path := "Secret.lean"
            version := 1
            line := 0
            character := 0
            text := "secret speculative text"
          }
        }
    requireSubstring "wrong daemon greeting" "identity does not match" msg
    match ← IO.wait serverTask with
    | .ok requestSeen =>
        require "a wrong daemon generation must not receive the capability-bound request"
          (!requestSeen)
    | .error err => throw err

private def checkStderrCaptureSurvivesSinkFailure : IO Unit := do
  let path := System.FilePath.mk s!"/tmp/beam-stderr-capture-{← IO.monoNanosNow}.txt"
  let contents := String.ofList (List.replicate 20000 'x')
  try
    IO.FS.writeFile path contents
    IO.FS.withFile path .read fun source => do
      let sink : Beam.StderrSink := fun _ =>
        throw <| IO.userError "intentional stderr sink failure"
      let capture ← Beam.StderrCapture.start source 1024 (some sink)
      match ← capture.awaitCompletion with
      | .drained => pure ()
      | .sourceFailed err => throw err
      | .pipeStillOpen => throw <| IO.userError "stderr capture did not finish"
      let some failure ← capture.disableSinkAndAwaitCurrentWrite
        | throw <| IO.userError "stderr capture did not retain its sink failure"
      requireSubstring "stderr sink failure" "intentional stderr sink failure" failure.toString
      let tail ← capture.snapshot
      require "stderr capture should continue draining into its bounded tail after sink failure"
        (tail.length == 1024)
  finally
    if ← path.pathExists then
      IO.FS.removeFile path

private abbrev stderrDescendantStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .piped

private def checkStderrSinkDisableIsSynchronized : IO Unit := do
  let path := System.FilePath.mk s!"/tmp/beam-stderr-sink-sync-{← IO.monoNanosNow}.txt"
  let entered ← IO.mkRef false
  let release ← IO.mkRef false
  try
    IO.FS.writeFile path "stderr evidence"
    IO.FS.withFile path .read fun source => do
      let sink : Beam.StderrSink := fun _ => do
        entered.set true
        while !(← release.get) do
          IO.sleep 10
        pure true
      let capture ← Beam.StderrCapture.start source 1024 (some sink)
      let rec awaitSinkEntry : Nat → IO Bool
        | 0 => pure false
        | fuel + 1 => do
            if ← entered.get then
              pure true
            else
              IO.sleep 10
              awaitSinkEntry fuel
      require "stderr sink did not start its write" (← awaitSinkEntry 100)
      let disableTask ← IO.asTask (prio := Task.Priority.dedicated) <|
        capture.disableSinkAndAwaitCurrentWrite
      IO.sleep 50
      require "disabling a stderr sink must await its current write"
        (!(← IO.hasFinished disableTask))
      release.set true
      match ← IO.wait disableTask with
      | .ok none => pure ()
      | .ok (some err) => throw err
      | .error err => throw err
      match ← capture.awaitCompletion with
      | .drained => pure ()
      | .sourceFailed err => throw err
      | .pipeStillOpen => throw <| IO.userError "synchronized stderr capture did not finish"
  finally
    release.set true
    if ← path.pathExists then
      IO.FS.removeFile path

private def checkStderrCaptureDoesNotJoinInheritedPipe : IO Unit := do
  let proc ← IO.Process.spawn {
    toStdioConfig := stderrDescendantStdio
    cmd := "/bin/sh"
    args := #["-c", "sleep 1 &"]
    setsid := true
  }
  let capture ← Beam.StderrCapture.start proc.stderr 1024
  discard <| proc.wait
  let started ← IO.monoNanosNow
  match ← capture.awaitCompletion 50 with
  | .pipeStillOpen => pure ()
  | .drained | .sourceFailed _ =>
      throw <| IO.userError "an inherited stderr pipe should remain unreaped before its writer exits"
  let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
  require "stderr finalization must remain bounded while a descendant owns the pipe"
    (elapsedMs < 500)
  IO.sleep 1100
  match ← capture.awaitCompletion with
  | .drained => pure ()
  | .sourceFailed err => throw err
  | .pipeStillOpen =>
      throw <| IO.userError "stderr capture did not drain after the descendant exited"

private def requireRequestJson
    (label : String)
    (actual expected : Beam.Broker.Request) : IO Unit := do
  let actualJson := toJson actual
  let expectedJson := toJson expected
  if actualJson != expectedJson then
    throw <| IO.userError s!"{label}: expected {expectedJson.compress}, got {actualJson.compress}"

private def sampleBrokerHandle : Beam.Broker.Handle := {
  workspaceId := Beam.Cli.projectDaemonWorkspaceId
  epoch := 3
  session := "session"
  raw := Json.mkObj [("value", toJson "raw-handle")]
}

private def checkProjectDaemonRequestSealing : IO Unit := do
  let selectedClient : Beam.Cli.ProjectDaemonClient := {
    endpoint := .tcp 42424
    identity := { daemonId := "selected-generation", configHash := "selected-config" }
    capability := "test-capability"
    workspaceId := "selected-workspace"
    controlDir := System.FilePath.mk "/tmp/beam-selected-control"
  }
  let selectedCancel := selectedClient.sealRequest <| Beam.Broker.Request.cancel "request"
  require "selected descriptor workspace should scope cancellation"
    (selectedCancel.workspaceId? == some "selected-workspace")
  require "selected descriptor capability should authorize cancellation"
    (selectedCancel.daemonCapability? == some "test-capability")
  let overwrittenCancel := selectedClient.sealRequest {
    Beam.Broker.Request.cancel "request" with
    workspaceId? := some "caller-selected-workspace"
    daemonCapability? := some "caller-selected-capability"
  }
  require "selected descriptor workspace should replace caller-supplied routing"
    (overwrittenCancel.workspaceId? == some "selected-workspace")
  require "selected descriptor capability should replace caller-supplied authority"
    (overwrittenCancel.daemonCapability? == some "test-capability")
  let selectedStats := selectedClient.sealRequest Beam.Broker.Request.stats
  require "selected descriptor workspace should scope optional workspace operations"
    (selectedStats.workspaceId? == some "selected-workspace")

private def checkClientResponsePresentation : IO Unit := do
  let semantic := Beam.Broker.Response.success Json.null
  let presented :=
    (Beam.Cli.prepareControlResponse semantic (some "visible-request")).json
  requireJsonString "presented response" "client_request_id" "visible-request" presented
  match fromJson? (α := Beam.Broker.Response) presented with
  | .ok response =>
      throw <| IO.userError
        s!"presentation-decorated response decoded as semantic response: {(toJson response).compress}"
  | .error _ => pure ()

private def checkFinalResponseWriteEvidence : IO Unit := do
  let saved := Json.mkObj [("module", toJson "Main"), ("sourceHash", toJson "committed")]
  let typedSave : Beam.Broker.SaveOleanResult := {
    module := "Main", sourceHash := "committed", olean := "/tmp/Main.olean"
    ilean := "/tmp/Main.ilean", c := "/tmp/Main.c", trace := "/tmp/Main.olean.trace"
    sync := {
      path := "Main.lean", version := 1, diagnostics := { counts := {} }
      readiness := { saveReady := true, reason := "ok" }
    }
  }
  let cases : Array (Option Beam.Output.Operation × Beam.Broker.Response) := #[
    (none, Beam.Broker.Response.success saved),
    (none, Beam.Broker.errorResponseFor .contentModified "checkpoint saved, document changed"
      (some <| Json.mkObj [("saved", saved), ("closed", toJson false)])),
    (some (.broker .saveOlean), Beam.Broker.Response.success (toJson typedSave))
  ]
  for (operation?, response) in cases do
    let stdout ← IO.getStdout
    let attempts ← IO.mkRef 0
    let failing := { stdout with putStr := fun _ => do
      attempts.modify (· + 1)
      throw <| IO.userError "fixture final writer failed"
    }
    let write := match operation? with
      | some operation => Beam.Cli.printOperationResponse operation response (some "writer-test")
      | none => Beam.Cli.printResponse response (some "writer-test")
    let outcome ← IO.withStdout failing <| write.run
    let .error failure := outcome
      | throw <| IO.userError "failed final writer returned success"
    require "failed final writer must guard against a replacement response" failure.responseStarted
    require "failed final writer must keep caller correlation" (failure.clientRequestId? == some "writer-test")
    let some data := failure.failure.error.data?
      | throw <| IO.userError "failed final writer lost received response"
    let actual ← IO.ofExcept <| data.getObjVal? "operationResponse"
    require "failed final writer must retain the exact received response" (actual == toJson response)
    require "failed final writer must not retry" ((← attempts.get) == 1)

private def checkWorkspaceOutputPresentation : IO Unit := do
  let first : Beam.WorkspaceOutput.Chunk := { source := .stderr, text := "config line 9791 ünïcödé " }
  let (state, initial) := ({} : Beam.Cli.WorkspaceOutputFormat).render first
  require "ordinary fragments must not wait for a newline" (initial == first.text)
  let (state, marker) := state.render { first with text := "935 ünïcödé", omittedBefore := true }
  require "omission marker must have its own line"
    (marker == "\nbeam: earlier workspace output omitted\n")
  let (state, remainder) := state.render { first with text := " ✔ continuation" }
  require "a truncated line may span multiple chunks" remainder.isEmpty
  let (state, recovered) := state.render { first with text := "\nconfig line 9793 ünïcödé ✔\nlast fragment" }
  require "resume at the next complete line without losing its Unicode text"
    (recovered == "config line 9793 ünïcödé ✔\nlast fragment")
  let (_, ending) := state.render { first with text := " complete\n" }
  require "ordinary fragments after recovery remain unchanged" (ending == " complete\n")
  let (_, atStart) := ({} : Beam.Cli.WorkspaceOutputFormat).render
    { first with text := "partial\nnext\n", omittedBefore := true }
  require "a gap at a line boundary must not add an empty line"
    (atStart == "beam: earlier workspace output omitted\nnext\n")

private def checkCliRecoveryHints : IO Unit := do
  let staleData := Json.mkObj [
    ("targetPath", toJson "SaveSmoke/A.lean"),
    ("recoveryPlan", toJson #[
      "lean-beam save \"SaveSmoke/B.lean\"",
      "lean-beam refresh \"SaveSmoke/A.lean\""
    ])
  ]
  let syncBarrierResp := Beam.Broker.errorResponseFor
    .syncBarrierIncomplete
    "Lean diagnostics barrier did not complete"
    (some staleData)
  let some hint := Beam.Cli.responseRecoveryHint? syncBarrierResp
    | throw <| IO.userError "syncBarrierIncomplete should produce a CLI recovery hint"
  requireSubstring "syncBarrier recovery hint" "lean-beam save \"SaveSmoke/B.lean\"" hint
  requireSubstring "syncBarrier recovery hint" "lean-beam refresh \"SaveSmoke/A.lean\"" hint
  require "syncBarrier recovery must not suggest an external build" (!hint.contains "lake build")
  requireSubstring "syncBarrier recovery must stop on failure" "stop if a step fails" hint
  requireSubstring "syncBarrier recovery must inspect readiness" "save readiness" hint

  let fallbackResp := Beam.Broker.errorResponseFor
    .syncBarrierIncomplete
    "Lean diagnostics barrier did not complete"
    (some <| Json.mkObj [("targetPath", toJson "SaveSmoke/A.lean")])
  require "syncBarrier missing plan must not invent fallback commands"
    (Beam.Cli.responseRecoveryHint? fallbackResp).isNone
  for plan in [toJson (#[] : Array String), toJson #[toJson (1 : Nat)]] do
    let malformed := Beam.Broker.errorResponseFor .syncBarrierIncomplete
      "Lean diagnostics barrier did not complete"
      (some <| Json.mkObj [("recoveryPlan", plan)])
    require "empty or malformed plans must not produce guessed recovery commands"
      (Beam.Cli.responseRecoveryHint? malformed).isNone

private def checkSyncWaitSpecs : IO Unit := do
  let okResp :=
    (Beam.Broker.Response.success <| toJson ({
      path := "Demo.lean"
      version := 5
      : Beam.Broker.SyncFileResult
    })).withFileProgress { updates := 2, done := true }
  require "sync complete message should include version and progress"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: sync complete for Demo.lean (version 5, fp updates=2)")
  require "refresh complete message should share sync-like formatting"
    ((Beam.Cli.refreshWaitSpec "Demo.lean").completeMsg okResp ==
      "beam: refresh complete for Demo.lean (version 5, fp updates=2)")
  let publicTodoSpec := Beam.Cli.leanTodoWaitSpec "Demo.lean"
    (some { start := { line := 1, character := 0 }, «end» := { line := 2, character := 3 } }) "todo"
  require "todo wait action should accept public wrapper label"
    (publicTodoSpec.action == "todo")
  requireSubstring "todo start message should use public wrapper label"
    "beam: querying todo for Demo.lean:1:0-2:3"
    publicTodoSpec.startMsg
  requireSubstring "todo complete message should use public wrapper label"
    "beam: todo complete for Demo.lean:1:0-2:3"
    (publicTodoSpec.completeMsg okResp)
  let publicDefinitionSpec := Beam.Cli.leanDefinitionWaitSpec "Demo.lean" 1 2 "definition"
  require "definition wait action should accept public wrapper label"
    (publicDefinitionSpec.action == "definition")
  requireSubstring "definition start message should use public wrapper label"
    "beam: running definition on Demo.lean:1:2"
    publicDefinitionSpec.startMsg
  let publicSignatureHelpSpec := Beam.Cli.leanSignatureHelpWaitSpec "Demo.lean" 1 2 "signature-help"
  require "signature-help wait action should accept public wrapper label"
    (publicSignatureHelpSpec.action == "signature-help")
  requireSubstring "signature-help start message should use public wrapper label"
    "beam: running signature-help on Demo.lean:1:2"
    publicSignatureHelpSpec.startMsg
  let publicDocumentSymbolsSpec := Beam.Cli.leanDocumentSymbolsWaitSpec "Demo.lean" "document-symbols"
  require "document-symbols wait action should accept public wrapper label"
    (publicDocumentSymbolsSpec.action == "document-symbols")
  requireSubstring "document-symbols complete message should use public wrapper label"
    "beam: document-symbols complete for Demo.lean"
    (publicDocumentSymbolsSpec.completeMsg okResp)
  let publicGoalsSpec := Beam.Cli.leanGoalsWaitSpec "Demo.lean" 1 2 .before (some "goals")
  require "goals wait action should accept public wrapper label"
    (publicGoalsSpec.action == "goals")
  requireSubstring "goals start message should use public wrapper label"
    "beam: running goals on Demo.lean:1:2"
    publicGoalsSpec.startMsg

  let notReadyResp := Beam.Broker.Response.success <| toJson ({
      path := "Demo.lean"
      version := 6
      readiness := {
        blockingErrorCount := 1
        saveReady := false
        reason := "documentErrors"
      }
      : Beam.Broker.SyncFileResult
    })
  requireSubstring "sync not-ready message"
    "saveReady=false (documentErrors, blockingErrorCount=1)"
    ((Beam.Cli.syncWaitSpec "Demo.lean").completeMsg notReadyResp)

private def checkCliRootParsing : IO Unit := do
  let missingRoot := System.FilePath.mk s!"/tmp/beam-cli-missing-root-{← IO.monoNanosNow}"
  expectUsageContains
    "missing explicit CLI root should use the workspace error boundary"
    "workspace root does not exist"
    (Beam.Cli.parseCliOptions {} ["--root", missingRoot.toString, "serve"])
  expectUsageContains
    "relative session directory should be rejected"
    "--session-dir requires an absolute path"
    (Beam.Cli.parseCliOptions {} ["--session-dir", "relative-session", "status"])
  let root := System.FilePath.mk s!"/tmp/beam-cli-root-{← IO.monoNanosNow}"
  let control := root / "shared-control"
  try
    IO.FS.createDirAll control
    let expectedRoot ← Beam.resolveExistingPath root
    let expectedControl ← Beam.resolveExistingPath control
    let opts ← cliValue <| Beam.Cli.parseCliOptions {} [
      "--root", root.toString,
      "--session-dir", control.toString,
      "stats"
    ]
    require "explicit CLI root should be canonicalized" (opts.explicitRoot? == some expectedRoot)
    require "explicit session directory should remain an exact selection"
      (opts.explicitControlDir? == some expectedControl)
    require "global selectors should not leak into command arguments" (opts.args == ["stats"])
    let literalSelectors ← cliValue <| Beam.Cli.parseCliOptions {} [
      "run-at", "Demo.lean", "1", "0", "0", "--",
      "--root", "/tmp/literal-root", "--session-dir", "/tmp/literal-session"
    ]
    require "command-level -- should make literal --root text opaque to global parsing"
      (literalSelectors.explicitRoot?.isNone)
    require "command-level -- should make literal --session-dir text opaque to global parsing"
      (literalSelectors.explicitControlDir?.isNone)
    require "global parsing should preserve the complete command tail after its first argument"
      (literalSelectors.args == [
        "run-at", "Demo.lean", "1", "0", "0", "--",
        "--root", "/tmp/literal-root", "--session-dir", "/tmp/literal-session"
      ])
    let literalPretty ← cliValue <| Beam.Cli.parseCliOptions {} [
      "run-at", "Demo.lean", "1", "0", "0", "--pretty"
    ]
    require "global parsing should preserve --pretty in opaque Lean text"
      (literalPretty.args == ["run-at", "Demo.lean", "1", "0", "0", "--pretty"])
    expectUsageContains
      "misplaced --pretty should explain global option placement on structured commands"
      "place it before the command"
      (Beam.Cli.parseCliOptions {} ["sync", "Demo.lean", "--pretty"])
  finally
    if ← root.pathExists then
      IO.FS.removeDirAll root

private def checkProjectRootSelection : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-cli-root-selection-{← IO.monoNanosNow}"
  let leanRoot := root / "lean"
  let rocqRoot := leanRoot / "rocq"
  let nested := rocqRoot / "src"
  try
    IO.FS.createDirAll nested
    IO.FS.writeFile (leanRoot / "lean-toolchain") "leanprover/lean4:stable\n"
    IO.FS.writeFile (rocqRoot / "_RocqProject") "\n"
    let expectedLeanRoot ← Beam.resolveExistingPath leanRoot
    require "Rocq project markers should not affect Lean root inference"
      ((← cliValue <| Beam.Cli.inferInspectionRoot nested) == expectedLeanRoot)
    let explicitLean ← Beam.resolveExistingPath leanRoot
    require "an explicit root should select the requested Lean workspace"
      ((← cliValue <| Beam.Cli.inspectionRoot { explicitRoot? := some explicitLean }) == explicitLean)

    IO.FS.writeFile (rocqRoot / "lean-toolchain") "leanprover/lean4:stable\n"
    let sharedRoot ← Beam.resolveExistingPath rocqRoot
    require "root inference should select the nearest Lean project"
      ((← cliValue <| Beam.Cli.inferInspectionRoot rocqRoot) == sharedRoot)
  finally
    if ← root.pathExists then
      IO.FS.removeDirAll root

private def checkProfileArgumentParsing : IO Unit := do
  for (selector, args) in [
      ("stdin", ["--stdin"]),
      ("text-file", ["--text-file", "ProfileProof.lean"]),
      ("raw text", ["--", "exact h"]),
      ("argv text", ["exact", "h"])] do
    let (enabled, remaining) ← cliValue <|
      Beam.Cli.parseProfileArg ("--profile" :: args)
    require s!"--profile before {selector} should enable profiling" enabled
    require s!"--profile before {selector} should preserve the text selector" (remaining == args)

  for (selector, args) in [
      ("stdin", ["--stdin"]),
      ("text-file", ["--text-file", "ProfileProof.lean"]),
      ("raw text", ["--", "exact h"]),
      ("argv text", ["exact", "h"])] do
    let (enabled, remaining) ← cliValue <| Beam.Cli.parseProfileArg args
    require s!"profiling should default off before {selector}" (!enabled)
    require s!"profiling should leave {selector} unchanged when absent" (remaining == args)

  let (enabled, literalArgs) ← cliValue <| Beam.Cli.parseProfileArg ["--", "--profile"]
  require "a profile-looking token after -- should remain source text" (!enabled)
  require "the -- delimiter and its text should be preserved" (literalArgs == ["--", "--profile"])
  let literal ← cliValue <| Beam.Cli.parseTextArg "run-at ProfileProof.lean 1 0 0" literalArgs
  require "--profile after -- should reach the Lean text unchanged" (literal.text == "--profile")

  expectUsageContains "duplicate profiling selector should fail" "duplicate --profile" <|
    Beam.Cli.parseProfileArg ["--profile", "--profile", "--stdin"]

private def checkLeanOperationRequests : IO Unit := do
  let path := "Demo.lean"

  let runAtInput : Beam.Lean.RunAtInput := {
    path
    version := 12
    line := 4
    character := 2
    text := "exact h"
  }
  requireRequestJson "runAt request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest path 12 4 2 "exact h")
    runAtInput.toBrokerRequest
  requireFieldAbsent "runAt should omit profiling by default" "profile"
    (toJson <| Beam.Cli.leanRunAtRequest path 12 4 2 "exact h")
  let profiledRunAtInput := { runAtInput with profile? := some true }
  requireRequestJson "runAt profile selector should reach the broker request"
    (Beam.Cli.leanRunAtRequest path 12 4 2 "exact h" (profile := true))
    profiledRunAtInput.toBrokerRequest
  requireRequestJson "runAt handle request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest path 12 4 2 "exact h" (storeHandle := true))
    (runAtInput.toBrokerRequest (storeHandle := true))
  requireRequestJson "runAt handle profile selector should reach the broker request"
    (Beam.Cli.leanRunAtRequest path 12 4 2 "exact h" (storeHandle := true) (profile := true))
    (profiledRunAtInput.toBrokerRequest (storeHandle := true))
  expectUsageContains "runAt missing text should fail at the CLI boundary"
    "usage: lean-beam" (Beam.Cli.parseTextArg "run-at Demo.lean 12 4 2" [])

  let positionInput : Beam.Lean.PositionInput := {
    path
    version := 13
    line := 7
    character := 3
  }
  requireRequestJson "hover request should share the Lean operation adapter"
    (Beam.Cli.leanHoverRequest path 13 7 3)
    positionInput.toHoverBrokerRequest
  requireRequestJson "signature-help request should share the Lean operation adapter"
    (Beam.Cli.leanSignatureHelpRequest path 13 7 3)
    positionInput.toSignatureHelpBrokerRequest
  requireRequestJson "definition request should share the Lean operation adapter"
    (Beam.Cli.leanDefinitionRequest path 13 7 3)
    positionInput.toDefinitionBrokerRequest
  let referencesInput : Beam.Lean.ReferencesInput := {
    path
    version := 13
    line := 7
    character := 3
    includeDeclaration? := some false
  }
  requireRequestJson "references request should share the Lean operation adapter"
    (Beam.Cli.leanReferencesRequest path 13 7 3 false)
    referencesInput.toBrokerRequest
  let documentSymbolsInput : Beam.Lean.DocumentSymbolsInput := {
    path
    version := 13
  }
  requireRequestJson "document-symbols request should share the Lean operation adapter"
    (Beam.Cli.leanDocumentSymbolsRequest path 13)
    documentSymbolsInput.toBrokerRequest
  let workspaceSymbolsInput : Beam.Lean.WorkspaceSymbolsInput := {
    query := "Demo"
  }
  requireRequestJson "workspace-symbols request should share the Lean operation adapter"
    (Beam.Cli.leanWorkspaceSymbolsRequest "Demo")
    workspaceSymbolsInput.toBrokerRequest
  requireRequestJson "goals request should share the Lean operation adapter"
    (Beam.Cli.leanGoalsRequest path 13 7 3 .before)
    (positionInput.toGoalsBrokerRequest .before)

  let runWithInput : Beam.Lean.RunWithInput := {
    path
    handle := sampleBrokerHandle
    text := "simp"
  }
  requireRequestJson "runWith request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp")
    runWithInput.toBrokerRequest
  requireFieldAbsent "runWith should omit profiling by default" "profile"
    (toJson <| Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp")
  let profiledRunWithInput := { runWithInput with profile? := some true }
  requireRequestJson "runWith profile selector should reach the broker request"
    (Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp" (profile := true))
    profiledRunWithInput.toBrokerRequest
  requireRequestJson "runWith linear request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp" (linear := true))
    (runWithInput.toBrokerRequest (linear := true))
  requireRequestJson "runWith linear profile selector should reach the broker request"
    (Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp" (linear := true) (profile := true))
    (profiledRunWithInput.toBrokerRequest (linear := true))
  expectUsageContains "runWith missing text should fail at the CLI boundary"
    "usage: lean-beam" (Beam.Cli.parseTextArg "run-with Demo.lean HANDLE" [])

  requireRequestJson "release request should share the Lean operation adapter"
    (Beam.Cli.leanReleaseRequest path sampleBrokerHandle)
    (({ path, handle := sampleBrokerHandle } : Beam.Lean.ReleaseInput).toBrokerRequest)

  let pathInput : Beam.Lean.PathInput := { path }
  requireRequestJson "update request should share the Lean operation adapter"
    (Beam.Cli.leanUpdateRequest path)
    pathInput.toUpdateBrokerRequest
  requireRequestJson "close request should share the Lean operation adapter"
    (Beam.Cli.leanCloseRequest path)
    pathInput.toCloseBrokerRequest

  let syncInput : Beam.Lean.SyncInput := { path, diagnosticScope? := some .all }
  let saveInput : Beam.Lean.SaveInput := { path, diagnosticScope? := some .all }
  requireRequestJson "sync request should share the Lean operation adapter"
    (Beam.Cli.leanSyncRequest path .all)
    syncInput.toSyncBrokerRequest
  requireRequestJson "refresh request should share the Lean operation adapter"
    (Beam.Cli.leanRefreshRequest path .all)
    syncInput.toRefreshBrokerRequest
  requireRequestJson "save request should share the Lean operation adapter"
    (Beam.Cli.leanSaveRequest path .all)
    saveInput.toSaveBrokerRequest
  requireRequestJson "close-save request should share the Lean operation adapter"
    (Beam.Cli.leanCloseSaveRequest path .all)
    saveInput.toCloseSaveBrokerRequest

  let closeSave := Beam.Cli.leanCloseSaveRequest path .all
  require "close-save should use close broker op" (closeSave.op == .close)
  let .close closeSave := closeSave.payload
    | throw <| IO.userError "close-save should carry a close payload"
  require "close-save should request artifact save" (closeSave.saveArtifacts? == some true)
  require "close-save should preserve diagnostic scope" (closeSave.diagnosticScope? == some .all)

private def checkDiagnosticScopeArgs : IO Unit := do
  let parsers : Array (String × (List String → Beam.Cli.CliM Beam.Broker.DiagnosticScope)) := #[
    ("sync", Beam.Cli.parseLeanSyncArgs),
    ("refresh", Beam.Cli.parseLeanRefreshArgs),
    ("save", Beam.Cli.parseLeanSaveArgs),
    ("close-save", Beam.Cli.parseLeanCloseSaveArgs)
  ]
  for (label, parse) in parsers do
    require s!"{label} diagnostic scope should default to errors"
      ((← cliValue <| parse []) == .errors)
    require s!"{label} diagnostic scope should accept +all-diagnostics"
      ((← cliValue <| parse ["+all-diagnostics"]) == .all)
    expectUsageContains s!"{label} diagnostic scope should reject obsolete +full"
      "+all-diagnostics" (parse ["+full"])

private def checkDaemonFailureContext : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-failure-context-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    discard <| ensureTestControlDir root
    let registryPath ← Beam.Daemon.registryPath root
    let entry : Beam.Daemon.SessionDescriptor := {
      schemaVersion := Beam.Daemon.registrySchemaVersion
      lifecycle := .live
      daemonId := "daemon-test"
      capability := "test-capability"
      pid := 999999999
      ownerPid := 999999999
      port := 42424
      workspace := {
        workspaceId := Beam.Cli.projectDaemonWorkspaceId
        root := root.toString
        leanCmd := "lean --server"
        plugin := "/tmp/beam-plugin"
        toolchain := "leanprover/lean4:test"
        bundleId := "bundle-test"
      }
      configHash := "config-test"
      daemonBin := "/tmp/beam-daemon-test"
      installationRoot := root.toString
      startedAt := "2026-07-02T00:00:00Z"
    }
    IO.FS.writeFile registryPath ((toJson entry).pretty ++ "\n")
    let startupLog ← Beam.Daemon.daemonStartupLogPath root
    IO.FS.writeFile startupLog "line 1\nline 2\n"
    let detail := "synthetic broker transport failure"
    let failure := brokerTransportFailure detail
    let msg ← Beam.Cli.daemonFailureMessage root failure
    requireSubstring "daemon failure context should include registry path" "Beam daemon registry" msg
    requireSubstring "daemon failure context should include daemon id" "daemonId: daemon-test" msg
    requireSubstring "daemon failure context should mark persisted pids as diagnostic"
      "pid: 999999999 (diagnostic only)" msg
    requireSubstring "daemon failure context should include endpoint" "endpoint: tcp://127.0.0.1:42424" msg
    requireSubstring "daemon failure context should include toolchain" "toolchain: leanprover/lean4:test" msg
    requireSubstring "daemon failure context should include bundle id" "bundleId: bundle-test" msg
    requireSubstring "daemon failure context should include daemon log tail" "Beam daemon log tail" msg
    requireSubstring "daemon failure context should include log contents" "line 2" msg
    requireSubstring "daemon failure context should include incident path" "Beam daemon incident:" msg

    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonNat "daemon failure incident should use schema version" "schemaVersion" 1 incidentJson
    requireJsonString "daemon failure incident should classify the typed transport failure"
      "kind" "brokerTransportFailure" incidentJson
    requireJsonString "daemon failure incident should retain typed operation context"
      "detail" failure.detail incidentJson
    requireJsonString "daemon failure incident should include root"
      "root" root.toString incidentJson
    requireJsonString "daemon failure incident should include registry path"
      "registryPath" registryPath.toString incidentJson
    let incidentRegistryJson ← IO.ofExcept <| incidentJson.getObjVal? "registry"
    let incidentRegistry ← IO.ofExcept <| fromJson? (α := Beam.Daemon.SessionDescriptor) incidentRegistryJson
    require "daemon failure incident should include daemon id"
      (incidentRegistry.daemonId == "daemon-test")
    require "daemon failure incident must redact the per-generation capability"
      (incidentRegistry.capability == "<redacted>")
    requireJsonString "daemon failure incident should include endpoint summary"
      "registryEndpoint" "tcp://127.0.0.1:42424" incidentJson
    requireJsonString "daemon failure incident should include startup log path"
      "startupLogPath" startupLog.toString incidentJson
    requireJsonString "daemon failure incident should include startup log tail"
      "startupLogTail" "line 1\nline 2" incidentJson
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDaemonFailureUnreadableStartupLog : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-unreadable-startup-log-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    discard <| ensureTestControlDir root
    let startupLog ← Beam.Daemon.daemonStartupLogPath root
    IO.FS.createDir startupLog
    let msg ← Beam.Cli.daemonFailureMessage root <|
      brokerTransportFailure "Beam daemon connection closed"
    requireSubstring "unreadable startup log should preserve original daemon failure"
      "Beam daemon connection closed" msg
    requireSubstring "unreadable startup log should still write incident path"
      "Beam daemon incident:" msg
    require "unreadable startup log should not print daemon log tail"
      (!Beam.Cli.hasSubstring msg "Beam daemon log tail")

    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonString "unreadable startup log incident should classify transport failure"
      "kind" "brokerTransportFailure" incidentJson
    requireJsonNull "unreadable startup log incident should omit startup log path"
      "startupLogPath" incidentJson
    requireJsonNull "unreadable startup log incident should omit startup log tail"
      "startupLogTail" incidentJson
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkTypedDaemonFailureClassification : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-typed-failure-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    discard <| ensureTestControlDir root
    let callbackDetail := "synthetic stream callback failure"
    let callbackMsg ← Beam.Cli.daemonFailureMessage root <|
      { cause := .streamCallback (IO.userError callbackDetail) }
    require "stream callback failure should preserve its detail" (callbackMsg == callbackDetail)
    require "stream callback failure should not create a daemon incident"
      (← sortedIncidentEntries root).isEmpty

    let invalidDetail := "synthetic invalid response"
    let invalidMsg ← Beam.Cli.daemonFailureMessage root <|
      { cause := .invalidResponse invalidDetail }
    requireSubstring "invalid response should include incident path" "Beam daemon incident:" invalidMsg
    let incidentJson ← readSingleDaemonFailureIncidentJson root
    requireJsonString "invalid response incident should retain its typed classification"
      "kind" "invalidBrokerResponse" incidentJson
    requireJsonString "invalid response incident should retain its detail"
      "detail" invalidDetail incidentJson
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def writeTestRegistryEntry
    (root : System.FilePath)
    (port : UInt16 := 42424) : IO Unit := do
  let registryPath ← Beam.Daemon.registryPath root
  discard <| ensureTestControlDir root
  let entry : Beam.Daemon.SessionDescriptor := {
    schemaVersion := Beam.Daemon.registrySchemaVersion
    lifecycle := .live
    daemonId := "daemon-test"
    capability := "test-capability"
    pid := 999999999
    ownerPid := 999999999
    port
    workspace := {
      workspaceId := Beam.Cli.projectDaemonWorkspaceId
      root := root.toString
      leanCmd := "lean --server"
      plugin := "/tmp/beam-plugin"
      toolchain := "leanprover/lean4:test"
      bundleId := "bundle-test"
    }
    configHash := "config-test"
    daemonBin := "/tmp/beam-daemon-test"
    installationRoot := root.toString
    startedAt := "2026-07-05T00:00:00Z"
  }
  IO.FS.writeFile registryPath ((toJson entry).pretty ++ "\n")

private def checkProbeFailureDispositions
    (root : System.FilePath) (entry : Beam.Daemon.SessionDescriptor) : IO Unit := do
  let error := IO.userError "probe fixture failure"
  let samples : List (Beam.Broker.BrokerClientFailureCause × Beam.Cli.ProbeFailureDisposition) := [
    (.transport .connect error, .manualRecoveryRequired),
    (.transport .send error, .unresponsive),
    (.transport .receive error, .unresponsive),
    (.invalidResponse "malformed greeting", .unresponsive),
    (.streamCallback error, .unresponsive),
    (.requestTimeout 2000, .unresponsive),
    (.interrupted, .unresponsive)]
  let control ← Beam.Daemon.controlDir root
  let deliveries : List (String × Beam.Broker.BrokerRequestDelivery) := [
    ("not sent", .notSent),
    ("send attempted", .unconfirmed),
    ("response received", .responseReceived (Beam.Broker.Response.success Json.null))]
  for (cause, beforeSendExpected) in samples do
    for (deliveryLabel, delivery) in deliveries do
      let failure : Beam.Broker.BrokerClientFailure := { cause, delivery }
      let expected := match delivery with
        | .notSent => beforeSendExpected
        | .unconfirmed | .responseReceived _ => .unresponsive
      require s!"probe disposition for {repr failure} ({deliveryLabel})"
        (Beam.Cli.probeFailureDisposition failure == expected)
      let blocker := Beam.Cli.RegistryBlocker.unusable entry (.endpointProbeFailed failure)
      let cli := blocker.cliFailure root control (some "original incident context")
      let some data := cli.failure.error.data? | throw <| IO.userError "missing probe failure data"
      requireJsonString "probe failure preserves generation" "generation" entry.daemonId data
      let detail ← IO.ofExcept <| data.getObjValAs? String "detail"
      requireSubstring "probe failure preserves detail" failure.detail detail
      requireJsonString "probe failure preserves incident context" "diagnostics" "original incident context" data
      require "probe failures exit 1" (cli.exitCode == 1)
      match expected with
      | .manualRecoveryRequired =>
          require "manual recovery is conditional, not proof of settlement"
            (cli.failure.error.code == "sessionRecoveryRequired" && cli.remedyCommand?.isSome)
          let precondition ← IO.ofExcept <| data.getObjValAs? String "recoveryPrecondition"
          requireSubstring "all producer lifetimes remain an operator prerequisite" "all other producers" precondition
      | .unresponsive =>
          require "uncertain probes never advertise recovery"
            (cli.failure.error.code == "sessionUnresponsive" && cli.remedyCommand?.isNone &&
              (data.getObjVal? "remedyCommand").toOption.isNone)

private def checkRecoveryGenerationRecheck : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-recovery-generation-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let endpoint ← withBrokerListener fun _ endpoint => pure endpoint
    let .tcp port := endpoint
    writeTestRegistryEntry root port
    let registry ← Beam.Daemon.registryPath root
    let .current entry ← Beam.Daemon.readRegistry root
      | throw <| IO.userError "missing recovery fixture descriptor"
    let replacements : List (String × Beam.Daemon.SessionDescriptor) := [
      ("generation", { entry with daemonId := "replacement-generation", capability := "replacement-capability" }),
      ("capability", { entry with capability := "replacement-capability" }),
      ("root", { entry with workspace := { entry.workspace with root := (root / "different-workspace").toString } }),
      ("installation", { entry with installationRoot := (root / "different-installation").toString })]
    for (label, replacement) in replacements do
      IO.FS.writeFile registry ((toJson entry).pretty ++ "\n")
      let replacementText := (toJson replacement).pretty ++ "\n"
      let admit := fun (_ : Beam.Cli.WrapperSessionCommand) (_ _ : System.FilePath) (_ : Beam.Daemon.SessionDescriptor) =>
        (show Beam.Cli.CliM Unit from do IO.FS.writeFile registry replacementText)
      let failure ← expectCliErrorMessage s!"recovery must recheck the {label}" <|
        Beam.Cli.recoverProjectDaemon admit root entry.daemonId
      requireSubstring "recovery descriptor recheck" "descriptor changed" failure
      require "recovery must preserve the replacement descriptor"
        ((← IO.FS.readFile registry) == replacementText)
    let control ← Beam.Daemon.controlDir root
    for leaf in ← control.readDir do
      require "recovery must not quarantine a replacement generation"
        (!leaf.fileName.startsWith "beam-daemon.recovered-")
  finally
    if ← root.pathExists then IO.FS.removeDirAll root

private def checkServeDoesNotProbe : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-serve-no-probe ' {← IO.monoNanosNow}"
  let runtime : Beam.Runtime.Description := {
    command := "/missing/lean", plugin := "/missing/plugin", toolchain := "test"
    identity := ⟨"/missing/installation", "test-bundle"⟩
    daemonBin := "/missing/beam-daemon"
  }
  let desired : Beam.Cli.DesiredConfig := { root, runtime }
  try
    for matching in [true, false] do
      withBrokerListener (fun listener endpoint => do
        let .tcp port := endpoint
        writeTestRegistryEntry root port
        let registry ← Beam.Daemon.registryPath root
        let .current entry ← Beam.Daemon.readRegistry root
          | throw <| IO.userError "missing serve admission fixture"
        let entry := { entry with configHash := if matching then desired.configHash else "different-config" }
        let original := (toJson entry).pretty ++ "\n"
        IO.FS.writeFile registry original
        let result ← (Beam.Cli.withProjectDaemonOwner (fun _ => pure desired) root none
          (fun _ => pure ())).run
        -- Only our marker may be queued on this otherwise silent listener. A hidden probe would
        -- leave an earlier connection here, even if its timeout or failure were later ignored.
        let marker ← Beam.Broker.Transport.connect endpoint
        try
          Beam.Broker.Transport.sendMsg marker "no-serve-probe"
          let accepted ← Beam.Broker.Transport.accept listener
          try
            let deadline := (← IO.monoNanosNow) + 5000000000
            require "serve must not connect to the recorded endpoint"
              ((← Beam.Broker.Transport.recvMsgUntil accepted deadline) == some "no-serve-probe")
          finally
            Beam.Broker.Transport.closeConnection accepted
        finally
          Beam.Broker.Transport.closeConnection marker
        let .error failure := result | throw <| IO.userError "serve replaced an existing descriptor"
        require "existing descriptors produce setupError" (failure.failure.error.code == "setupError")
        let control ← Beam.Daemon.controlDir root
        require "serve gives the exact status selector"
          (failure.remedyCommand? == some (Beam.Cli.wrapperSessionCommand root control .status))
        let some data := failure.failure.error.data? | throw <| IO.userError "missing serve failure data"
        requireJsonString "serve preserves recorded generation" "generation" entry.daemonId data
        requireJsonString "serve identifies recorded configuration" "recordedConfigHash" entry.configHash data
        requireJsonString "serve identifies requested configuration" "requestedConfigHash" desired.configHash data
        require "serve preserves descriptor bytes" ((← IO.FS.readFile registry) == original)
      ) (backlog := 3)
  finally
    if ← root.pathExists then IO.FS.removeDirAll root

private def checkUnconfirmedShutdown : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-unconfirmed-shutdown ' {← IO.monoNanosNow}"
  try
    let endpoint ← withBrokerListener fun _ endpoint => pure endpoint
    let .tcp port := endpoint
    writeTestRegistryEntry root port
    let registry ← Beam.Daemon.registryPath root
    let control ← Beam.Daemon.controlDir root
    let .current original ← Beam.Daemon.readRegistry root
      | throw <| IO.userError "missing shutdown fixture descriptor"
    let entry := { original with lifecycle := .draining }
    let bytes := (toJson entry).pretty ++ "\n"
    IO.FS.writeFile registry bytes
    match ← Beam.Cli.observeProjectRegistry root with
    | .recoveryRequired (.unusable observed .shutdownUnconfirmed) =>
        require "shutdown observation preserves the generation" (observed == entry)
    | _ => throw <| IO.userError "unfinished shutdown must not promise an active owner"
    require "status preserves the unconfirmed shutdown descriptor" ((← IO.FS.readFile registry) == bytes)
    let .error doctorFailure ← (Beam.Cli.doctor root
        (fun _ => throw <| Beam.Cli.CliFailure.setup "fixture inspection unavailable")
        { explicitRoot? := some root }).run
      | throw <| IO.userError "doctor fixture inspection unexpectedly succeeded"
    let diagnostics := doctorFailure.contextLines
    require "doctor reports unconfirmed shutdown without prescribing recovery"
      (diagnostics.contains "daemon status: shutdown completion unconfirmed")
    require "doctor retains the exact shutdown generation"
      (diagnostics.contains s!"daemon generation: {entry.daemonId}")
    require "doctor preserves the unconfirmed shutdown descriptor" ((← IO.FS.readFile registry) == bytes)
    let actions : List (String × Beam.Cli.CliM Unit) := [
      ("repeated stop", do
        discard <| Beam.Cli.shutdownRegisteredProjectDaemon (fun _ _ _ _ => pure ()) root),
      ("attachment", Beam.Cli.withProjectDaemon (fun _ => pure entry.configHash) root
        (fun _ => throw <| Beam.Cli.CliFailure.internal (IO.userError "unexpected attachment")))]
    for (label, action) in actions do
      let .error failure ← action.run | throw <| IO.userError s!"{label} ignored the shutdown fence"
      require label (failure.exitCode == 1 && failure.failure.error.code == "sessionShutdownUnconfirmed")
      requireSubstring "shutdown does not infer owner death" "completion is unconfirmed" failure.failure.error.message
      require "shutdown remedy observes the exact session instead of recovering it"
        (failure.remedyCommand? == some (Beam.Cli.installationSessionCommand
          (System.FilePath.mk entry.installationRoot) root control .status))
      let some data := failure.failure.error.data? | throw <| IO.userError "missing shutdown recovery data"
      requireJsonString "shutdown recovery generation" "generation" entry.daemonId data
      requireJsonString "conditional shutdown recovery selects the owning installation" "recoveryCommand"
        (Beam.Cli.installationSessionCommand (System.FilePath.mk entry.installationRoot)
          root control (.recoverGeneration entry.daemonId)) data
      let precondition ← IO.ofExcept <| data.getObjValAs? String "recoveryPrecondition"
      requireSubstring "all producers must stop before recovery" "all other producers" precondition
      require "observation preserves the shutdown fence" ((← IO.FS.readFile registry) == bytes)
    -- This fixture owns no processes. Its closed endpoint and complete lack of producers are
    -- independently established here; the observation above does not establish those facts.
    match ← cliValue <| Beam.Cli.recoverProjectDaemon (fun _ _ _ _ => pure ()) root entry.daemonId with
    | .recoveredGeneration generation archived =>
        require "manual recovery retains the exact shutdown generation" (generation == entry.daemonId)
        require "manual recovery preserves shutdown evidence" ((← IO.FS.readFile archived) == bytes)
    | _ => throw <| IO.userError "explicit shutdown recovery did not quarantine the fixture"
    require "explicit recovery removes the original fence" (!(← registry.pathExists))
  finally
    if ← root.pathExists then IO.FS.removeDirAll root

private def checkTypedRegistryReads : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-typed-registry-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    discard <| ensureTestControlDir root
    let registryPath ← Beam.Daemon.registryPath root

    match ← Beam.Daemon.readRegistry root with
    | .absent => pure ()
    | state => throw <| IO.userError s!"missing registry was classified as {state.status}"

    IO.FS.writeFile registryPath "{\"daemonId\":\"legacy\"}\n"
    match ← Beam.Daemon.readRegistry root with
    | .invalid .missingSchema => pure ()
    | state => throw <| IO.userError s!"schema-less descriptor was classified as {state.status}"

    IO.FS.writeFile registryPath "{\"schemaVersion\":999}\n"
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.unsupportedSchema 999) => pure ()
    | state => throw <| IO.userError s!"unsupported registry was classified as {state.status}"

    IO.FS.writeFile registryPath "{\"schemaVersion\":2}\n"
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.unsupportedSchema 2) => pure ()
    | state => throw <| IO.userError s!"superseded multi-workspace registry was classified as {state.status}"

    IO.FS.writeFile registryPath "{\"schemaVersion\":\"one\"}\n"
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "mistyped registry schemaVersion should be malformed"
          (detail.contains "invalid registry schemaVersion")
    | state => throw <| IO.userError s!"mistyped registry version was classified as {state.status}"

    IO.FS.writeFile registryPath "{"
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "malformed registry should preserve parse context" (detail.contains "invalid registry JSON")
    | state => throw <| IO.userError s!"malformed registry was classified as {state.status}"

    IO.FS.writeFile registryPath
      ("{\"schemaVersion\":" ++ toString Beam.Daemon.registrySchemaVersion ++ "}\n")
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "incomplete current registry should preserve schema context"
          (detail.contains "invalid registry schema")
    | state => throw <| IO.userError s!"incomplete registry was classified as {state.status}"

    writeTestRegistryEntry root
    match ← Beam.Daemon.readRegistry root with
    | .current entry =>
        require "current registry should preserve its generation capability"
          (entry.capability == "test-capability")
        checkProbeFailureDispositions root entry
    | state => throw <| IO.userError s!"current registry was classified as {state.status}"

    let longGeneration := String.ofList <| List.replicate 100000 'x'
    match ← (Beam.Cli.recoverProjectDaemon
        (fun _ _ _ _ => throw <| Beam.Cli.CliFailure.internal
          (IO.userError "mismatched generation reached ownership admission")) root longGeneration).run with
    | .ok _ => throw <| IO.userError "long mismatched generation unexpectedly recovered"
    | .error failure =>
        require "long recovery generation is a bounded usage failure"
          (failure.exitCode == 2 && failure.failure.error.code == "invalidParams" &&
            failure.failure.error.message.length < 1024)
        let some data := failure.failure.error.data? | throw <| IO.userError "missing recovery argument data"
        let argument ← IO.ofExcept <| data.getObjVal? "argument"
        requireJsonString "recovery argument field" "field" "generation" argument
        let omitted ← IO.ofExcept <| argument.getObjValAs? Nat "omittedChars"
        require "long recovery generation keeps omitted length" (omitted == 99872)
        require "local response must not echo the complete recovery generation" ((toJson (Beam.Broker.Response.errorResult failure.failure)).compress.length < 2048)

    let validText ← IO.FS.readFile registryPath
    let validJson ← IO.ofExcept <| Json.parse validText
    let eraseObjectField (json : Json) (field : String) : Json :=
      match json with
      | .obj fields => .obj (fields.erase field)
      | other => other
    let expectMalformedRegistry (label needle : String) (json : Json) : IO Unit := do
      IO.FS.writeFile registryPath json.compress
      match ← Beam.Daemon.readRegistry root with
      | .invalid (.malformed detail) =>
          require label (detail.contains needle)
      | state => throw <| IO.userError s!"{label}: descriptor was classified as {state.status}"
      require s!"{label}: malformed descriptor should be preserved"
        ((← IO.FS.readFile registryPath) == json.compress)

    expectMalformedRegistry "missing daemon binary should fail the typed boundary"
      "invalid registry schema" (eraseObjectField validJson "daemonBin")
    expectMalformedRegistry "missing installation ownership should fail the typed boundary"
      "invalid registry schema" (eraseObjectField validJson "installationRoot")
    expectMalformedRegistry "relative installation ownership should fail the typed boundary"
      "owning installation root must be absolute"
      (validJson.setObjVal! "installationRoot" (toJson "relative/installation"))
    let previous := eraseObjectField (validJson.setObjVal! "schemaVersion" (toJson (4 : Nat)))
      "installationRoot"
    IO.FS.writeFile registryPath previous.compress
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.unsupportedSchema 4) => pure ()
    | state => throw <| IO.userError s!"descriptor without typed ownership was classified as {state.status}"
    require "superseded descriptor remains preserved" ((← IO.FS.readFile registryPath) == previous.compress)

    let workspaceJson ← IO.ofExcept <| validJson.getObjVal? "workspace"
    for field in #["rocqCmd", "unexpected"] do
      expectMalformedRegistry s!"workspace descriptor rejects undeclared field {field}"
        field <| validJson.setObjVal! "workspace" <|
          workspaceJson.setObjVal! field (toJson "coq-lsp")
    expectMalformedRegistry "session descriptor rejects undeclared fields"
      "unexpected" (validJson.setObjVal! "unexpected" (toJson true))
    expectMalformedRegistry "missing bundle id should fail the typed boundary"
      "invalid registry schema" <|
        validJson.setObjVal! "workspace" (eraseObjectField workspaceJson "bundleId")
    for field in #["leanCmd", "plugin", "toolchain"] do
      expectMalformedRegistry s!"workspace descriptor requires {field}"
        field <| validJson.setObjVal! "workspace" (eraseObjectField workspaceJson field)
      expectMalformedRegistry s!"workspace descriptor rejects null {field}"
        "invalid registry schema" <| validJson.setObjVal! "workspace" <|
          workspaceJson.setObjVal! field Json.null
    expectMalformedRegistry "empty bundle id should fail descriptor validation"
      "bundle id must not be empty" <|
        validJson.setObjVal! "workspace" <| workspaceJson.setObjVal! "bundleId" (toJson "")
    expectMalformedRegistry "empty daemon binary should fail descriptor validation"
      "daemon binary must not be empty" <| validJson.setObjVal! "daemonBin" (toJson "")
    expectMalformedRegistry "empty Lean command should fail descriptor validation"
      "Lean command must not be empty" <|
        validJson.setObjVal! "workspace" <| workspaceJson.setObjVal! "leanCmd" (toJson "")
    expectMalformedRegistry "empty Lean plugin should fail descriptor validation"
      "Lean plugin must not be empty" <|
        validJson.setObjVal! "workspace" <| workspaceJson.setObjVal! "plugin" (toJson "")
    expectMalformedRegistry "empty Lean toolchain should fail descriptor validation"
      "Lean toolchain must not be empty" <|
        validJson.setObjVal! "workspace" <| workspaceJson.setObjVal! "toolchain" (toJson "")

    let missingPortJson :=
      eraseObjectField validJson "port"
    IO.FS.writeFile registryPath missingPortJson.compress
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "missing current endpoint should fail the typed boundary"
          (detail.contains "invalid registry schema")
    | state => throw <| IO.userError s!"endpoint-less registry was classified as {state.status}"

    IO.FS.writeFile registryPath <|
      (validJson.setObjVal! "port" (toJson 65536)).compress
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "out-of-range current endpoint should fail the typed boundary"
          (detail.contains "invalid registry schema")
    | state => throw <| IO.userError s!"out-of-range endpoint was classified as {state.status}"

    expectMalformedRegistry "port zero should fail descriptor validation"
      "port must be in range 1-65535" <| validJson.setObjVal! "port" (toJson 0)

    IO.FS.writeFile registryPath <|
      (validJson.setObjVal! "workspace" (Json.mkObj [])).compress
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.malformed detail) =>
        require "incomplete workspace descriptors should fail the typed boundary"
          (detail.contains "invalid registry schema")
    | state => throw <| IO.userError s!"empty workspace descriptor was classified as {state.status}"

    IO.FS.writeFile registryPath validText
    let debug ← Beam.Daemon.daemonDebugContextJson root
    let debugRegistry ← IO.ofExcept <| debug.getObjVal? "registry"
    requireJsonString "daemon debug context must redact its capability"
      "capability" "<redacted>" debugRegistry

    let symlinkTarget := root / "registry-symlink-target.json"
    let targetText := validText
    IO.FS.writeFile symlinkTarget targetText
    IO.FS.removeFile registryPath
    createSymlink "registry fixture" symlinkTarget registryPath
    match ← Beam.Daemon.readRegistry root with
    | .invalid (.unsafeLeaf detail) =>
        requireSubstring "symlinked registry detail" "symbolic links are not accepted" detail
    | state => throw <| IO.userError s!"symlinked registry was classified as {state.status}"
    requireSubstring "stop should reject a symlinked registry"
      "symbolic links are not accepted"
      (← expectCliErrorMessage "symlinked stop" <| Beam.Cli.shutdownRegisteredProjectDaemon (fun _ _ _ _ => pure ()) root)
    requireSubstring "recovery should reject a symlinked registry"
      "symbolic links are not accepted"
      (← expectCliErrorMessage "symlinked recover" <| Beam.Cli.recoverProjectDaemon (fun _ _ _ _ => pure ()) root "fixture-generation")
    require "registry operations must not mutate a symlink target"
      ((← IO.FS.readFile symlinkTarget) == targetText)
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkBrokerConnectionClosedIncident : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-broker-connection-closed-incident-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    withClosingBrokerEndpoint fun endpoint => do
      let port :=
        match endpoint with
        | .tcp port => port
      writeTestRegistryEntry root port
      let controlDir ← Beam.Daemon.controlDir root
      let stopped : Beam.Cli.InterruptWatcher := {
        interrupted := pure true
        awaitInterrupt := pure ()
      }
      let stoppedMsg ← expectCliErrorMessage "a latched stop must survive request handoff" <|
        Beam.Cli.ensureProjectSession stopped root (projectDaemonClientForTest endpoint controlDir)
      requireSubstring "latched stop must cancel before consuming the broker connection"
        "Beam request interrupted" stoppedMsg
      let msg ← expectCliErrorMessage "broker connection close should surface daemon failure" <|
        ExceptT.mk <| Beam.Cli.withOwnerInterruptWatcher fun watcher =>
          (Beam.Cli.ensureProjectSession watcher root (projectDaemonClientForTest endpoint controlDir)).run
      requireSubstring "broker connection close should preserve transport failure"
        "Beam daemon receive failed:" msg
      requireSubstring "broker connection close should include incident path"
        "Beam daemon incident:" msg

      let incidentJson ← readSingleDaemonFailureIncidentJson root
      requireJsonString "broker close incident should classify the typed transport failure"
        "kind" "brokerTransportFailure" incidentJson
      requireJsonStringContains "broker close incident should keep transport detail"
        "detail" "Beam daemon receive failed:" incidentJson
      requireJsonString "broker close incident should include endpoint summary"
        "registryEndpoint" (Beam.Daemon.endpointSummary endpoint) incidentJson
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDaemonFailureIncidentRetention : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-incident-retention-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    discard <| ensureTestControlDir root
    let incidentDir ← Beam.Daemon.daemonFailureIncidentDir root
    Beam.ensurePrivateDir "test Beam daemon incident directory" incidentDir
    for i in [0:55] do
      IO.FS.writeFile (incidentDir / s!"000000000000000000{i}.json") "{}\n"
    let msg ← Beam.Cli.daemonFailureMessage root <|
      brokerTransportFailure "Beam daemon connection closed"
    requireSubstring "retention failure should include incident path" "Beam daemon incident:" msg
    let entries ← sortedIncidentEntries root
    require s!"daemon incident retention should keep 50 files, got {entries.size}" (entries.size == 50)
    let newIncidents := entries.filter (fun entry => entry.fileName.contains "brokerTransportFailure")
    require "daemon incident retention should keep newly written incident"
      (newIncidents.size == 1)
    let some newIncident := newIncidents[0]?
      | throw <| IO.userError "expected retained daemon failure incident entry"
    require "daemon incident filename should use sortable timestamp prefix"
      (newIncident.fileName.startsWith "incident-")
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDoctorDaemonFailureIncidentLines : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-doctor-daemon-incidents-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let absentLines ← Beam.Cli.daemonFailureIncidentDoctorLines root
    require "doctor should report no daemon incidents when directory is absent"
      (absentLines == ["daemon incidents: none"])

    discard <| ensureTestControlDir root
    discard <| Beam.Cli.daemonFailureMessage root <|
      brokerTransportFailure "Beam daemon connection closed"
    let lines ← Beam.Cli.daemonFailureIncidentDoctorLines root
    require s!"doctor should report one recent daemon incident, got {lines}"
      (lines.head? == some "daemon incidents: 1 recent")
    let some incidentLine := lines.tail?.bind (·.head?)
      | throw <| IO.userError s!"doctor should include daemon incident path line, got {lines}"
    requireSubstring "doctor daemon incident line should include prefix"
      "daemon incident: " incidentLine
    requireSubstring "doctor daemon incident line should include incident directory"
      "daemon-failures" incidentLine
  finally
    try
      let control ← Beam.Daemon.controlDir root
      if ← control.pathExists then
        IO.FS.removeDirAll control
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkDaemonFailureIncidentDoesNotRecreateRoot : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-daemon-incident-deleted-root-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let control ← ensureTestControlDir root
    IO.FS.removeDirAll root
    let msg ← Beam.Cli.daemonFailureMessage root
      (brokerTransportFailure "Beam daemon connection closed") (some control)
    require "incident logging should preserve the original transport detail"
      (msg.contains "Beam daemon connection closed")
    require "incident logging must not recreate a deleted project root"
      (!(← root.pathExists))
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkPathCanonicalization : IO Unit := do
  let stamp ← IO.monoNanosNow
  let root := System.FilePath.mk s!"/tmp/beam-path-canonical-root-{stamp}"
  let alias := System.FilePath.mk s!"/tmp/beam-path-canonical-alias-{stamp}"
  let dotdotAlias := System.FilePath.mk s!"/tmp/beam-path-dotdot-alias-{stamp}"
  let missingUnderRoot := root / "missing" / "session"
  let missingUnderAlias := alias / "missing" / "session"
  try
    IO.FS.createDirAll root
    createSymlink "path canonicalization fixture" root alias
    IO.FS.createDir (root / "existing")
    createSymlink "path dotdot canonicalization fixture" (root / "existing") dotdotAlias
    require "canonical path equality should treat symlinked workspace roots as the same path"
      (← Beam.sameFilePath root alias)
    require "missing paths should fall back to exact text equality"
      (!(← Beam.sameFilePath missingUnderRoot missingUnderAlias))
    let resolvedBeforeCreation ← Beam.resolvePathForCreation missingUnderAlias
    let expectedBeforeCreation := (← Beam.resolveExistingPath root) / "missing" / "session"
    require "creation-path resolution should canonicalize the longest existing ancestor"
      (resolvedBeforeCreation == expectedBeforeCreation)
    IO.FS.createDirAll missingUnderAlias
    let resolvedAfterCreation ← Beam.resolveExistingPath missingUnderAlias
    require "creation-path identity should remain stable after creating the missing suffix"
      (resolvedAfterCreation == resolvedBeforeCreation)
    let missingAfterSymlinkDotdot := dotdotAlias / ".." / "dotdot-missing" / "session"
    let resolvedAfterSymlinkDotdot ← Beam.resolvePathForCreation missingAfterSymlinkDotdot
    let expectedAfterSymlinkDotdot :=
      ((← Beam.resolveExistingPath root) / "dotdot-missing" / "session").normalize
    require "creation-path resolution should preserve filesystem semantics for symlink followed by dotdot"
      (resolvedAfterSymlinkDotdot == expectedAfterSymlinkDotdot)
    IO.FS.createDirAll missingAfterSymlinkDotdot
    require "symlink-dotdot path identity should remain stable after creation"
      ((← Beam.resolveExistingPath missingAfterSymlinkDotdot) == resolvedAfterSymlinkDotdot)
  finally
    try
      if ← dotdotAlias.pathExists then
        IO.FS.removeFile dotdotAlias
    catch _ =>
      pure ()
    try
      if ← alias.pathExists then
        IO.FS.removeFile alias
    catch _ =>
      pure ()
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkLockLifecycle : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-cli-lock-test-{← IO.monoNanosNow}"
  let lockPath := root / "lock"
  try
    Beam.Cli.withLock lockPath do
      require "lock file should exist while lock is held" (← lockPath.pathExists)
      expectIoErrorContains "contended kernel lock timeout" "timed out after" <|
        Beam.Cli.withLockTimeout lockPath 100 do
          pure ()
    require "stable lock file should remain after release" (← lockPath.pathExists)

    Beam.Cli.withLockTimeout lockPath 100 do
      require "released kernel lock should be immediately reusable" true

    Beam.Cli.withLock lockPath do
      expectIoErrorContains "second contended kernel lock timeout" "timeout: 100 ms" <|
        Beam.Cli.withLockTimeout lockPath 100 do
          pure ()
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

private def checkSdkRuntimeAdmission : IO Unit := do
  let layout : Beam.Installation.Bundled.Layout := { root := "/sdk" }
  let p : Beam.Installation.Bundled.Provenance := {
    schemaVersion := 3
    sourceCommit := "beam-source"
    buildId := "build-one"
    payloadHash := "payload-one"
    components := {
      frontends := {
        cli := "bin/lean-beam"
        mcp := "bin/lean-beam-mcp"
        compilerRevision := Lean.githash
      }
      license := "LICENSE"
      targets := #[{
        lean := "bin/lean", daemon := "bin/beam-daemon", plugin := "lib/beam-plugin"
        toolchain := "SDK compiler version", compilerRevision := Lean.githash
        leanVersion := "SDK compiler version", lakeVersion := "Lake version"
      }]
    }
    artifacts := #["bin/lean-beam", "bin/lean-beam-mcp", "bin/beam-daemon", "lib/beam-plugin", "LICENSE"].map
      fun path => { source := path, destination := path, hash := String.ofList (List.replicate 64 'a') }
  }
  let compiled : Beam.BuildInfo.Identity := {
    compilerRevision := Lean.githash, sourceRevision := p.sourceCommit, buildId := p.buildId
  }
  let validate := Beam.Installation.Bundled.validateProvenance (layout.home / "provenance.json") compiled Lean.githash
  discard <| IO.ofExcept <| (validate p).mapError (·.message)
  for invalid in [{ p with schemaVersion := 0 }, { p with payloadHash := "" },
      { p with buildId := "replacement-build" }] do
    require "invalid native construction record must fail" (!(validate invalid).isOk)
  for revision in ["stale-compiler", ""] do
    require "compiled compiler identity must be independently checked"
      (!(Beam.Installation.Bundled.validateProvenance (layout.home / "provenance.json")
        { compiled with compilerRevision := revision } Lean.githash p).isOk)

private def withFirstStderrWrite (before : IO Unit) (action : IO α) : IO α := do
  let stderr ← IO.getStderr
  let first ← IO.mkRef true
  let observed := { stderr with putStr := fun text => do
    if ← first.get then
      first.set false
      before
    stderr.putStr text
  }
  IO.withStderr observed action

/-- Run the real CLI request/rendering path against a parent-owned fake broker. -/
private def blockedOutputRequest : Beam.Broker.Request := {
  payload := .saveOlean { path := "Main.lean" }
}

def blockedOutput (stream : String) (port : UInt16) : Beam.Cli.CliM Unit := do
  let root : System.FilePath := "/tmp"
  let client := projectDaemonClientForTest (.tcp port) root
  match stream with
  | "progress-start" =>
      ExceptT.mk <| withFirstStderrWrite (do
        IO.println "progress start reached"
        (← IO.getStdout).flush
        -- The parent sends SIGINT before releasing the first progress write.
        unless (← (← IO.getStdin).getLine) == "release\n" do
          throw <| IO.userError "progress start gate was not released") <|
        (Beam.Cli.callBrokerWithProgress root client blockedOutputRequest
          (Beam.Cli.syncWaitSpec "Main.lean")).run
  | "stderr" =>
      ExceptT.mk <| withFirstStderrWrite (do
        IO.println "diagnostic write reached"
        (← IO.getStdout).flush) <|
        (Beam.Cli.callBrokerWithProgress root client blockedOutputRequest
          (Beam.Cli.syncWaitSpec "Main.lean")).run
  | "stderr-fails" | "stderr-fails-once" | "stderr-flush-fails" =>
      let stderr ← IO.getStderr
      let first ← IO.mkRef true
      let fail : IO Unit := do
        if ← first.get then
          first.set false
          IO.println "fixture stderr failed"
          (← IO.getStdout).flush
        throw <| IO.userError "fixture stderr write or flush failed"
      let failing := if stream == "stderr-flush-fails" then
          { stderr with flush := fail }
        else
          { stderr with putStr := fun text => do
            -- Progress tests must fail on the broker event, after the request
            -- was sent, rather than on the locally queued start notice.
            if text.contains "fixture progress start" then return
            if (← first.get) || stream == "stderr-fails" then fail
            else stderr.putStr text
          }
      let spec := { Beam.Cli.syncWaitSpec "Main.lean" with startMsg := "fixture progress start" }
      ExceptT.mk <| IO.withStderr failing <|
        (Beam.Cli.callBrokerWithProgress root client blockedOutputRequest spec).run
  | "stdout" => Beam.Cli.callBroker root client blockedOutputRequest
  | "stdout-progress" =>
      Beam.Cli.callBrokerWithProgress root client blockedOutputRequest
        (Beam.Cli.syncWaitSpec "Main.lean")
  | _ => throw <| Beam.Cli.CliFailure.usage s!"unknown blocked output stream: {stream}"

/-- Exercise physical writes and flushes while counting every final response attempt. -/
def withFailedStdout (stream : String) (action : Beam.Cli.CliM Unit)
    (output : Beam.Cli.FailureOutput := .jsonAndDiagnostic) : IO UInt32 := do
  let stdout ← IO.getStdout
  let attempts ← IO.mkRef 0
  let failing := if stream == "stdout-fails" then
      { stdout with putStr := fun text => do
        attempts.modify (· + 1)
        stdout.putStr (text.take 12).toString
        stdout.flush
        throw <| IO.userError "fixture stdout write failed"
      }
    else
      { stdout with flush := do
        attempts.modify (· + 1)
        stdout.flush
        throw <| IO.userError "fixture stdout flush failed"
      }
  let code ← IO.withStdout failing <| Beam.Cli.run (action *> pure 0) output
  IO.eprintln s!"fixture response write attempts: {← attempts.get}"
  pure code

private def checkClientDoctorFailureIsolation : IO Unit := do
  let failed ← Beam.Cli.ClientDoctor.inspectSafely .codex false do
    throw <| IO.userError "DOCTOR_SECRET_SENTINEL"
  require "client inspection faults must not expose exception contents"
    (failed.findings.size == 1 && failed.findings[0]?.any (·.code == "inspection.failed") &&
      !Beam.Cli.hasSubstring ((toJson failed).compress) "DOCTOR_SECRET_SENTINEL")
  require "client inspection faults are incomplete, not absent"
    (failed.mcp == .unverified && failed.skill == .unverified && failed.discovered)
  let explicit ← Beam.Cli.ClientDoctor.inspectSafely .pi true do
    throw <| IO.userError "DOCTOR_SECRET_SENTINEL"
  require "inspection faults retain explicit scope and Pi's lack of MCP"
    (explicit.mcp == .notApplicable && explicit.skill == .outOfScope)

def clientReport (severity : String) : Beam.Cli.ClientDoctor.Report := {
  workspace := "fixture"
  clients := #[{
    client := .codex
    findings := match severity with
      | "0" => #[]
      | "1" => #[{ code := "fixture.error", status := .error, message := "fixture" }]
      | _ => #[{ code := "fixture.incomplete", status := .unknown, message := "fixture" }]
  }]
}

private def checkClientReportOutput : IO Unit := do
  for severity in ["0", "1", "2"] do
    let report := clientReport severity
    for format in [Beam.Cli.JsonOutputFormat.compact, .pretty] do
      for stream in ["write", "flush"] do
        let attempts ← IO.mkRef 0
        let fail := do
          attempts.modify (· + 1)
          throw <| IO.userError "fixture report output failed"
        let stdout ← IO.getStdout
        let failing := if stream == "write" then { stdout with putStr := fun _ => fail }
          else { stdout with putStr := fun _ => pure (), flush := fail }
        let .error failure ← IO.withStdout failing <|
            (Beam.Cli.ClientDoctor.emitReport report { json := true } format).run
          | throw <| IO.userError "report output failure was ignored"
        require "report output attempted once" ((← attempts.get) == 1)
        require "report output suppresses fallback JSON" failure.responseStarted
        require "report output retains selected JSON format" (failure.jsonOutputFormat == format)
        require "report output retains diagnostic exit status"
          (failure.exitCode == max 1 report.exitCode)
        let some data := failure.failure.error.data?
          | throw <| IO.userError "report output lost its completed inspection"
        require "report output retains the typed report at the output boundary"
          ((data.getObjVal? "inspection").toOption == some (toJson report))

def main : IO Unit := do
  checkSdkRuntimeAdmission
  checkClientDoctorFailureIsolation
  checkClientReportOutput
  checkLeanConfigLowering
  checkProjectDaemonRequestSealing
  checkClientResponsePresentation
  checkFinalResponseWriteEvidence
  checkWorkspaceOutputPresentation
  checkCliRecoveryHints
  checkSyncWaitSpecs
  checkCliRootParsing
  checkProjectRootSelection
  checkProfileArgumentParsing
  checkLeanOperationRequests
  checkDiagnosticScopeArgs
  checkDaemonFailureContext
  checkDaemonFailureUnreadableStartupLog
  checkTypedDaemonFailureClassification
  checkRequestDeliveryEvidence
  checkSilentEndpointProbeTimeout
  checkSilentShutdownTimeout
  checkPlainBrokerTaskCancellation
  checkBrokerSendInterruption
  checkWrongGreetingProtectsRequest
  checkStderrCaptureSurvivesSinkFailure
  checkStderrSinkDisableIsSynchronized
  checkStderrCaptureDoesNotJoinInheritedPipe
  OutputTest.check
  checkBrokerConnectionClosedIncident
  checkServeDoesNotProbe
  checkUnconfirmedShutdown
  checkTypedRegistryReads
  checkRecoveryGenerationRecheck
  checkDaemonFailureIncidentRetention
  checkDoctorDaemonFailureIncidentLines
  checkDaemonFailureIncidentDoesNotRecreateRoot
  checkPathCanonicalization
  checkLockLifecycle

end BeamTest.Broker.CliDaemonTest

def main (args : List String) : IO UInt32 :=
  match args with
  | [] => do BeamTest.Broker.CliDaemonTest.main; pure 0
  | ["--interrupt-watcher", mode] => BeamTest.Broker.InterruptWatcherTest.child mode
  | ["--blocked-output", stream, port] => do
      let some port := port.toNat?
        | throw <| IO.userError "invalid fixture port"
      unless port > 0 && port < 65536 do throw <| IO.userError "invalid fixture port"
      if stream == "stdout-fails" || stream == "stdout-flush-fails" then
        BeamTest.Broker.CliDaemonTest.withFailedStdout stream <|
          BeamTest.Broker.CliDaemonTest.blockedOutput "stdout" port.toUInt16
      else
        Beam.Cli.run <| BeamTest.Broker.CliDaemonTest.blockedOutput stream port.toUInt16 *> pure 0
  | ["--cli-error", "owner-output", stream] =>
      BeamTest.Broker.CliDaemonTest.withFailedStdout stream <|
        Beam.Cli.withOwnerResponse fun printReadiness => do
          try
            printReadiness <| Beam.Broker.Response.success <| Json.mkObj [("state", toJson "running")]
          finally
            -- A raw cleanup error replaces the typed writer failure, just as an
            -- owner finalizer can. The enclosing output scope must retain the guard.
            let cleanup : IO Unit := throw <| IO.userError "fixture owner cleanup failed"
            cleanup
  | ["--doctor-report-output", mode, stream] =>
      BeamTest.Broker.CliDaemonTest.withFailedStdout stream
        (Beam.Cli.doctor "." (fun _ => pure ["fixture inspection complete"])
          { explicitRoot? := some "." } (json := mode == "json"))
        (output := if mode == "json" then .json else .text)
  | ["--client-report-output", severity, stream, format] => do
      let format ← match format with
        | "compact" => pure Beam.Cli.JsonOutputFormat.compact
        | "pretty" => pure Beam.Cli.JsonOutputFormat.pretty
        | _ => throw <| IO.userError "invalid report fixture format"
      BeamTest.Broker.CliDaemonTest.withFailedStdout stream do
        discard <| Beam.Cli.ClientDoctor.emitReport
          (BeamTest.Broker.CliDaemonTest.clientReport severity) { json := true } format
  | ["--cli-error", "internal"] => Beam.Cli.run do
      let action : IO Unit := throw <| IO.userError "fixture unexpected fault"
      action
      pure 0
  | ["--cli-error", "doctor-lookup", root, control] =>
      let root := System.FilePath.mk root
      let control := System.FilePath.mk control
      Beam.Cli.run do
        Beam.Cli.doctor "."
          (fun root => Beam.Cli.withProjectDaemon
            (fun _ => pure "fixture-requested-config") root (fun _ => pure []) (some control))
          { explicitRoot? := some root, explicitControlDir? := some control }
        pure 0
  | ["--cli-error", "pre-input", kind] => do
      IO.eprintln "fixture-input-ready"
      (← IO.getStderr).flush
      Beam.Cli.run do
        if kind == "text" then
          discard <| Beam.Cli.parseTextArg "run-at fixture" ["--stdin"]
        else
          discard <| Beam.Cli.parseHandleArg "-"
        throw <| Beam.Cli.CliFailure.setup "input fixture unexpectedly reached EOF"
  | ["--cli-error", "input-io", kind] => Beam.Cli.run do
      let error : IO.Error := match kind with
        | "missing" => .noFileOrDirectory "fixture-input" 2 "missing"
        | "permission" => .permissionDenied (some "fixture-input") 13 "denied"
        | "eio" => .hardwareFault 5 "fixture IO fault"
        | _ => .resourceExhausted none 24 "fixture resource exhaustion"
      throw <| Beam.Cli.CliFailure.inputFile "--text-file" "fixture-input" error
  | ["--cli-error", "broker"] => Beam.Cli.run do
      let failure : Beam.Broker.ResponseFailure := {
        error := {
          code := "fileChanged"
          message := "fixture stale file"
          data? := some (Json.mkObj [("version", toJson (7 : Nat))])
        }
        fileProgress? := some { updates := 9, done := false }
      }
      Beam.Cli.failOnError (.errorResult failure) (some "fixture-request")
      pure 0
  | ["--cli-error", "semantic"] => Beam.Cli.run do
      let response := Beam.Broker.Response.success (Json.mkObj [("success", toJson false)])
      Beam.Cli.failOnError response
      Beam.Cli.printResponse response
      pure 0
  | _ => throw <| IO.userError "unexpected CLI daemon test arguments"
