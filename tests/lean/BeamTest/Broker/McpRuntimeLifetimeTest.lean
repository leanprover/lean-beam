/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.Server
import Beam.Mcp.StdioServer
import BeamTest.Broker.JsonAssert

open Lean
open Beam.Mcp
open Beam.Mcp.Server
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpRuntimeLifetimeTest

-- Keep the lifetime fixture typed without adding production state setters.
local macro "mcpPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Mcp.Server name.getId)

private def checkPermanentClosure : IO Unit := do
  let state ← ServerState.create
  state.closeRuntime
  state.closeRuntime
  let resolutions ← IO.mkRef (0 : Nat)
  let opts : Beam.Mcp.Server.Options := {
    resolveRuntime := fun _ _ => do
      resolutions.modify (· + 1)
      throw <| IO.userError "closed MCP runtime must not resolve another installation"
  }
  let result ← (mcpPrivate% Beam.Mcp.Server.ensureRuntimeForWorkspace)
    state opts "closed" "." (pure false)
  match result with
  | .ok _ => throw <| IO.userError "closed MCP session recreated its runtime"
  | .error error =>
      require "closed admission reports session closure" (error.code == -32600)
  require "closed runtime rejects before installation resolution" ((← resolutions.get) == 0)
  let root : System.FilePath := "."
  let workspace := (mcpPrivate% Beam.Mcp.Server.ResolvedWorkspace.mk)
    (Beam.Workspace.Descriptor.ofRoot root) root "closed"
  let dropped ← (mcpPrivate% Beam.Mcp.Server.handleDropWorkspace) state workspace
  match dropped with
  | .ok _ => throw <| IO.userError "closed session was mistaken for an absent workspace"
  | .error error =>
      require "closed eviction reports session closure" (error.code == -32600)

private def checkSharedCleanupFailure : IO Unit := do
  let state ← ServerState.create
  let completion ← IO.Promise.new
  ((mcpPrivate% Beam.Mcp.Server.ServerState.runtime) state).atomically do
    set ((mcpPrivate% Beam.Mcp.Server.RuntimeState.closed) completion)
  let first ← IO.asTask state.closeRuntime Task.Priority.dedicated
  let second ← IO.asTask state.closeRuntime Task.Priority.dedicated
  completion.resolve (.error <| IO.userError "shared MCP cleanup failure")
  for task in [first, second] do
    match ← IO.wait task with
    | .ok () => throw <| IO.userError "concurrent close lost its shared cleanup failure"
    | .error error =>
        require "each closer receives the retained outcome"
          (error.toString.contains "shared MCP cleanup failure")
  let result : Except IO.Error Unit ← try
    state.closeRuntime
    pure (.ok ())
  catch error => pure (.error error)
  match result with
  | .ok () => throw <| IO.userError "repeated close forgot its cleanup failure"
  | .error _ => pure ()

-- Exercise coordinator ownership directly with a transport-only writer. No production test hooks,
-- subprocess timing, client pipe scheduling, or extra test entry point is needed for these cutoffs.
local macro "stdioPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Mcp.StdioServer name.getId)

private def withCoordinator
    (test : (stdioPrivate% Beam.Mcp.Server.Coordinator) → IO.Ref (Array String) → IO Unit)
    (beforeWrite : IO Unit := pure ()) : IO Unit := do
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← Beam.Mcp.StdioOutput.start fun frame => do
    beforeWrite
    frames.modify (·.push frame.text)
  let coordinator := (stdioPrivate% Beam.Mcp.Server.Coordinator.mk)
    (← ServerState.create)
    (← Std.Mutex.new ((stdioPrivate% Beam.Mcp.Server.RoutingState.mk) 1 {} {} none false 0))
    writer (← IO.Promise.new) 32
  try test coordinator frames
  finally
    writer.fail (IO.userError "coordinator fixture cleanup")
    ((stdioPrivate% Beam.Mcp.Server.Coordinator.state) coordinator).closeRuntime
    discard <| IO.wait writer.finishedTask

private def registerFixture
    (coordinator : (stdioPrivate% Beam.Mcp.Server.Coordinator)) (id : String)
    (protectStarted : Bool := false) : IO (stdioPrivate% Beam.Mcp.Server.InFlightRequest) := do
  let policy := if protectStarted then (stdioPrivate% Beam.Mcp.Server.ClientCancellationPolicy.protectStarted)
    else (stdioPrivate% Beam.Mcp.Server.ClientCancellationPolicy.cooperative)
  let .ok request ← (stdioPrivate% Beam.Mcp.Server.Coordinator.registerRequest)
      coordinator (.string id) policy
    | throw <| IO.userError "coordinator fixture could not register its request"
  pure request

private def checkOversizedResponseIsolation : IO Unit :=
  withCoordinator fun coordinator frames => do
    let large ← registerFixture coordinator "large"
    let peer ← registerFixture coordinator "peer"
    let mut text := "x"
    for _ in [:23] do text := text ++ text
    let response := successResponse (.str "large") <| Json.mkObj [("text", .str text)]
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator large response
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator peer
      (successResponse (.str "peer") (Json.mkObj [("ok", .bool true)]))
    (stdioPrivate% Beam.Mcp.Server.Coordinator.awaitRequestBoundary) coordinator large
    (stdioPrivate% Beam.Mcp.Server.Coordinator.awaitRequestBoundary) coordinator peer
    let responses ← (← frames.get).mapM fun frame =>
      IO.ofExcept <| (Json.parse frame).mapError IO.userError
    require "oversized result preserves both terminal outcomes" (responses.size == 2)
    let some large := responses.find? (fun response =>
        (response.getObjValAs? String "id").toOption == some "large")
      | throw <| IO.userError "oversized request lost its error response"
    let error ← requireObjVal "oversized request" "error" large
    requireJsonInt "oversized request" "code" (-32023) error
    let data ← requireObjVal "oversized request" "data" error
    requireJsonBool "oversized request" "operationMayHaveCompleted" true data
    require "unrelated request succeeds after the oversized result"
      (responses.any fun response =>
        (response.getObjValAs? String "id").toOption == some "peer" &&
        (response.getObjVal? "result").isOk)

private def checkExecutionAdmissionLifetime : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (fun coordinator frames => do
    try
      let mut requests := #[]
      for index in [:32] do
        requests := requests.push (← registerFixture coordinator s!"admitted-{index}")
      for index in [32:40] do
        let request? ← (stdioPrivate% Beam.Mcp.Server.Coordinator.reserveRequestId)
          coordinator (.string s!"busy-{index}")
          (stdioPrivate% Beam.Mcp.Server.ClientCancellationPolicy.cooperative)
        require "overflow requests are rejected before execution" request?.isNone
      let some _ ← IO.wait entered.result?
        | throw <| IO.userError "fixture writer never reached its gate"
      let some first := requests[0]?
        | throw <| IO.userError "fixture did not register its first request"
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator first (.str "finished")
      require "completed execution can still await delivery"
        (!(← IO.hasFinished ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.output) first).deliveryTask))
      let replacement ← registerFixture coordinator "replacement"
      require "execution admission was released before output resumed"
        (← ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.executionDone) first).isResolved)
      discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
      for request in requests.extract 1 requests.size |>.push replacement do
        (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator request (.str "cancelled")
      release.resolve ()
      (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
      let writer := (stdioPrivate% Beam.Mcp.Server.Coordinator.output) coordinator
      let some (.ok ()) ← IO.wait writer.finishedTask
        | throw <| IO.userError "fixture writer did not finish successfully"
      let responses ← (← frames.get).mapM fun frame =>
        IO.ofExcept <| (Json.parse frame).mapError IO.userError
      require "all forty original requests have a receipt or explicit EOF cancellation"
        (responses.size == 9)
      let errors := responses.filterMap fun response => (response.getObjVal? "error").toOption
      require "each rejected request has its own busy reply" (errors.size == 8)
      for error in errors do requireJsonInt "busy reply" "code" (-32024) error
    finally release.resolve ()) (beforeWrite := do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| IO.userError "fixture writer release was dropped")

private def checkDiagnosticOmissionProjection : IO Unit := do
  let result := Json.mkObj [("value", .num 42), ("_meta", Json.mkObj [("existing", .bool true)])]
  let response := successResponse (.str "sync") result
  let projected := (stdioPrivate% Beam.Mcp.Server.withDiagnosticOmissions) response 150
  let result ← requireObjVal "diagnostic omission" "result" projected
  requireJsonInt "diagnostic omission preserves result" "value" 42 result
  let metadata ← requireObjVal "diagnostic omission" "_meta" result
  requireJsonBool "diagnostic omission preserves metadata" "existing" true metadata
  let output ← requireObjVal "diagnostic omission" "lean-beam/output" metadata
  requireJsonInt "diagnostic omission" "diagnosticsOmitted" 150 output
  let error := errorResponse (.str "sync") {
    code := -32603, message := "failed"
    data? := some <| Json.mkObj [("existing", .bool true)] }
  let projected := (stdioPrivate% Beam.Mcp.Server.withDiagnosticOmissions) error 2
  let error ← requireObjVal "error diagnostic omission" "error" projected
  requireJsonInt "error diagnostic omission preserves code" "code" (-32603) error
  let data ← requireObjVal "error diagnostic omission" "data" error
  requireJsonBool "error diagnostic omission preserves data" "existing" true data
  let output ← requireObjVal "error diagnostic omission" "lean-beam/output" data
  requireJsonInt "error diagnostic omission" "diagnosticsOmitted" 2 output

private def checkQueuedEviction (closeBeforeFence : Bool) : IO Unit :=
  withCoordinator fun coordinator frames => do
    let prior ← registerFixture coordinator "prior"
    let drop ← registerFixture coordinator "queued-drop" true
    let fence ← (stdioPrivate% Beam.Mcp.Server.Coordinator.pushControlBarrier) coordinator drop
    let later ← registerFixture coordinator "later"
    if closeBeforeFence then discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator prior (.str "prior")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.awaitRequests) coordinator
      ((stdioPrivate% Beam.Mcp.Server.ControlRequestFence.priorRequests) fence)
    -- The second variant closes after the fence is satisfied but before execution ownership.
    if !closeBeforeFence then discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    require "EOF prevents queued eviction from acquiring execution ownership"
      (!(← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator drop))
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator drop (.str "must not be delivered")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.awaitControlBarrier) coordinator (some drop)
    require "later work stays cancelled after the eviction fence settles"
      (!(← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator later))
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator later (.str "must not be delivered")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
    let expected := if closeBeforeFence then #[] else #["\"prior\"\n"]
    require "queued eviction and later work emit no terminal response" ((← frames.get) == expected)

private def checkStartedEviction : IO Unit :=
  withCoordinator fun coordinator frames => do
    let drop ← registerFixture coordinator "started-drop" true
    require "eviction acquires execution ownership while admission is open"
      (← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator drop)
    discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    require "started eviction remains active through client cancellation"
      (← (stdioPrivate% Beam.Mcp.Server.InFlightRequest.isActive) drop)
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator drop (.str "started outcome")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.awaitRequestBoundary) coordinator drop
    let some result ← IO.wait ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.output) drop).deliveryTask
      | throw <| IO.userError "started eviction fixture dropped delivery"
    match result with
    | .error error => throw error
    | .ok () => pure ()
    require "started eviction retains its terminal outcome after EOF"
      ((← frames.get) == #["\"started outcome\"\n"])
    (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator

private def checkEvictionCleanupDuringEof : IO Unit :=
  withCoordinator fun coordinator frames => do
    let root := System.FilePath.mk s!"/tmp/beam-mcp-eviction-cutoff-{← IO.monoNanosNow}"
    let cleanupEntered ← IO.Promise.new
    let releaseCleanup ← IO.Promise.new
    let otherTeardown ← IO.Promise.new
    let state := (stdioPrivate% Beam.Mcp.Server.Coordinator.state) coordinator
    IO.FS.createDirAll root
    let root ← Beam.resolveExistingPath root
    try
      IO.FS.writeFile (root / "lakefile.lean") "import Lake\nopen Lake DSL\npackage fixture\n"
      let workspaceId := (Beam.Workspace.Descriptor.ofRoot root).cacheKey
      let otherRoot := root / "other"
      IO.FS.createDirAll otherRoot
      IO.FS.writeFile (otherRoot / "lakefile.lean") "import Lake\nopen Lake DSL\npackage other\n"
      let otherId := (Beam.Workspace.Descriptor.ofRoot otherRoot).cacheKey
      let broker ← Beam.Broker.ServerRuntime.create { root } workspaceId
      match ← broker.initWorkspaceWithConfig otherId { root := otherRoot } with
      | .ok _ => pure ()
      | .error failure => throw <| IO.userError failure.error.message
      IO.FS.writeFile (root / "empty-stderr") ""
      let capture ← IO.FS.withFile (root / "empty-stderr") .read fun source => do
        let capture ← Beam.Broker.startBackendStderrCapture source
        discard <| capture.awaitCompletion
        pure capture
      let process ← Beam.Broker.BackendProcess.create 0 (do
        -- The broker removed workspace membership before calling detached-session cleanup.
        cleanupEntered.resolve ()
        let some _ ← IO.wait releaseCleanup.result?
          | throw <| IO.userError "eviction cleanup release was dropped"
        pure (some 0)) (throw <| IO.userError "fixture must not signal an observed exit")
      let stream ← IO.getStdin
      let session : Beam.Broker.Session := {
        workspaceId, workspaceGeneration := 1, root, epoch := 1
        sessionToken := "eviction-cutoff", proc := process
        stdin := stream, stdout := stream, stderrCapture := capture
        pending := ← Beam.Broker.PendingRequestStore.create
      }
      let otherProcess ← Beam.Broker.BackendProcess.create 0 (do
        otherTeardown.resolve ()
        pure (some 0)) (throw <| IO.userError "fixture must not signal the other observed exit")
      let otherSession := { session with
        workspaceId := otherId, root := otherRoot, sessionToken := "other-workspace"
        proc := otherProcess, pending := ← Beam.Broker.PendingRequestStore.create }
      broker.state.atomically do
        let current ← get
        let some workspace := current.workspaces.get? workspaceId
          | throw <| IO.userError "eviction fixture lost its workspace"
        let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
        let some other := current.workspaces.get? otherId
          | throw <| IO.userError "eviction fixture lost its other workspace"
        let other := { other with lean := { nextEpoch := 2, session? := some otherSession } }
        set { current with workspaces := current.workspaces.insert workspaceId workspace |>.insert otherId other }
      let description : Beam.Runtime.Description := {
        command := "unused", plugin := root / "unused-plugin", daemonBin := root / "unused-daemon"
        toolchain := "eviction-cutoff", identity := ⟨root, "eviction-cutoff"⟩
      }
      let owned := (mcpPrivate% Beam.Mcp.Server.OwnedRuntime.mk) broker <|
        ({} : Std.HashMap _ _).insert workspaceId
          ((mcpPrivate% Beam.Mcp.Server.OwnedWorkspace.mk) root description 0)
        |>.insert otherId ((mcpPrivate% Beam.Mcp.Server.OwnedWorkspace.mk) otherRoot description 1)
      ((mcpPrivate% Beam.Mcp.Server.ServerState.runtime) state).atomically do
        set ((mcpPrivate% Beam.Mcp.Server.RuntimeState.active) (some owned))
        (mcpPrivate% Beam.Mcp.Server.ServerState.nextWorkspaceInstance) state |>.set 2
      let request (id : String) := Json.mkObj [
        ("jsonrpc", .str "2.0"), ("id", .str id), ("method", .str "tools/call"),
        ("params", Json.mkObj [
          ("name", .str "lean_drop_workspace"),
          ("arguments", Json.mkObj [("workspace", toJson (Beam.Workspace.Descriptor.ofRoot root))]),
          ("_meta", Json.mkObj [
            ("io.modelcontextprotocol/protocolVersion", .str Beam.Mcp.protocolVersion),
            ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
            ("io.modelcontextprotocol/clientInfo", Json.mkObj [("name", .str "eviction-cutoff"), ("version", .str "0")])
          ])
        ])
      ]
      let .ok incoming := Beam.Mcp.Incoming.fromJson? (request "started")
        | throw <| IO.userError "invalid eviction fixture request"
      (stdioPrivate% Beam.Mcp.Server.Coordinator.handleIncoming) coordinator {} incoming
      let some _ ← IO.wait cleanupEntered.result?
        | throw <| IO.userError "eviction fixture never entered detached cleanup"
      require "workspace removal commits before cleanup gate" (← broker.workspaceRoot? workspaceId).isNone
      let .ok later := Beam.Mcp.Incoming.fromJson? (request "later")
        | throw <| IO.userError "invalid later eviction fixture request"
      (stdioPrivate% Beam.Mcp.Server.Coordinator.handleIncoming) coordinator {} later
      -- Deterministic EOF after removal, before cleanup completion. Runtime close joins the same
      -- cleanup rather than inventing notFound or suppressing the protected operation's receipt.
      discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
      let closing ← IO.asTask (prio := Task.Priority.dedicated)
        ((stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator)
      let some (some _) ← Beam.waitTaskWithTimeout otherTeardown.result? 5000
        | throw <| IO.userError "EOF teardown of the other workspace waited for drop cleanup"
      require "drop cleanup remains gated while the other backend shuts down"
        (!(← IO.hasFinished closing))
      releaseCleanup.resolve ()
      match ← IO.wait closing with
      | .error error => throw error
      | .ok () => pure ()
      let writer := (stdioPrivate% Beam.Mcp.Server.Coordinator.output) coordinator
      let some result ← IO.wait writer.finishedTask
        | throw <| IO.userError "eviction fixture dropped writer completion"
      match result with
      | .error error => throw error
      | .ok () => pure ()
      let responses ← frames.get
      require "only the started eviction responds after EOF" (responses.size == 1)
      let response ← IO.ofExcept <| (Json.parse responses[0]!).mapError IO.userError
      requireJsonString "started eviction receipt" "id" "started" response
      let result ← requireObjVal "started eviction receipt" "result" response
      let content ← requireObjVal "started eviction receipt" "structuredContent" result
      requireJsonBool "started eviction preserves committed removal" "dropped" true content
      let resolved := (mcpPrivate% Beam.Mcp.Server.ResolvedWorkspace.mk)
        (Beam.Workspace.Descriptor.ofRoot root) root workspaceId
      match ← (mcpPrivate% Beam.Mcp.Server.handleDropWorkspace) state resolved with
      | .error error => require "late cleanup retains permanent closure" (error.code == -32600)
      | .ok _ => throw <| IO.userError "late eviction cleanup reopened the closed runtime"
    finally
      releaseCleanup.resolve ()
      state.closeRuntime
      IO.FS.removeDirAll root

def run : IO Unit := do
  checkPermanentClosure
  checkSharedCleanupFailure
  checkOversizedResponseIsolation
  checkExecutionAdmissionLifetime
  checkDiagnosticOmissionProjection
  checkQueuedEviction true
  checkQueuedEviction false
  checkStartedEviction
  checkEvictionCleanupDuringEof

end BeamTest.Broker.McpRuntimeLifetimeTest
