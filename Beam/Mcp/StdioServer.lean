/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Mcp.Server
import Beam.Mcp.SelfCheck
import Beam.Mcp.Stdio
import Beam.Cli.Toolchain

open Lean

/-!
Stdio transport and concurrent request coordination for the MCP server.

`runStdio` is the only stdin reader, and every stdout message passes through `OutputSink` so JSON-RPC
messages remain serialized while independent tool calls execute concurrently.
-/

namespace Beam.Mcp.Server

private def outgoingJsonLabel (json : Json) : String :=
  let idLabel :=
    match json.getObjVal? "id" with
    | .ok id =>
        match RequestId.fromJson? id with
        | .ok id => id.label
        | .error _ => id.compress
    | .error _ => "<none>"
  let methodLabel :=
    match json.getObjVal? "method" with
    | .ok (.str method) => method
    | .ok method => method.compress
    | .error _ => "<none>"
  let kind :=
    if methodLabel != "<none>" then
      "method"
    else if (json.getObjVal? "error").isOk then
      "error"
    else
      "response"
  s!"kind={kind} id={idLabel} method={methodLabel}"

private def writeJsonLine (json : Json) : IO Unit := do
  let payload := json.compress
  let trace := ← Internal.traceEnabled "LEAN_BEAM_MCP_TRACE"
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write start {outgoingJsonLabel json} chars={payload.length}"
  let stdout ← IO.getStdout
  stdout.putStr (payload ++ "\n")
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write putStr done {outgoingJsonLabel json}"
  stdout.flush
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write flush done {outgoingJsonLabel json}"

private structure OutputSink where
  mutex : Std.Mutex Unit

private def OutputSink.create : BaseIO OutputSink := do
  pure { mutex := ← Std.Mutex.new () }

private def OutputSink.sendWhen
    (sink : OutputSink)
    (condition : IO Bool)
    (json : Json) : IO Unit := do
  sink.mutex.atomically do
    if ← condition then
      writeJsonLine json

private def OutputSink.send (sink : OutputSink) (json : Json) : IO Unit := do
  sink.sendWhen (pure true) json

private inductive RequestPhase where
  | active
  | clientCancelled
  | completed
  deriving BEq

private inductive ClientCancellationPolicy where
  | cooperative
  | nonCancellable
  deriving BEq

private structure InFlightState where
  phase : RequestPhase := .active
  brokerRequest? : Option Beam.Broker.RequestHandle := none

private structure InFlightRequest where
  id : RequestId
  brokerId : String
  cancellationPolicy : ClientCancellationPolicy
  state : Std.Mutex InFlightState
  done : IO.Promise Unit

private structure RoutingState where
  nextBrokerId : Nat := 1
  -- `inFlight` is the client-ID routing surface. `admitted` retains exact generations through
  -- terminal output so EOF shutdown and control fences can still await them after ID retirement.
  inFlight : Std.TreeMap RequestId InFlightRequest := {}
  admitted : Std.TreeMap String InFlightRequest := {}
  controlBarrier? : Option (IO.Promise Unit) := none
  closing : Bool := false

private inductive RequestRegistrationError where
  | duplicate
  | closing

/-
Nested coordinator locks flow in one direction:

* progress → output → request for request notifications
* output → request for active request messages

Routing is released before runtime control, request, or output is acquired. Runtime control is owned
by `ServerState` and does not acquire coordinator locks. Request state is inspected only after output
serialization is available, so cancellation never waits for a blocked stdout write.
-/
private structure Coordinator where
  state : ServerState
  routing : Std.Mutex RoutingState
  output : OutputSink

private def Coordinator.create : IO Coordinator := do
  pure {
    state := ← ServerState.create
    routing := ← Std.Mutex.new {}
    output := ← OutputSink.create
  }

private def Coordinator.registerRequest
    (coordinator : Coordinator)
    (id : RequestId)
    (cancellationPolicy : ClientCancellationPolicy) :
    IO (Except RequestRegistrationError InFlightRequest) := do
  let request : InFlightRequest := {
    id
    brokerId := ""
    cancellationPolicy
    state := ← Std.Mutex.new {}
    done := ← IO.Promise.new
  }
  coordinator.routing.atomically do
    let routing ← get
    if routing.inFlight.contains id then
      pure <| .error .duplicate
    else if routing.closing then
      pure <| .error .closing
    else
      let brokerId := s!"mcp:{routing.nextBrokerId}"
      let request := { request with brokerId }
      set {
        routing with
          nextBrokerId := routing.nextBrokerId + 1
          inFlight := routing.inFlight.insert id request
          admitted := routing.admitted.insert brokerId request
      }
      pure <| .ok request

private def Coordinator.retireRequestId
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO Unit := do
  coordinator.routing.atomically do
    modify fun routing =>
      match routing.inFlight.get? request.id with
      | some current =>
          if current.brokerId == request.brokerId then
            { routing with inFlight := routing.inFlight.erase request.id }
          else
            routing
      | none => routing

private def Coordinator.completeRequest
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO Unit := do
  coordinator.routing.atomically do
    modify fun routing =>
      { routing with admitted := routing.admitted.erase request.brokerId }

private def InFlightRequest.resolveDone (request : InFlightRequest) : IO Unit := do
  try
    request.done.resolve ()
  catch _ =>
    pure ()

private def InFlightRequest.isActive (request : InFlightRequest) : IO Bool := do
  request.state.atomically do
    pure ((← get).phase == .active)

private def awaitPromise (label : String) (promise : IO.Promise Unit) : IO Unit := do
  let some _ ← IO.wait promise.result?
    | throw <| IO.userError s!"{label} promise was dropped"
  pure ()

private def resolvePromise (promise : IO.Promise Unit) : IO Unit := do
  try
    promise.resolve ()
  catch _ =>
    pure ()

private def Coordinator.currentControlBarrier?
    (coordinator : Coordinator) : IO (Option (IO.Promise Unit)) := do
  coordinator.routing.atomically do
    pure (← get).controlBarrier?

private structure ControlRequestFence where
  previous? : Option (IO.Promise Unit)
  done : IO.Promise Unit
  priorRequests : Array InFlightRequest

private def Coordinator.pushControlBarrier
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO ControlRequestFence := do
  let done ← IO.Promise.new
  let (previous?, priorRequests) ← coordinator.routing.atomically do
    let routing ← get
    let priorRequests := routing.admitted.toList.filterMap (fun (_, other) =>
      if other.brokerId == request.brokerId then none else some other) |>.toArray
    set { routing with controlBarrier? := some done }
    pure (routing.controlBarrier?, priorRequests)
  pure { previous?, done, priorRequests }

private def awaitControlBarrier (barrier? : Option (IO.Promise Unit)) : IO Unit := do
  match barrier? with
  | none => pure ()
  | some barrier => awaitPromise "MCP workspace control" barrier

private def InFlightRequest.sendIfActive
    (request : InFlightRequest)
    (output : OutputSink)
    (json : Json) : IO Unit := do
  output.sendWhen request.isActive json

private def InFlightRequest.bindBrokerRequest
    (request : InFlightRequest)
    (brokerRequest : Beam.Broker.RequestHandle) : IO Bool := do
  request.state.atomically do
    let current ← get
    if current.phase == .active then
      set { current with brokerRequest? := some brokerRequest }
      pure true
    else
      pure false

private def Coordinator.finishRequest
    (coordinator : Coordinator)
    (request : InFlightRequest)
    (response : Json) : IO Unit := do
  try
    let sendResponse ← request.state.atomically do
      let current ← get
      match current.phase with
      | .active =>
          set { current with phase := .completed }
          pure true
      | .clientCancelled =>
          set { current with phase := .completed }
          pure false
      | .completed =>
          pure false
    -- Retire the exact admission before its terminal response becomes visible. A client may reuse
    -- an ID as soon as it observes that response; retaining the routing entry until after the write
    -- creates a race in which the new request is mistaken for a duplicate active request.
    coordinator.retireRequestId request
    if sendResponse then
      coordinator.output.send response
  finally
    -- Retry retirement when an earlier state/routing operation failed, and make every cleanup step
    -- independent. Barriers observe completion only after the terminal write has finished.
    try
      coordinator.retireRequestId request
    finally
      try
        coordinator.completeRequest request
      finally
        request.resolveDone

private def traceMcpSafely (message : String) : IO Unit := do
  try
    Internal.traceMcp message
  catch _ =>
    pure ()

/--
Own one registered request through terminal completion.

`after` belongs to the same ownership scope and runs after the request's terminal write attempt. In
particular, a workspace-control fence is not released before the request is retired and its `done`
promise is resolved.
-/
private def Coordinator.runOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (work : IO Json)
    (after : IO Unit := pure ()) : IO Unit := do
  try
    let response ←
      try
        work
      catch e =>
        traceMcpSafely s!"request work failed id={req.id.label}: {e.toString}"
        pure <| errorResponse req.id (RpcError.internalError e.toString)
    try
      coordinator.finishRequest request response
    catch e =>
      if !Beam.Mcp.Stdio.isClosedOutputError e then
        traceMcpSafely s!"request completion failed id={req.id.label}: {e.toString}"
    pure ()
  finally
    try
      after
    catch e =>
      traceMcpSafely s!"request finalizer failed id={req.id.label}: {e.toString}"

/-- Project a worker or setup failure through the registered request's single completion path. -/
private def Coordinator.failOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (error : IO.Error)
    (after : IO Unit := pure ()) : IO Unit := do
  traceMcpSafely s!"request work failed id={req.id.label}: {error.toString}"
  coordinator.runOwnedRequest req request
    (pure <| errorResponse req.id (RpcError.internalError error.toString)) after

/-- Transfer a registered request to a worker, or complete it synchronously if task startup fails. -/
private def Coordinator.spawnOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (work : IO Json)
    (after : IO Unit := pure ()) : IO Unit := do
  try
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      coordinator.runOwnedRequest req request work after
    pure ()
  catch e =>
    coordinator.failOwnedRequest req request e after

private def InFlightRequest.markClientCancelled
    (request : InFlightRequest) : IO (Bool × Option Beam.Broker.RequestHandle) := do
  if request.cancellationPolicy == .nonCancellable then
    return (false, none)
  request.state.atomically do
    let current ← get
    match current.phase with
    | .active =>
        set { current with phase := .clientCancelled }
        pure (true, current.brokerRequest?)
    | .clientCancelled | .completed =>
        pure (false, none)

private def InFlightRequest.cancel (request : InFlightRequest) : IO Unit := do
  let (cancelled, brokerRequest?) ← request.markClientCancelled
  if cancelled then
    match brokerRequest? with
    | none => pure ()
    | some brokerRequest =>
        let _ ← IO.asTask (prio := Task.Priority.dedicated) do
          try
            discard <| brokerRequest.cancel
          catch e =>
            Internal.traceMcp s!"broker cancellation failed id={request.id.label}: {e.toString}"
        pure ()

private def Coordinator.cancelRequest
    (coordinator : Coordinator)
    (id : RequestId) : IO Unit := do
  let request? ← coordinator.routing.atomically do
    pure <| (← get).inFlight.get? id
  match request? with
  | none => pure ()
  | some request => request.cancel

private def Coordinator.beginClosing
    (coordinator : Coordinator) : IO (Array InFlightRequest) := do
  let requests ← coordinator.routing.atomically do
    let routing ← get
    let requests := routing.admitted.toList.map Prod.snd |>.toArray
    set { routing with closing := true }
    pure requests
  for request in requests do
    request.cancel
  pure requests

private def awaitRequestDone (request : InFlightRequest) : IO Unit := do
  awaitPromise s!"in-flight request {request.id.label}" request.done

private def awaitRequests (requests : Array InFlightRequest) : IO Unit := do
  for request in requests do
    awaitRequestDone request

private def Coordinator.closeTransport (coordinator : Coordinator) : IO Unit := do
  try
    let requests ← coordinator.beginClosing
    awaitRequests requests
  finally
    coordinator.state.closeRuntime

private def Coordinator.admitToolRequest
    (coordinator : Coordinator)
    (req : Request)
    (evidence : RequestProtocolEvidence) : IO (Except Json AdmittedRequestContext) := do
  match ← Internal.admitOperationRequest coordinator.state evidence with
  | .ok admitted => pure <| .ok admitted
  | .error err => return .error <| errorResponse req.id err

private def Coordinator.executeToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (admitted : AdmittedRequestContext)
    (parsedParams : Except String CallToolParams)
    (request : InFlightRequest)
    (initialProgress : Nat := 0) : IO Json := do
  let notifications : NotificationSink := {
    send := fun json => request.sendIfActive coordinator.output json
  }
  match ← Internal.handleToolCall
      coordinator.state
      opts
      request.brokerId
      request.bindBrokerRequest
      req
      admitted
      parsedParams
      notifications
      initialProgress with
  | .ok result => pure <| successResponseForEra admitted.era req.id result
  | .error err => pure <| errorResponse req.id err

private def Coordinator.toolRequestResponse
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (admitted : AdmittedRequestContext)
    (parsedParams : Except String CallToolParams)
    (request : InFlightRequest)
    (barrier? : Option (IO.Promise Unit))
    (initialProgress : Nat := 0) : IO Json := do
  awaitControlBarrier barrier?
  if ← request.isActive then
    coordinator.executeToolRequest opts req admitted parsedParams request initialProgress
  else
    pure <| errorResponse req.id <|
      RpcError.invalidRequest "request was cancelled before execution"

private def finishReporterSafely
    (req : Request)
    (finishReporter : IO Unit) : IO Unit := do
  try
    finishReporter
  catch e =>
    traceMcpSafely s!"request reporter finish failed id={req.id.label}: {e.toString}"

private def Coordinator.spawnToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (evidence : RequestProtocolEvidence)
    (parsedParams : Except String CallToolParams)
    (request : InFlightRequest) : IO Unit := do
  let admission ←
    try
      coordinator.admitToolRequest req evidence
    catch e =>
      coordinator.failOwnedRequest req request e
      return
  let admitted ←
    match admission with
    | .ok admitted => pure admitted
    | .error response =>
        coordinator.runOwnedRequest req request (pure response)
        return
  let barrier? ←
    try
      coordinator.currentControlBarrier?
    catch e =>
      coordinator.failOwnedRequest req request e
      return
  coordinator.spawnOwnedRequest req request <|
    coordinator.toolRequestResponse opts req admitted parsedParams request barrier?

private def Coordinator.handleControlToolRequest
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (evidence : RequestProtocolEvidence)
    (parsedParams : Except String CallToolParams)
    (request : InFlightRequest) : IO Unit := do
  let admission ←
    try
      coordinator.admitToolRequest req evidence
    catch e =>
      coordinator.failOwnedRequest req request e
      return
  match admission with
  | .error response => coordinator.runOwnedRequest req request (pure response)
  | .ok admitted =>
      let fence ←
        try
          coordinator.pushControlBarrier request
        catch e =>
          coordinator.failOwnedRequest req request e
          return
      let work : IO Json := do
        let notifications : NotificationSink := {
          send := fun json => request.sendIfActive coordinator.output json
        }
        let reporter? ←
          match parsedParams with
          | .ok params =>
              Internal.createPreDispatchReporter?
                coordinator.state req.id admitted params notifications
          | .error _ => pure none
        let run (initialProgress : Nat) : IO Json := do
          -- A control operation is a full stream-order fence: work admitted before it drains,
          -- while work admitted afterward waits on `done`.
          awaitRequests fence.priorRequests
          coordinator.toolRequestResponse opts req admitted parsedParams request fence.previous?
            initialProgress
        match reporter? with
        | none => run 0
        | some reporter =>
            try
              run reporter.initialProgress
            finally
              finishReporterSafely req reporter.finish
      coordinator.spawnOwnedRequest req request work (resolvePromise fence.done)

private def isWorkspaceControl : Except String CallToolParams → Bool
  | .ok params => params.name == .leanDropWorkspace
  | .error _ => false

private def Coordinator.reserveRequestId
    (coordinator : Coordinator)
    (id : RequestId)
    (cancellationPolicy : ClientCancellationPolicy) : IO (Option InFlightRequest) := do
  match ← coordinator.registerRequest id cancellationPolicy with
  | .ok request => pure <| some request
  | .error .duplicate =>
      Internal.traceMcp s!"ignoring duplicate active request id={id.label}"
      pure none
  | .error .closing =>
      coordinator.output.send <| errorResponse id <|
        RpcError.invalidRequest "MCP server is shutting down"
      pure none

private def Coordinator.reserveRequest
    (coordinator : Coordinator)
    (req : Request)
    (cancellationPolicy : ClientCancellationPolicy) : IO (Option InFlightRequest) :=
  coordinator.reserveRequestId req.id cancellationPolicy

private def Coordinator.handleInvalidMessage
    (coordinator : Coordinator)
    (json : Json)
    (message : String) : IO Unit := do
  let invalidRequest := RpcError.invalidRequest message
  match RequestId.fromEnvelope? json with
  | none =>
      coordinator.output.send <| errorResponse Json.null invalidRequest
  | some id =>
      let some request ← coordinator.reserveRequestId id .nonCancellable
        | return
      coordinator.finishRequest request <| errorResponse id invalidRequest

private def Coordinator.handleNotification
    (coordinator : Coordinator)
    (notification : Notification) : IO Unit := do
  match notification.method with
  | "notifications/cancelled" =>
      match parseCancelledParams notification.params? with
      | .ok params => coordinator.cancelRequest params.requestId
      | .error err => Internal.traceMcp s!"ignoring invalid notifications/cancelled: {err}"
      pure ()
  | _ =>
      Beam.Mcp.Server.handleNotification coordinator.state notification

private def Coordinator.handleIncoming
    (coordinator : Coordinator)
    (opts : Options)
    (incoming : Incoming) : IO Unit := do
  match incoming with
  | .request req =>
      let parsedToolParams? :=
        if req.method == "tools/call" then some <| parseCallToolParams req.params? else none
      let cancellationPolicy :=
        match parsedToolParams? with
        | some parsedParams =>
            if isWorkspaceControl parsedParams then .nonCancellable else .cooperative
        | none => .nonCancellable
      let some request ← coordinator.reserveRequest req cancellationPolicy
        | return
      let evidence ←
        match req.protocolEvidence with
        | .ok evidence => pure evidence
        | .error err =>
            coordinator.finishRequest request <| errorResponse req.id err
            return
      match parsedToolParams? with
      | some parsedParams =>
        if isWorkspaceControl parsedParams then
          coordinator.handleControlToolRequest opts req evidence parsedParams request
        else
          coordinator.spawnToolRequest opts req evidence parsedParams request
        pure ()
      | none =>
        let response ←
          try
            Internal.handleRequestForProtocol coordinator.state opts req evidence {
              send := coordinator.output.send
            }
          catch e =>
            pure <| errorResponse req.id (RpcError.internalError e.toString)
        coordinator.finishRequest request response
  | .notification notification =>
      coordinator.handleNotification notification

partial def runStdio (opts : Options) : IO Unit := do
  let stdin ← IO.getStdin
  let coordinator ← Coordinator.create
  let rec loop : IO Unit := do
    let input ← stdin.getLine
    if input.isEmpty then
      pure ()
    else
      let line := Beam.Mcp.Stdio.stripLineEnding input
      match Json.parse line with
      | .error err =>
          coordinator.output.send <| errorResponse Json.null (RpcError.parseError err)
      | .ok json =>
          match Incoming.fromJson? json with
          | .ok incoming => coordinator.handleIncoming opts incoming
          | .error err => coordinator.handleInvalidMessage json err
      loop
  try
    loop
  catch e =>
    if Beam.Mcp.Stdio.isClosedOutputError e then
      pure ()
    else
      throw e
  finally
    coordinator.closeTransport

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  let opts ← if Beam.Cli.Toolchain.enabled then do
    let beamCli ← Beam.Cli.Toolchain.executable "lean-beam"
    let mismatch := IO.userError "bundled lean-beam-mcp uses only its containing toolchain"
    unless opts.leanCmd?.isNone && opts.leanPlugin?.isNone do
      throw mismatch
    if let some selected := opts.beamCli? then
      unless ← Beam.sameFilePath beamCli (System.FilePath.mk selected) do
        throw mismatch
    pure { opts with beamCli? := some beamCli.toString }
  else
    pure opts
  if opts.showVersion then
    IO.println (← Internal.serverVersionText opts)
    return
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      runStdio opts

end Beam.Mcp.Server
