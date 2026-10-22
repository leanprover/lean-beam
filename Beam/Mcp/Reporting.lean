/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.Protocol
import Beam.WorkspaceOutput.Types
import Std.Sync.Mutex

open Lean

/-! Shared reporting policy and projection data. Delivery retains no runtime authority. -/
namespace Beam.Mcp.Server

/-- Logging policy retains connection data, never a broker or runtime. -/
inductive LogPolicy where
  | legacy (protocol : Std.Mutex ProtocolState)
  | request (minimum? : Option LogLevel)

def LogPolicy.minimumLogLevel? : LogPolicy → IO (Option LogLevel)
  | .legacy protocol => protocol.atomically do
      match ← get with
      | .legacy legacyState => pure <| some legacyState.logLevel
      | .undecided | .modern => pure none
  | .request minimum? => pure minimum?

/-- Legacy policy can change while a request is active; modern policy is immutable. -/
def LogPolicy.mayAllow (policy : LogPolicy) (level : LogLevel) : Bool :=
  match policy with
  | .legacy _ => true
  | .request minimum? => minimum?.any (·.allows level)

/-- Plain projection metadata for the request's raw helper text. -/
structure WorkspaceTextContext where
  requestId : RequestId
  tool : String
  policy : LogPolicy

def WorkspaceTextContext.notification (context : WorkspaceTextContext)
    (chunk : Beam.WorkspaceOutput.Chunk) : Json :=
  logMessageNotification .info "lake.output" <| Json.mkObj [
    ("requestId", context.requestId.json),
    ("tool", toJson context.tool),
    ("source", toJson <| match chunk.source with | .stdout => "stdout" | .stderr => "stderr"),
    ("text", toJson chunk.text),
    ("omittedBefore", toJson chunk.omittedBefore)
  ]


end Beam.Mcp.Server
