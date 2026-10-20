/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import BeamTest.Broker.JsonAssert

open Lean Beam.Broker BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.SaveOwnerTest

private def workspaceId : WorkspaceId := "save-owner-test"

private def call (server : ServerRuntime) (payload : RequestPayload) : IO Response :=
  server.dispatchRequest { payload, workspaceId? := some workspaceId }

private def result (response : Response) : IO Json := do
  require s!"expected success: {(toJson response).compress}" response.ok
  pure <| response.result?.getD Json.null

private def session (server : ServerRuntime) : IO Session :=
  server.withState do
    let some workspace := (← get).workspaces.get? workspaceId
      | throw <| IO.userError "missing fixture workspace"
    let some current := workspace.lean.session?
      | throw <| IO.userError "missing fixture backend"
    pure current

private def doc (server : ServerRuntime) (uri : String) : IO DocState := do
  DocumentState.requireDocState (← session server).docs uri

private def waitForGate (gate : System.FilePath) : IO Unit := do
  let deadline := (← IO.monoMsNow) + 20000
  repeat
    if ← (gate / "entered").pathExists then return
    require "save did not enter the trace helper" ((← IO.monoMsNow) < deadline)
    IO.sleep 10

/-- Exercise owner replacement while real artifact publication awaits the trace helper. -/
def run (description : Beam.Runtime.Description) (root : System.FilePath)
    (case : String) : IO Unit := do
  let some gate ← IO.getEnv "BEAM_TEST_SAVE_GATE_DIR"
    | throw <| IO.userError "missing save gate directory"
  let gate := System.FilePath.mk gate
  let config := BrokerConfig.ofRuntime root description
  let first ← ServerRuntime.create config workspaceId
  let second? ← if case == "distinct-runtime" then
      some <$> ServerRuntime.create config workspaceId
    else pure none
  let uri := sessionUri (root / "Main.lean")
  try
    discard <| result (← call first (.syncFile { path := "Main.lean" }))
    let original ← session first
    if let some second := second? then
      discard <| result (← call second (.syncFile { path := "Main.lean" }))
      let other ← session second
      require "fixture must reuse address and local counters in distinct runtimes"
        (original.workspaceId == other.workspaceId &&
         original.workspaceGeneration == other.workspaceGeneration &&
         original.epoch == other.epoch &&
         DocumentState.basis (← doc first uri) == DocumentState.basis (← doc second uri))
    IO.FS.writeFile (gate / "enabled") ""
    let pending ← IO.asTask (prio := .dedicated) <|
      call first (.close { path := "Main.lean", saveArtifacts? := some true })
    try
      waitForGate gate
      let target := second?.getD first
      if case == "backend-restart" then
        match ← original.proc.terminate 2000 with
        | .exited _ => pure ()
        | .unconfirmed .. => throw <| IO.userError "fixture backend termination was not confirmed"
      else if case == "workspace-replace" then
        discard <| result (← call first .dropWorkspace)
        match ← first.initWorkspaceWithConfig workspaceId config (some .set) with
        | .ok _ => pure ()
        | .error failure => throw <| IO.userError failure.error.message
      else
        require "unknown owner test" (case == "distinct-runtime")
      discard <| result (← call target (.syncFile { path := "Main.lean" }))
      let replacement ← session target
      if case == "backend-restart" then
        require "restart must change backend within the same workspace"
          (replacement.workspaceGeneration == original.workspaceGeneration &&
           replacement.epoch != original.epoch)
      if case == "workspace-replace" then
        require "recreation must change workspace generation"
          (replacement.workspaceGeneration != original.workspaceGeneration)
      let before ← doc target uri
      require "replacement starts uncheckpointed at reused version one"
        (before.version == 1 && before.checkpointedVersion?.isNone)
      let seed ← result (← call target (.runAt {
        path := "Main.lean", version := before.version, line := 2, character := 2
        text := "skip", storeHandle? := some true
      }))
      let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      IO.FS.writeFile (gate / "response.json") (toJson response).pretty
      if case == "distinct-runtime" then
        requireJsonBool "first runtime closes its own document" "closed" true (← result response)
        require "first document was closed" (!(← session first).docs.contains uri)
      else
        let some error := response.error?
          | throw <| IO.userError "replaced owner incorrectly finalized"
        require "replaced owner preserves failure" (error.code == "workerExited")
        let data := error.data?.getD Json.null
        requireJsonInt "committed checkpoint retained" "version" 1
          (← requireObjVal "owner loss" "saved" data)
        requireFieldAbsent "owner loss does not claim closure outcome" "closed" data
      let after ← doc target uri
      require "completion must preserve the other acceptance and its state"
        (DocumentState.basis after == DocumentState.basis before &&
         after.checkpointedVersion?.isNone && after.lastSyncEventSeq == before.lastSyncEventSeq &&
         after.fileProgress? == before.fileProgress?)
      requireJsonBool "replacement continuation survives" "success" true
        (← result (← call target (.runWith { path := "Main.lean", handle, text := "trivial" })))
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| IO.ofExcept pending.get
  finally
    IO.FS.writeFile (gate / "release") ""
    first.close
    if let some second := second? then second.close
  IO.println s!"save owner ({case}): passed"

end BeamTest.Broker.SaveOwnerTest
