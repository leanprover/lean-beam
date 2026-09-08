/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.DaemonManager
import Beam.Cli.Feedback
import Beam.Cli.Info
import Beam.Cli.InstallPrune
import Beam.Cli.LeanOperation
import Beam.Cli.Project
import Beam.Cli.RuntimeBundle
import Beam.Cli.Usage

open Lean

namespace Beam.Cli

open Beam.Broker

private inductive SessionState where
  | absent
  | running
  | stopping
  | recoveryRequired
  deriving BEq, Repr

private instance : ToJson SessionState where
  toJson
    | .absent => "absent"
    | .running => "running"
    | .stopping => "stopping"
    | .recoveryRequired => "recoveryRequired"

private structure SessionStatus where
  state : SessionState
  workspace : String
  sessionDir : String
  generation? : Option String := none
  detail? : Option String := none
  deriving ToJson

private structure SessionTransitionWarning where
  code : String
  message : String
  deriving ToJson

private structure SessionTransitionResult where
  state : SessionState
  changed : Bool
  warning? : Option SessionTransitionWarning := none
  deriving ToJson

private structure SessionRecoveryResult where
  state : SessionState
  changed : Bool
  generation? : Option String := none
  quarantinedPath? : Option String := none
  reason? : Option String := none
  deriving ToJson

private def mkSessionStatus
    (state : SessionState)
    (workspace sessionDir : System.FilePath)
    (generation? detail? : Option String := none) : SessionStatus := {
  state
  workspace := workspace.toString
  sessionDir := sessionDir.toString
  generation?
  detail?
}

private def updateSnapshotForRocqGoals
    (root : System.FilePath)
    (client : ProjectDaemonClient)
    (path : String) : IO SnapshotRef := do
  let resp ← requestBroker root client {
    payload := .updateFile { backend := .rocq, path }
  }
  match decodeUpdateFileResult resp with
  | .ok result => pure result.snapshot
  | .error (.broker failure) => throw <| IO.userError failure.error.message
  | .error (.invalidPayload detail) =>
      throw <| IO.userError <|
        s!"update_file returned an invalid result while obtaining document snapshot: {detail}"

private def runLeanRunAt
    (opts : CliOptions)
    (action path snapshotText lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let position ← parseLeanPositionArgs path snapshotText lineText characterText
  let parsedText ← parseTextArg s!"{action} <path> <snapshot> <line> <character>" textArgs
  let root ← projectRoot opts .lean
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client => do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest position parsedText.text (storeHandle := storeHandle)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
    callBrokerWithProgress root client req (leanRunAtWaitSpec action path position.line position.character)

private def runLeanRunWith
    (opts : CliOptions)
    (action path : String)
    (args : List String)
    (linear : Bool := false) : IO Unit := do
  let textArgs :=
    match args with
    | [] => []
    | "--handle-file" :: _ :: rest => rest
    | _ :: rest => rest
  if handleArgReadsStdin args && textArgReadsStdin textArgs then
    throw <| IO.userError <| String.intercalate "\n" [
      textArgUsage s!"{action} <path> <handle-json|-|--handle-file <path>>",
      "cannot read both handle json and continuation text from stdin; pass the handle inline, use --handle-file, or use --text-file for the text"
    ]
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let root ← projectRoot opts .lean
  let req ← withEnvClientRequestId <|
    leanRunWithRequest path handle parsedText.text (linear := linear)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBrokerWithProgress root client req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (opts : CliOptions)
    (action : String)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts .lean
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage s!"{action} <path>")
  withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBroker root client <| leanReleaseRequest path handle

private def stopProjectSession (opts : CliOptions) : IO Unit := do
  let root ← explicitProjectRoot opts "stop"
  match ← shutdownRegisteredProjectDaemon root opts.explicitControlDir? with
  | .absent =>
      printResponse <| Response.success <|
        toJson ({ state := .absent, changed := false } : SessionTransitionResult)
  | .alreadyStopping =>
      printResponse <| Response.success <| toJson ({
        state := .stopping
        changed := false
      } : SessionTransitionResult)
  | .stopping delivery =>
      let warning? ←
        match delivery with
        | .acknowledged => pure none
        | .rejected failure =>
            pure <| some ({
              code := "shutdownRejected"
              message := failure.error.message
            } : SessionTransitionWarning)
        | .failed failure =>
            pure <| some ({
              code := "shutdownDeliveryFailed"
              message := ← daemonFailureMessage root failure opts.explicitControlDir?
            } : SessionTransitionWarning)
      printResponse <| Response.success <| toJson ({
        state := .stopping
        changed := true
        warning?
      } : SessionTransitionResult)

private def recoverProjectSession (opts : CliOptions) (args : List String) : IO Unit := do
  let root ← explicitProjectRoot opts "recover"
  let (generation?, forceOpaque) ←
    match args with
    | ["--generation", generation] => pure (some generation, false)
    | ["--force"] => pure (none, true)
    | _ =>
        throw <| IO.userError
          "usage: lean-beam --root PATH [--session-dir DIR] recover --generation ID | --force"
  let result ← recoverProjectDaemon root generation? forceOpaque opts.explicitControlDir?
  let result : SessionRecoveryResult :=
    match result with
    | .absent => {
        state := .absent
        changed := false
        reason? := some "absent"
      }
    | .recoveredGeneration generation quarantinedPath => {
        state := .absent
        changed := true
        generation? := some generation
        quarantinedPath? := some quarantinedPath.toString
      }
    | .recoveredOpaque quarantinedPath => {
        state := .absent
        changed := true
        quarantinedPath? := some quarantinedPath.toString
        reason? := some "opaque"
      }
  printResponse <| Response.success <| toJson result

private def parseBackendName (name : String) : IO Backend := do
  match fromJson? (Json.str name) with
  | .ok backend => pure backend
  | .error err => throw <| IO.userError err

private def runThenHoldUntilInterrupted
    (owner : ProjectDaemonOwner)
    (act : IO Unit) : IO Unit :=
  withInterruptWatcher fun watcher => do
    act
    while !(← watcher.interrupted) && (← owner.exitCode?).isNone &&
        (← owner.registered) && !(← IO.checkCanceled) do
      IO.sleep 50
    if ← watcher.interrupted then
      watcher.awaitInterrupt
    else if let some exitCode ← owner.exitCode? then
      unless exitCode == 0 do
        let tail := (← owner.stderrTail).trimAscii.toString
        let detail := if tail.isEmpty then "" else s!"\ndaemon stderr tail:\n{tail}"
        throw <| IO.userError s!"owned Beam daemon exited with status {exitCode}{detail}"

private def serveBackend
    (home : System.FilePath)
    (opts : CliOptions)
    (backend : Backend) : IO Unit := do
  let root ← projectRoot opts backend
  withProjectDaemonOwner home root backend
      (explicitControlDir? := opts.explicitControlDir?) fun owner =>
    runThenHoldUntilInterrupted owner do
      callBrokerQuiet root owner.client <| Request.ensure backend
      printResponse <| Response.success <| toJson <|
        mkSessionStatus .running root owner.client.controlDir (some owner.generation)
      (← IO.getStdout).flush
      IO.eprintln <|
        "beam: serving Beam session; interrupt this process or run when finished:\n" ++
        wrapperSessionCommand root owner.client.controlDir .stop

private def sessionStatus (opts : CliOptions) : IO Unit := do
  let root ← projectRootAny opts
  let sessionDir ← Beam.Daemon.controlDirFor root opts.explicitControlDir?
  let result : SessionStatus ←
    match ← observeProjectRegistry root opts.explicitControlDir? with
    | .absent => pure <| mkSessionStatus .absent root sessionDir
    | .live entry => pure <| mkSessionStatus .running root sessionDir (some entry.daemonId)
    | .draining entry => pure <| mkSessionStatus .stopping root sessionDir (some entry.daemonId)
    | .selectorMismatch entry =>
        throw <| IO.userError <| sessionSelectorMismatchMessage root sessionDir entry
    | .recoveryRequired blocker =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir blocker.generation?
          (some blocker.statusDetail)
  printResponse <| Response.success (toJson result)

def runCommand (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  match opts.args with
  | [] | ["-h"] | ["--help"] | ["help"] =>
      IO.println usage
  | "version" :: [] | "--version" :: [] =>
      printVersion home
  | "bundle-install" :: toolchain :: [] =>
      let cacheRoot ←
        match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
        | some path => pure <| System.FilePath.mk path
        | none =>
            let roots ← installBundleCacheRoots
            pure <| roots.headD (beamStateDir home / installBundlesDirName)
      let _ ← ensureToolchainBundleIn cacheRoot home toolchain
      pure ()
  | "prune" :: args =>
      runInstallPrune home args
  | "validated-toolchains" :: [] =>
      printValidatedToolchains home "lean"
  | "validated-toolchains" :: backend :: [] =>
      printValidatedToolchains home backend
  | "compatible-release-lines" :: [] =>
      printCompatibleReleaseLines home
  | "install-layout" :: [] =>
      printInstallLayout
  | "install-manifest" :: payloadHash :: sourceCommitArg :: createdWithToolchains =>
      printInstallManifest payloadHash sourceCommitArg createdWithToolchains
  | "install-manifest-with-source-commit" :: manifestPath :: sourceCommitArg :: [] =>
      printInstallManifestWithSourceCommit (System.FilePath.mk manifestPath) sourceCommitArg
  | "install-runtime-validate" :: path :: [] =>
      validateInstalledRuntimeForReuse (System.FilePath.mk path)
  | "mcp-config" :: [] =>
      printMcpConfig home opts
  | "feedback-report" :: args =>
      Beam.Cli.Feedback.run home opts args
  | "serve" :: [] =>
      serveBackend home opts .lean
  | "serve" :: backend :: [] =>
      serveBackend home opts (← parseBackendName backend)
  | "run-at" :: path :: snapshot :: line :: character :: text =>
      runLeanRunAt opts "run-at" path snapshot line character text
  | "run-at-handle" :: path :: snapshot :: line :: character :: text =>
      runLeanRunAt opts "run-at-handle" path snapshot line character text
        (storeHandle := true)
  | "hover" :: path :: snapshotText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let position ← parseLeanPositionArgs path snapshotText line character
      let action := "hover"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanHoverRequest position)
          (leanHoverWaitSpec path position.line position.character action)
  | "signature-help" :: path :: snapshotText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let position ← parseLeanPositionArgs path snapshotText line character
      let action := "signature-help"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSignatureHelpRequest position)
          (leanSignatureHelpWaitSpec path position.line position.character action)
  | "definition" :: path :: snapshotText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let position ← parseLeanPositionArgs path snapshotText line character
      let action := "definition"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDefinitionRequest position)
          (leanDefinitionWaitSpec path position.line position.character action)
  | "references" :: path :: snapshotText :: line :: character :: extra =>
      let root ← projectRoot opts .lean
      let position ← parseLeanPositionArgs path snapshotText line character
      let includeDeclaration ← parseLeanReferencesArgs extra
      let action := "references"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanReferencesRequest position includeDeclaration)
          (leanReferencesWaitSpec path position.line position.character action)
  | "document-symbols" :: path :: snapshotText :: [] =>
      let root ← projectRoot opts .lean
      let document ← parseLeanDocumentArgs path snapshotText
      let action := "document-symbols"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDocumentSymbolsRequest document)
          (leanDocumentSymbolsWaitSpec path action)
  | "workspace-symbols" :: queryParts =>
      let root ← projectRoot opts .lean
      let query ←
        match joinTextArgs queryParts with
        | some query => pure query
        | none => throw <| IO.userError "usage: lean-beam [--root PATH] workspace-symbols <query...>"
      let action := "workspace-symbols"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanWorkspaceSymbolsRequest query)
          (leanWorkspaceSymbolsWaitSpec query action)
  | "goals" :: modeText :: path :: snapshotText :: line :: character :: [] =>
      let root ← projectRoot opts .lean
      let mode ← parseLeanGoalsModeArg modeText
      let position ← parseLeanPositionArgs path snapshotText line character
      let action := "goals"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanGoalsRequest position mode)
          (leanGoalsWaitSpec path position.line position.character mode (some action))
  | "todo" :: path :: snapshotText :: startLine :: startCharacter :: endLine :: endCharacter :: extra => do
      let root ← projectRoot opts .lean
      let snapshot ← IO.ofExcept <| SnapshotRef.decode snapshotText
      let startLine ← parseNatArg "startLine" startLine
      let startCharacter ← parseNatArg "startCharacter" startCharacter
      let endLine ← parseNatArg "endLine" endLine
      let endCharacter ← parseNatArg "endCharacter" endCharacter
      let (kinds?, suggest?) ← parseLeanTodoArgs extra
      let action := "todo"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanTodoRequest path snapshot startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter action)
  | "run-with" :: path :: args =>
      runLeanRunWith opts "run-with" path args
  | "run-with-linear" :: path :: args =>
      runLeanRunWith opts "run-with-linear" path args
        (linear := true)
  | "release" :: path :: args =>
      runLeanRelease opts "release" path args
  | "save" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSaveArgs extra
      let action := "save"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (action? := some action))
  | "update" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanUpdateRequest path
  | "sync" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanSyncArgs extra
      let action := "sync"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSyncRequest path diagnosticScope)
          (syncWaitSpec path action)
  | "refresh" :: path :: extra => do
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanRefreshArgs extra
      let action := "refresh"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanRefreshRequest path diagnosticScope)
          (refreshWaitSpec path action)
  | "close" :: path :: [] =>
      let root ← projectRoot opts .lean
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanCloseRequest path
  | "close-save" :: path :: extra =>
      let root ← projectRoot opts .lean
      let diagnosticScope ← parseLeanCloseSaveArgs extra
      let action := "close-save"
      withProjectDaemon root .lean (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanCloseSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action))
  | "rocq-goals-after" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      withProjectDaemon root .rocq (explicitControlDir? := opts.explicitControlDir?) fun client => do
        let snapshot ← updateSnapshotForRocqGoals root client path
        callBroker root client {
          payload := .goals {
            backend := .rocq
            path
            snapshot
            line := ← parseNatArg "line" line
            character := ← parseNatArg "character" character
            mode? := some .after
            compact? := some false
            ppFormat? := some .str
            text? := joinTextArgs text
          }
        }
  | "rocq-goals-prev" :: path :: line :: character :: text =>
      let root ← projectRoot opts .rocq
      withProjectDaemon root .rocq (explicitControlDir? := opts.explicitControlDir?) fun client => do
        let snapshot ← updateSnapshotForRocqGoals root client path
        callBroker root client {
          payload := .goals {
            backend := .rocq
            path
            snapshot
            line := ← parseNatArg "line" line
            character := ← parseNatArg "character" character
            mode? := some .before
            compact? := some false
            ppFormat? := some .str
            text? := joinTextArgs text
          }
        }
  | "doctor" :: [] =>
      doctor home opts .lean
  | "doctor" :: backend :: [] =>
      doctor home opts (← parseBackendName backend)
  | "open-files" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.openDocs
  | "cancel" :: requestId :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| Request.cancel requestId
  | "stats" :: [] =>
      let root ← projectRootAny opts
      withExistingProjectDaemon root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.stats
  | "status" :: [] =>
      sessionStatus opts
  | "stop" :: [] =>
      stopProjectSession opts
  | "recover" :: args =>
      recoverProjectSession opts args
  | _ =>
      throw <| IO.userError usage

end Beam.Cli
