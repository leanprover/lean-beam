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
    (beforeWrite : IO Unit := pure ())
    (limits : Beam.Mcp.Admission.Limits := {})
    (outputLimits : Beam.Mcp.StdioOutput.Limits := {}) : IO Unit := do
  let frames ← IO.mkRef (#[] : Array String)
  let writer ← Beam.Mcp.StdioOutput.start (limits := outputLimits) fun frame => do
    beforeWrite
    frames.modify (·.push frame.text)
  let coordinator := (stdioPrivate% Beam.Mcp.Server.Coordinator.mk)
    (← ServerState.create)
    (← Std.Mutex.new ((stdioPrivate% Beam.Mcp.Server.RoutingState.mk) 1 {} {} none false {}))
    writer limits
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
  -- Protected fixtures stand for workspace drops; the rest are ordinary work.
  let requestClass : Beam.Mcp.Admission.RequestClass :=
    if protectStarted then .workspaceControl else .ordinary
  let .ok request ← (stdioPrivate% Beam.Mcp.Server.Coordinator.registerRequest)
      coordinator (.string id) policy requestClass
    | throw <| IO.userError "coordinator fixture could not register its request"
  pure request

private def tryRegister
    (coordinator : (stdioPrivate% Beam.Mcp.Server.Coordinator)) (id : String)
    (requestClass : Beam.Mcp.Admission.RequestClass) :
    IO (Option (stdioPrivate% Beam.Mcp.Server.InFlightRequest)) := do
  let policy := if requestClass == .ordinary then
      (stdioPrivate% Beam.Mcp.Server.ClientCancellationPolicy.cooperative)
    else (stdioPrivate% Beam.Mcp.Server.ClientCancellationPolicy.protectStarted)
  (stdioPrivate% Beam.Mcp.Server.Coordinator.reserveRequestId)
    coordinator (.string id) policy requestClass

private def admissionLedger (coordinator : (stdioPrivate% Beam.Mcp.Server.Coordinator)) :
    IO Beam.Mcp.Admission.Ledger := do
  let routing ← ((stdioPrivate% Beam.Mcp.Server.Coordinator.routing) coordinator).atomically get
  pure ((stdioPrivate% Beam.Mcp.Server.RoutingState.admissions) routing)

private def requirePool (label : String)
    (request : (stdioPrivate% Beam.Mcp.Server.InFlightRequest))
    (pool : Beam.Mcp.Admission.Pool) : IO Unit :=
  require label ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.pool) request == pool)

private def awaitDelivery (request : (stdioPrivate% Beam.Mcp.Server.InFlightRequest)) : IO Unit := do
  let some result ← IO.wait ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.output) request).deliveryTask
    | throw <| IO.userError "fixture delivery completion was dropped"
  match result with
  | .ok () => pure ()
  | .error error => throw error

private def oversizedResponse (id : Json) : Json := Id.run do
  let mut text := "x"
  for _ in [:23] do text := text ++ text
  return successResponse id <| Json.mkObj [("text", .str text)]

private def checkOversizedResponseIsolation : IO Unit :=
  withCoordinator fun coordinator frames => do
    let large ← registerFixture coordinator "large"
    let peer ← registerFixture coordinator "peer"
    let response := oversizedResponse (.str "large")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator large response
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator peer
      (successResponse (.str "peer") (Json.mkObj [("ok", .bool true)]))
    awaitDelivery large
    awaitDelivery peer
    let responses ← (← frames.get).mapM fun frame =>
      IO.ofExcept <| (Json.parse frame).mapError IO.userError
    require "oversized result preserves both terminal outcomes" (responses.size == 2)
    let some large := responses.find? (fun response =>
        (response.getObjValAs? String "id").toOption == some "large")
      | throw <| IO.userError "oversized request lost its error response"
    let error ← requireObjVal "oversized request" "error" large
    requireJsonInt "oversized request" "code" (-32023) error
    let data ← requireObjVal "oversized request" "data" error
    requireJsonBool "oversized request" "operation_may_have_completed" true data
    require "unrelated request succeeds after the oversized result"
      (responses.any fun response =>
        (response.getObjValAs? String "id").toOption == some "peer" &&
        (response.getObjVal? "result").isOk)

private def checkUnrepresentableReplyIds : IO Unit :=
  withCoordinator fun coordinator _ => do
    let id := String.ofList (List.replicate 5000 'x')
    let effects ← IO.mkRef (0 : Nat)
    let opts : Beam.Mcp.Server.Options := { identity := do
      effects.modify (· + 1)
      pure { name := Beam.Version.mcpServerName } }
    let root ← IO.currentDir
    for tool in #["beam_version", "lean_drop_workspace"] do
      let json := Json.mkObj [
        ("jsonrpc", .str "2.0"), ("id", .str id), ("method", .str "tools/call"),
        ("params", Json.mkObj [
          ("name", .str tool), ("arguments", if tool == "lean_drop_workspace" then
            Json.mkObj [("workspace", toJson (Beam.Workspace.Descriptor.ofRoot root))]
            else Json.mkObj []),
          ("_meta", Json.mkObj [
            ("io.modelcontextprotocol/protocolVersion", .str Beam.Mcp.protocolVersion),
            ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
            ("io.modelcontextprotocol/clientInfo", Json.mkObj [("name", .str "reply-boundary"), ("version", .str "0")])
          ])
        ])
      ]
      let .ok incoming := Incoming.fromJson? json
        | throw <| IO.userError "invalid reply-boundary fixture request"
      let rejected ← try
        (stdioPrivate% Beam.Mcp.Server.Coordinator.handleIncoming) coordinator opts incoming
        pure false
      catch _ => pure true
      require "unrepresentable ordinary/control envelope is rejected before work" rejected
    let rejected ← try
      (stdioPrivate% Beam.Mcp.Server.Coordinator.handleInvalidMessage) coordinator
        (Json.mkObj [("jsonrpc", .str "2.0"), ("id", .str id), ("method", .num 42)]) "invalid method"
      pure false
    catch _ => pure true
    require "invalid envelopes share reply-ID preflight" rejected
    let routing ← ((stdioPrivate% Beam.Mcp.Server.Coordinator.routing) coordinator).atomically get
    require "no private admission identity was allocated"
      ((stdioPrivate% Beam.Mcp.Server.RoutingState.nextBrokerId) routing == 1)
    require "no execution admission was allocated"
      ((stdioPrivate% Beam.Mcp.Server.RoutingState.admissions) routing == {})
    require "no request was retained"
      ((stdioPrivate% Beam.Mcp.Server.RoutingState.admitted) routing).isEmpty
    require "no operation effects began" ((← effects.get) == 0)
    let writer := (stdioPrivate% Beam.Mcp.Server.Coordinator.output) coordinator
    writer.finish
    let some (some (.ok ())) ← Beam.waitTaskWithTimeout writer.finishedTask 5000
      | throw <| IO.userError "unrepresentable envelopes retained an output admission"

private def checkReservedReplyBoundary : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (fun coordinator frames => do
    try
      let writer := (stdioPrivate% Beam.Mcp.Server.Coordinator.output) coordinator
      let makeId (size : Nat) := String.ofList (List.replicate size 'x')
      let fits (size : Nat) :=
        let error := errorResponse (.str (makeId size)) RpcError.outputLimit
        (writer.validateReserved error ((stdioPrivate% Beam.Mcp.Server.outgoingJsonLabel) error)).isOk
      let mut lower := 0
      let mut upper := 8192
      while lower + 1 < upper do
        let middle := (lower + upper) / 2
        if fits middle then lower := middle else upper := middle
      require "fixture found the exact encoded fallback boundary" (fits lower && !fits upper)
      let id := makeId lower
      let request ← registerFixture coordinator id
      let slot := (stdioPrivate% Beam.Mcp.Server.InFlightRequest.output) request
      let diagnostic := logMessageNotification .error "lean.diagnostic" (.str "prefix")
      slot.diagnostic diagnostic
      let some _ ← IO.wait entered.result?
        | throw <| IO.userError "boundary fixture did not enter its writer gate"
      for _ in [:70] do slot.diagnostic diagnostic
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator request (oversizedResponse (.str id))
      release.resolve ()
      awaitDelivery request
      let responses ← (← frames.get).mapM fun frame =>
        IO.ofExcept <| (Json.parse frame).mapError IO.userError
      let some response := responses.find? (fun response => (response.getObjVal? "error").isOk)
        | throw <| IO.userError "boundary request lost its reserved error"
      requireJsonString "reserved error preserves exact ID" "id" id response
      let error ← requireObjVal "reserved boundary error" "error" response
      requireJsonInt "reserved boundary error" "code" (-32023) error
      let data ← requireObjVal "reserved boundary error" "data" error
      requireJsonBool "reserved boundary error" "operation_may_have_completed" true data
      require "fixed fallback does not append variable omission metadata"
        (!(data.getObjVal? "lean-beam/output").isOk)
      require "boundary fallback leaves the transport healthy" (!(← IO.hasFinished writer.outcomeTask))
    finally release.resolve ()) (beforeWrite := do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| IO.userError "boundary fixture release was dropped")

private def checkExecutionAdmissionLifetime : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (fun coordinator frames => do
    try
      let mut requests := #[]
      for index in [:32] do
        requests := requests.push (← registerFixture coordinator s!"admitted-{index}")
      for index in [32:40] do
        let request? ← tryRegister coordinator s!"busy-{index}" .ordinary
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
  requireJsonInt "diagnostic omission" "diagnostics_omitted" 150 output
  let error := errorResponse (.str "sync") {
    code := -32603, message := "failed"
    data? := some <| Json.mkObj [("existing", .bool true)] }
  let projected := (stdioPrivate% Beam.Mcp.Server.withDiagnosticOmissions) error 2
  let error ← requireObjVal "error diagnostic omission" "error" projected
  requireJsonInt "error diagnostic omission preserves code" "code" (-32603) error
  let data ← requireObjVal "error diagnostic omission" "data" error
  requireJsonBool "error diagnostic omission preserves data" "existing" true data
  let output ← requireObjVal "error diagnostic omission" "lean-beam/output" data
  requireJsonInt "error diagnostic omission" "diagnostics_omitted" 2 output
  for original in #[Json.null, toJson "opaque backend detail"] do
    let raw := errorResponse (.str "sync") { code := -32603, message := "failed", data? := some original }
    let projected := (stdioPrivate% Beam.Mcp.Server.withDiagnosticOmissions) raw 1
    let error ← requireObjVal "opaque error diagnostic omission" "error" projected
    let data ← requireObjVal "opaque error diagnostic omission" "data" error
    let retained ← requireObjVal "opaque error diagnostic omission" "original_data" data
    require "omission wrapper preserves opaque data including explicit null" (retained == original)

private def checkLiveExecutionFence : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (fun coordinator frames => do
    try
      let prior ← registerFixture coordinator "prior"
      let drop ← registerFixture coordinator "drop" true
      let priorRequests ← (stdioPrivate% Beam.Mcp.Server.Coordinator.pushControlBarrier) coordinator drop
      let later ← registerFixture coordinator "later"
      let barrier? ← (stdioPrivate% Beam.Mcp.Server.Coordinator.currentControlBarrier?) coordinator
      require "prior work acquires execution ownership"
        (← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator prior)
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator prior (.str "prior")
      let some _ ← IO.wait entered.result?
        | throw <| IO.userError "live fence writer never reached its gate"
      (stdioPrivate% Beam.Mcp.Server.awaitExecutions) priorRequests
      require "live drop starts while prior output is blocked"
        (← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator drop)
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator drop (.str "drop")
      let some barrier := barrier? | throw <| IO.userError "live fence was not installed"
      (stdioPrivate% Beam.Mcp.Server.InFlightRequest.awaitExecution) barrier
      require "later work starts while drop output is pending"
        (← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator later)
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator later (.str "later")
      let routing ← ((stdioPrivate% Beam.Mcp.Server.Coordinator.routing) coordinator).atomically get
      require "all execution admissions are released before any delivery"
        ((stdioPrivate% Beam.Mcp.Server.RoutingState.admissions) routing == {})
      require "physical output remains blocked throughout live execution" ((← frames.get).isEmpty)
      for request in #[prior, drop, later] do
        require "only delivery remains pending"
          (!(← IO.hasFinished ((stdioPrivate% Beam.Mcp.Server.InFlightRequest.output) request).deliveryTask))
      release.resolve ()
      (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
      for request in #[prior, drop, later] do awaitDelivery request
      require "all completed outcomes survive teardown" ((← frames.get).size == 3)
    finally release.resolve ()) (beforeWrite := do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| IO.userError "live fence writer release was dropped")

private def checkQueuedEviction (closeBeforeFence : Bool) : IO Unit :=
  withCoordinator fun coordinator frames => do
    let prior ← registerFixture coordinator "prior"
    let drop ← registerFixture coordinator "queued-drop" true
    let fence ← (stdioPrivate% Beam.Mcp.Server.Coordinator.pushControlBarrier) coordinator drop
    let later ← registerFixture coordinator "later"
    if closeBeforeFence then discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator prior (.str "prior")
    (stdioPrivate% Beam.Mcp.Server.awaitExecutions) fence
    -- The second variant closes after the fence is satisfied but before execution ownership.
    if !closeBeforeFence then discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    require "EOF prevents queued eviction from acquiring execution ownership"
      (!(← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator drop))
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator drop (.str "must not be delivered")
    (stdioPrivate% Beam.Mcp.Server.InFlightRequest.awaitExecution) drop
    require "later work stays cancelled after the eviction fence settles"
      (!(← (stdioPrivate% Beam.Mcp.Server.Coordinator.startExecution) coordinator later))
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator later (.str "must not be delivered")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
    let some (.ok ()) ← IO.wait
        ((stdioPrivate% Beam.Mcp.Server.Coordinator.output) coordinator).finishedTask
      | throw <| IO.userError "queued eviction fixture did not drain"
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
    (stdioPrivate% Beam.Mcp.Server.InFlightRequest.awaitExecution) drop
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

private def busyReplies (frames : IO.Ref (Array String)) : IO Nat := do
  let responses ← (← frames.get).mapM fun frame =>
    IO.ofExcept <| (Json.parse frame).mapError IO.userError
  pure <| responses.filter (fun response =>
    match response.getObjVal? "error" with
    | .ok error => (error.getObjValAs? Int "code").toOption == some (-32024)
    | .error _ => false) |>.size

/-- Ordinary saturation by cancelled-but-unsettled work leaves recovery admissible, with
separate bounded reserves for drops and observation, and exact capacity reuse. -/
private def checkRecoveryCapacity (ordinary : Nat) : IO Unit :=
  withCoordinator (limits := { ordinary }) fun coordinator frames => do
    let mut stuck := #[]
    for index in [:ordinary] do
      stuck := stuck.push (← registerFixture coordinator s!"stuck-{index}")
    for request in stuck do (stdioPrivate% Beam.Mcp.Server.InFlightRequest.cancel) request
    require "cancellation does not release unsettled admission"
      ((← tryRegister coordinator "ordinary-busy" .ordinary).isNone)
    let some drop ← tryRegister coordinator "drop-1" .workspaceControl
      | throw <| IO.userError "drop was busy under cancelled ordinary saturation"
    requirePool "drop is charged to the control reserve" drop .controlReserve
    let some queuedDrop ← tryRegister coordinator "drop-2" .workspaceControl
      | throw <| IO.userError "second drop was busy"
    require "control reserve is bounded"
      ((← tryRegister coordinator "drop-busy" .workspaceControl).isNone)
    let some version ← tryRegister coordinator "version" .observation
      | throw <| IO.userError "queued drops starved observation"
    requirePool "observation is charged to its own reserve" version .observationReserve
    let some stats ← tryRegister coordinator "stats" .observation
      | throw <| IO.userError "second observation was busy"
    require "observation reserve is bounded"
      ((← tryRegister coordinator "observation-busy" .observation).isNone)
    -- Settlement (here: the queued drop and one stuck request) returns capacity to its own pool.
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator queuedDrop (.str "queued")
    let some redrop ← tryRegister coordinator "drop-3" .workspaceControl
      | throw <| IO.userError "settled reserve capacity was not reusable"
    requirePool "reused drop capacity stays in the reserve" redrop .controlReserve
    let some settled := stuck[0]? | throw <| IO.userError "fixture has no stuck request"
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator settled (.str "settled")
    let some fresh ← tryRegister coordinator "fresh" .ordinary
      | throw <| IO.userError "settled ordinary capacity was not reusable"
    requirePool "fresh work uses the ordinary pool" fresh .ordinary
    discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    for request in (stuck.extract 1 stuck.size) ++ #[drop, redrop, version, stats, fresh] do
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator request (.str "eof")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
    require "EOF releases every pool exactly once" ((← admissionLedger coordinator) == {})
    require "each exhausted pool replied busy without executing" ((← busyReplies frames) == 3)

/-- An ordinary pool with room does not help when ordinary output storage is full; recovery
admission then uses the reserve pool together with its own output budget. -/
private def checkRecoveryOutputBudget : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (outputLimits := { pendingBytes := 4096 }) (fun coordinator _ => do
    try
      let blocker ← registerFixture coordinator "blocker"
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator blocker (.str "blocked")
      let some _ ← IO.wait entered.result?
        | throw <| IO.userError "output budget fixture never blocked its writer"
      require "full ordinary output rejects ordinary work"
        ((← tryRegister coordinator "ordinary-busy" .ordinary).isNone)
      let some drop ← tryRegister coordinator "drop" .workspaceControl
        | throw <| IO.userError "full ordinary output denied recovery admission"
      requirePool "drop falls back to the reserve and its output budget" drop .controlReserve
      let some version ← tryRegister coordinator "version" .observation
        | throw <| IO.userError "full ordinary output denied observation"
      requirePool "observation falls back to its reserve" version .observationReserve
      release.resolve ()
      discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
      for request in #[drop, version] do
        (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator request (.str "eof")
      (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
      require "output-limited admissions release exactly once" ((← admissionLedger coordinator) == {})
    finally release.resolve ()) (beforeWrite := do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| IO.userError "output budget fixture release was dropped")

/-- Completed drops release execution while their replies stay undelivered. Once those replies
fill the control output budget, further drops are busy, but observation is still admitted. -/
private def checkReserveOutputIsolation : IO Unit := do
  let entered ← IO.Promise.new
  let release ← IO.Promise.new
  withCoordinator (outputLimits := { pendingBytes := 4096, controlBytes := 8192 }) (fun coordinator _ => do
    try
      let blocker ← registerFixture coordinator "blocker"
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator blocker (.str "blocked")
      let some _ ← IO.wait entered.result?
        | throw <| IO.userError "isolation fixture never blocked its writer"
      for index in [:2] do
        let some drop ← tryRegister coordinator s!"drop-{index}" .workspaceControl
          | throw <| IO.userError s!"drop {index} was busy"
        requirePool "drop uses the control reserve" drop .controlReserve
        (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator drop (.str "dropped")
      require "undelivered replies do not pin control execution capacity"
        ((← admissionLedger coordinator).controlReserve == 0)
      require "a full control output budget makes further drops busy"
        ((← tryRegister coordinator "drop-busy" .workspaceControl).isNone)
      let some version ← tryRegister coordinator "version" .observation
        | throw <| IO.userError "undelivered control replies denied observation"
      requirePool "observation uses its own reserve" version .observationReserve
      release.resolve ()
      discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
      (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator version (.str "eof")
      (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
      require "isolated admissions release exactly once" ((← admissionLedger coordinator) == {})
    finally release.resolve ()) (beforeWrite := do
      entered.resolve ()
      let some _ ← IO.wait release.result?
        | throw <| IO.userError "isolation fixture release was dropped")

/-- Task-start failure completes through `failOwnedRequest`, which must release reserve capacity. -/
private def checkReserveReleaseOnFailure : IO Unit :=
  withCoordinator (limits := { ordinary := 1 }) fun coordinator frames => do
    let stuck ← registerFixture coordinator "stuck"
    let json := Json.mkObj [
      ("jsonrpc", .str "2.0"), ("id", .str "drop"), ("method", .str "tools/call"),
      ("params", Json.mkObj [("name", .str "lean_drop_workspace"), ("arguments", Json.mkObj [])])]
    let .ok (.request req) := Incoming.fromJson? json
      | throw <| IO.userError "invalid failure fixture request"
    for attempt in [:3] do
      let some drop ← tryRegister coordinator "drop" .workspaceControl
        | throw <| IO.userError s!"reserve capacity leaked after failure {attempt}"
      requirePool "failure fixture uses the reserve" drop .controlReserve
      (stdioPrivate% Beam.Mcp.Server.Coordinator.failOwnedRequest) coordinator req drop
        (IO.userError "task start failed")
      (stdioPrivate% Beam.Mcp.Server.InFlightRequest.awaitExecution) drop
    discard <| (stdioPrivate% Beam.Mcp.Server.Coordinator.beginClosing) coordinator
    (stdioPrivate% Beam.Mcp.Server.Coordinator.finishRequest) coordinator stuck (.str "eof")
    (stdioPrivate% Beam.Mcp.Server.Coordinator.closeTransport) coordinator
    require "failures and EOF release every pool" ((← admissionLedger coordinator) == {})
    let responses ← (← frames.get).mapM fun frame =>
      IO.ofExcept <| (Json.parse frame).mapError IO.userError
    require "each failed start has an internal-error reply"
      ((responses.filter fun response =>
        match response.getObjVal? "error" with
        | .ok error => (error.getObjValAs? Int "code").toOption == some (-32603)
        | .error _ => false).size == 3)

def run : IO Unit := do
  checkPermanentClosure
  checkSharedCleanupFailure
  checkOversizedResponseIsolation
  checkUnrepresentableReplyIds
  checkReservedReplyBoundary
  checkExecutionAdmissionLifetime
  checkDiagnosticOmissionProjection
  checkLiveExecutionFence
  checkQueuedEviction true
  checkQueuedEviction false
  checkStartedEviction
  checkRecoveryCapacity 1
  checkRecoveryCapacity 2
  checkRecoveryCapacity 32
  checkRecoveryOutputBudget
  checkReserveOutputIsolation
  checkReserveReleaseOnFailure
  checkEvictionCleanupDuringEof

end BeamTest.Broker.McpRuntimeLifetimeTest
