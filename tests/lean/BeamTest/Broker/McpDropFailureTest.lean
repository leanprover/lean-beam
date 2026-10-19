/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Server
import BeamTest.Broker.JsonAssert

open Lean
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpDropFailureTest

-- Beam still uses Lean's pre-module format, which cannot be consumed by `import all`.
-- Resolve these fixture-only declarations through Lean's private-name API instead of exposing
-- production setters or fault-injection options. Every access remains checked by Lean's types.
local macro "mcpPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Mcp.Server name.getId)

private abbrev runtimeRef (state : Beam.Mcp.Server.ServerState) :=
  (mcpPrivate% Beam.Mcp.Server.ServerState.runtime) state

private abbrev nextInstanceRef (state : Beam.Mcp.Server.ServerState) :=
  (mcpPrivate% Beam.Mcp.Server.ServerState.nextWorkspaceInstance) state

private abbrev cachedWorkspaces (runtime : (mcpPrivate% Beam.Mcp.Server.OwnedRuntime)) :=
  (mcpPrivate% Beam.Mcp.Server.OwnedRuntime.workspaces) runtime

private def callTool
    (state : Beam.Mcp.Server.ServerState)
    (opts : Beam.Mcp.Server.Options)
    (id : Nat)
    (name : String)
    (root : System.FilePath) : IO Json := do
  let arguments := Json.mkObj <| [
    ("workspace", toJson (Beam.Workspace.Descriptor.ofRoot root))
  ] ++ if name == "lean_close" then [("path", toJson "Missing.lean")] else []
  let request := Json.mkObj [
    ("jsonrpc", toJson "2.0"), ("id", toJson id), ("method", toJson "tools/call"),
    ("params", Json.mkObj [
      ("name", toJson name), ("arguments", arguments),
      ("_meta", Json.mkObj [
        ("io.modelcontextprotocol/protocolVersion", toJson Beam.Mcp.protocolVersion),
        ("io.modelcontextprotocol/clientCapabilities", Json.mkObj []),
        ("io.modelcontextprotocol/clientInfo", Json.mkObj [
          ("name", toJson "drop-failure-test"), ("version", toJson "0")
        ])
      ])
    ])
  ]
  let some response ← Beam.Mcp.Server.handleJson state opts request
    | throw <| IO.userError "MCP drop-failure fixture received no response"
  pure response

private def successfulResult (label : String) (response : Json) : IO Json := do
  let result ← requireObjVal label "result" response
  requireJsonBool label "isError" false result
  requireObjVal label "structuredContent" result

def run : IO Unit := do
  let base := System.FilePath.mk s!"/tmp/beam-mcp-drop-failure-{← IO.monoNanosNow}"
  let state ← Beam.Mcp.Server.ServerState.create
  try
    for name in ["failed", "healthy"] do
      IO.FS.createDirAll (base / name)
      IO.FS.writeFile (base / name / "lakefile.lean") "import Lake\nopen Lake DSL\npackage fixture\n"
    let failedRoot ← Beam.resolveExistingPath (base / "failed")
    let healthyRoot ← Beam.resolveExistingPath (base / "healthy")
    let failedId := (Beam.Workspace.Descriptor.ofRoot failedRoot).cacheKey
    let healthyId := (Beam.Workspace.Descriptor.ofRoot healthyRoot).cacheKey
    let broker ← Beam.Broker.ServerRuntime.create { root := failedRoot } failedId
    match ← broker.initWorkspaceWithConfig healthyId { root := healthyRoot } with
    | .ok _ => pure ()
    | .error failure => throw <| IO.userError failure.error.message
    let (capture, sourceError) ← IO.FS.withFile (base / "write-only-stderr") .write fun source => do
      let capture ← Beam.Broker.startBackendStderrCapture source
      match ← capture.awaitCompletion with
      | .sourceFailed error => pure (capture, error)
      | _ => throw <| IO.userError "MCP cleanup fixture did not fail its stderr source"
    let writes ← IO.mkRef (0 : Nat)
    let signals ← IO.mkRef (0 : Nat)
    let process ← Beam.Broker.BackendProcess.create 0 (pure (some 9)) do
      signals.modify (· + 1)
      throw <| IO.userError "MCP cleanup fixture must not signal an observed exit"
    let stream ← IO.getStdin
    let pending ← Beam.Broker.PendingRequestStore.create
    let session : Beam.Broker.Session := {
      workspaceId := failedId, workspaceGeneration := 1, root := failedRoot
      epoch := 1, sessionToken := "drop-failure-fixture", proc := process
      stdin := { stream with putStr := fun _ => do
        writes.modify (· + 1)
        throw <| IO.userError "MCP cleanup fixture must not write after observed exit"
      }
      stdout := stream, stderrCapture := capture, pending
    }
    broker.state.atomically do
      let current ← get
      let some workspace := current.workspaces.get? failedId
        | throw <| IO.userError "MCP cleanup fixture lost its broker workspace"
      let workspace := { workspace with lean := { nextEpoch := 2, session? := some session } }
      set { current with workspaces := current.workspaces.insert failedId workspace }
    let description : Beam.Runtime.Description := {
      command := "unused", plugin := base / "unused-plugin", daemonBin := base / "unused-daemon"
      toolchain := "drop-failure-fixture", identity := ⟨base, "drop-failure-fixture"⟩
    }
    let cached := (mcpPrivate% Beam.Mcp.Server.OwnedRuntime.mk) broker <|
      ({} : Std.HashMap _ _)
        |>.insert failedId ((mcpPrivate% Beam.Mcp.Server.OwnedWorkspace.mk) failedRoot description 0)
        |>.insert healthyId ((mcpPrivate% Beam.Mcp.Server.OwnedWorkspace.mk) healthyRoot description 1)
    (runtimeRef state).atomically <| set (some cached)
    (nextInstanceRef state).set 2
    let resolutions ← IO.mkRef (0 : Nat)
    let opts : Beam.Mcp.Server.Options := {
      resolveRuntime := fun _ _ => do
        resolutions.modify (· + 1)
        pure (.ok description)
      admitRuntime := fun _ _ _ => pure (.ok ())
    }
    let dropOutcome : Except IO.Error Json ←
      try pure (.ok (← callTool state opts 1 "lean_drop_workspace" failedRoot))
      catch error => pure (.error error)
    match dropOutcome with
    | .error (.userError message) =>
        require "failed drop retains the original typed cleanup error"
          (message == s!"backend stderr source failed while draining: {sourceError}")
    | .error error => throw error
    | .ok _ => throw <| IO.userError "failed drop hid its cleanup error"
    require "failed drop keeps the committed broker removal"
      ((← broker.workspaceRoot? failedId).isNone)
    (runtimeRef state).atomically do
      let some runtime ← get | throw <| IO.userError "failed drop lost the shared runtime"
      require "failed drop removes stale MCP membership" (!(cachedWorkspaces runtime).contains failedId)
      require "failed drop retains unrelated MCP membership" ((cachedWorkspaces runtime).contains healthyId)
    discard <| successfulResult "unrelated workspace after failed drop" <|
      ← callTool state opts 2 "lean_close" healthyRoot
    require "unrelated cached workspace does not resolve again" ((← resolutions.get) == 0)
    discard <| successfulResult "ordinary request after failed drop" <|
      ← callTool state opts 3 "lean_close" failedRoot
    require "ordinary request recreates the dropped broker workspace"
      ((← broker.workspaceRoot? failedId) == some failedRoot && (← resolutions.get) == 1)
    (runtimeRef state).atomically do
      let some runtime ← get | throw <| IO.userError "recreated workspace lost its runtime"
      require "recreated workspace has a new MCP instance"
        ((cachedWorkspaces runtime)[failedId]?.any fun workspace =>
          (mcpPrivate% Beam.Mcp.Server.OwnedWorkspace.serial) workspace == 2)
    let dropped ← successfulResult "drop recreated workspace" <|
      ← callTool state opts 4 "lean_drop_workspace" failedRoot
    requireJsonBool "drop recreated workspace" "dropped" true dropped
    let repeated ← successfulResult "repeat drop after cleanup failure" <|
      ← callTool state opts 5 "lean_drop_workspace" failedRoot
    requireJsonBool "repeat drop after cleanup failure" "dropped" false repeated
    requireJsonString "repeat drop after cleanup failure" "reason" "notFound" repeated
    require "drop and repeated drop do not resolve runtimes" ((← resolutions.get) == 1)
    require "observed exit prevents graceful writes and signalling"
      ((← writes.get) == 0 && (← signals.get) == 0)
  finally
    state.closeRuntime
    IO.FS.removeDirAll base

end BeamTest.Broker.McpDropFailureTest
