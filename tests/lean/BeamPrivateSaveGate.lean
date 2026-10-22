/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.LSP.Plugin

open Lean Lean.Server

/-! Opt-in regression plugin. It delays one delivered request before the production handler, or
after real serialization and before its reply. It is never shipped. -/

private def writeJson (path : System.FilePath) (value : Json) : IO Unit := do
  let temporary := System.FilePath.mk (path.toString ++ ".tmp")
  IO.FS.writeFile temporary value.pretty
  IO.FS.rename temporary path

private def claimGate (gate : System.FilePath) : IO Bool := do
  try
    IO.FS.withFile (gate / "claimed") .writeNew fun _ => pure ()
    pure true
  catch
  | .alreadyExists .. => pure false
  | error => throw error

private def waitForRelease (gate : System.FilePath) : IO Unit := do
  let deadline := (← IO.monoMsNow) + 60000
  repeat
    if ← (gate / "release").pathExists then return
    if (← IO.monoMsNow) >= deadline then
      throw <| IO.userError "private-publication effect gate timed out"
    IO.sleep 10

private def wrapSave (handler : RequestHandler) (params : Json) :
    RequestM (RequestTask SerializedLspResponse) := do
  let some directory ← IO.getEnv "BEAM_PRIVATE_EFFECT_GATE" | return ← handler.handle params
  let gate := System.FilePath.mk directory
  let afterSerialization := (← IO.getEnv "BEAM_PRIVATE_EFFECT_PHASE") == some "after-serialization"
  if afterSerialization then
    unless ← (gate / "enabled").pathExists do return ← handler.handle params
  unless ← claimGate gate do
    writeJson (gate / "replacement-entry.json") <| Json.mkObj [
      ("workerPid", toJson (← IO.Process.getPID).toNat), ("params", params)
    ]
    return ← handler.handle params
  let entered := fun (phase : String) => do
    writeJson (gate / "entered.json") <| Json.mkObj [
      ("workerPid", toJson (← IO.Process.getPID).toNat),
      ("enteredAtMs", toJson (← IO.monoMsNow)),
      ("phase", toJson phase), ("params", params)
    ]
  let task ← if afterSerialization then
      handler.handle params
    else do
      let gateTask ← RequestM.asTask do
        entered "before-handler"
        waitForRelease gate
      -- Preserve the captured RequestContext for the old-producer schedule.
      RequestM.bindRequestTaskCheap gateTask fun _ => handler.handle params
  RequestM.mapTaskCheap task fun outcome => do
    if afterSerialization then
      entered "after-serialization"
      waitForRelease gate
    let terminal := match outcome with
      | .ok response => Json.mkObj [
          ("kind", toJson "response"),
          ("response", (Json.parse response.serialized).toOption.getD Json.null)
        ]
      | .error error => Json.mkObj [
          ("kind", toJson "requestError"),
          ("code", toJson error.code),
          ("message", toJson error.message)
        ]
    writeJson (gate / "terminal.json") <| Json.mkObj [
      ("workerPid", toJson (← IO.Process.getPID).toNat),
      ("terminalAtMs", toJson (← IO.monoMsNow)),
      ("outcome", terminal)
    ]
    match outcome with
    | .ok response => pure response
    | .error error => throw error

initialize
  let handlers ← requestHandlers.get
  let some handler := handlers.find? Beam.LSP.Save.saveArtifactsMethod
    | throw <| IO.userError "private-publication investigation requires the production save handler"
  requestHandlers.modify fun handlers => handlers.insert Beam.LSP.Save.saveArtifactsMethod {
    handler with handle := wrapSave handler
  }
