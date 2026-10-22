/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Mcp.Server
import Beam.Mcp.Stdio
import Beam.Mcp.StdioOutput

open Lean

/-!
Stdio transport and concurrent request coordination for the MCP server.

`runStdio` supervises one input reader and one output writer. Only complete saturation of the
rejection reserve pauses input. Admitted work and broker cleanup never wait for stdout capacity.
-/

namespace Beam.Mcp.Server

private def outgoingJsonLabel (json : Json) : String :=
  let short (value : String) := (value.take 128).toString
  let idLabel := match json.getObjVal? "id" with
    | .ok (.str value) => short value
    | .ok (.num value) => short (toString value)
    | _ => "<none>"
  let methodLabel := match json.getObjVal? "method" with
    | .ok (.str value) => short value
    | _ => "<none>"
  let kind := if methodLabel != "<none>" then "method"
    else if (json.getObjVal? "error").isOk then "error" else "response"
  s!"kind={kind} id={idLabel} method={methodLabel}"

private def writeFrame (frame : Beam.Mcp.StdioOutput.Frame) : IO Unit := do
  let trace := ← Internal.traceEnabled "LEAN_BEAM_MCP_TRACE"
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write start {frame.label} chars={frame.text.length}"
  let stdout ← IO.getStdout
  stdout.putStr frame.text
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write putStr done {frame.label}"
  stdout.flush
  if trace then
    let now ← IO.monoNanosNow
    IO.eprintln s!"lean-beam-mcp trace {now}: stdout write flush done {frame.label}"

private inductive RequestPhase where
  | queued
  | executing
  | clientCancelled
  | completed
  deriving BEq

private inductive ClientCancellationPolicy where
  | cooperative
  | protectStarted
  deriving BEq

private structure InFlightState where
  phase : RequestPhase := .queued
  brokerRequest? : Option Beam.Broker.RequestHandle := none

private structure InFlightRequest where
  id : RequestId
  brokerId : String
  cancellationPolicy : ClientCancellationPolicy
  state : Std.Mutex InFlightState
  executionDone : IO.Promise Unit
  deliveryDone : IO.Promise Unit
  output : Beam.Mcp.StdioOutput.Slot

private structure RoutingState where
  nextBrokerId : Nat := 1
  -- `inFlight` is the client-ID routing surface. `admitted` retains exact generations through
  -- terminal output so shutdown and control fences retain the exact admission after ID retirement.
  inFlight : Std.TreeMap RequestId InFlightRequest := {}
  admitted : Std.TreeMap String InFlightRequest := {}
  controlBarrier? : Option InFlightRequest := none
  closing : Bool := false
  executionAdmissions : Nat := 0

private inductive RequestRegistrationError where
  | duplicate
  | closing
  | busy

/-
Nested state locks flow routing → request → output. They perform only bounded in-memory transitions.
No physical output, broker operation, or wait runs under a coordinator or output lock.
-/
private structure Coordinator where
  state : ServerState
  routing : Std.Mutex RoutingState
  output : Beam.Mcp.StdioOutput.Writer
  closing : IO.Promise Unit
  executionLimit : Nat := 32

private def Coordinator.create : IO Coordinator := do
  pure {
    state := ← ServerState.create
    routing := ← Std.Mutex.new {}
    output := ← Beam.Mcp.StdioOutput.start writeFrame
    closing := ← IO.Promise.new
  }

private def Coordinator.registerRequest
    (coordinator : Coordinator)
    (id : RequestId)
    (cancellationPolicy : ClientCancellationPolicy) :
    IO (Except RequestRegistrationError InFlightRequest) := do
  -- Ignore duplicates before reserving capacity; registration is driven by the sole reader.
  let unavailable? ← coordinator.routing.atomically do
    let routing ← get
    if routing.inFlight.contains id then return some .duplicate
    if routing.closing then return some .closing
    if routing.executionAdmissions >= coordinator.executionLimit then return some .busy
    return none
  if let some reason := unavailable? then return .error reason
  let some output ← coordinator.output.tryReserve | return .error .busy
  let request : InFlightRequest := {
    id
    brokerId := ""
    cancellationPolicy
    output
    state := ← Std.Mutex.new {}
    executionDone := ← IO.Promise.new
    deliveryDone := ← IO.Promise.new
  }
  let result ← coordinator.routing.atomically do
    let routing ← get
    if routing.inFlight.contains id then
      pure <| .error .duplicate
    else if routing.closing then
      pure <| .error .closing
    else if routing.executionAdmissions >= coordinator.executionLimit then
      pure <| .error .busy
    else
      let brokerId := s!"mcp:{routing.nextBrokerId}"
      let request := { request with brokerId }
      set {
        routing with
          nextBrokerId := routing.nextBrokerId + 1
          inFlight := routing.inFlight.insert id request
          admitted := routing.admitted.insert brokerId request
          executionAdmissions := routing.executionAdmissions + 1
      }
      pure <| .ok request
  if let .error _ := result then output.release
  pure result

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

/-- Release execution admission once, independently of response storage and delivery. -/
private def Coordinator.finishExecution (coordinator : Coordinator) (request : InFlightRequest) : IO Unit :=
  coordinator.routing.atomically do
    if ← request.executionDone.isResolved then return
    modify fun routing => { routing with executionAdmissions := routing.executionAdmissions - 1 }
    request.state.atomically do modify fun current => { current with brokerRequest? := none }
    request.executionDone.resolve ()

private def InFlightRequest.isActive (request : InFlightRequest) : IO Bool := do
  request.state.atomically do
    let phase := (← get).phase
    pure (phase == .queued || phase == .executing)

private def awaitPromise (label : String) (promise : IO.Promise Unit) : IO Unit := do
  let some _ ← IO.wait promise.result?
    | throw <| IO.userError s!"{label} promise was dropped"
  pure ()

/-- Live control fences include delivery; EOF waits only for execution and resource cleanup. -/
private def Coordinator.awaitRequestBoundary
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO Unit := do
  let some _ ← IO.waitAny [request.deliveryDone.result?, coordinator.closing.result?]
    | throw <| IO.userError "MCP request boundary promise was dropped"
  let closing ← coordinator.routing.atomically do pure (← get).closing
  if closing then
    -- A delivery may finish while EOF is still marking the remaining admissions cancelled.
    awaitPromise "MCP closing admission" coordinator.closing
    awaitPromise s!"in-flight execution {request.id.label}" request.executionDone
  else
    awaitPromise s!"in-flight delivery {request.id.label}" request.deliveryDone

private def Coordinator.currentControlBarrier?
    (coordinator : Coordinator) : IO (Option InFlightRequest) := do
  coordinator.routing.atomically do
    pure (← get).controlBarrier?

private structure ControlRequestFence where
  previous? : Option InFlightRequest
  priorRequests : Array InFlightRequest

private def Coordinator.pushControlBarrier
    (coordinator : Coordinator)
    (request : InFlightRequest) : IO ControlRequestFence := do
  let (previous?, priorRequests) ← coordinator.routing.atomically do
    let routing ← get
    let priorRequests := routing.admitted.toList.filterMap (fun (_, other) =>
      if other.brokerId == request.brokerId then none else some other) |>.toArray
    set { routing with controlBarrier? := some request }
    pure (routing.controlBarrier?, priorRequests)
  pure { previous?, priorRequests }

private def Coordinator.awaitControlBarrier
    (coordinator : Coordinator) (barrier? : Option InFlightRequest) : IO Unit := do
  match barrier? with
  | none => pure ()
  | some barrier => coordinator.awaitRequestBoundary barrier

/-- Acquire execution ownership after fences, atomically against EOF and cancellation. -/
private def Coordinator.startExecution (coordinator : Coordinator) (request : InFlightRequest) : IO Bool :=
  coordinator.routing.atomically do
    let closing := (← get).closing
    request.state.atomically do
      let current ← get
      if current.phase != .queued then return false
      if closing then
        set { current with phase := .clientCancelled }
        return false
      set { current with phase := .executing }
      return true

private def InFlightRequest.notify (request : InFlightRequest)
    (delivery : NotificationDelivery) (json : Json) : IO Unit := do
  if !(← request.isActive) then return
  match delivery with
  | .diagnostic => request.output.diagnostic json (outgoingJsonLabel json)
  | .replaceableProgress => request.output.progress json (outgoingJsonLabel json)

private def InFlightRequest.bindBrokerRequest
    (request : InFlightRequest)
    (brokerRequest : Beam.Broker.RequestHandle) : IO Bool := do
  request.state.atomically do
    let current ← get
    if current.phase == .executing then
      set { current with brokerRequest? := some brokerRequest }
      pure true
    else
      pure false

private def traceMcpSafely (message : String) : IO Unit := do
  try
    Internal.traceMcp message
  catch _ =>
    pure ()

/-- Delivery omissions annotate the response, leaving the operation's result and metadata intact. -/
private def withDiagnosticOmissions (response : Json) (omitted : Nat) : Json := Id.run do
  if omitted == 0 then return response
  let output := Json.mkObj [("diagnosticsOmitted", toJson omitted)]
  if let .ok result@(.obj _) := response.getObjVal? "result" then
    let metadata := match result.getObjVal? "_meta" with
      | .ok metadata@(.obj _) => metadata
      | _ => Json.mkObj []
    return response.setObjVal! "result" <|
      result.setObjVal! "_meta" (metadata.setObjVal! "lean-beam/output" output)
  if let .ok error@(.obj _) := response.getObjVal? "error" then
    let data := match error.getObjVal? "data" with
      | .ok data@(.obj _) => data
      | .ok original => Json.mkObj [("originalData", original)]
      | .error _ => Json.mkObj []
    return response.setObjVal! "error" <|
      error.setObjVal! "data" (data.setObjVal! "lean-beam/output" output)
  return response

private def respondWithinLimit (slot : Beam.Mcp.StdioOutput.Slot) (id : Json)
    (response : Json) : IO Unit := do
  match ← slot.respond (withDiagnosticOmissions response) (outgoingJsonLabel response) with
  | .ok () => pure ()
  | .error limit =>
      let limit? := match limit with
        | .tooLarge bytes => some bytes
        | .capacity => none
      let error := errorResponse id (RpcError.outputLimit limit?)
      match ← slot.respondReserved (withDiagnosticOmissions error) (outgoingJsonLabel error) with
      | .ok () => pure ()
      | .error _ => throw <| IO.userError "MCP request ID exceeds the error response budget"

private def Coordinator.finishDelivery (coordinator : Coordinator) (request : InFlightRequest)
    (result? : Option (Except IO.Error Unit)) : IO Unit := do
  try
    let some result := result?
      | throw <| IO.userError "MCP output delivery promise was dropped"
    match result with
    | .ok () => pure ()
    | .error error => throw error
  finally
    coordinator.completeRequest request
    request.deliveryDone.resolve ()

private def Coordinator.finishRequest
    (coordinator : Coordinator)
    (request : InFlightRequest)
    (response : Json)
    (deliveryDependencies : Array InFlightRequest := #[]) : IO Unit := do
  try
    -- Execution has released its admission. Delivery retains no broker handle.
    coordinator.finishExecution request
    for dependency in deliveryDependencies do
      coordinator.awaitRequestBoundary dependency
    -- Routing retirement and terminal acceptance share the cancellation cutoff. The input reader
    -- cannot route a cancellation through the gap or mistake a reused ID for this generation.
    coordinator.routing.atomically do
      let routing ← get
      match routing.inFlight.get? request.id with
      | some current =>
          if current.brokerId == request.brokerId then
            set { routing with inFlight := routing.inFlight.erase request.id }
      | none => pure ()
      request.state.atomically do
        let current ← get
        match current.phase with
        | .queued | .executing =>
            -- Queueing never waits for stdout or free capacity. Encoding is bounded by the slot.
            respondWithinLimit request.output request.id response
            set { current with phase := .completed }
        | .clientCancelled =>
            request.output.release
            set { current with phase := .completed }
        | .completed => pure ()
    traceMcpSafely s!"terminal response ready id={request.id.label}"
  catch error =>
    coordinator.output.fail error
    try coordinator.retireRequestId request
    finally
      coordinator.completeRequest request
      request.deliveryDone.resolve ()
    throw error
  finally
    coordinator.finishExecution request
  -- A short continuation retires delivery; pending replies need no dedicated waiting thread.
  try
    let _ ← IO.mapTask (fun result => do
      try coordinator.finishDelivery request result
      catch error => traceMcpSafely s!"request delivery failed id={request.id.label}: {error}")
      request.output.deliveryTask
    pure ()
  catch error =>
    coordinator.output.fail error
    coordinator.completeRequest request
    request.deliveryDone.resolve ()
    throw error

/-- Own one registered request through execution cleanup and terminal delivery. -/
private def Coordinator.runOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (work : IO Json)
    (deliveryDependencies : Array InFlightRequest := #[]) : IO Unit := do
  let response ←
    try
      work
    catch e =>
      traceMcpSafely s!"request work failed id={req.id.label}: {e.toString}"
      pure <| errorResponse req.id (RpcError.internalError e.toString)
  try
    coordinator.finishRequest request response deliveryDependencies
  catch e =>
    if !Beam.Mcp.Stdio.isClosedOutputError e then
      traceMcpSafely s!"request completion failed id={req.id.label}: {e.toString}"

/-- Project a worker or setup failure through the registered request's single completion path. -/
private def Coordinator.failOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (error : IO.Error)
    (deliveryDependencies : Array InFlightRequest := #[]) : IO Unit := do
  traceMcpSafely s!"request work failed id={req.id.label}: {error.toString}"
  coordinator.runOwnedRequest req request
    (pure <| errorResponse req.id (RpcError.internalError error.toString)) deliveryDependencies

/-- Transfer a registered request to a worker, or complete it synchronously if task startup fails. -/
private def Coordinator.spawnOwnedRequest
    (coordinator : Coordinator)
    (req : Request)
    (request : InFlightRequest)
    (work : IO Json)
    (deliveryDependencies : Array InFlightRequest := #[]) : IO Unit := do
  try
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      coordinator.runOwnedRequest req request work deliveryDependencies
    pure ()
  catch e =>
    coordinator.failOwnedRequest req request e deliveryDependencies

private def InFlightRequest.markClientCancelled
    (request : InFlightRequest) : IO (Bool × Option Beam.Broker.RequestHandle) := do
  request.state.atomically do
    let current ← get
    match current.phase with
    | .queued =>
        set { current with phase := .clientCancelled }
        pure (true, none)
    | .executing =>
        if request.cancellationPolicy == .protectStarted then return (false, none)
        set { current with phase := .clientCancelled }
        pure (true, current.brokerRequest?)
    | .clientCancelled | .completed => pure (false, none)

private def InFlightRequest.cancel (request : InFlightRequest) : IO Unit := do
  let (cancelled, brokerRequest?) ← request.markClientCancelled
  if cancelled then
    request.output.cancel
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
  try
    for request in requests do
      request.cancel
  finally
    -- Mark cancellable admissions before waking work queued behind a control fence.
    coordinator.closing.resolve ()
  pure requests

private def Coordinator.awaitRequests
    (coordinator : Coordinator) (requests : Array InFlightRequest) : IO Unit := do
  for request in requests do
    coordinator.awaitRequestBoundary request

private def Coordinator.closeTransport (coordinator : Coordinator) : IO Unit := do
  let requests ← coordinator.beginClosing
  -- Backend closure may be what releases outstanding execution; never join execution first.
  try
    coordinator.state.closeRuntime
  finally
    traceMcpSafely "runtime close finished"
    try coordinator.awaitRequests requests
    finally coordinator.output.finish

private def Coordinator.sendUnowned (coordinator : Coordinator) (json : Json) : IO Unit := do
  -- This is the sole capacity wait. It runs on the reader, outside all coordinator locks.
  let slot ← coordinator.output.reserveRejection
  let id := (json.getObjVal? "id").toOption.getD Json.null
  respondWithinLimit slot id json

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
    send := request.notify
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
      initialProgress
      (isCancelled := do return !(← request.isActive)) with
  | .ok result => pure <| successResponseForEra admitted.era req.id result
  | .error err => pure <| errorResponse req.id err

private def Coordinator.toolRequestResponse
    (coordinator : Coordinator)
    (opts : Options)
    (req : Request)
    (admitted : AdmittedRequestContext)
    (parsedParams : Except String CallToolParams)
    (request : InFlightRequest)
    (barrier? : Option InFlightRequest)
    (initialProgress : Nat := 0) : IO Json := do
  coordinator.awaitControlBarrier barrier?
  if ← coordinator.startExecution request then
    traceMcpSafely s!"request execution started id={req.id.label}"
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
  coordinator.spawnOwnedRequest req request
    (coordinator.toolRequestResponse opts req admitted parsedParams request barrier?)
    barrier?.toArray

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
          send := request.notify
        }
        let reporter? ←
          match parsedParams with
          | .ok params =>
              Internal.createPreDispatchReporter?
                coordinator.state req.id admitted params notifications
          | .error _ => pure none
        let run (initialProgress : Nat) : IO Json := do
          -- Live fences include delivery. EOF wakes the fence, then startExecution atomically
          -- rejects queued work; a drop that already owns execution keeps its committed outcome.
          coordinator.awaitRequests fence.priorRequests
          coordinator.toolRequestResponse opts req admitted parsedParams request fence.previous?
            initialProgress
        match reporter? with
        | none => run 0
        | some reporter =>
            try
              run reporter.initialProgress
            finally
              finishReporterSafely req reporter.finish
      coordinator.spawnOwnedRequest req request work fence.priorRequests

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
      coordinator.sendUnowned <| errorResponse id <|
        RpcError.invalidRequest "MCP server is shutting down"
      pure none
  | .error .busy =>
      coordinator.sendUnowned <| errorResponse id RpcError.serverBusy
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
      coordinator.sendUnowned <| errorResponse Json.null invalidRequest
  | some id =>
      let some request ← coordinator.reserveRequestId id .protectStarted
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
            if isWorkspaceControl parsedParams then .protectStarted else .cooperative
        | none => .protectStarted
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
              send := request.notify
            }
          catch e =>
            pure <| errorResponse req.id (RpcError.internalError e.toString)
        coordinator.finishRequest request response
  | .notification notification =>
      coordinator.handleNotification notification

partial def runStdio (opts : Options) : IO Unit := do
  let stdin ← IO.getStdin
  let coordinator ← Coordinator.create
  let readerDone : IO.Promise (Except IO.Error Unit) ← IO.Promise.new
  let rec loop : IO Unit := do
    let input ← stdin.getLine
    if input.isEmpty then return
    if ← coordinator.routing.atomically (do return (← get).closing) then return
    let line := Beam.Mcp.Stdio.stripLineEnding input
    match Json.parse line with
    | .error err => coordinator.sendUnowned <| errorResponse Json.null (RpcError.parseError err)
    | .ok json =>
        match Incoming.fromJson? json with
        | .ok incoming => coordinator.handleIncoming opts incoming
        | .error err => coordinator.handleInvalidMessage json err
    loop
  try
    let _ ← IO.asTask (prio := Task.Priority.dedicated) do
      let result ← try loop; pure (.ok ()) catch error => pure (.error error)
      readerDone.resolve result
    -- Failure reaches the session owner even if stdin and stdout are both blocked.
    let outcome ← IO.waitAny [
      readerDone.result?,
      coordinator.output.outcomeTask
    ]
    match outcome with
    | some (.ok ()) => pure ()
    | some (.error error) =>
        coordinator.output.fail error
        if !Beam.Mcp.Stdio.isClosedOutputError error then throw error
    | none => throw <| IO.userError "MCP transport completion promise was dropped"
  finally
    coordinator.closeTransport
  -- Orderly EOF may drain accepted responses after backend cleanup. Logical failure remains
  -- independently observable if a physical write is stuck; never join that writer on failure.
  let some result ← IO.wait coordinator.output.outcomeTask
    | throw <| IO.userError "MCP writer completion promise was dropped"
  match result with
  | .ok () => pure ()
  | .error error =>
      if !Beam.Mcp.Stdio.isClosedOutputError error then throw error

end Beam.Mcp.Server
