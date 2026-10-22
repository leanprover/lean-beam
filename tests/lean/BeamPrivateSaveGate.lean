/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.LSP.Plugin

open Lean Lean.Server

/-! Opt-in regression plugin. It delays one delivered request before delegating to the unchanged
production save handler. It is never loaded by the ordinary fixture or shipped plugin. -/

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

private def wrapSave (handler : RequestHandler) (params : Json) :
    RequestM (RequestTask SerializedLspResponse) := do
  let some directory ← IO.getEnv "BEAM_PRIVATE_EFFECT_GATE" | return ← handler.handle params
  let gate := System.FilePath.mk directory
  unless ← claimGate gate do
    writeJson (gate / "replacement-entry.json") <| Json.mkObj [
      ("workerPid", toJson (← IO.Process.getPID).toNat), ("params", params)
    ]
    return ← handler.handle params
  let gateTask ← RequestM.asTask do
    writeJson (gate / "entered.json") <| Json.mkObj [
      ("workerPid", toJson (← IO.Process.getPID).toNat),
      ("enteredAtMs", toJson (← IO.monoMsNow)),
      ("params", params)
    ]
    let deadline := (← IO.monoMsNow) + 60000
    repeat
      if ← (gate / "release").pathExists then break
      if (← IO.monoMsNow) >= deadline then
        throw <| RequestError.internalError "private-publication effect gate timed out"
      IO.sleep 10
  -- Crucially, the original handler is invoked after the gate, with the captured RequestContext.
  let task ← RequestM.bindRequestTaskCheap gateTask fun _ => handler.handle params
  RequestM.mapTaskCheap task fun outcome => do
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
