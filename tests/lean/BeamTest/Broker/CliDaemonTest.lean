/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.CompilerRevision
import Beam.Broker.Errors
import Beam.Cli.Args
import Beam.Cli.Broker
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
open BeamTest.Broker.JsonAssert (requireJsonNull requireJsonString)

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
  .transport .receive (IO.userError detail)

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
    toolchain := "leanprover/lean4:v4.33.0"
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
      | .probeFailed (.requestTimeout timeoutMs) =>
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
      | .error (.requestTimeout timeoutMs) =>
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
      Beam.Cli.requestBroker (System.FilePath.mk "/tmp")
        (projectDaemonClientForTest endpoint (System.FilePath.mk "/tmp")) Beam.Broker.Request.stats
    let some _ ← IO.wait requestObserved.result?
      | throw <| IO.userError "plain wrapper request observation promise dropped"
    IO.cancel requestTask
    match ← IO.wait requestTask with
    | .ok response =>
        throw <| IO.userError s!"interrupted plain wrapper request returned {toJson response}"
    | .error err =>
        requireSubstring "interrupted plain wrapper request" "Beam request interrupted" err.toString
    match ← IO.wait serverTask with
    | .ok () => pure ()
    | .error err => throw err

private def serveGreetingWithoutReading
    (listener : Beam.Broker.Transport.Listener)
    (identity : Beam.Broker.DaemonIdentity)
    (greeted release : IO.Promise Unit) : IO Unit := do
  let conn ← Beam.Broker.Transport.accept listener
  try
    Beam.Broker.Transport.sendMsg conn <|
      toJson (Beam.Broker.ServerHello.current identity) |>.compress
    greeted.resolve ()
    let some _ ← IO.wait release.result?
      | throw <| IO.userError "blocked-send release promise dropped"
    pure ()
  finally
    Beam.Broker.Transport.closeConnection conn

private def checkBrokerSendInterruption : IO Unit := do
  withBrokerListener fun listener endpoint => do
    let identity : Beam.Broker.DaemonIdentity := {
      daemonId := "test-generation"
      configHash := "test-config"
    }
    let greeted ← IO.Promise.new
    let release ← IO.Promise.new
    let interrupted ← IO.mkRef false
    let serverTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      serveGreetingWithoutReading listener identity greeted release
    let largeText := String.ofList (List.replicate (8 * 1024 * 1024) 'x')
    let clientTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      Beam.Broker.sendRequestWithCallbacksInterruptiblyResult endpoint {
        payload := .runAt {
          path := "Secret.lean"
          version := 1
          line := 0
          character := 0
          text := largeText
        }
        workspaceId? := some Beam.Cli.projectDaemonWorkspaceId
        clientRequestId? := some "blocked-send"
        daemonCapability? := some "test-capability"
      } interrupted.get (server := .wrapper identity)
    let some _ ← IO.wait greeted.result?
      | throw <| IO.userError "blocked-send greeting promise dropped"
    IO.sleep 100
    interrupted.set true
    let result? ← Beam.waitTaskWithTimeout clientTask 2000
    release.resolve ()
    let some result := result?
      | throw <| IO.userError "interrupt did not release a blocked Beam request send"
    match result with
    | .ok (.error .interrupted) => pure ()
    | .ok (.error failure) =>
        throw <| IO.userError s!"blocked send reported {repr failure} instead of interruption"
    | .ok (.ok response) =>
        throw <| IO.userError s!"blocked send unexpectedly returned {toJson response}"
    | .error err => throw err
    match ← IO.wait serverTask with
    | .ok () => pure ()
    | .error err => throw err

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
    let msg ← expectIoErrorMessage "wrong daemon greeting" <|
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
    Beam.Cli.responseOutputJson semantic (some "visible-request")
  requireJsonString "presented response" "clientRequestId" "visible-request" presented
  match fromJson? (α := Beam.Broker.Response) presented with
  | .ok response =>
      throw <| IO.userError
        s!"presentation-decorated response decoded as semantic response: {(toJson response).compress}"
  | .error _ => pure ()

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
      "lean-beam refresh \"SaveSmoke/A.lean\"",
      "lake build"
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
  requireSubstring "syncBarrier recovery hint" "lake build" hint

  let fallbackResp := Beam.Broker.errorResponseFor
    .syncBarrierIncomplete
    "Lean diagnostics barrier did not complete"
    (some <| Json.mkObj [("targetPath", toJson "SaveSmoke/A.lean")])
  let some fallbackHint := Beam.Cli.responseRecoveryHint? fallbackResp
    | throw <| IO.userError "syncBarrierIncomplete fallback should produce a CLI recovery hint"
  requireSubstring "syncBarrier fallback hint" "lean-beam refresh \"SaveSmoke/A.lean\"" fallbackHint
  requireSubstring "syncBarrier fallback hint" "lake build" fallbackHint

  let invalidResp := Beam.Broker.errorResponseFor .invalidParams "bad input"
  require "invalidParams should not produce a sync recovery hint"
    (Beam.Cli.responseRecoveryHint? invalidResp).isNone

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
  let publicTodoSpec := Beam.Cli.leanTodoWaitSpec "Demo.lean" 1 0 2 3 "todo"
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
  expectIoErrorContains
    "missing explicit CLI root should use the workspace error boundary"
    "workspace root does not resolve"
    (Beam.Cli.parseCliOptions {} ["--root", missingRoot.toString, "serve"])
  expectIoErrorContains
    "relative session directory should be rejected"
    "--session-dir requires an absolute path"
    (Beam.Cli.parseCliOptions {} ["--session-dir", "relative-session", "status"])
  let root := System.FilePath.mk s!"/tmp/beam-cli-root-{← IO.monoNanosNow}"
  let control := root / "shared-control"
  try
    IO.FS.createDirAll control
    let expectedRoot ← Beam.resolveExistingPath root
    let expectedControl ← Beam.resolveExistingPath control
    let opts ← Beam.Cli.parseCliOptions {} [
      "--root", root.toString,
      "--session-dir", control.toString,
      "stats"
    ]
    require "explicit CLI root should be canonicalized" (opts.explicitRoot? == some expectedRoot)
    require "explicit session directory should remain an exact selection"
      (opts.explicitControlDir? == some expectedControl)
    require "global selectors should not leak into command arguments" (opts.args == ["stats"])
    let literalSelectors ← Beam.Cli.parseCliOptions {} [
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
      ((← Beam.Cli.inferInspectionRoot nested) == expectedLeanRoot)
    let explicitLean ← Beam.resolveExistingPath leanRoot
    require "an explicit root should select the requested Lean workspace"
      ((← Beam.Cli.inspectionRoot { explicitRoot? := some explicitLean }) == explicitLean)

    IO.FS.writeFile (rocqRoot / "lean-toolchain") "leanprover/lean4:stable\n"
    let sharedRoot ← Beam.resolveExistingPath rocqRoot
    require "root inference should select the nearest Lean project"
      ((← Beam.Cli.inferInspectionRoot rocqRoot) == sharedRoot)
  finally
    if ← root.pathExists then
      IO.FS.removeDirAll root

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
  requireRequestJson "runAt handle request should share the Lean operation adapter"
    (Beam.Cli.leanRunAtRequest path 12 4 2 "exact h" (storeHandle := true))
    (runAtInput.toBrokerRequest (storeHandle := true))
  expectIoErrorContains "runAt missing text should fail at the CLI boundary"
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
  requireRequestJson "runWith linear request should share the Lean operation adapter"
    (Beam.Cli.leanRunWithRequest path sampleBrokerHandle "simp" (linear := true))
    (runWithInput.toBrokerRequest (linear := true))
  expectIoErrorContains "runWith missing text should fail at the CLI boundary"
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
  let parsers : Array (String × (List String → IO Beam.Broker.DiagnosticScope)) := #[
    ("sync", Beam.Cli.parseLeanSyncArgs),
    ("refresh", Beam.Cli.parseLeanRefreshArgs),
    ("save", Beam.Cli.parseLeanSaveArgs),
    ("close-save", Beam.Cli.parseLeanCloseSaveArgs)
  ]
  for (label, parse) in parsers do
    require s!"{label} diagnostic scope should default to errors"
      ((← parse []) == .errors)
    require s!"{label} diagnostic scope should accept +all-diagnostics"
      ((← parse ["+all-diagnostics"]) == .all)
    let obsoleteRejected ←
      try
        discard <| parse ["+full"]
        pure false
      catch err =>
        pure <| err.toString.contains "+all-diagnostics"
    require s!"{label} diagnostic scope should reject obsolete +full" obsoleteRejected

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
      .streamCallback (IO.userError callbackDetail)
    require "stream callback failure should preserve its detail" (callbackMsg == callbackDetail)
    require "stream callback failure should not create a daemon incident"
      (← sortedIncidentEntries root).isEmpty

    let invalidDetail := "synthetic invalid response"
    let invalidMsg ← Beam.Cli.daemonFailureMessage root <|
      .invalidResponse invalidDetail
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
    | state => throw <| IO.userError s!"current registry was classified as {state.status}"

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
    expectIoErrorContains "stop should reject a symlinked registry"
      "symbolic links are not accepted"
      (Beam.Cli.shutdownRegisteredProjectDaemon (fun _ => pure ()) root)
    expectIoErrorContains "recovery should reject a symlinked registry"
      "symbolic links are not accepted"
      (Beam.Cli.recoverProjectDaemon (fun _ => pure ()) root "fixture-generation")
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
      let stoppedMsg ← expectIoErrorMessage "a latched stop must survive request handoff" <|
        Beam.Cli.ensureProjectSession stopped root (projectDaemonClientForTest endpoint controlDir)
      requireSubstring "latched stop must cancel before consuming the broker connection"
        "Beam request interrupted" stoppedMsg
      let msg ← expectIoErrorMessage "broker connection close should surface daemon failure" <|
        Beam.Cli.withOwnerInterruptWatcher fun watcher =>
          Beam.Cli.ensureProjectSession watcher root (projectDaemonClientForTest endpoint controlDir)
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
def blockedOutput (stream : String) (port : UInt16) : IO Unit := do
  let root : System.FilePath := "/tmp"
  let client := projectDaemonClientForTest (.tcp port) root
  match stream with
  | "progress-start" =>
      withFirstStderrWrite (do
        IO.println "progress start reached"
        (← IO.getStdout).flush
        -- The parent sends SIGINT before releasing the first progress write.
        unless (← (← IO.getStdin).getLine) == "release\n" do
          throw <| IO.userError "progress start gate was not released") <|
        Beam.Cli.callBrokerWithProgress root client Beam.Broker.Request.stats
          (Beam.Cli.syncWaitSpec "Main.lean")
  | "stderr" =>
      withFirstStderrWrite (do
        IO.println "diagnostic write reached"
        (← IO.getStdout).flush) <|
        Beam.Cli.callBrokerWithProgress root client Beam.Broker.Request.stats
          (Beam.Cli.syncWaitSpec "Main.lean")
  | "stdout" => Beam.Cli.callBroker root client Beam.Broker.Request.stats
  | "stdout-progress" =>
      Beam.Cli.callBrokerWithProgress root client Beam.Broker.Request.stats
        (Beam.Cli.syncWaitSpec "Main.lean")
  | _ => throw <| IO.userError s!"unknown blocked output stream: {stream}"

def main : IO Unit := do
  checkSdkRuntimeAdmission
  checkLeanConfigLowering
  checkProjectDaemonRequestSealing
  checkClientResponsePresentation
  checkWorkspaceOutputPresentation
  checkCliRecoveryHints
  checkSyncWaitSpecs
  checkCliRootParsing
  checkProjectRootSelection
  checkLeanOperationRequests
  checkDiagnosticScopeArgs
  checkDaemonFailureContext
  checkDaemonFailureUnreadableStartupLog
  checkTypedDaemonFailureClassification
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
  checkTypedRegistryReads
  checkDaemonFailureIncidentRetention
  checkDoctorDaemonFailureIncidentLines
  checkDaemonFailureIncidentDoesNotRecreateRoot
  checkPathCanonicalization
  checkLockLifecycle

end BeamTest.Broker.CliDaemonTest

def main (args : List String) : IO Unit :=
  match args with
  | [] => BeamTest.Broker.CliDaemonTest.main
  | ["--interrupt-watcher", mode] => BeamTest.Broker.InterruptWatcherTest.child mode
  | ["--blocked-output", stream, port] => do
      let some port := port.toNat?
        | throw <| IO.userError "invalid fixture port"
      unless port > 0 && port < 65536 do throw <| IO.userError "invalid fixture port"
      BeamTest.Broker.CliDaemonTest.blockedOutput stream port.toUInt16
  | _ => throw <| IO.userError "unexpected CLI daemon test arguments"
