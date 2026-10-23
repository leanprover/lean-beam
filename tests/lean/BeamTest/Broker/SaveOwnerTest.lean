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

private def artifactPaths (saved : SaveOleanResult) : Array System.FilePath := Id.run do
  let mut paths := #[saved.olean, saved.ilean, saved.c, saved.trace]
  for path? in #[saved.oleanServer?, saved.oleanPrivate?, saved.ir?, saved.irSig?, saved.bc?] do
    if let some path := path? then paths := paths.push path
  return paths.map System.FilePath.mk

private structure CheckpointFile where
  path : System.FilePath
  contents : ByteArray
  modified : IO.FS.SystemTime

private def snapshotFiles (paths : Array System.FilePath) : IO (Array CheckpointFile) :=
  paths.mapM fun path => do
    pure { path, contents := ← IO.FS.readBinFile path, modified := (← path.metadata).modified }

private def snapshotCheckpoint (saved : SaveOleanResult) : IO (Array CheckpointFile) :=
  snapshotFiles (artifactPaths saved)

private def requireCheckpointUnchanged (prior : Array CheckpointFile) : IO Unit := do
  for file in prior do
    require s!"precommit refusal changed checkpoint bytes: {file.path}"
      ((← IO.FS.readBinFile file.path) == file.contents)
    require s!"precommit refusal rewrote checkpoint: {file.path}"
      ((← file.path.metadata).modified == file.modified)

private def requireCanonicalPresent (saved : SaveOleanResult) : IO Unit := do
  for path in artifactPaths saved do
    require s!"committed receipt artifact is absent: {path}" ((← path.metadata).type == .file)

private def requirePrivateRetention (saved : SaveOleanResult) (retained : Bool) : IO Unit := do
  let mut directories : Array System.FilePath := #[]
  let mut claims : Array System.FilePath := #[]
  for path in artifactPaths saved do
    for entry in ← (path.parent.getD ".").readDir do
      if entry.fileName.startsWith ".beam-publication-" then
        if entry.fileName.endsWith ".claim" then
          if !claims.contains entry.path then claims := claims.push entry.path
        else
          if !directories.contains entry.path then directories := directories.push entry.path
  let expected := if retained then (artifactPaths saved).size else 0
  require "private preparation retained the wrong number of directories"
    (directories.size == expected)
  require "private preparation retained the wrong number of claims" (claims.size == expected)
  for directory in directories do
    require "unsettled private directory lost its exclusive claim"
      (claims.contains (System.FilePath.mk (directory.toString ++ ".claim")))

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

private def requireNoAdmissions (server : ServerRuntime) : IO Unit :=
  server.withState do
    let some workspace := (← get).workspaces.get? workspaceId
      | throw <| IO.userError "missing fixture workspace"
    require "completed request leaked document admission" workspace.documents.entries.isEmpty

/-- Pause a real admitted request before source reading, without adding a production test hook. -/
private def delayedAdmission (description : Beam.Runtime.Description) (root gate : System.FilePath) :
    IO Unit := do
  let config := BrokerConfig.ofRuntime root description
  let armed ← Std.Mutex.new false
  let server ← ServerRuntime.create config workspaceId (admission? := some fun _ => do
    let pause ← armed.atomically do
      let value ← get
      set false
      pure value
    if pause then
      IO.FS.writeFile (gate / "entered") ""
      let deadline := (← IO.monoMsNow) + 20000
      repeat
        if ← (gate / "release").pathExists then break
        require "delayed admission gate timed out" ((← IO.monoMsNow) < deadline)
        IO.sleep 10
    pure <| .ok config)
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    armed.atomically (set true)
    let pending ← IO.asTask (prio := .dedicated) <|
      call server (.updateFile { path := "Main.lean" })
    try
      waitForGate gate
      requireJsonBool "close-save completes while an old admission is paused" "closed" true
        (← result (← call server (.close { path := "Main.lean", saveArtifacts? := some true })))
      -- A genuinely new request may reopen, even before the old scope releases its permit.
      discard <| result (← call server (.syncFile { path := "Main.lean" }))
      let uri := sessionUri (root / "Main.lean")
      let before ← doc server uri
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      let some error := response.error? | throw <| IO.userError "old admission reopened the file"
      requireJsonString "old request retains its captured permit" "reason" "documentAdmissionExpired"
        (error.data?.getD Json.null)
      require "old cleanup preserved the new document"
        (DocumentState.basis (← doc server uri) == DocumentState.basis before)
      requireNoAdmissions server
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| IO.ofExcept pending.get
  finally
    server.close

/-- A worker's settled rejection must preserve this document and unrelated continuations. -/
private def rejectedClose (description : Beam.Runtime.Description) (root : System.FilePath) :
    IO Unit := do
  IO.FS.writeFile (root / "Main.lean") "def broken : Nat := \"broken\"\n"
  IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let other ← result (← call server (.syncFile { path := "Other.lean" }))
    let version : Nat ← IO.ofExcept <| other.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let before ← doc server uri
    let artifact := root / ".lake" / "build" / "lib" / "lean" / "Main.olean"
    IO.FS.createDirAll (artifact.parent.getD root)
    IO.FS.writeFile artifact "prior checkpoint"
    let response ← call server (.close { path := "Main.lean", saveArtifacts? := some true })
    let some error := response.error? | throw <| IO.userError "broken document was saved"
    require "document errors remain invalidParams" (error.code == "invalidParams")
    let sync ← requireObjVal "rejected save" "sync" (error.data?.getD Json.null)
    let readiness ← requireObjVal "rejected save sync" "readiness" sync
    requireJsonBool "blocking readiness remains false" "saveReady" false readiness
    let blocking : Nat ← IO.ofExcept <| readiness.getObjValAs? Nat "blockingErrorCount"
    require "readiness retains blocking Lean errors" (blocking > 0)
    require "completed progress survives rejection" (response.fileProgress?.any (·.done))
    require "readiness rejection precedes artifact publication"
      ((← IO.FS.readFile artifact) == "prior checkpoint")
    require "settled rejection preserves the backend" ((← session server).epoch == original.epoch)
    require "settled rejection preserves the document"
      (DocumentState.basis (← doc server uri) == DocumentState.basis before)
    requireNoAdmissions server
    requireJsonBool "unrelated continuation survives rejected close-save" "success" true
      (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
    -- Close before changing the source outside the broker, then synchronize the repaired file.
    discard <| result (← call server (.close { path := "Main.lean" }))
    IO.FS.writeFile (root / "Main.lean") "def repaired : Nat := 42\n"
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    requireJsonBool "repaired document can close-save" "closed" true
      (← result (← call server (.close { path := "Main.lean", saveArtifacts? := some true })))
    require "successful retry removes the repaired document" (!(← session server).docs.contains uri)
    require "retry retains the original backend" ((← session server).epoch == original.epoch)
    requireJsonBool "unrelated continuation survives successful retry" "success" true
      (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
  finally
    server.close

/-- Inject router replies at the existing stream boundary, before a worker task is launched. -/
private def completionReply (description : Beam.Runtime.Description) (root gate : System.FilePath)
    (case : String) (closeAfter : Bool) : IO Unit := do
  let workerCrash := case == "remote-worker-crashed" || case == "cancelled-remote-worker-crashed"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
    let other ← result (← call server (.syncFile { path := "Other.lean" }))
    let version : Nat ← IO.ofExcept <| other.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let prior ← snapshotCheckpoint saved
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let before ← doc server uri
    IO.FS.writeFile (gate / "enabled") ""
    let pending ← IO.asTask (prio := .dedicated) <|
      server.dispatchRequest {
        payload := if closeAfter then .close { path := "Main.lean", saveArtifacts? := some true }
          else .saveOlean { path := "Main.lean" }
        workspaceId? := some workspaceId, clientRequestId? := some "completion-reply"
      }
    try
      waitForGate gate
      let intercepted ← IO.mkRef false
      server.withState do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "missing fixture workspace"
        let some current := workspace.lean.session?
          | throw <| IO.userError "missing fixture backend"
        let current := { current with stdin := { current.stdin with putStr := fun text => do
          if !text.contains saveArtifactsMethod then
            current.stdin.putStr text
            return
          intercepted.set true
          let entries ← current.pending.snapshotEntries
          require "save reply fixture expects one pending request" (entries.size == 1)
          let some (id, request) := entries[0]?
            | throw <| IO.userError "missing intercepted save request"
          discard <| current.pending.remove id
          if case == "cancelled-handler-failure" || case == "cancelled-remote-owner-loss" ||
              case == "cancelled-remote-worker-crashed" then
            let some _ ← ActiveRequestRegistry.markCancelled server.activeRequests
                (some workspaceId) "completion-reply"
              | throw <| IO.userError "missing save caller cancellation identity"
            pure ()
          if case == "remote-invalid-params" then
            request.resolveError .invalidParams "bare remote parameter rejection"
          else if workerCrash then
            request.resolveError .workerCrashed "worker crashed during private save completion"
          else if case == "remote-owner-loss" || case == "cancelled-remote-owner-loss" then
            request.resolveError .contentModified "file worker terminated"
          else if case == "remote-cancelled" then
            request.resolveError .requestCancelled "completion acknowledgement suppressed"
          else if case == "malformed-completion" then
            -- An old success payload is not a completion acknowledgement.
            request.resolveResponse <| toJson ({ version := 1, textHash := 0 } :
              Beam.LSP.Save.SaveArtifactsResult)
          else
            request.resolveResponse <| toJson (Beam.LSP.Save.SaveArtifactsCompletion.failure
              .internalError "completed handler failure")
        }}
        set { state with workspaces := state.workspaces.insert workspaceId {
          workspace with lean := { workspace.lean with session? := some current } } }
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      require "fixture did not intercept the save reply" (← intercepted.get)
      let some error := response.error? | throw <| IO.userError "injected save failure succeeded"
      let expected := if case == "remote-invalid-params" then "invalidParams"
        else if case == "remote-owner-loss" then "contentModified"
        else if case == "remote-worker-crashed" then "workerCrashed"
        else if case == "cancelled-handler-failure" || case == "cancelled-remote-owner-loss" ||
            case == "cancelled-remote-worker-crashed" || case == "remote-cancelled" then "requestCancelled"
        else "internalError"
      require "save reply preserves public error presentation" (error.code == expected)
      require "save failure preserves barrier progress" (response.fileProgress?.any (·.done))
      let settled := case == "handler-failure" || case == "cancelled-handler-failure"
      require "private preparation reply preserves the backend"
        ((← session server).epoch == original.epoch)
      require "private preparation reply preserves the accepted document"
        (DocumentState.basis (← doc server uri) == DocumentState.basis before)
      if workerCrash then
        let error? := (← doc server uri).workerError?
        require "private save records worker failure before cancellation presentation"
          (error?.map (·.code) == some "workerCrashed" &&
           error?.map (·.message) == some "worker crashed during private save completion")
      requireCheckpointUnchanged prior
      requirePrivateRetention saved (!settled)
      requireNoAdmissions server
      requireJsonBool "unrelated continuation survives private preparation reply" "success" true
        (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| IO.ofExcept pending.get
  finally
    server.close

/-- A real accepted trace reply followed by failed directory cleanup must not commit a save. -/
private def traceCleanupFailure (description : Beam.Runtime.Description)
    (root gate : System.FilePath) (cancelled : Bool) : IO Unit := do
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  let obstacle? ← IO.mkRef (none : Option System.FilePath)
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let prior ← snapshotCheckpoint saved
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let before ← doc server uri
    IO.FS.writeFile (gate / "enabled") ""
    let handleRef ← IO.mkRef (none : Option RequestHandle)
    let pending ← IO.asTask (prio := .dedicated) <|
      server.dispatchRequestWithHandle {
        payload := .close { path := "Main.lean", saveArtifacts? := some true }
        workspaceId? := some workspaceId
      } (fun active => handleRef.set (some active) *> pure true)
    try
      waitForGate gate
      let entered ← IO.ofExcept <| Json.parse (← IO.FS.readFile (gate / "entered"))
      let job : System.FilePath ← IO.ofExcept <| entered.getObjValAs? System.FilePath "job"
      let temporaryRoot ← IO.FS.realPath (gate / "helper-temporary")
      require "cleanup fault must stay in the fixture's temporary root"
        (job.fileName == some "job" &&
         (← IO.FS.realPath (job.parent.bind (·.parent) |>.getD ".")) == temporaryRoot)
      let obstacle := job / "cleanup-denied"
      obstacle?.set (some obstacle)
      IO.FS.createDir obstacle
      IO.FS.writeFile (obstacle / "owned") "fixture-owned cleanup obstacle\n"
      IO.setAccessRights obstacle {}
      if cancelled then
        let some active ← handleRef.get | throw <| IO.userError "missing cancellation handle"
        require "public cancellation was not accepted" (← active.cancel)
        require "cancellation completed before the trace producer settled"
          ((← Beam.waitTaskWithTimeout pending 100).isNone)
      let conflict ← call server (.syncFile { path := "Main.lean" })
      let some error := conflict.error? | throw <| IO.userError "trace helper lost close reservation"
      requireJsonString "trace helper retains close reservation" "reason" "documentClosing"
        (error.data?.getD Json.null)
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      IO.FS.writeFile (gate / "response.json") (toJson response).pretty
      let some error := response.error? | throw <| IO.userError "cleanup failure committed a save"
      require "cleanup failure survives cancellation" (error.code == "internalError")
      let info := error.data?.getD Json.null
      requireJsonString "cleanup classification" "reason" "helperCleanupFailed" info
      let cleanup ← requireObjVal "helper failure" "cleanup" info
      discard <| requireObjVal "directory failure" "temporaryDirectory" cleanup
      let outcome ← requireObjVal "helper failure" "operationOutcome" info
      requireJsonString "private trace completed" "status" "succeeded" outcome
      let receipt ← requireObjVal "helper failure" "operationResponse" info
      requireJsonBool "accepted helper acknowledgement retained" "ok" true receipt
      requireCheckpointUnchanged prior
      requirePrivateRetention saved true
      require "cleanup failure preserves the backend" ((← session server).epoch == original.epoch)
      let after ← doc server uri
      require "cleanup failure preserves the document and checkpoint association"
        (DocumentState.basis after == DocumentState.basis before &&
         after.checkpointedVersion? == before.checkpointedVersion?)
      requireNoAdmissions server
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| IO.ofExcept pending.get
  finally
    -- Restore only the obstacle inside the Python-owned temporary root, after helper teardown.
    try
      if let some obstacle ← obstacle?.get then
        IO.setAccessRights obstacle { user := { read := true, write := true, execution := true } }
    finally
      server.close

private def cancelledPreparation (description : Beam.Runtime.Description)
    (root gate : System.FilePath) (closeAfter : Bool) : IO Unit := do
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
    let other ← result (← call server (.syncFile { path := "Other.lean" }))
    let version : Nat ← IO.ofExcept <| other.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let hashes := (artifactPaths saved).map (·.addExtension "hash")
    for path in hashes do IO.FS.writeFile path s!"prior cached hash: {path}"
    let prior ← snapshotFiles ((artifactPaths saved) ++ hashes)
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let before ← doc server uri
    let cancellations ← IO.mkRef (0 : Nat)
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing cancellation fixture workspace"
      let current := { original with stdin := { original.stdin with putStr := fun text => do
        if text.contains "$/cancelRequest" then cancellations.modify (· + 1)
        original.stdin.putStr text
      }}
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    IO.FS.writeFile (gate / "enabled") ""
    let handleRef ← IO.mkRef (none : Option RequestHandle)
    let payload : RequestPayload := if closeAfter then .close { path := "Main.lean", saveArtifacts? := some true }
      else .saveOlean { path := "Main.lean" }
    let pending ← IO.asTask (prio := .dedicated) <|
      server.dispatchRequestWithHandle {
        payload, workspaceId? := some workspaceId, clientRequestId? := some "cancel-prepared"
      }
        (fun active => handleRef.set (some active) *> pure true)
    try
      let deadline := (← IO.monoMsNow) + 20000
      repeat
        if ← (gate / "entered.json").pathExists then break
        require "worker did not reach the post-serialization gate" ((← IO.monoMsNow) < deadline)
        IO.sleep 10
      let entered ← IO.ofExcept <| Json.parse (← IO.FS.readFile (gate / "entered.json"))
      requireJsonString "worker gate phase" "phase" "after-serialization" entered
      let params : Beam.LSP.Save.SaveArtifactsParams ←
        IO.ofExcept <| fromJson? (← requireObjVal "worker gate" "params" entered)
      let mut privatePaths := #[params.oleanFile, params.ileanFile, params.cFile]
      if let some modulePaths := params.moduleArtifacts? then
        privatePaths := privatePaths ++ #[modulePaths.oleanServerFile, modulePaths.oleanPrivateFile,
          modulePaths.irFile, modulePaths.irSigFile]
      if let some path := params.bcFile? then privatePaths := privatePaths.push path
      for path in privatePaths do
        require "real worker did not finish a private output before cancellation"
          ((← (System.FilePath.mk path).metadata).type == .file)
      let some active ← handleRef.get | throw <| IO.userError "missing public cancellation handle"
      require "public cancellation was not accepted" (← active.cancel)
      require "cancelled save completed before its producer settled"
        ((← Beam.waitTaskWithTimeout pending 100).isNone)
      requireJsonBool "sibling continuation progresses while cancelled producer is held" "success" true
        (← result (← call server (.runWith {
          path := "Other.lean", handle, text := "skip", linear? := some false
        })))
      if closeAfter then
        let conflict ← call server (.syncFile { path := "Main.lean" })
        let some error := conflict.error? | throw <| IO.userError "cancel released reservation early"
        requireJsonString "cancellation retains close reservation" "reason" "documentClosing"
          (error.data?.getD Json.null)
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      IO.FS.writeFile (gate / "response.json") (toJson response).pretty
      let some error := response.error? | throw <| IO.userError "cancelled preparation committed"
      require "preparation cancellation lost public precedence" (error.code == "requestCancelled")
      requireCheckpointUnchanged prior
      requirePrivateRetention saved false
      for path in privatePaths do
        require "private candidate has an indexable artifact extension" (path.endsWith ".candidate")
      require "caller cancellation reached the private worker" ((← cancellations.get) == 0)
      require "cancelled preparation replaced healthy backend" ((← session server).epoch == original.epoch)
      require "cancelled preparation changed accepted document"
        (DocumentState.basis (← doc server uri) == DocumentState.basis before)
      requireNoAdmissions server
      requireJsonBool "sibling continuation survives deferred cancellation" "success" true
        (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
      require "cancelled worker preparation launched the trace helper"
        (!(← (gate / "trace-entered").pathExists))
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| Beam.waitTaskWithTimeout pending 20000
  finally
    IO.FS.writeFile (gate / "release") ""
    server.close

private def uncertainWrite (description : Beam.Runtime.Description) (root gate : System.FilePath)
    (case : String) (closeAfter : Bool) : IO Unit := do
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let prior ← snapshotCheckpoint saved
    let original ← session server
    IO.FS.writeFile (gate / "enabled") ""
    let pending ← IO.asTask (prio := .dedicated) <|
      call server (if closeAfter then .close { path := "Main.lean", saveArtifacts? := some true }
        else .saveOlean { path := "Main.lean" })
    try
      waitForGate gate
      let method := if case == "uncertain-close" then "textDocument/didClose" else saveArtifactsMethod
      let delivered ← IO.mkRef false
      let requestWritten ← IO.mkRef false
      server.withState do
        let state ← get
        let some workspace := state.workspaces.get? workspaceId
          | throw <| IO.userError "missing fixture workspace"
        let some current := workspace.lean.session?
          | throw <| IO.userError "missing fixture backend"
        let current := { current with stdin := { current.stdin with
          putStr := fun text => do
            current.stdin.putStr text
            if text.contains method then
              requestWritten.set true
              if case != "uncertain-save-flush" then
                current.stdin.flush
                delivered.set true
                throw <| IO.userError "controlled failure after backend write"
          flush := do
            current.stdin.flush
            if case == "uncertain-save-flush" && (← requestWritten.get) then
              delivered.set true
              throw <| IO.userError "controlled failure after backend flush"
        }}
        set { state with workspaces := state.workspaces.insert workspaceId {
          workspace with lean := { workspace.lean with session? := some current } } }
      IO.FS.writeFile (gate / "release") ""
      let response ← IO.ofExcept pending.get
      require "fixture did not exercise backend write uncertainty" (← delivered.get)
      require "fixture did not reach the selected request" (← requestWritten.get)
      let some error := response.error? | throw <| IO.userError "uncertain write returned success"
      require "write error remains typed" (error.code == "internalError")
      if case == "uncertain-close" then
        let data := error.data?.getD Json.null
        requireFieldAbsent "uncertain delivery does not assert closed=false" "closed" data
        let savedJson ← requireObjVal "postcommit failure" "saved" data
        requireJsonInt "checkpoint remains committed" "version" 1 savedJson
        let saved : SaveOleanResult ← IO.ofExcept <| fromJson? savedJson
        requireCanonicalPresent saved
      else
        requireFieldAbsent "preparation write failure has no saved receipt" "saved"
          (error.data?.getD Json.null)
        requireCheckpointUnchanged prior
      match ← original.proc.observe with
      | some (.exited _) => pure ()
      | _ => throw <| IO.userError "uncertain backend effect was not settled"
      requireNoAdmissions server
      discard <| result (← call server (.syncFile { path := "Main.lean" }))
      require "recovery must use a different backend" ((← session server).epoch != original.epoch)
    finally
      IO.FS.writeFile (gate / "release") ""
      discard <| IO.ofExcept pending.get
  finally
    server.close

/-- Exercise owner replacement while private preparation awaits the trace helper. -/
def run (description : Beam.Runtime.Description) (root : System.FilePath)
    (case : String) : IO Unit := do
  let some gate ← IO.getEnv "BEAM_TEST_SAVE_GATE_DIR"
    | throw <| IO.userError "missing save gate directory"
  let gate := System.FilePath.mk gate
  if ["trace-cleanup-failure", "cancelled-trace-cleanup-failure"].contains case then
    traceCleanupFailure description root gate (case == "cancelled-trace-cleanup-failure")
    IO.println s!"save owner ({case}): passed"
    return
  if ["cancel-prepared-close", "cancel-prepared-save", "module-cancel-prepared-close",
      "module-cancel-prepared-save"].contains case then
    cancelledPreparation description root gate (case.endsWith "close")
    IO.println s!"save owner ({case}): passed"
    return
  let closeAfter := !case.startsWith "ordinary-"
  let case := if closeAfter then case else (case.drop "ordinary-".length).toString
  if ["remote-invalid-params", "remote-owner-loss", "remote-cancelled", "malformed-completion",
      "handler-failure", "cancelled-handler-failure", "cancelled-remote-owner-loss",
      "remote-worker-crashed", "cancelled-remote-worker-crashed"].contains case then
    completionReply description root gate case closeAfter
    IO.println s!"save owner ({case}): passed"
    return
  if case == "rejected-close" then
    rejectedClose description root
    IO.println "save owner (rejected-close): passed"
    return
  if case == "delayed-admission" then
    delayedAdmission description root gate
    IO.println "save owner (delayed-admission): passed"
    return
  if ["uncertain-close", "uncertain-save", "uncertain-save-flush"].contains case then
    uncertainWrite description root gate case closeAfter
    IO.println s!"save owner ({case}): passed"
    return
  let config := BrokerConfig.ofRuntime root description
  let first ← ServerRuntime.create config workspaceId
  let second? ← if case == "distinct-runtime" then
      some <$> ServerRuntime.create config workspaceId
    else pure none
  let uri := sessionUri (root / "Main.lean")
  try
    discard <| result (← call first (.syncFile { path := "Main.lean" }))
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call first (.saveOlean { path := "Main.lean" })))
    let prior ← snapshotCheckpoint saved
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
      requireCheckpointUnchanged prior
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
        requireFieldAbsent "precommit owner loss has no saved receipt" "saved" data
        requireFieldAbsent "owner loss does not claim closure outcome" "closed" data
        requireCheckpointUnchanged prior
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
