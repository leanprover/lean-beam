/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Beam.LSP.Lib.Goal
import Beam.LSP.Lib.Request
import Beam.LSP.RunAt.Handles

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
The speculative execution request family.

This module owns the public `$/lean/runAt` method plus the related handle continuation methods
`$/lean/runWith` and `$/lean/releaseHandle`.
-/
namespace Beam.LSP.RunAt

/--
JSON-RPC method name for the standalone `runAt` request.

This is the only public entry point. Backend selection remains internal:

- proof/tactic execution when a proof basis can be recovered at the given position
- command execution otherwise
-/
def method : String := "$/lean/runAt"

/-- JSON-RPC method name for follow-up execution from a stored handle. -/
def runWithMethod : String := "$/lean/runWith"

/-- JSON-RPC method name for explicit follow-up handle release. -/
def releaseHandleMethod : String := "$/lean/releaseHandle"

/--
Public request payload for `$/lean/runAt`.

Current request semantics:

- the request is identified by versioned `textDocument`, `position`, and `text`
- `textDocument.version` is required and must match the current open document version
- callers do not choose command vs tactic mode
- command-mode `text` is one Lean command, not a top-level command sequence
- proof-mode `text` is one tactic block
- `position` uses Lean/LSP `Position` semantics against the matching document version
- proof execution uses Lean's cursor-selected before/after tactic state; the tactic's start
  selects its before-state, while positions inside it may select its after-state
- positions outside the document are invalid request parameters
- request-level failures are reported as transport errors rather than as `Result`
-/
structure Params where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  position : Lean.Lsp.Position
  text : String
  storeHandle? : Option Bool := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource Params where
  fileSource p := p.textDocument.uri

/-- Request payload for `$/lean/runWith`. -/
structure RunWithParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  text : String
  storeHandle? : Option Bool := none
  linear? : Option Bool := none
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource RunWithParams where
  fileSource p := p.textDocument.uri

/-- Request payload for `$/lean/releaseHandle`. -/
structure ReleaseHandleParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  handle : Handle
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource ReleaseHandleParams where
  fileSource p := p.textDocument.uri

/-- A user-visible message emitted by isolated execution. -/
structure Message where
  severity : Lean.MessageSeverity
  text : String
  deriving FromJson, ToJson

/--
Typed success payload for `$/lean/runAt`.

Current frozen response semantics:

- request-level failures are not encoded here; they are transport errors
- `success = true` iff execution completes without any error-severity messages
- semantic Lean failures stay in this payload through `messages`
- command-mode proof-body diagnostics from the probed theorem are part of execution
- command-mode top-level command sequences fail here with a `runAtSupportsOneCommandOnly` message
- no backend tag is exposed in the public payload
- no extra status enum is exposed beyond `success`
- `handle?` is present only when requested and execution produced reusable follow-up state
- `proofState?` is present only for proof-oriented execution
- proof goals are structured into target, hypotheses, and optional case name
- solved proof states use `proofState.goals = #[]`
- `traces` stays as a plain array; empty traces are represented as `#[]`
- positions outside the document produce transport `invalidParams`
- in-document positions with no usable command/proof snapshot may also produce transport `invalidParams`
- in-document whitespace/comment positions may still resolve to a nearby execution basis
- editing a document while a request is pending may produce transport `contentModified`
- stale pending requests may produce transport `contentModified`
- explicit cancellation may produce transport `requestCancelled`
- cancellation is cooperative inside isolated execution; prompt `requestCancelled` depends on inner
  elaboration polling Lean interruption
-/
structure Result where
  success : Bool := true
  messages : Array Message := #[]
  traces : Array String := #[]
  handle? : Option Handle := none
  proofState? : Option ProofState := none
  deriving FromJson, ToJson

def mkMessage (severity : MessageSeverity) (text : String) : Message :=
  { severity, text }

def trimOutput (text : String) : String :=
  text.trimAscii.toString

def outputMessage? (output : String) : Option Message :=
  let output := trimOutput output
  if output.isEmpty then none else some <| mkMessage .information output

def errorResult (message : String) (proofState? : Option ProofState := none) : Result :=
  {
    success := false
    messages := #[mkMessage .error message]
    proofState?
  }

def messagesToProtocol (messages : List Lean.Message) : IO (Array Message) := do
  messages.toArray.filter (! ·.isSilent) |>.mapM fun message => do
    return mkMessage message.severity (← message.data.toString)

def tracesToStrings (traces : List TraceElem) : IO (Array String) := do
  traces.toArray.mapM fun trace => do
    return (← trace.msg.toString)

structure ExecutionArtifacts where
  messages : Array Message
  traces : Array String
  hasErrors : Bool

def mkExecutionArtifacts
    (output : String)
    (messages : List Lean.Message)
    (traces : List TraceElem) : RequestM ExecutionArtifacts := do
  let mut protocolMessages ← messagesToProtocol messages
  if let some outputMessage := outputMessage? output then
    protocolMessages := protocolMessages.push outputMessage
  let protocolTraces ← tracesToStrings traces
  return {
    messages := protocolMessages
    traces := protocolTraces
    hasErrors := protocolMessages.any (fun message => message.severity == .error)
  }

def mkExecutionResult
    (error? : Option String)
    (artifacts : ExecutionArtifacts)
    (proofState? : Option ProofState := none) : Result :=
  match error? with
  | some error =>
      if artifacts.hasErrors then
        { success := false, messages := artifacts.messages, traces := artifacts.traces, proofState? }
      else
        {
          success := false
          messages := artifacts.messages.push (mkMessage .error error)
          traces := artifacts.traces
          proofState?
        }
  | none =>
      {
        success := !artifacts.hasErrors
        messages := artifacts.messages
        traces := artifacts.traces
        proofState?
      }

def withInnerCancelToken (k : IO.CancelToken → RequestM α) : RequestM α := do
  let rc ← readThe RequestContext
  let innerCancelTk ← IO.CancelToken.new
  let finished ← IO.Promise.new
  let finishedTask : ServerTask Bool :=
    finished.resultD () |>.asServerTask |>.mapCheap (fun _ => false)
  let cancelTasks :=
    rc.cancelTk.cancellationTasks.map (·.mapCheap (fun _ => true)) ++ [finishedTask]
  discard <| ServerTask.BaseIO.asTask do
    if ← ServerTask.waitAny cancelTasks then
      innerCancelTk.set
  try
    k innerCancelTk
  finally
    finished.resolve ()

def runCommandElabMWithCancel
    (snap : Snapshots.Snapshot)
    (doc : DocumentMeta)
    (cancelTk? : Option IO.CancelToken)
    (c : Elab.Command.CommandElabM α) : EIO Exception α := do
  let ctx : Command.Context := {
    cmdPos := snap.stx.getPos? |>.getD 0
    fileName := doc.uri
    fileMap := doc.text
    snap? := none
    cancelTk?
  }
  c.run ctx |>.run' snap.cmdState

def noSnapshotFoundMessage (position : Lean.Lsp.Position) : String :=
  s!"position {position} is inside the document, but Lean has no command or tactic snapshot there; try a position inside a command or proof body, not a standalone comment, blank line, or declaration header"

def withRunAtSnapAtPos
    (position : Lean.Lsp.Position)
    (f : Snapshots.Snapshot → RequestM α) : RequestM (RequestTask α) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.withWaitFindSnap doc (fun snap => snap.endPos >= pos)
    (notFoundX := throw <| RequestError.invalidParams (noSnapshotFoundMessage position))
    (x := f)

private partial def finishedHeaderLevelNamesAt (snap : Language.DynamicSnapshot)
    (text : FileMap) (pos : String.Pos.Raw) : BaseIO (Option (List Name)) := do
  if let some defs := snap.toTyped? Elab.DefsParsedSnapshot then
    for defn in defs.defs do
      let some (some header) ← defn.headerProcessedSnap.get? | continue
      let some range := header.bodyStx.getRangeWithTrailing? | continue
      if text.rangeContainsHoverPos range pos (includeStop := true) then
        return some header.view.levelNames
  -- Commands such as `set_option ... in` are macro wrappers around the declaration.
  if let some expanded := snap.toTyped? Elab.Command.MacroExpandedSnapshot then
    for child in expanded.next do
      let some value ← child.get? | continue
      if let some levels ← finishedHeaderLevelNamesAt value text pos then
        return some levels
  return none

private def withProofScopeAtPos (position : Lean.Lsp.Position)
    (f : List Name → RequestM α) : RequestM (RequestTask α) := do
  let doc ← RequestM.readDoc
  let pos := doc.meta.text.lspPosToUtf8Pos position
  RequestM.bindTaskCostly
    (Language.Lean.findCmdParsedSnap doc.initSnap doc.meta.text pos).asServerTask fun
    | none => throw <| RequestError.invalidParams (noSnapshotFoundMessage position)
    | some parsed => do
      let some commandStart := parsed.stx.getPos?
        | throw <| RequestError.invalidParams (noSnapshotFoundMessage position)
      let headerLevels ← do
        -- Read only finished header snapshots. A goal can be available while its body is still
        -- running, and explicit universe binders need not occur in the goal or local types.
        let some dynamicSnap ← parsed.elabSnap.elabSnap.get? | pure []
        let levels? ← finishedHeaderLevelNamesAt dynamicSnap doc.meta.text pos
        pure (levels?.getD [])
      -- The preceding parser state ends at this command's start. Its universe scope is
      -- available already; waiting for the containing command would block behind later tactics.
      RequestM.withWaitFindSnap doc (fun snap => snap.endPos >= commandStart)
        (notFoundX := throw <| RequestError.invalidParams (noSnapshotFoundMessage position))
        (x := fun snap => f (headerLevels ++ snap.cmdState.scopes.head!.levelNames))

def maybeAttachHandle
    (result : Result)
    (storeHandle : Bool)
    (state? : Option StoredHandleState) : RequestM Result := do
  if !storeHandle || !result.success then
    return result
  let some state := state?
    | return result
  return { result with handle? := some (← mintHandle state) }

def runAtSupportsOneCommandOnlyCode : String :=
  "runAtSupportsOneCommandOnly"

private inductive CommandParseResult where
  | ok (stx : Syntax)
  | extraInput (err : String)
  | error (err : String)

private def parseOneCommandText (env : Environment) (text : String) : CommandParseResult :=
  let p := Parser.andthenFn Parser.whitespace (Parser.categoryParserFnImpl `command)
  let ictx := Parser.mkInputContext text "<runAt>"
  let s := p.run ictx { env, options := {} } (Parser.getTokenTable env) (Parser.mkParserState text)
  if !s.allErrors.isEmpty then
    .error (s.toErrorMsg ictx)
  else if ictx.atEnd s.pos then
    .ok s.stxStack.back
  else
    .extraInput ((s.mkError "end of input").toErrorMsg ictx)

private def oneCommandOnlyResult (err : String) : Result :=
  errorResult
    s!"{runAtSupportsOneCommandOnlyCode}: command-mode runAt accepts exactly one Lean command, not a top-level command sequence. Use a stored handle continuation for explicit speculative sequencing, or write the sequence to the file and sync it. Original parse error: {err}"

-- With `Elab.async`, `elabCommandTopLevel` may return before nested work has produced its
-- diagnostics. Top-level theorem commands use this path for proof-body elaboration, so these
-- snapshot messages are part of the command-mode `runAt` result even though unrelated full-file
-- diagnostics remain out of scope.
private def collectSnapshotTaskArtifacts
    (tasks : Array (Language.SnapshotTask Language.SnapshotTree)) :
    BaseIO (List Lean.Message × List TraceElem) := do
  if tasks.isEmpty then
    return ([], [])
  let tree := Language.SnapshotTree.mk { diagnostics := .empty } tasks
  let waitTask ← tree.waitAll
  -- Force every child snapshot before reading the tree; otherwise theorem proof failures can be
  -- hidden behind unfinished async tasks.
  let _ := waitTask.get
  let snapshots := tree.getAll
  let messages := snapshots.foldl (init := []) fun acc snapshot =>
    acc ++ snapshot.diagnostics.msgLog.toList
  let traces := snapshots.foldl (init := []) fun acc snapshot =>
    acc ++ snapshot.traces.traces.toList
  return (messages, traces)

def runCommandText (snap : Snapshots.Snapshot) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let rc ← readThe RequestContext
    let stx ←
      match parseOneCommandText snap.env text with
      | .ok stx => pure stx
      | .extraInput err => return (oneCommandOnlyResult err, none)
      | .error err => return (errorResult err, none)
    let (output, response) ← IO.FS.withIsolatedStreams do
      EIO.toBaseIO do
        runCommandElabMWithCancel snap rc.doc.meta (some innerCancelTk) do
          -- The incoming snapshot can carry already-accounted-for async work from the saved file.
          -- A speculative command result should include only tasks spawned by this command.
          modify fun state => { state with snapshotTasks := #[] }
          let initialMsgCount := (← get).messages.toList.length
          let initialTraceCount := (← getTraces).size
          let error? ← try
            Elab.Command.elabCommandTopLevel stx
            pure none
          catch ex =>
            if ex.isInterrupt then
              throw ex
            pure (some (← ex.toMessageData.toString))
          let state ← get
          let messages := state.messages.toList.drop initialMsgCount
          let traces := (← getTraces).toList.drop initialTraceCount
          let (snapshotMessages, snapshotTraces) ←
            collectSnapshotTaskArtifacts state.snapshotTasks
          return (
            error?,
            messages ++ snapshotMessages,
            traces ++ snapshotTraces,
            -- Completed snapshot tasks have been folded into the result. Do not leak them into a
            -- stored command handle, where a later `runWith` would report them again.
            { state with snapshotTasks := #[] })
    let (error?, newMessages, newTraces, newState) ←
      match response with
      | .ok response => pure response
      | .error ex =>
          checkRequestCancelled
          throw <| RequestError.internalError (← ex.toMessageData.toString)
    let artifacts ← mkExecutionArtifacts output newMessages newTraces
    checkRequestCancelled
    let result := mkExecutionResult error? artifacts
    let nextHandle? :=
      if result.success then
        some <| StoredHandleState.command { snap with cmdState := newState }
      else
        none
    return (result, nextHandle?)

def proofStateOfSnapshot (snapshot : ProofSnapshot) : RequestM ProofState := do
  let (proofState, _) ← snapshot.runMetaM <| proofStateOfGoalList snapshot.tacticState.goals
  return proofState

private inductive TacticSnapshotDisposition where
  | keepAdvanced
  | restoreInitial

private def TacticSnapshotDisposition.proofState
    (disposition : TacticSnapshotDisposition)
    (initialProofState : ProofState)
    (advancedSnapshot : ProofSnapshot) : RequestM ProofState := do
  match disposition with
  | .keepAdvanced =>
      proofStateOfSnapshot advancedSnapshot
  | .restoreInitial =>
      pure initialProofState

private def TacticSnapshotDisposition.nextHandleState?
    (disposition : TacticSnapshotDisposition)
    (result : Result)
    (advancedSnapshot : ProofSnapshot) : Option StoredHandleState :=
  match disposition with
  | .keepAdvanced =>
      if result.success then
        some <| StoredHandleState.proof advancedSnapshot
      else
        none
  | .restoreInitial =>
      none

private structure TacticExecutionOutcome where
  disposition : TacticSnapshotDisposition
  error? : Option String
  messages : List Lean.Message
  traces : List TraceElem

private def collectNewTacticArtifacts
    (initialMsgCount : Nat)
    (initialTraceCount : Nat) : Elab.Tactic.TacticM (List Lean.Message × List TraceElem) := do
  let messages := (← Core.getMessageLog).toList.drop initialMsgCount
  let traces := (← getTraces).toList.drop initialTraceCount
  pure (messages, traces)

private def classifyTacticException
    (ex : Exception)
    (messages : List Lean.Message) : Elab.Tactic.TacticM (Option String) := do
  if ex.isInterrupt then
    throw ex
  match ex with
  | .internal id _ =>
      if id != abortTacticExceptionId then
        throw ex
      -- `abortTactic` is Lean's tactic-control exception for a failed tactic. If diagnostics were
      -- already emitted, those are the user-level error; otherwise retain a fallback message.
      if messages.any (·.severity == .error) then
        pure none
      else
        pure (some "tactic aborted without diagnostics")
  | _ =>
      pure (some (← ex.toMessageData.toString))

def runTacticText (snapshot : ProofSnapshot) (initialProofState : ProofState) (text : String) :
    RequestM (Result × Option StoredHandleState) := do
  checkRequestCancelled
  withInnerCancelToken fun innerCancelTk => do
    let snapshot := snapshot.withCancelToken (some innerCancelTk)
    let stx ←
      match Parser.runParserCategory snapshot.coreState.env `tactic text "<runAt>" with
      | .ok stx => pure stx
      | .error err => return (errorResult err (some initialProofState), none)
    let (output, (outcome, proofSnapshot')) ←
      try
        IO.FS.withIsolatedStreams do
          let run : IO (TacticExecutionOutcome × ProofSnapshot) := snapshot.runTacticM do
            let saved ← Elab.Tactic.saveState
            let initialMsgCount := (← Core.getMessageLog).toList.length
            let initialTraceCount := (← getTraces).size
            try
              Elab.Tactic.evalTactic stx
              Elab.Term.synthesizeSyntheticMVarsNoPostponing
              -- Lean lifts local recursive definitions and checks their termination when
              -- finalizing the enclosing declaration. A standalone tactic probe has no such
              -- finalization step, so it must not report these pending definitions as solved.
              unless (← Elab.Term.getLetRecsToLift).isEmpty do
                throwError "Local recursive declarations are not supported in runAt tactics. Add the declaration to the document and sync before probing."
              let (messages, traces) ← collectNewTacticArtifacts initialMsgCount initialTraceCount
              return { disposition := .keepAdvanced, error? := none, messages, traces }
            catch ex =>
              let (messages, traces) ← collectNewTacticArtifacts initialMsgCount initialTraceCount
              let error? ← classifyTacticException ex messages
              saved.restore (restoreInfo := true)
              return { disposition := .restoreInitial, error?, messages, traces }
          run
      catch ex =>
        checkRequestCancelled
        throw ex
    let artifacts ← mkExecutionArtifacts output outcome.messages outcome.traces
    checkRequestCancelled
    let proofState ← outcome.disposition.proofState initialProofState proofSnapshot'
    let result := mkExecutionResult outcome.error? artifacts (proofState? := some proofState)
    let nextHandle? := outcome.disposition.nextHandleState? result proofSnapshot'
    return (result, nextHandle?)

def runTacticAtBasis (basis : GoalsAtResult) (text : String) (levelNames : List Name) :
    RequestM (Result × Option StoredHandleState) := do
  let ctxInfo := mkBasisCtxInfo basis
  let initialProofState ← basisProofState basis
  let proofSnapshot ← ProofSnapshot.create ctxInfo (basisGoals basis) (levelNames := levelNames)
  runTacticText proofSnapshot initialProofState text

def handleRunAt (p : Params) : RequestM (RequestTask Result) := do
  requireDocumentVersion p.textDocument
  syncHandleStoreForCurrentDoc
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis =>
        withProofScopeAtPos p.position fun levelNames => do
          checkRequestCancelled
          let (result, state?) ← runTacticAtBasis basis p.text levelNames
          maybeAttachHandle result (p.storeHandle?.getD false) state?
    | none =>
        withRunAtSnapAtPos p.position fun snap => do
          checkRequestCancelled
          let (result, state?) ← runCommandText snap p.text
          maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleRunWith (p : RunWithParams) : RequestM (RequestTask Result) := do
  syncHandleStoreForCurrentDoc
  checkRequestCancelled
  withStoredHandle p.handle (p.linear?.getD false) fun stored => do
    RequestM.asTask do
      checkRequestCancelled
      let (result, state?) ←
        match stored.state with
        | .command snapshot =>
            runCommandText snapshot p.text
        | .proof snapshot =>
            let initialProofState ← proofStateOfSnapshot snapshot
            runTacticText snapshot initialProofState p.text
      maybeAttachHandle result (p.storeHandle?.getD false) state?

def handleReleaseHandle (p : ReleaseHandleParams) : RequestM (RequestTask Json) := do
  syncHandleStoreForCurrentDoc
  releaseStoredHandle p.handle
  return RequestTask.pure Json.null

end Beam.LSP.RunAt
