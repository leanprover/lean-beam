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
import Beam.Cli.Installation
import Beam.Cli.Prune
import Beam.Cli.LeanOperation
import Beam.Cli.Project
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

private def runLeanRunAt
    (runtime : RuntimeAccess)
    (opts : CliOptions)
    (action path versionText lineText characterText : String)
    (textArgs : List String)
    (storeHandle : Bool := false) : IO Unit := do
  let version ← parseNatArg "version" versionText
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let parsedText ← parseTextArg s!"{action} <path> <version> <line> <character>" textArgs
  let root ← projectRoot opts
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client => do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest path version line character parsedText.text (storeHandle := storeHandle)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
    callBrokerWithProgress root client req (leanRunAtWaitSpec action path line character)

private def runLeanRunWith
    (runtime : RuntimeAccess)
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
  let root ← projectRoot opts
  let req ← withEnvClientRequestId <|
    leanRunWithRequest path handle parsedText.text (linear := linear)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBrokerWithProgress root client req (leanRunWithWaitSpec path (linear := linear))

private def runLeanRelease
    (runtime : RuntimeAccess)
    (opts : CliOptions)
    (action : String)
    (path : String)
    (args : List String) : IO Unit := do
  let root ← projectRoot opts
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| IO.userError (handleArgUsage s!"{action} <path>")
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBroker root client <| leanReleaseRequest path handle

private def stopProjectSession (runtime : RuntimeAccess) (opts : CliOptions) : IO Unit := do
  let root ← explicitProjectRoot opts "stop"
  match ← shutdownRegisteredProjectDaemon runtime.control root opts.explicitControlDir? with
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

private def recoverProjectSession (runtime : RuntimeAccess) (opts : CliOptions) (args : List String) : IO Unit := do
  let root ← explicitProjectRoot opts "recover"
  let generation ←
    match args with
    | ["--generation", generation] => pure generation
    | _ =>
        throw <| IO.userError
          "usage: lean-beam --root PATH [--session-dir DIR] recover --generation ID"
  let result ← recoverProjectDaemon runtime.control root generation opts.explicitControlDir?
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
  printResponse <| Response.success <| toJson result

private def runThenHoldUntilInterrupted
    (watcher : InterruptWatcher)
    (owner : ProjectDaemonOwner)
    (act : IO Unit) : IO Unit := do
  unless ← watcher.interrupted do act
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

private def serveProject
    (runtime : RuntimeAccess)
    (opts : CliOptions) : IO Unit := do
  let root ← projectRoot opts
  withInterruptWatcher fun watcher =>
    withProjectDaemonOwner runtime.resolve root
      (explicitControlDir? := opts.explicitControlDir?) fun owner =>
      runThenHoldUntilInterrupted watcher owner do
        IO.eprintln "beam: loading Lake workspace configuration..."
        callBrokerQuiet root owner.client <| Request.ensure
        printResponse <| Response.success <| toJson <|
          mkSessionStatus .running root owner.client.controlDir (some owner.generation)
        (← IO.getStdout).flush
        IO.eprintln <|
          "beam: serving Beam session; interrupt this process or run when finished:\n" ++
          wrapperSessionCommand root owner.client.controlDir .stop

private def sessionStatus (opts : CliOptions) : IO Unit := do
  let root ← inspectionRoot opts
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

def runCommand (installation : Installation) (opts : CliOptions) : IO Unit := do
  IO.ofExcept <| (installation.admitCommand opts.args).mapError
    (IO.userError ∘ CommandRejection.message)
  let home := installation.home
  let runtime := installation.runtime
  match opts.args with
  | [] | ["-h"] | ["--help"] | ["help"] =>
      IO.println installation.usage
  | "version" :: [] | "--version" :: [] =>
      printVersion installation.cliIdentity
  | "toolchain-build-info" :: [] =>
      printJsonLine compilerBuildInfo
  | "prune" :: args =>
      runPrune home args
  | "feedback-report" :: args =>
      Beam.Cli.Feedback.run installation.cliIdentity opts args
  | "serve" :: [] =>
      serveProject runtime opts
  | "run-at" :: path :: version :: line :: character :: text =>
      runLeanRunAt runtime opts "run-at" path version line character text
  | "run-at-handle" :: path :: version :: line :: character :: text =>
      runLeanRunAt runtime opts "run-at-handle" path version line character text
        (storeHandle := true)
  | "hover" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action := "hover"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanHoverRequest path version line character)
          (leanHoverWaitSpec path line character action)
  | "signature-help" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action := "signature-help"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSignatureHelpRequest path version line character)
          (leanSignatureHelpWaitSpec path line character action)
  | "definition" :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action := "definition"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDefinitionRequest path version line character)
          (leanDefinitionWaitSpec path line character action)
  | "references" :: path :: versionText :: line :: character :: extra =>
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let includeDeclaration ← parseLeanReferencesArgs extra
      let action := "references"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanReferencesRequest path version line character includeDeclaration)
          (leanReferencesWaitSpec path line character action)
  | "document-symbols" :: path :: versionText :: [] =>
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let action := "document-symbols"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDocumentSymbolsRequest path version)
          (leanDocumentSymbolsWaitSpec path action)
  | "workspace-symbols" :: queryParts =>
      let root ← projectRoot opts
      let query ←
        match joinTextArgs queryParts with
        | some query => pure query
        | none => throw <| IO.userError "usage: lean-beam [--root PATH] workspace-symbols <query...>"
      let action := "workspace-symbols"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanWorkspaceSymbolsRequest query)
          (leanWorkspaceSymbolsWaitSpec query action)
  | "goals" :: modeText :: path :: versionText :: line :: character :: [] =>
      let root ← projectRoot opts
      let mode ← parseLeanGoalsModeArg modeText
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let action := "goals"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanGoalsRequest path version line character mode)
          (leanGoalsWaitSpec path line character mode (some action))
  | "todo" :: path :: versionText :: startLine :: startCharacter :: endLine :: endCharacter :: extra => do
      let root ← projectRoot opts
      let version ← parseNatArg "version" versionText
      let startLine ← parseNatArg "startLine" startLine
      let startCharacter ← parseNatArg "startCharacter" startCharacter
      let endLine ← parseNatArg "endLine" endLine
      let endCharacter ← parseNatArg "endCharacter" endCharacter
      let (kinds?, suggest?) ← parseLeanTodoArgs extra
      let action := "todo"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanTodoRequest path version startLine startCharacter endLine endCharacter kinds? suggest?)
          (leanTodoWaitSpec path startLine startCharacter endLine endCharacter action)
  | "run-with" :: path :: args =>
      runLeanRunWith runtime opts "run-with" path args
  | "run-with-linear" :: path :: args =>
      runLeanRunWith runtime opts "run-with-linear" path args
        (linear := true)
  | "release" :: path :: args =>
      runLeanRelease runtime opts "release" path args
  | "save" :: path :: extra => do
      let root ← projectRoot opts
      let diagnosticScope ← parseLeanSaveArgs extra
      let action := "save"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (action? := some action))
  | "update" :: path :: [] =>
      let root ← projectRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanUpdateRequest path
  | "sync" :: path :: extra => do
      let root ← projectRoot opts
      let diagnosticScope ← parseLeanSyncArgs extra
      let action := "sync"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSyncRequest path diagnosticScope)
          (syncWaitSpec path action)
  | "refresh" :: path :: extra => do
      let root ← projectRoot opts
      let diagnosticScope ← parseLeanRefreshArgs extra
      let action := "refresh"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanRefreshRequest path diagnosticScope)
          (refreshWaitSpec path action)
  | "close" :: path :: [] =>
      let root ← projectRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| leanCloseRequest path
  | "close-save" :: path :: extra =>
      let root ← projectRoot opts
      let diagnosticScope ← parseLeanCloseSaveArgs extra
      let action := "close-save"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanCloseSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action))
  | "doctor" :: [] =>
      doctor home installation.doctorLines opts
  | "open-files" :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.openDocs
  | "cancel" :: requestId :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client <| Request.cancel requestId
  | "stats" :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.stats
  | "status" :: [] =>
      sessionStatus opts
  | "stop" :: [] =>
      stopProjectSession runtime opts
  | "recover" :: args =>
      recoverProjectSession runtime opts args
  | _ =>
      throw <| IO.userError installation.usage

end Beam.Cli
