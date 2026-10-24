/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Beam.Broker.Server
import BeamTest.Broker.DocumentFixture
import BeamTest.Broker.JsonAssert

open Lean Lean.Lsp System Beam.Broker BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.PublicationClaimTest

private def source := "def publicationValue : Nat := 7\n"

private def awaitTask (label : String) (task : Task (Except IO.Error α))
    (unblock : IO Unit := pure ()) : IO α := do
  match ← Beam.waitTaskWithTimeout task 5000 with
  | some (.ok value) => pure value
  | some (.error error) => throw error
  | none =>
    unblock
    discard <| Beam.waitTaskWithTimeout task 5000
    throw <| IO.userError s!"{label}: task did not finish"

private def bounded (label : String) (action : IO α) (unblock : IO Unit) : IO α := do
  awaitTask label (← IO.asTask (prio := .dedicated) action) unblock

private def awaitSignal (label : String) (signal : IO.Promise Unit)
    (unblock : IO Unit) : IO Unit := do
  let some (some ()) ← Beam.waitTaskWithTimeout signal.result? 5000
    | unblock *> throw (IO.userError s!"{label}: signal did not arrive")

/-- A controlled backend with immediate typed replies; artifact publication uses real files. -/
private def installSession (server : ServerRuntime) (id : WorkspaceId) (root : FilePath) : IO Session := do
  IO.FS.createDirAll root
  IO.FS.writeFile (root / "Main.lean") source
  IO.FS.writeFile (root / "transport") ""
  let handle ← IO.FS.Handle.mk (root / "transport") .readWrite
  let stream := IO.FS.Stream.ofHandle handle
  let capture ← startBackendStderrCapture (← IO.FS.Handle.mk (root / "transport") .read)
  let pending ← PendingRequestStore.create
  let exitCode ← IO.mkRef (none : Option UInt32)
  let proc ← BackendProcess.create 0 exitCode.get (exitCode.set (some 0))
  let stdin := { stream with flush := pure (), putStr := fun frame => do
    let [_, body] := frame.splitOn "\r\n\r\n"
      | throw <| IO.userError "publication fixture expected one complete LSP frame"
    let message ← IO.ofExcept <| Json.parse body
    let method ← IO.ofExcept <| message.getObjValAs? String "method"
    if method == "shutdown" then exitCode.set (some 0)
    if let .ok requestId := message.getObjValAs? JsonRpc.RequestID "id" then
      let some request ← PendingRequestStore.remove pending requestId
        | if method == importBasisMethod then return
          throw <| IO.userError "publication fixture request was not registered"
      let result ← if method == diagnosticsBarrierMethod then do
        let params ← IO.ofExcept <| message.getObjValAs? WaitForDiagnosticsParams "params"
        request.progressRef.set (some { updates := 1, done := true })
        pure <| toJson ({
          version := params.version, hasFatalSnapshot := false,
          saveReadiness := { version := params.version, textHash := hash source }
          : DiagnosticsBarrierResult })
      else if method == importBasisMethod then
        pure <| toJson ({ status := .current } : Beam.LSP.ImportBasis.Result)
      else if method == "shutdown" then pure Json.null
      else throw <| IO.userError s!"unexpected publication fixture request: {method}"
      request.resolveResponse result
  }
  let uri := sessionUri (← IO.FS.realPath (root / "Main.lean"))
  let doc ← DocumentFixture.accepted (DocumentState.FileSnapshot.ofText source default)
  server.withState do
    let state ← get
    let some workspace := state.workspaces.get? id
      | throw <| IO.userError "publication fixture workspace missing"
    let session : Session := {
      workspaceId := id, workspaceGeneration := workspace.generation, root, epoch := 1,
      sessionToken := s!"publication-{id}", proc, stdin, stdout := stream, stderrCapture := capture,
      pending, docs := ({} : Std.TreeMap String DocState).insert uri doc
    }
    set { state with workspaces := state.workspaces.insert id {
      workspace with nextFileSnapshotSeq := 2, lean := { nextEpoch := 2, session? := some session } } }
    pure session

private def withFixture (action : ServerRuntime → Session → Session → IO Unit) : IO Unit :=
  IO.FS.withTempDir fun root => do
    let server ← ServerRuntime.create { root := root / "a" } "a"
    try
      let .ok _ ← server.initWorkspaceWithConfig "b" { root := root / "b" }
        | throw <| IO.userError "publication fixture could not initialize the unrelated workspace"
      action server (← installSession server "a" (root / "a"))
        (← installSession server "b" (root / "b"))
    finally server.close

private def document (session : Session) : IO (DocumentUri × DocumentBasis) := do
  let some (uri, doc) := session.docs.toList.head?
    | throw <| IO.userError "publication fixture has no accepted document"
  pure (uri, DocumentState.basis doc)

private def outputPaths (outputs : LeanSaveOutputs) : Array FilePath :=
  #[outputs.oleanPath, outputs.ileanPath, outputs.cPath, outputs.tracePath]

private def writeOutputs (outputs canonical : LeanSaveOutputs) (tag : String) : IO Unit := do
  for (path, target) in (outputPaths outputs).zip (outputPaths canonical) do
    IO.FS.writeFile path (tag ++ target.fileName.getD "")

private def readOutputs (outputs : LeanSaveOutputs) : IO (Array String) :=
  (outputPaths outputs).mapM IO.FS.readFile

private def hasFailureCode (outcome : Except ResponseFailure α) (code : String) : Bool :=
  match outcome with
  | .error failure => failure.error.code == code
  | .ok _ => false

private inductive Transition where
  | reset | drop | updateFile | refresh | closeFile | exited | closeRuntime
  deriving BEq, Repr

private def transition (kind : Transition) (server : ServerRuntime) (owner : Session) : IO Unit := do
  match kind with
  | .reset =>
    let .ok _ ← server.initWorkspaceWithConfig "a" { root := owner.root } (some .reset)
      | throw <| IO.userError "publication fixture reset failed"
  | .drop =>
    let .ok _ ← server.dropWorkspace "a"
      | throw <| IO.userError "publication fixture drop failed"
  | .updateFile =>
    IO.FS.writeFile (owner.root / "Main.lean") (source ++ "def publicationUpdate := 8\n")
    let response ← server.dispatchRequest {
      workspaceId? := some "a",
      payload := .updateFile { path := "Main.lean" } }
    require "ordinary update did not resume after publication" response.ok
  | .refresh | .closeFile =>
    let payload := if kind == .refresh then
      RequestPayload.refreshFile { path := "Main.lean" }
    else .close { path := "Main.lean" }
    let response ← server.dispatchRequest { workspaceId? := some "a", payload }
    require "publication fixture document transition failed" response.ok
  | .exited =>
    let .exited _ ← owner.proc.terminate 0
      | throw <| IO.userError "controlled backend did not reach its terminal observation"
    let response ← server.dispatchRequest {
      workspaceId? := some "a",
      payload := .close { path := "Main.lean" } }
    require "terminal backend admission did not resume after publication" response.ok
  | .closeRuntime => server.close

private def checkSchedule (kind : Transition) (failPromotion : Bool := false) : IO Unit :=
  withFixture fun server owner _ => do
    let (uri, basis) ← document owner
    let outputs : LeanSaveOutputs := {
      oleanPath := owner.root / "Main.olean", ileanPath := owner.root / "Main.ilean",
      cPath := owner.root / "Main.c", tracePath := owner.root / "Main.trace"
    }
    writeOutputs outputs outputs "old:"
    for path in #[outputs.oleanPath, outputs.ileanPath, outputs.cPath] do
      IO.FS.writeFile (path.addExtension "hash") "old hash"
    let plan ← Publication.create outputs
    writeOutputs plan.outputs outputs "new:"
    plan.ready
    let .ok active ← ActiveRequestRegistry.register server.activeRequests (some "a") (some "publisher")
      | throw <| IO.userError "publication fixture could not register its publisher"
    let entered ← IO.Promise.new
    let release ← IO.Promise.new
    let competingEntered ← IO.Promise.new
    let competing? ← IO.mkRef (none : Option (Task (Except IO.Error Unit)))
    let publicationSettled ← IO.mkRef false
    let rename := fun sourcePath targetPath => do
      if sourcePath == plan.outputs.ileanPath then
        require "promotion gate preceded the first real artifact replacement"
          ((← IO.FS.readFile outputs.oleanPath) == "new:Main.olean" &&
            !(← plan.outputs.oleanPath.pathExists))
        entered.resolve ()
        discard <| IO.wait release.result?
        if failPromotion then throw <| IO.Error.hardwareFault 5 "controlled promotion failure"
      IO.FS.rename sourcePath targetPath
    let publisher ← IO.asTask (prio := .dedicated) do
      try
        Internal.withDocumentPublication server owner uri basis (some active.cancelRef)
          (do
            try Publication.Internal.promote plan rename IO.FS.removeFile
            finally publicationSettled.set true)
      finally ActiveRequestRegistry.unregister server.activeRequests (some active)
    try
      awaitSignal "real artifact rename" entered (release.resolve ())
      let stats ← bounded "stats during promotion" (server.dispatchRequest Request.stats) (release.resolve ())
      require "stats could not read during promotion" stats.ok
      let synced ← bounded "unrelated sync during promotion" (server.dispatchRequest {
        workspaceId? := some "b", payload := .syncFile { path := "Main.lean" }
      }) (release.resolve ())
      require "unrelated workspace sync did not progress during promotion" synced.ok
      let cancelled ← bounded "cancel during promotion" (server.dispatchRequest {
        Request.cancel "publisher" with workspaceId? := some "a"
      }) (release.resolve ())
      require "cancel could not reach the claimed publisher"
        (cancelled.ok && (← active.cancelRef.get))
      let unchanged ← server.withState do
        let some workspace := (← get).workspaces.get? "a"
          | throw <| IO.userError "publication owner disappeared before its transition"
        require "ordinary publication acquired a closing reservation" (!workspace.documents.isClosing uri)
        pure <| workspace.lean.session?.any (·.sessionToken == owner.sessionToken)
      require "publication owner changed before the competing transition" unchanged
      let competing ← IO.asTask (prio := .dedicated) do
        competingEntered.resolve ()
        transition kind server owner
        require "same-workspace transition completed before the publication action settled"
          (← publicationSettled.get)
      competing?.set (some competing)
      awaitSignal "competing transition" competingEntered (release.resolve ())
      if kind == .closeRuntime then
        let deadline := (← IO.monoMsNow) + 5000
        let mut closed := false
        repeat
          match ← ActiveRequestRegistry.register server.activeRequests none none with
          | .error failure =>
            require "runtime closure rejected admission with the wrong failure"
              (failure.code == .requestCancelled)
            closed := true
            break
          | .ok request => ActiveRequestRegistry.unregister server.activeRequests (some request)
          if (← IO.monoMsNow) >= deadline then break
          IO.sleep 1
        require "runtime close did not close admission while publication was held" closed
      let current ← bounded "owner read while lifecycle waits" (server.withState do
        pure <| ((← get).workspaces.get? "a").bind (·.lean.session?)
      ) (release.resolve ())
      require "same-workspace transition detached or replaced a claimed owner"
        (current.any fun session => session.sessionToken == owner.sessionToken &&
          DocumentState.matchBasis session.docs uri basis == .current)
      let premature ← Beam.waitTaskWithTimeout competing 100
      require "same-workspace transition finished while filesystem publication was held" premature.isNone
      release.resolve ()
      let outcome ← Beam.waitTaskWithTimeout publisher 5000
      if failPromotion then
        match outcome with
        | some (.error (.hardwareFault 5 _)) => pure ()
        | _ => throw <| IO.userError "publication exception lost its typed failure"
      else
        match outcome with
        | some (.ok (.ok ())) => pure ()
        | _ => throw <| IO.userError "post-claim cancellation revoked publication"
      awaitTask "ordered competing transition" competing
      if failPromotion then
        require "failed publication did not restore its already replaced artifact"
          ((← IO.FS.readFile outputs.oleanPath) == "old:Main.olean")
        require "failed publication retained its trace" (!(← outputs.tracePath.pathExists))
      else
        require "publication did not commit its complete real output family"
          ((← readOutputs outputs) == (outputPaths outputs).map (fun path => "new:" ++ path.fileName.getD ""))
      let ran ← IO.mkRef false
      let stale ← Internal.withDocumentPublication server owner uri basis none (ran.set true)
      let expectedCode := if kind == .updateFile || kind == .refresh || kind == .closeFile then
        "contentModified" else "workerExited"
      require "an old owner/basis published after its ordered transition"
        (hasFailureCode stale expectedCode && !(← ran.get))
    finally
      release.resolve ()
      discard <| Beam.waitTaskWithTimeout publisher 5000
      if let some competing ← competing?.get then
        discard <| Beam.waitTaskWithTimeout competing 5000
      ActiveRequestRegistry.unregister server.activeRequests (some active)
      plan.dispose true

private def checkBeforeClaim : IO Unit := withFixture fun server owner _ => do
  let (uri, basis) ← document owner
  let ran ← IO.mkRef false
  let cancelled ← IO.mkRef true
  let rejected ← Internal.withDocumentPublication server owner uri basis (some cancelled) (ran.set true)
  require "pre-claim cancellation entered filesystem promotion"
    (hasFailureCode rejected "requestCancelled" && !(← ran.get))
  let refreshed ← server.dispatchRequest {
    workspaceId? := some "a",
    payload := .refreshFile { path := "Main.lean" } }
  require "pre-claim fixture could not reopen its document" refreshed.ok
  let stale ← Internal.withDocumentPublication server owner uri basis none (ran.set true)
  require "same-version reopened basis entered filesystem promotion"
    (hasFailureCode stale "contentModified" && !(← ran.get))

private def checkClosingReservation : IO Unit := withFixture fun server owner _ => do
  let (uri, basis) ← document owner
  let permit ← server.withState do
    let state ← get
    let some workspace := state.workspaces.get? "a"
      | throw <| IO.userError "closing publication fixture workspace missing"
    let .ok (documents, permit) := workspace.documents.admit uri
      | throw <| IO.userError "closing publication fixture could not admit its owner"
    let .ok documents := documents.reserve permit
      | throw <| IO.userError "closing publication fixture could not reserve its owner"
    set { state with workspaces := state.workspaces.insert "a" { workspace with documents } }
    pure permit
  let outcome ← Internal.withDocumentPublication server owner uri basis none do
    server.withState do
      let some workspace := (← get).workspaces.get? "a"
        | throw <| IO.userError "closing publication fixture workspace missing"
      require "publication lost close-save's existing reservation" (workspace.documents.isClosing uri)
  require "reserved publication failed" outcome.isOk
  let conflicting ← server.dispatchRequest {
    workspaceId? := some "a",
    payload := .close { path := "Main.lean" } }
  require "publication release prematurely released close-save's reservation"
    (conflicting.error?.any (·.code == "contentModified"))
  server.withState do
    let state ← get
    let some workspace := state.workspaces.get? "a"
      | throw <| IO.userError "closing publication fixture workspace missing"
    set { state with workspaces := state.workspaces.insert "a" {
      workspace with documents := workspace.documents.release permit } }

private def publishedEvent? (server : ServerRuntime) : IO (Option Nat × Nat) :=
  server.withState do
    let some session := ((← get).workspaces.get? "a").bind (·.lean.session?)
      | throw <| IO.userError "publication record fixture session missing"
    pure (session.publishedModules.get? "Main", session.nextEventSeq)

/-- The import basis check of later saves sees every promotion, even of a document closed after it. -/
private def checkPublicationRecord : IO Unit := withFixture fun server owner _ => do
  let (uri, basis) ← document owner
  let cancelled ← IO.mkRef true
  discard <| Internal.withDocumentPublication server owner uri basis (some cancelled) (pure ())
    (module? := some "Main")
  require "a refused claim entered the publication record" ((← publishedEvent? server).1.isNone)
  let failed ← (Internal.withDocumentPublication server owner uri basis none
    (throw (IO.userError "promotion failed") : IO Unit) (module? := some "Main")).toBaseIO
  require "failing promotion fixture did not fail" (failed matches .error _)
  let (some first, _) ← publishedEvent? server
    | throw <| IO.userError "a failed promotion was not recorded"
  let outcome ← Internal.withDocumentPublication server owner uri basis none (pure ())
    (module? := some "Main")
  require "publication record fixture failed" outcome.isOk
  let closed ← server.dispatchRequest {
    workspaceId? := some "a",
    payload := .close { path := "Main.lean" } }
  require "publication record fixture could not close its document" closed.ok
  let (some second, next) ← publishedEvent? server
    | throw <| IO.userError "closing the document dropped its publication record"
  require s!"publication record did not advance: {first} then {second}, next {next}"
    (first < second && second < next)

def run : IO Unit := do
  checkBeforeClaim
  checkPublicationRecord
  checkClosingReservation
  checkSchedule .reset
  checkSchedule .drop
  checkSchedule .updateFile
  checkSchedule .refresh
  checkSchedule .closeFile
  checkSchedule .exited
  checkSchedule .closeRuntime
  checkSchedule .drop true

end BeamTest.Broker.PublicationClaimTest
