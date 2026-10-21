/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.Server
import BeamTest.Broker.JsonAssert

open Lean
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
  let opts : Options := {
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
  let workspace : (mcpPrivate% Beam.Mcp.Server.ResolvedWorkspace) := {
    root, descriptor := Beam.Workspace.Descriptor.ofRoot root, workspaceId := "closed"
  }
  let dropped ← ((mcpPrivate% Beam.Mcp.Server.ServerState.runtime) state).atomically <|
    (mcpPrivate% Beam.Mcp.Server.handleDropWorkspace) workspace
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
  let result ← try
    state.closeRuntime
    pure (.ok ())
  catch error => pure (.error error)
  match result with
  | .ok () => throw <| IO.userError "repeated close forgot its cleanup failure"
  | .error _ => pure ()

def run : IO Unit := do
  checkPermanentClosure
  checkSharedCleanupFailure

end BeamTest.Broker.McpRuntimeLifetimeTest
