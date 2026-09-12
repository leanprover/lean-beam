/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Json
import Beam.Mcp.Projection
import Beam.Version

open Lean

namespace Beam.Mcp

/-- Preferred stateless MCP protocol revision implemented by `lean-beam-mcp`. -/
def protocolVersion : String :=
  Beam.Version.mcpProtocolVersion

/-- Initialization-based MCP protocol revision retained for legacy clients. -/
def legacyProtocolVersion : String :=
  Beam.Version.legacyMcpProtocolVersion

/-- Protocol revisions selectable through modern per-request metadata. -/
def perRequestProtocolVersions : Array String :=
  #[protocolVersion]

/-- One-hour public-cache hint used by static discovery and tool-list results. -/
def publicCacheTtlMs : Nat :=
  60 * 60 * 1000

def serverName : String :=
  Beam.Version.mcpServerName

def serverVersion : String :=
  Beam.Version.projectVersion

structure RpcError where
  code : Int
  message : String
  data? : Option Json := none
  deriving ToJson

namespace RpcError

def parseError (message : String) : RpcError :=
  { code := -32700, message }

def invalidRequest (message : String) : RpcError :=
  { code := -32600, message }

def methodNotFound (method : String) : RpcError :=
  { code := -32601, message := s!"method not found: {method}" }

def invalidParams (message : String) : RpcError :=
  { code := -32602, message }

def internalError (message : String) : RpcError :=
  { code := -32603, message }

def unsupportedProtocolVersion (requested : String) : RpcError :=
  {
    code := -32022
    message := "Unsupported protocol version"
    data? := some <| Json.mkObj [
      ("supported", toJson perRequestProtocolVersions),
      ("requested", toJson requested)
    ]
  }

end RpcError

inductive RequestId where
  | string (value : String)
  | number (source : JsonNumber) (value : Int)
  deriving Repr

namespace RequestId

private def jsonNumberIntValue? (value : JsonNumber) : Option Int :=
  if value.mantissa == 0 then
    some 0
  else
    let rec divide (mantissa : Int) : Nat → Option Int
      | 0 => some mantissa
      | exponent + 1 =>
          if mantissa % 10 == 0 then
            divide (mantissa / 10) exponent
          else
            none
    divide value.mantissa value.exponent

def fromJson? : Json → Except String RequestId
  | .str value => pure <| .string value
  | .num value =>
      match jsonNumberIntValue? value with
      | some integer => pure <| .number value integer
      | none => throw "request id must be a string or integer"
  | _ => throw "request id must be a string or integer"

/-- Recover a typed request ID from an otherwise invalid JSON-RPC envelope. -/
def fromEnvelope? (json : Json) : Option RequestId :=
  match json.getObjVal? "id" with
  | .ok id => (fromJson? id).toOption
  | .error _ => none

def json : RequestId → Json
  | .string value => .str value
  | .number source _ => .num source

instance : Coe RequestId Json where
  coe := json

def label : RequestId → String
  | .string value => value
  | id => id.json.compress

def compare : RequestId → RequestId → Ordering
  | .string left, .string right => Ord.compare left right
  | .string _, .number _ _ => .lt
  | .number _ _, .string _ => .gt
  | .number _ left, .number _ right => Ord.compare left right

def beq : RequestId → RequestId → Bool
  | .string left, .string right => left == right
  | .number _ left, .number _ right => left == right
  | _, _ => false

instance : BEq RequestId where
  beq := beq

instance : Ord RequestId where
  compare := compare

end RequestId

structure Request where
  id : RequestId
  method : String
  params? : Option Json := none

structure Notification where
  method : String
  params? : Option Json := none

structure CancelledParams where
  requestId : RequestId
  reason? : Option String := none

inductive Incoming where
  | request (request : Request)
  | notification (notification : Notification)

def Incoming.fromJson? (json : Json) : Except String Incoming := do
  let version ← json.getObjValAs? String "jsonrpc"
  if version != "2.0" then
    throw "expected jsonrpc=\"2.0\""
  match json.getObjVal? "method" with
  | .ok _ =>
      let method ← json.getObjValAs? String "method"
      let params? ← optionalField? (α := Json) json "params"
      match json.getObjVal? "id" with
      | .ok id => do
          requireOnlyFields "JSON-RPC request" #["jsonrpc", "id", "method", "params"] json
          pure <| .request { id := ← RequestId.fromJson? id, method, params? }
      | .error _ => do
          requireOnlyFields "JSON-RPC notification" #["jsonrpc", "method", "params"] json
          pure <| .notification { method, params? }
  | .error _ =>
      throw "client message must be a JSON-RPC request or notification"

def requireObject (label : String) : Json → Except String Json
  | obj@(.obj _) => pure obj
  | other => throw s!"{label} must be an object, got {other.compress}"

private def validateOptionalMetaObject (label : String) (params : Json) : Except String Unit := do
  match params.getObjVal? "_meta" with
  | .ok metaJson => discard <| requireObject s!"{label} _meta" metaJson
  | .error _ => pure ()

def parseCancelledParams (params? : Option Json) : Except String CancelledParams := do
  let params ←
    match params? with
    | some params => requireObject "notifications/cancelled params" params
    | none => throw "notifications/cancelled params are required"
  requireOnlyFields "notifications/cancelled params" #["requestId", "reason", "_meta"] params
  validateOptionalMetaObject "notifications/cancelled params" params
  let requestId ← RequestId.fromJson? (← params.getObjVal? "requestId")
  let reason? ← optionalField? (α := String) params "reason"
  pure { requestId, reason? }

inductive LogLevel where
  | debug
  | info
  | notice
  | warning
  | error
  | critical
  | alert
  | emergency
  deriving BEq, Repr

def LogLevel.key : LogLevel → String
  | .debug => "debug"
  | .info => "info"
  | .notice => "notice"
  | .warning => "warning"
  | .error => "error"
  | .critical => "critical"
  | .alert => "alert"
  | .emergency => "emergency"

def LogLevel.severityRank : LogLevel → Nat
  | .emergency => 0
  | .alert => 1
  | .critical => 2
  | .error => 3
  | .warning => 4
  | .notice => 5
  | .info => 6
  | .debug => 7

def LogLevel.allows (minimum event : LogLevel) : Bool :=
  event.severityRank <= minimum.severityRank

instance : ToJson LogLevel where
  toJson level := toJson level.key

instance : FromJson LogLevel where
  fromJson?
    | .str "debug" => .ok .debug
    | .str "info" => .ok .info
    | .str "notice" => .ok .notice
    | .str "warning" => .ok .warning
    | .str "error" => .ok .error
    | .str "critical" => .ok .critical
    | .str "alert" => .ok .alert
    | .str "emergency" => .ok .emergency
    | j => .error s!"expected MCP log level, got {j.compress}"

/-- The required identity fields shared by legacy initialization and modern request metadata. -/
structure ImplementationInfo where
  name : String
  version : String
  deriving FromJson

structure ModernRequestContext where
  protocolVersion : String
  clientCapabilities : Json
  clientInfo? : Option ImplementationInfo := none
  logLevel? : Option LogLevel := none

structure LegacyInitializeParams where
  protocolVersion : String
  capabilities : Json
  clientInfo : ImplementationInfo

inductive RequestEra where
  | legacy
  | modern (context : ModernRequestContext)

/-- Wire evidence used to select a request's protocol era against the transport lifecycle state. -/
inductive RequestProtocolEvidence where
  | unmarked
  | legacyInitialize
  | modern (context : ModernRequestContext)

/-- Per-request protocol data whose construction proves that lifecycle admission succeeded. -/
inductive AdmittedRequestContext where
  | legacy
  | modern (context : ModernRequestContext)

def AdmittedRequestContext.era : AdmittedRequestContext → RequestEra
  | .legacy => .legacy
  | .modern context => .modern context

private def protocolVersionMetaKey : String :=
  "io.modelcontextprotocol/protocolVersion"

private def clientInfoMetaKey : String :=
  "io.modelcontextprotocol/clientInfo"

private def clientCapabilitiesMetaKey : String :=
  "io.modelcontextprotocol/clientCapabilities"

private def logLevelMetaKey : String :=
  "io.modelcontextprotocol/logLevel"

private def carriesModernMetadata (params? : Option Json) : Bool :=
  match params? with
  | none => false
  | some params =>
      match params.getObjVal? "_meta" with
      | .error _ => false
      | .ok metaJson =>
          (metaJson.getObjVal? protocolVersionMetaKey).isOk ||
          (metaJson.getObjVal? clientCapabilitiesMetaKey).isOk ||
          (metaJson.getObjVal? clientInfoMetaKey).isOk ||
          (metaJson.getObjVal? logLevelMetaKey).isOk

private def decodeModernRequestContext
    (params? : Option Json) : Except String ModernRequestContext := do
  let params ←
    match params? with
    | some params => requireObject "modern request params" params
    | none => throw "modern request params are required"
  let metaJson ← requireObject "modern request params _meta" (← params.getObjVal? "_meta")
  let protocolVersion ← metaJson.getObjValAs? String protocolVersionMetaKey
  let clientCapabilities ←
    requireObject "modern request client capabilities" <|
      ← metaJson.getObjVal? clientCapabilitiesMetaKey
  let clientInfo? ← optionalField? (α := ImplementationInfo) metaJson clientInfoMetaKey
  let logLevel? ← optionalField? (α := LogLevel) metaJson logLevelMetaKey
  pure { protocolVersion, clientCapabilities, clientInfo?, logLevel? }

def Request.protocolEvidence (req : Request) : Except RpcError RequestProtocolEvidence := do
  if req.method == "initialize" && !carriesModernMetadata req.params? then
    pure .legacyInitialize
  else if req.method == "server/discover" || carriesModernMetadata req.params? then
    let context ← decodeModernRequestContext req.params? |>.mapError RpcError.invalidParams
    if context.protocolVersion != protocolVersion then
      throw <| RpcError.unsupportedProtocolVersion context.protocolVersion
    pure <| .modern context
  else
    pure .unmarked

def validateDiscoverParams (params? : Option Json) : Except String Unit := do
  let params ←
    match params? with
    | some params => requireObject "server/discover params" params
    | none => throw "server/discover params are required"
  requireOnlyFields "server/discover params" #["_meta"] params

private def validateUnpaginatedToolsListParams (params : Json) : Except String Unit := do
  requireOnlyFields "tools/list params" #["cursor", "_meta"] params
  validateOptionalMetaObject "tools/list params" params
  match ← optionalField? (α := String) params "cursor" with
  | some _ => throw "tools/list cursor is invalid because this server does not paginate its tool list"
  | none => pure ()

def validateToolsListParams (params? : Option Json) : Except String Unit := do
  let params ←
    match params? with
    | some params => requireObject "tools/list params" params
    | none => throw "tools/list params are required"
  validateUnpaginatedToolsListParams params

private def optionalLegacyParamsObject
    (label : String)
    (params? : Option Json) : Except String Json := do
  match params? with
  | some params => requireObject s!"{label} params" params
  | none => pure <| Json.mkObj []

private def validateOptionalLegacyParams
    (label : String)
    (allowedFields : Array String)
    (params? : Option Json) : Except String Json := do
  let params ← optionalLegacyParamsObject label params?
  requireOnlyFields s!"{label} params" allowedFields params
  validateOptionalMetaObject s!"{label} params" params
  pure params

def validateLegacyToolsListParams (params? : Option Json) : Except String Unit := do
  let params ← optionalLegacyParamsObject "tools/list" params?
  validateUnpaginatedToolsListParams params

def validateLegacyPingParams (params? : Option Json) : Except String Unit := do
  discard <| validateOptionalLegacyParams "ping" #["_meta"] params?

def validateInitializedParams (params? : Option Json) : Except String Unit := do
  discard <| validateOptionalLegacyParams "notifications/initialized" #["_meta"] params?

def parseLegacyInitializeParams
    (params? : Option Json) : Except String LegacyInitializeParams := do
  let params ←
    match params? with
    | some params => requireObject "initialize params" params
    | none => throw "initialize params are required"
  requireOnlyFields "initialize params" #["protocolVersion", "capabilities", "clientInfo", "_meta"] params
  validateOptionalMetaObject "initialize params" params
  let protocolVersion ← params.getObjValAs? String "protocolVersion"
  let capabilities ← requireObject "initialize client capabilities" <|
    ← params.getObjVal? "capabilities"
  let clientInfo ← params.getObjValAs? ImplementationInfo "clientInfo"
  pure { protocolVersion, capabilities, clientInfo }

structure SetLogLevelParams where
  level : LogLevel
  deriving FromJson

def parseSetLogLevelParams (params? : Option Json) : Except String LogLevel := do
  let params ←
    match params? with
    | some params => requireObject "logging/setLevel params" params
    | none => throw "logging/setLevel params are required"
  requireOnlyFields "logging/setLevel params" #["level", "_meta"] params
  validateOptionalMetaObject "logging/setLevel params" params
  let decoded ← fromJson? (α := SetLogLevelParams) params
  pure decoded.level

def notification (method : String) (params : Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson method),
    ("params", params)
  ]

def logMessageNotification (level : LogLevel) (logger : String) (data : Json) : Json :=
  notification "notifications/message" <| Json.mkObj [
    ("level", toJson level),
    ("logger", toJson logger),
    ("data", data)
  ]

inductive ToolStatusState where
  | running
  | preparingDependencies
  deriving BEq, Repr

def ToolStatusState.key : ToolStatusState → String
  | .running => "running"
  | .preparingDependencies => "preparing_dependencies"

instance : ToJson ToolStatusState where
  toJson state := toJson state.key

structure ToolStatus where
  requestId : RequestId
  tool : String
  state : ToolStatusState
  message : String
  path? : Option String := none
  progressHint? : Option String := none

instance : ToJson ToolStatus where
  toJson status :=
    Json.mkObj <|
      [
        ("requestId", status.requestId.json),
        ("tool", toJson status.tool),
        ("state", toJson status.state),
        ("message", toJson status.message)
      ] ++
      (match status.path? with
      | some path => [("path", toJson path)]
      | none => []) ++
      match status.progressHint? with
      | some hint => [("progressHint", toJson hint)]
      | none => []

def toolStatusNotification (status : ToolStatus) : Json :=
  logMessageNotification .notice "beam.status" (toJson status)

def successResponse (id : Json) (result : Json) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", id),
    ("result", result)
  ]

def serverInfoJson : Json :=
  Json.mkObj [
    ("name", toJson serverName),
    ("version", toJson serverVersion)
  ]

def modernResult (result : Json) : Json :=
  let resultMeta :=
    match result.getObjVal? "_meta" with
    | .ok resultMeta@(.obj _) => resultMeta
    | _ => Json.mkObj []
  (result.setObjVal! "resultType" (toJson "complete")).setObjVal! "_meta" <|
    resultMeta.setObjVal! "io.modelcontextprotocol/serverInfo" serverInfoJson

def modernSuccessResponse (id : Json) (result : Json) : Json :=
  successResponse id (modernResult result)

def successResponseForEra (era : RequestEra) (id : Json) (result : Json) : Json :=
  match era with
  | .legacy => successResponse id result
  | .modern _ => modernSuccessResponse id result

def errorResponse (id : Json) (err : RpcError) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("id", id),
    ("error", toJson err)
  ]

def initializeResult : Json :=
  Json.mkObj [
    ("protocolVersion", toJson legacyProtocolVersion),
    ("capabilities", Json.mkObj [
      ("logging", Json.mkObj []),
      ("tools", Json.mkObj [
        ("listChanged", toJson false)
      ])
    ]),
    ("serverInfo", serverInfoJson)
  ]

private def publicCacheResult (result : Json) : Json :=
  (result.setObjVal! "ttlMs" (toJson publicCacheTtlMs)).setObjVal!
    "cacheScope" (toJson "public")

def discoverResult : Json :=
  publicCacheResult <| Json.mkObj [
    ("supportedVersions", toJson perRequestProtocolVersions),
    ("capabilities", Json.mkObj [
      ("logging", Json.mkObj []),
      ("tools", Json.mkObj [
        ("listChanged", toJson false)
      ])
    ]),
    ("instructions", toJson
      "Use an explicit local workspace descriptor on every workspace-bound Beam tool call.")
  ]

def toolDescriptorJson (desc : ToolDescriptor) : Json :=
  Json.mkObj <|
    [
      ("name", toJson desc.name),
      ("description", toJson desc.description),
      ("inputSchema", desc.inputSchema)
    ] ++ match desc.annotations.toJson? with
      | some annotations => [("annotations", annotations)]
      | none => []

def toolsListResult : Json :=
  Json.mkObj [
    ("tools", toJson <| toolDescriptors.map toolDescriptorJson)
  ]

def modernToolsListResult : Json :=
  publicCacheResult toolsListResult

structure CallToolParams where
  name : ToolName
  arguments : Json := Json.mkObj []
  progressToken? : Option Json := none

def validProgressToken : Json → Bool
  | .str _ => true
  | .num _ => true
  | _ => false

private def parseProgressToken? (params : Json) : Except String (Option Json) := do
  let metaJson ←
    match params.getObjVal? "_meta" with
    | .ok rawMeta => requireObject "tools/call params _meta" rawMeta
    | .error _ => pure (Json.mkObj [])
  match metaJson.getObjVal? "progressToken" with
  | .ok token =>
      if validProgressToken token then
        pure <| some token
      else
        throw "tools/call params _meta.progressToken must be a string or number"
  | .error _ =>
      pure none

def parseCallToolParams (params? : Option Json) : Except String CallToolParams := do
  let params ←
    match params? with
    | some params => requireObject "tools/call params" params
    | none => throw "tools/call params are required"
  requireOnlyFields "tools/call params"
    #["name", "arguments", "inputResponses", "requestState", "_meta"] params
  if (params.getObjVal? "inputResponses").isOk || (params.getObjVal? "requestState").isOk then
    throw "tools/call MRTR continuation fields are invalid because lean-beam-mcp did not issue an input_required result"
  let rawName ← params.getObjVal? "name"
  let name ← fromJson? (α := ToolName) rawName
  let progressToken? ← parseProgressToken? params
  let arguments ←
    match params.getObjVal? "arguments" with
    | .ok arguments => requireObject "tools/call arguments" arguments
    | .error _ => pure (Json.mkObj [])
  pure { name, arguments, progressToken? }

def progressNotification
    (progressToken : Json)
    (progress : Nat)
    (message? : Option String := none)
    (total? : Option Nat := none) : Json :=
  Json.mkObj [
    ("jsonrpc", toJson "2.0"),
    ("method", toJson "notifications/progress"),
    ("params", Json.mkObj <|
      [
        ("progressToken", progressToken),
        ("progress", toJson progress)
      ] ++
      (match total? with
      | some total => [("total", toJson total)]
      | none => []) ++
      (match message? with
      | some message => [("message", toJson message)]
      | none => []))
  ]

private def textContent (text : String) : Json :=
  Json.mkObj [
    ("type", toJson "text"),
    ("text", toJson text)
  ]

def callToolResult (structured : Json) (isError : Bool := false) : Json :=
  Json.mkObj [
    ("content", Json.arr #[textContent structured.compress]),
    ("structuredContent", structured),
    ("isError", toJson isError)
  ]

def toolErrorJson (err : ToolError) : Json :=
  Json.mkObj <|
    [
      ("code", toJson err.code),
      ("message", toJson err.message)
    ] ++
    match err.data? with
    | some data => [("data", data)]
    | none => []

def callToolErrorResult (err : ToolError) : Json :=
  callToolResult (toolErrorJson err) (isError := true)

end Beam.Mcp
