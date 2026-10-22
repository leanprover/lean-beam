/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.Server
import BeamTest.Broker.JsonAssert

open Lean Beam.Broker BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.PrivatePublicationTest

private def workspaceId : WorkspaceId := "r2-investigation"

private def call (server : ServerRuntime) (payload : RequestPayload) : IO Response :=
  server.dispatchRequest { payload, workspaceId? := some workspaceId }

private def result (response : Response) : IO Json := do
  require s!"fixture request failed: {(toJson response).compress}" response.ok
  pure <| response.result?.getD Json.null

private def session (server : ServerRuntime) : IO Session :=
  server.withState do
    let some workspace := (← get).workspaces.get? workspaceId
      | throw <| IO.userError "missing private-publication workspace"
    let some session := workspace.lean.session?
      | throw <| IO.userError "missing private-publication backend"
    pure session

private def waitForPath (path : System.FilePath) (timeoutMs : Nat := 20000) : IO Bool := do
  let deadline := (← IO.monoMsNow) + timeoutMs
  repeat
    if ← path.pathExists then return true
    if (← IO.monoMsNow) >= deadline then return false
    IO.sleep 10
  pure false

private def readJson (path : System.FilePath) : IO Json := do
  IO.ofExcept <| Json.parse (← IO.FS.readFile path)

private def copyArtifacts (gate : System.FilePath) (label : String)
    (paths : Array System.FilePath) : IO (Array ByteArray × Json) := do
  let directory := gate / label
  IO.FS.createDirAll directory
  let mut contents := #[]
  let mut observations := #[]
  for path in paths do
    let bytes ← IO.FS.readBinFile path
    let copy := directory / path.fileName.getD "artifact"
    IO.FS.writeBinFile copy bytes
    contents := contents.push bytes
    observations := observations.push <| Json.mkObj [
      ("target", toJson path.toString),
      ("copy", toJson copy.toString),
      ("bytes", toJson bytes.size),
      ("leanHash", toJson (hash bytes))
    ]
  pure (contents, toJson observations)

/-- Directed old-producer regression against canonical artifact and trace bytes. -/
def run (description : Beam.Runtime.Description) (root : System.FilePath) : IO Unit := do
  let some directory ← IO.getEnv "BEAM_PRIVATE_EFFECT_GATE"
    | throw <| IO.userError "missing private-publication effect gate"
  let gate := System.FilePath.mk directory
  let sourcePrefix := if (← IO.getEnv "BEAM_PRIVATE_MODULE") == some "1" then "module\npublic " else ""
  let sourceA := sourcePrefix ++ "def r2Value : Nat := 11\n"
  let sourceB := sourcePrefix ++ "def r2Value : Nat := 22\n"
  let closeAfter := (← IO.getEnv "BEAM_PRIVATE_ORDINARY") != some "1"
  let operation : RequestPayload := if closeAfter then
      .close { path := "Main.lean", saveArtifacts? := some true }
    else .saveOlean { path := "Main.lean" }
  IO.FS.writeFile (root / "Main.lean") sourceA
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  let original? ← IO.mkRef (none : Option Session)
  let oldTask? ← IO.mkRef (none : Option (Task (Except IO.Error Response)))
  let gateEntered ← IO.mkRef false
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let original ← session server
    original?.set (some original)
    let faultArmed ← IO.mkRef false
    let polls ← IO.mkRef (0 : Nat)
    let failedWaits ← IO.mkRef (0 : Nat)
    let signals ← IO.mkRef (0 : Nat)
    let delivered ← IO.mkRef false
    let controlled ← BackendProcess.create original.proc.pid
      (do
        polls.modify (· + 1)
        if ← faultArmed.get then
          failedWaits.modify (· + 1)
          throw <| IO.userError "controlled private-publication process wait failure"
        pure none)
      (signals.modify (· + 1))
    -- Install the controlled owner before close-save captures its DocumentRef. The existing
    -- reader and this lexical scope retain the independent real child owner for final cleanup.
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing private-publication workspace"
      let session := { original with
        proc := controlled
        stdin := { original.stdin with putStr := fun text => do
          original.stdin.putStr text
          if text.contains saveArtifactsMethod then
            original.stdin.flush
            delivered.set true
            require "delivered save did not enter its worker gate"
              (← waitForPath (gate / "entered.json"))
            gateEntered.set true
            faultArmed.set true
            throw <| IO.userError "controlled private-publication failure after save request flush"
        }
      }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some session } } }
    let oldTask ← IO.asTask (prio := .dedicated) <|
      call server (.close { path := "Main.lean", saveArtifacts? := some true })
    oldTask?.set (some oldTask)
    let some (.ok failed) ← Beam.waitTaskWithTimeout oldTask 30000
      | throw <| IO.userError "private-publication close-save did not finish its cleanup/unwind"
    require "fixture never delivered the old artifact request" (← delivered.get)
    IO.FS.writeFile (gate / "first-response.json") (toJson failed).pretty
    let some error := failed.error? | throw <| IO.userError "faulted close-save unexpectedly succeeded"
    require "unconfirmed exit error was not surfaced"
      (error.message.contains "backend process exit was not confirmed" &&
       error.message.contains "controlled private-publication process wait failure")
    let entered ← readJson (gate / "entered.json")
    let params : Beam.LSP.Save.SaveArtifactsParams ←
      IO.ofExcept <| fromJson? (← IO.ofExcept <| entered.getObjVal? "params")
    let mut paths := #[System.FilePath.mk params.oleanFile, System.FilePath.mk params.ileanFile,
      System.FilePath.mk params.cFile]
    if let some modulePaths := params.moduleArtifacts? then
      paths := paths ++ #[System.FilePath.mk modulePaths.oleanServerFile,
        System.FilePath.mk modulePaths.oleanPrivateFile, System.FilePath.mk modulePaths.irFile,
        System.FilePath.mk modulePaths.irSigFile]
    if let some bc := params.bcFile? then paths := paths.push (System.FilePath.mk bc)
    require "old task passed the gate before replacement admission"
      (!(← (gate / "release").pathExists) && !(← (gate / "terminal.json").pathExists))
    for path in paths do
      require "held old handler unexpectedly published an artifact" (!(← path.pathExists))
    require "real old backend exited before the effect was released" ((← original.proc.observe).isNone)
    require "controlled wait failure must be retained exactly once" ((← failedWaits.get) == 1)
    require "controlled owner must not signal the real child" ((← signals.get) == 0)
    let afterFailure ← server.withState do
      let some workspace := (← get).workspaces.get? workspaceId
        | throw <| IO.userError "private-publication workspace disappeared"
      require "old session remained admitted after retirement" workspace.lean.session?.isNone
      require "old request did not release its document scope" workspace.documents.entries.isEmpty
      pure <| Json.mkObj [
        ("sessionActive", toJson workspace.lean.session?.isSome),
        ("admissionEntries", toJson workspace.documents.entries.length),
        ("nextEpoch", toJson workspace.lean.nextEpoch)
      ]
    -- The broker has detached the old mirror and released its request scope. The experiment
    -- deliberately retains that worker's immutable old snapshot while changing the owned source.
    IO.FS.writeFile (root / "Main.lean") sourceB
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let replacement ← session server
    require "replacement must have a new backend epoch" (replacement.epoch != original.epoch)
    let replacementTask ← IO.asTask (prio := .dedicated) <|
      call server operation
    let replacementOutcome ← Beam.waitTaskWithTimeout replacementTask 20000
    let replacementWhileHeld := replacementOutcome.isSome
    let mut replacementResponse := Json.null
    let mut replacementArtifacts := Json.null
    let mut replacementBytes : Array ByteArray := #[]
    let mut canonicalPaths : Array System.FilePath := #[]
    if let some (.ok response) := replacementOutcome then
      replacementResponse := toJson response
      if response.ok then
        let json := response.result?.getD Json.null
        let savedJson ← if closeAfter then IO.ofExcept (json.getObjVal? "saved") else pure json
        let saved : SaveOleanResult ← IO.ofExcept <| fromJson? savedJson
        require "worker was given canonical artifact destinations"
          (saved.olean != params.oleanFile && saved.ilean != params.ileanFile && saved.c != params.cFile)
        canonicalPaths := #[saved.olean, saved.ilean, saved.c].map System.FilePath.mk
        for path in [saved.oleanServer?, saved.oleanPrivate?, saved.ir?, saved.irSig?, saved.bc?] do
          if let some path := path then canonicalPaths := canonicalPaths.push (System.FilePath.mk path)
        canonicalPaths := canonicalPaths.push (System.FilePath.mk saved.trace)
        let nextEntry ← readJson (gate / "replacement-entry.json")
        let nextParams : Beam.LSP.Save.SaveArtifactsParams ←
          IO.ofExcept <| fromJson? (← IO.ofExcept <| nextEntry.getObjVal? "params")
        require "replacement reused abandoned private outputs" (nextParams.oleanFile != params.oleanFile)
        let (bytes, evidence) ← copyArtifacts gate "replacement-artifacts" canonicalPaths
        replacementBytes := bytes
        replacementArtifacts := evidence
    else if let some (.error error) := replacementOutcome then
      throw error
    require "old effect completed before explicit release" (!(← (gate / "terminal.json").pathExists))
    require "old backend is not live before explicit release" ((← original.proc.observe).isNone)
    IO.FS.writeFile (gate / "release") "released after replacement attempt"
    require "released old handler did not reach its terminal task outcome"
      (← waitForPath (gate / "terminal.json") 20000)
    let terminal ← readJson (gate / "terminal.json")
    let outcome ← IO.ofExcept <| terminal.getObjVal? "outcome"
    let completion : Beam.LSP.Save.SaveArtifactsCompletion ←
      IO.ofExcept <| fromJson? (← IO.ofExcept <| outcome.getObjVal? "response")
    match completion with
    | .success saved =>
        require "old publication no longer describes the captured source"
          (saved.version == params.expectedVersion && saved.textHash == hash sourceA)
    | .failure _ message => throw <| IO.userError s!"old real handler failed after release: {message}"
    let (_, oldArtifacts) ← copyArtifacts gate "old-private-artifacts" paths
    let (afterBytes, afterArtifacts) ← copyArtifacts gate "after-old-canonical" canonicalPaths
    let unchanged := !replacementBytes.isEmpty && afterBytes == replacementBytes
    require "replacement did not publish before old private producer completed" (!replacementBytes.isEmpty)
    require "abandoned private producer changed canonical artifacts or trace" unchanged
    require "late completion resurrected the old backend" ((← session server).epoch == replacement.epoch)
    let report := Json.mkObj [
      ("kind", toJson "privatePublicationRegression"),
      ("isSafetyRegressionTest", toJson true),
      ("replacementCloseAfter", toJson closeAfter),
      ("oldBackendPid", toJson original.proc.pid.toNat),
      ("oldEpoch", toJson original.epoch),
      ("replacementEpoch", toJson replacement.epoch),
      ("sourceAText", toJson sourceA),
      ("sourceBText", toJson sourceB),
      ("sourceAHash", toJson (hash sourceA)),
      ("sourceBHash", toJson (hash sourceB)),
      ("deliveredAndFlushed", toJson (← delivered.get)),
      ("controlledPolls", toJson (← polls.get)),
      ("controlledFailedWaits", toJson (← failedWaits.get)),
      ("controlledSignals", toJson (← signals.get)),
      ("firstResponse", toJson failed),
      ("stateAfterFailure", afterFailure),
      ("gateEntry", entered),
      ("replacementFinishedWhileOldHeld", toJson replacementWhileHeld),
      ("replacementPublishedWhileOldHeld", toJson (!replacementBytes.isEmpty)),
      ("replacementResponse", replacementResponse),
      ("replacementArtifacts", replacementArtifacts),
      ("oldTerminal", terminal),
      ("oldPrivateArtifacts", oldArtifacts),
      ("afterOldCanonicalArtifacts", afterArtifacts),
      ("canonicalUnchangedAfterOldCompletion", toJson unchanged)
    ]
    IO.FS.writeFile (gate / "observation.json") report.pretty
    IO.println report.compress
  finally
    try
      IO.FS.writeFile (gate / "release") "finally release"
      if ← gateEntered.get then
        discard <| waitForPath (gate / "terminal.json") 20000
      if let some oldTask ← oldTask?.get then
        discard <| Beam.waitTaskWithTimeout oldTask 5000
      if let some original ← original?.get then
        -- The stream failure was injected after a complete flushed frame. This fixture knows
        -- that the captured pipe is intact and may request exit before the real owner's fallback.
        try
          original.stdin.writeLspNotification
            ({ method := "exit", param := Json.null : JsonRpc.Notification Json })
        catch _ => pure ()
        match ← original.proc.waitForExit 2000 with
        | some (.exited _) => pure ()
        | _ =>
          match ← original.proc.terminate 2000 with
          | .exited _ => pure ()
          | .unconfirmed .. => throw <| IO.userError "real private-publication backend cleanup was not confirmed"
    finally
      server.close

end BeamTest.Broker.PrivatePublicationTest
