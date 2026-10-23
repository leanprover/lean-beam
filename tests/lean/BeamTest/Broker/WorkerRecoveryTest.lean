/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.Server
import BeamTest.Broker.JsonAssert

open Lean Beam.Broker BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.WorkerRecoveryTest

private def workspaceId : WorkspaceId := "worker-recovery-test"

private def call (server : ServerRuntime) (payload : RequestPayload) : IO Response :=
  server.dispatchRequest { payload, workspaceId? := some workspaceId }

private def result (response : Response) : IO Json := do
  require s!"fixture request failed: {(toJson response).compress}" response.ok
  pure <| response.result?.getD Json.null

private def session (server : ServerRuntime) : IO Session :=
  server.withState do
    let some workspace := (← get).workspaces.get? workspaceId
      | throw <| IO.userError "missing recovery workspace"
    let some session := workspace.lean.session?
      | throw <| IO.userError "missing recovery backend"
    pure session

private def doc (server : ServerRuntime) (uri : String) : IO DocState := do
  DocumentState.requireDocState (← session server).docs uri

private def waitUntil (label : String) (ready : IO Bool) : IO Unit := do
  let deadline := (← IO.monoMsNow) + 20000
  while !(← ready) do
    require s!"{label} did not reach its gate" ((← IO.monoMsNow) < deadline)
    IO.sleep 10

private inductive Recovery where
  | sync
  | update
  | refresh

private def runCase (description : Beam.Runtime.Description) (root : System.FilePath)
    (code : JsonRpc.ErrorCode) (cancelled : Bool) (recovery : Recovery) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "lakefile.toml") "name = \"Main\"\n[[lean_lib]]\nname = \"Main\"\n"
  IO.FS.writeFile (root / "Main.lean") "def mainValue : Nat := 42\n"
  IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    let main ← result (← call server (.syncFile { path := "Main.lean" }))
    let version : Nat ← IO.ofExcept <| main.getObjValAs? Nat "version"
    let other ← result (← call server (.syncFile { path := "Other.lean" }))
    let otherVersion : Nat ← IO.ofExcept <| other.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version := otherVersion, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let mainSeed ← result (← call server (.runAt {
      path := "Main.lean", version, line := 0, character := 0
      text := "def oldWorkerProbe : Nat := 7", storeHandle? := some true
    }))
    let mainHandle : Handle ← IO.ofExcept <| mainSeed.getObjValAs? Handle "handle"
    let paths := #[saved.olean, saved.ilean, saved.c, saved.trace].map System.FilePath.mk
    let checkpoint ← paths.mapM IO.FS.readBinFile
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let siblingUri := sessionUri (root / "Other.lean")
    let before ← doc server uri
    let siblingBefore ← doc server siblingUri
    let intercepted ← IO.mkRef false
    let closes ← IO.mkRef (0 : Nat)
    let opens ← IO.mkRef (0 : Nat)
    let dispatched ← IO.mkRef (0 : Nat)
    -- Inject one real typed response at the existing stream seam. The worker stays healthy,
    -- making an unintended second dispatch observable independently of upstream routing.
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing recovery workspace"
      let current := { original with stdin := { original.stdin with putStr := fun text => do
        if text.contains "textDocument/didClose" then closes.modify (· + 1)
        if text.contains "textDocument/didOpen" then opens.modify (· + 1)
        if text.contains runAtMethod then
          dispatched.modify (· + 1)
          unless ← intercepted.get do
            intercepted.set true
            let entries ← original.pending.snapshotEntries
            require "worker reply expects exactly one pending request" (entries.size == 1)
            let some (id, pending) := entries[0]?
              | throw <| IO.userError "missing intercepted worker request"
            discard <| original.pending.remove id
            if cancelled then
              let some _ ← ActiveRequestRegistry.markCancelled server.activeRequests
                  (some workspaceId) "worker-failure"
                | throw <| IO.userError "missing recovery caller identity"
              pure ()
            pending.resolveError code "controlled worker reply"
            return
        original.stdin.putStr text
      } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    let request : RequestPayload := .runAt {
      path := "Main.lean", version, line := 0, character := 0, text := "#check Nat"
    }
    let failed ← server.dispatchRequest {
      payload := request, workspaceId? := some workspaceId, clientRequestId? := some "worker-failure"
    }
    let some error := failed.error? | throw <| IO.userError "controlled failure succeeded"
    require "caller presentation retains cancellation policy"
      (error.code == if cancelled then "requestCancelled" else errorCodeName code)
    let workerFailure := code == .workerExited || code == .workerCrashed
    let observed ← doc server uri
    require "only worker errors mark the document" (observed.workerError?.isSome == workerFailure)
    require "observation retains exact document acceptance"
      (DocumentState.basis observed == DocumentState.basis before)
    if workerFailure then
      require "cancelled callers retain the original worker cause"
        (observed.workerError?.map (·.code) == some (errorCodeName code))
      let blocked ← call server request
      require "known failure returns without another backend dispatch"
        (blocked.error?.map (·.code) == some (errorCodeName code) && (← dispatched.get) == 1)
      let view ← result (← call server .openDocs)
      let files : Array Json ← IO.ofExcept <| (← IO.ofExcept <| view.getObjVal? "session").getObjValAs? _ "files"
      let some file := files.find? (fun file =>
          match file.getObjValAs? String "path" with | .ok "Main.lean" => true | _ => false)
        | throw <| IO.userError "failed document disappeared from open_docs"
      discard <| requireObjVal "failed document" "workerError" file
      requireFieldAbsent "failed document" "fileProgress" file
      requireJsonBool "failure retains checkpoint association" "checkpointed" true file
    let recoveryRequest : RequestPayload := match recovery with
      | .sync => .syncFile { path := "Main.lean" }
      | .update => .updateFile { path := "Main.lean" }
      | .refresh => .refreshFile { path := "Main.lean" }
    discard <| result (← call server recoveryRequest)
    let recovered ← doc server uri
    require "fresh synchronization recovers only an explicitly failed worker"
      ((DocumentState.basis recovered != DocumentState.basis before) == workerFailure)
    let expectedCheckpoint := match recovery with
      | .refresh => none
      | .sync | .update => before.checkpointedVersion?
    require "recovery retains same-source version and the command's checkpoint policy"
      (recovered.version == before.version && recovered.checkpointedVersion? == expectedCheckpoint)
    require "recovery clears the recorded failure" recovered.workerError?.isNone
    require "recovery uses one close/open pair"
      ((← closes.get) == (if workerFailure then 1 else 0) &&
       (← opens.get) == (if workerFailure then 1 else 0))
    require "recovery preserves sibling acceptance"
      (DocumentState.basis (← doc server siblingUri) == DocumentState.basis siblingBefore)
    require "recovery preserves the shared backend" ((← session server).epoch == original.epoch)
    require "recovery preserves checkpoint bytes" ((← paths.mapM IO.FS.readBinFile) == checkpoint)
    let oldHandle ← call server (.runWith { path := "Main.lean", handle := mainHandle, text := "#check Nat" })
    if workerFailure then
      require "recovery rejects the previous worker's handle at the same source version"
        (oldHandle.error?.map (·.code) == some "contentModified")
    else
      discard <| result oldHandle
    requireJsonBool "recovered worker accepts new requests" "success" true
      (← result (← call server request))
    requireJsonBool "sibling continuation survives recovery" "success" true
      (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
    server.withState do
      let some workspace := (← get).workspaces.get? workspaceId
        | throw <| IO.userError "missing recovery workspace"
      require "completed recovery leaked an admission" workspace.documents.entries.isEmpty
  finally
    server.close

private def runRealExit (description : Beam.Runtime.Description) (root : System.FilePath) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "Main.lean") "import Lean\n\ndef mainValue : Nat := 42\n"
  IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    let synced ← result (← call server (.syncFile { path := "Main.lean" }))
    let version : Nat ← IO.ofExcept <| synced.getObjValAs? Nat "version"
    let other ← result (← call server (.syncFile { path := "Other.lean" }))
    let otherVersion : Nat ← IO.ofExcept <| other.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version := otherVersion, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let siblingUri := sessionUri (root / "Other.lean")
    let before ← doc server uri
    let siblingBefore ← doc server siblingUri
    let failed ← call server (.runAt {
      path := "Main.lean", version, line := 2, character := 0
      text := "#eval (IO.Process.forceExit 3 : IO Unit)"
    })
    require "real worker exit returns its typed cause"
      (failed.error?.map (·.code) == some "workerCrashed")
    require "real worker failure is retained" (← doc server uri).workerError?.isSome
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let recovered ← doc server uri
    require "real recovery has a new acceptance at the same public version"
      (DocumentState.basis recovered != DocumentState.basis before && recovered.version == version)
    require "real recovery preserves the router process" ((← session server).epoch == original.epoch)
    require "real recovery preserves the sibling acceptance"
      (DocumentState.basis (← doc server siblingUri) == DocumentState.basis siblingBefore)
    requireJsonBool "new request reaches the restarted worker" "success" true
      (← result (← call server (.runAt {
        path := "Main.lean", version, line := 2, character := 0, text := "#check Nat"
      })))
    requireJsonBool "real exit preserves sibling continuation" "success" true
      (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
    IO.println "worker recovery: actual worker exit passed"
  finally
    server.close

/-- Recovery through update leaves completed-sync module history unchanged. Check that an edited
source still sends the ordinary didSave notification needed to invalidate open importers. -/
private def runImporterRecovery (description : Beam.Runtime.Description) (root : System.FilePath)
    (edited : Bool) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "lakefile.toml") "name = \"A\"\n[[lean_lib]]\nname = \"A\"\n"
  IO.FS.writeFile (root / "A.lean") "def aValue : Nat := 42\n"
  IO.FS.writeFile (root / "B.lean") "import A\nexample : True := by\n  trivial\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "A.lean" })))
    let sibling ← result (← call server (.syncFile { path := "B.lean" }))
    let siblingVersion : Nat ← IO.ofExcept <| sibling.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "B.lean", version := siblingVersion, line := 2, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let original ← session server
    let aUri := sessionUri (root / "A.lean")
    let bUri := sessionUri (root / "B.lean")
    let beforeA ← doc server aUri
    let beforeB ← doc server bUri
    let some history := original.moduleHistory.get? "A"
      | throw <| IO.userError "saved dependency has no module history"
    let failed ← call server (.runAt {
      path := "A.lean", version := saved.version, line := 0, character := 0
      text := "#eval (IO.Process.forceExit 3 : IO Unit)"
    })
    require "dependency worker exit is explicit"
      (failed.error?.map (·.code) == some "workerCrashed")
    let notifications ← IO.mkRef (#[] : Array String)
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing dependency-recovery workspace"
      let some current := workspace.lean.session?
        | throw <| IO.userError "missing dependency-recovery session"
      let current := { current with stdin := { current.stdin with putStr := fun text => do
          for method in #["textDocument/didClose", "textDocument/didOpen", "textDocument/didSave"] do
            if text.contains method then
              require "recovery notification names the dependency" (text.contains aUri)
              notifications.modify (·.push method)
          -- Forward the real notification. Lean registers its import graph asynchronously;
          -- diagnostics/barrier completion does not establish that registration has finished.
          -- This test checks Beam's notification contract, not native delivery timing.
          original.stdin.putStr text
        } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    if edited then
      IO.FS.writeFile (root / "A.lean") "def aValue : Nat := 43\n"
    discard <| result (← call server (.updateFile { path := "A.lean" }))
    let recovered ← doc server aUri
    require "dependency recovery accepts the source at the expected version"
      (recovered.version == beforeA.version + (if edited then 1 else 0) && recovered.workerError?.isNone)
    let some afterHistory := (← session server).moduleHistory.get? "A"
      | throw <| IO.userError "dependency update lost module history"
    require "update recovery does not mask missing native invalidation with sync history"
      (afterHistory.lastSyncEventSeq == history.lastSyncEventSeq &&
       afterHistory.lastTextChangeEventSeq == history.lastTextChangeEventSeq &&
       afterHistory.lastSaveEventSeq == history.lastSaveEventSeq)
    unless edited do
      discard <| result (← call server (.syncFile { path := "B.lean" }))
      requireJsonBool "unchanged-source recovery keeps the importer handle usable" "success" true
        (← result (← call server (.runWith { path := "B.lean", handle, text := "trivial" })))
    let expected := #["textDocument/didClose", "textDocument/didOpen"] ++
      (if edited then #["textDocument/didSave"] else #[])
    require "only edited recovery sends dependency invalidation, after reopening"
      ((← notifications.get) == expected)
    require "dependency invalidation never replaces the importer's worker basis"
      (DocumentState.basis (← doc server bUri) == DocumentState.basis beforeB)
    require "dependency recovery preserves the shared router" ((← session server).epoch == original.epoch)
  finally
    server.close

/-- A newly issued save has the same recovery semantics as its initial sync. The original
failed speculative request stays failed, and close-save reserves only the reopened document. -/
private def runSaveRecovery (description : Beam.Runtime.Description) (root : System.FilePath)
    (closeAfter edited : Bool) : IO Unit := do
  IO.FS.createDirAll root
  let source (value : Nat) := s!"import Lean\n\ndef mainValue : Nat := {value}\n"
  IO.FS.writeFile (root / "lakefile.toml") "name = \"Main\"\n[[lean_lib]]\nname = \"Main\"\n"
  IO.FS.writeFile (root / "Main.lean") (source 42)
  IO.FS.writeFile (root / "Other.lean") "example : True := by\n  trivial\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  try
    let prior : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let paths := #[prior.olean, prior.ilean, prior.c, prior.trace].map System.FilePath.mk
    let checkpoint ← paths.mapM IO.FS.readBinFile
    let sibling ← result (← call server (.syncFile { path := "Other.lean" }))
    let siblingVersion : Nat ← IO.ofExcept <| sibling.getObjValAs? Nat "version"
    let seed ← result (← call server (.runAt {
      path := "Other.lean", version := siblingVersion, line := 1, character := 2
      text := "skip", storeHandle? := some true
    }))
    let handle : Handle ← IO.ofExcept <| seed.getObjValAs? Handle "handle"
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let siblingUri := sessionUri (root / "Other.lean")
    let before ← doc server uri
    let siblingBefore ← doc server siblingUri
    let failed ← call server (.runAt {
      path := "Main.lean", version := prior.version, line := 2, character := 0
      text := "#eval (IO.Process.forceExit 3 : IO Unit)"
    })
    require "save recovery starts from an observed worker crash"
      (failed.error?.map (·.code) == some "workerCrashed" && (← doc server uri).workerError?.isSome)
    require "the failed speculative request leaves the old checkpoint intact"
      ((← paths.mapM IO.FS.readBinFile) == checkpoint)
    let events ← IO.mkRef (#[] : Array String)
    let replayed ← IO.mkRef false
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing save-recovery workspace"
      let some current := workspace.lean.session?
        | throw <| IO.userError "missing save-recovery session"
      let current := { current with stdin := { current.stdin with putStr := fun text => do
        for (method, event) in [("textDocument/didClose", "close"), ("textDocument/didOpen", "open"),
            ("textDocument/didSave", "invalidate"), (diagnosticsBarrierMethod, "barrier"),
            (saveArtifactsMethod, "prepare")] do
          if text.contains method then events.modify (·.push event)
        if text.contains runAtMethod then replayed.set true
        original.stdin.putStr text
      } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    let text := source (if edited then 43 else 42)
    if edited then IO.FS.writeFile (root / "Main.lean") text
    let response ← result (← call server <| if closeAfter then
        .close { path := "Main.lean", saveArtifacts? := some true }
      else .saveOlean { path := "Main.lean" })
    let savedJson ← if closeAfter then do
        requireJsonBool "recovered close-save closes the saved document" "closed" true response
        IO.ofExcept <| response.getObjVal? "saved"
      else pure response
    let completed : SaveOleanResult ← IO.ofExcept <| fromJson? savedJson
    let version := before.version + (if edited then 1 else 0)
    require "recovered save checkpoints the newly synchronized source"
      (completed.version == version && completed.sourceHash == (Lake.Hash.ofText text).toString)
    for path in #[completed.olean, completed.ilean, completed.c, completed.trace] do
      require "recovered save publishes its complete artifact family"
        (!(← IO.FS.readBinFile path).isEmpty)
    let observed ← events.get
    let expectedEvents := if edited then #["close", "open", "invalidate", "barrier", "prepare"]
      else #["close", "open", "barrier", "prepare"]
    require s!"recovery must precede save readiness and private production: {observed}"
      (observed.extract 0 expectedEvents.size == expectedEvents)
    require "fresh save only reopens once before optional close-after-save"
      ((observed.filter (· == "open")).size == 1 &&
       (observed.filter (· == "close")).size == if closeAfter then 2 else 1)
    require "fresh save never replays the failed speculative request" (!(← replayed.get))
    if closeAfter then
      require "close-save removes the recovered document after publication" (!(← session server).docs.contains uri)
    else
      let recovered ← doc server uri
      require "save retains the new healthy acceptance and checkpoint"
        (recovered.workerError?.isNone && recovered.version == version &&
         recovered.checkpointedVersion? == some version &&
         DocumentState.basis recovered != DocumentState.basis before)
    require "save recovery preserves sibling acceptance and shared backend"
      (DocumentState.basis (← doc server siblingUri) == DocumentState.basis siblingBefore &&
       (← session server).epoch == original.epoch)
    requireJsonBool "sibling handle survives save recovery" "success" true
      (← result (← call server (.runWith { path := "Other.lean", handle, text := "trivial" })))
    server.withState do
      let some workspace := (← get).workspaces.get? workspaceId
        | throw <| IO.userError "save-recovery workspace disappeared"
      require "save recovery releases its admission/reservation" workspace.documents.entries.isEmpty
    IO.println s!"worker recovery: fresh save closeAfter={closeAfter} edited={edited} passed"
  finally
    server.close

private inductive Replacement where
  | reopen
  | workspace
  | change

private def runLateError (description : Beam.Runtime.Description) (root : System.FilePath)
    (replacement : Replacement) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "Main.lean") "def mainValue : Nat := 42\n"
  let config := BrokerConfig.ofRuntime root description
  let server ← ServerRuntime.create config workspaceId
  let held ← IO.mkRef (none : Option PendingRequest)
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let original ← session server
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing late-error workspace"
      let current := { original with stdin := { original.stdin with putStr := fun text => do
        if text.contains runAtMethod && (← held.get).isNone then
          let entries ← original.pending.snapshotEntries
          require "late-error fixture expects one pending request" (entries.size == 1)
          let some (id, pending) := entries[0]?
            | throw <| IO.userError "missing held worker request"
          discard <| original.pending.remove id
          held.set (some pending)
        else original.stdin.putStr text
      } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    let request ← IO.asTask (prio := .dedicated) <| call server (.runAt {
      path := "Main.lean", version := 1, line := 0, character := 0, text := "#check Nat"
    })
    try
      waitUntil "late-error request" ((·.isSome) <$> held.get)
      let some pending ← held.get | throw <| IO.userError "missing gated worker request"
      match replacement with
      | .workspace =>
        match ← server.initWorkspaceWithConfig workspaceId config (some .reset) with
        | .ok _ => pure ()
        | .error failure => throw <| IO.userError failure.error.message
        discard <| result (← call server (.syncFile { path := "Main.lean" }))
      | .reopen =>
        discard <| result (← call server (.refreshFile { path := "Main.lean" }))
      | .change =>
        -- Simulate a client saving new source while an older worker reply is withheld.
        IO.FS.writeFile (root / "Main.lean") "def mainValue : Nat := 43\n"
        discard <| result (← call server (.updateFile { path := "Main.lean" }))
      let uri := sessionUri (root / "Main.lean")
      let replacement ← doc server uri
      pending.resolveError .workerCrashed "late error from original worker"
      let response ← IO.ofExcept request.get
      require "late worker error still reaches its original caller"
        (response.error?.map (·.code) == some "workerCrashed")
      let after ← doc server uri
      require "late error cannot invalidate a replacement document or workspace"
        (after.workerError?.isNone && DocumentState.basis after == DocumentState.basis replacement)
      requireJsonBool "replacement remains usable after a late error" "success" true
        (← result (← call server (.runAt {
          path := "Main.lean", version := after.version, line := 0, character := 0, text := "#check Nat"
        })))
    finally
      if let some pending ← held.get then
        pending.resolveError .workerCrashed "release late-error fixture"
      discard <| IO.ofExcept request.get
  finally
    server.close

/-- Recording one conclusive error does not fabricate replies for other in-flight requests.
The controlled router releases the second reply on close, as an older watchdog may require. -/
private def runQueuedReply (description : Beam.Runtime.Description) (root : System.FilePath) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "Main.lean") "def mainValue : Nat := 42\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  let held ← IO.mkRef (#[] : Array PendingRequest)
  let tasks ← IO.mkRef (#[] : Array (Task (Except IO.Error Response)))
  try
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let original ← session server
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing queued-reply workspace"
      let current := { original with stdin := { original.stdin with putStr := fun text => do
        if text.contains runAtMethod && (← held.get).size < 2 then
          let entries ← original.pending.snapshotEntries
          require "queued-reply fixture expects one new pending request" (entries.size == 1)
          let some (id, pending) := entries[0]?
            | throw <| IO.userError "missing queued worker request"
          discard <| original.pending.remove id
          held.modify (·.push pending)
          return
        if text.contains "textDocument/didClose" then
          if let some pending := (← held.get)[1]? then
            pending.resolveError .contentModified "controlled old router reply on close"
        original.stdin.putStr text
      } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    let payload : RequestPayload := .runAt {
      path := "Main.lean", version := 1, line := 0, character := 0, text := "#check Nat"
    }
    let first ← IO.asTask (prio := .dedicated) <| call server payload
    tasks.modify (·.push first)
    waitUntil "first queued request" ((fun entries => entries.size == 1) <$> held.get)
    let second ← IO.asTask (prio := .dedicated) <| call server payload
    tasks.modify (·.push second)
    waitUntil "second queued request" ((fun entries => entries.size == 2) <$> held.get)
    let some pending := (← held.get)[0]? | throw <| IO.userError "missing first queued reply"
    pending.resolveError .workerCrashed "controlled first worker error"
    let failed ← IO.ofExcept first.get
    require "first queued error reaches its caller"
      (failed.error?.map (·.code) == some "workerCrashed")
    let beforeRecovery ← Beam.waitTaskWithTimeout second 25
    -- This is an observation of the current limitation, not a requirement that future
    -- implementations leave it pending: only the controlled router has withheld a reply.
    IO.println s!"worker recovery: second queued reply pending before recovery={beforeRecovery.isNone}"
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    let released ← IO.ofExcept second.get
    require "queued request completes when its router supplies the close reply" released.error?.isSome
    require "old queued reply does not invalidate the reopened document"
      (← doc server (sessionUri (root / "Main.lean"))).workerError?.isNone
  finally
    for pending in ← held.get do
      pending.resolveError .requestCancelled "release queued-reply fixture"
    for task in ← tasks.get do discard <| IO.ofExcept task.get
    server.close

/-- An older router can withhold the close-save barrier while another request reports a crash.
Recovery must not steal the closing admission, including after cancellation was acknowledged. -/
private def runClosingReply (description : Beam.Runtime.Description) (root : System.FilePath) : IO Unit := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "lakefile.toml") "name = \"Main\"\n[[lean_lib]]\nname = \"Main\"\n"
  IO.FS.writeFile (root / "Main.lean") "def mainValue : Nat := 42\n"
  let server ← ServerRuntime.create (BrokerConfig.ofRuntime root description) workspaceId
  let held ← IO.mkRef (#[] : Array PendingRequest)
  let tasks ← IO.mkRef (#[] : Array (Task (Except IO.Error Response)))
  try
    let saved : SaveOleanResult ← IO.ofExcept <| fromJson?
      (← result (← call server (.saveOlean { path := "Main.lean" })))
    let paths := #[saved.olean, saved.ilean, saved.c, saved.trace].map System.FilePath.mk
    let checkpoint ← paths.mapM IO.FS.readBinFile
    let original ← session server
    let uri := sessionUri (root / "Main.lean")
    let closes ← IO.mkRef (0 : Nat)
    server.withState do
      let state ← get
      let some workspace := state.workspaces.get? workspaceId
        | throw <| IO.userError "missing closing-reply workspace"
      let current := { original with stdin := { original.stdin with putStr := fun text => do
        if text.contains "textDocument/didClose" then closes.modify (· + 1)
        let count := (← held.get).size
        if (count == 0 && text.contains runAtMethod) ||
            (count == 1 && text.contains diagnosticsBarrierMethod) then
          let entries ← original.pending.snapshotEntries
          require "closing-reply gate expects one newly pending request" (entries.size == 1)
          let some (id, pending) := entries[0]? | throw <| IO.userError "missing closing-reply request"
          discard <| original.pending.remove id
          held.modify (·.push pending)
          return
        original.stdin.putStr text
      } }
      set { state with workspaces := state.workspaces.insert workspaceId {
        workspace with lean := { workspace.lean with session? := some current } } }
    let ordinary ← IO.asTask (prio := .dedicated) <| call server (.runAt {
      path := "Main.lean", version := saved.version, line := 0, character := 0, text := "#check Nat"
    })
    tasks.modify (·.push ordinary)
    waitUntil "ordinary request before close-save" ((fun entries => entries.size == 1) <$> held.get)
    let closing ← IO.asTask (prio := .dedicated) <| server.dispatchRequest {
      payload := .close { path := "Main.lean", saveArtifacts? := some true }
      workspaceId? := some workspaceId, clientRequestId? := some "withheld-close-save"
    }
    tasks.modify (·.push closing)
    waitUntil "reserved close-save barrier" ((fun entries => entries.size == 2) <$> held.get)
    let some first := (← held.get)[0]? | throw <| IO.userError "missing ordinary crash reply"
    first.resolveError .workerCrashed "original worker crash while close-save waits"
    let failed ← IO.ofExcept ordinary.get
    require "ordinary request records the conclusive crash"
      (failed.error?.map (·.code) == some "workerCrashed" && (← doc server uri).workerError?.isSome)
    let cancelled ← result (← call server (.cancel "withheld-close-save"))
    requireJsonBool "close-save cancellation was acknowledged" "cancelled" true cancelled
    for (label, payload) in [("update", RequestPayload.updateFile { path := "Main.lean" }),
        ("sync", .syncFile { path := "Main.lean" }),
        ("refresh", .refreshFile { path := "Main.lean" }),
        ("close", .close { path := "Main.lean" }),
        ("save", .saveOlean { path := "Main.lean" })] do
      let rejected ← call server payload
      require s!"{label} cannot bypass the close-save owner"
        (rejected.error?.map (·.code) == some "contentModified")
      requireJsonString "retained closing admission" "reason" "documentClosing"
        ((rejected.error?.bind (·.data?)).getD Json.null)
    server.withState do
      let some workspace := (← get).workspaces.get? workspaceId
        | throw <| IO.userError "closing-reply workspace disappeared"
      require "worker failure/cancellation retains the closing owner" (workspace.documents.isClosing uri)
    require "blocked recovery never closes the retained worker" ((← closes.get) == 0)
    require "blocked close-save preserves the prior checkpoint" ((← paths.mapM IO.FS.readBinFile) == checkpoint)
    require "soft cancellation does not fabricate a withheld producer reply"
      (← Beam.waitTaskWithTimeout closing 25).isNone
    let some barrier := (← held.get)[1]? | throw <| IO.userError "missing withheld barrier"
    barrier.resolveError .workerCrashed "later controlled close-save reply"
    let completed ← IO.ofExcept closing.get
    require "cancelled closing owner returns after its reply settles"
      (completed.error?.map (·.code) == some "requestCancelled")
    require "the first recorded worker cause survives the closing reply"
      ((← doc server uri).workerError?.map (·.message) == some "original worker crash while close-save waits")
    discard <| result (← call server (.syncFile { path := "Main.lean" }))
    require "document recovery resumes only after closing ownership is released"
      ((← closes.get) == 1 && (← doc server uri).workerError?.isNone)
    IO.println "worker recovery trace: withheld close-save owns document after crash/cancel; recovery resumes after reply"
  finally
    for pending in ← held.get do
      pending.resolveError .requestCancelled "release closing-reply fixture"
    for task in ← tasks.get do discard <| IO.ofExcept task.get
    server.close

def run (description : Beam.Runtime.Description) (root : System.FilePath) : IO Unit := do
  for (name, code, cancelled, recovery) in [
      ("exited", JsonRpc.ErrorCode.workerExited, false, Recovery.sync),
      ("crashed", .workerCrashed, false, .update),
      ("cancelled", .workerCrashed, true, .sync),
      ("refresh-failed", .workerCrashed, false, .refresh),
      ("ordinary-error", .contentModified, false, .sync)] do
    runCase description (root / name) code cancelled recovery
    IO.println s!"worker recovery: {name} passed"
  runRealExit description (root / "real-exit")
  runImporterRecovery description (root / "edited-importer") true
  IO.println "worker recovery: edited-source update invalidates its importer passed"
  runImporterRecovery description (root / "unchanged-importer") false
  IO.println "worker recovery: unchanged-source update preserves its importer passed"
  runLateError description (root / "late-document") .reopen
  IO.println "worker recovery: late error after document reopening passed"
  runLateError description (root / "late-workspace") .workspace
  IO.println "worker recovery: late error after workspace replacement passed"
  runLateError description (root / "late-change") .change
  IO.println "worker recovery: late error after ordinary didChange passed"
  runQueuedReply description (root / "queued-reply")
  IO.println "worker recovery: withheld second reply released during recovery passed"
  runClosingReply description (root / "closing-reply")
  for closeAfter in [false, true] do
    for edited in [false, true] do
      runSaveRecovery description (root / s!"save-{closeAfter}-{edited}") closeAfter edited

end BeamTest.Broker.WorkerRecoveryTest
