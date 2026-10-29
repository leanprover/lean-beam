/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Args
import Beam.Cli.Broker
import Beam.Cli.ClientDoctor
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
  | shutdownUnconfirmed
  | recoveryRequired
  | unresponsive
  deriving BEq, Repr

private instance : ToJson SessionState where
  toJson
    | .absent => "absent"
    | .running => "running"
    | .stopping => "stopping"
    | .shutdownUnconfirmed => "shutdownUnconfirmed"
    | .recoveryRequired => "recoveryRequired"
    | .unresponsive => "unresponsive"

private structure SessionStatus where
  state : SessionState
  workspace : String
  sessionDir : String
  generation? : Option String := none
  detail? : Option String := none

private instance : ToJson SessionStatus where
  toJson status := Json.mkObj <|
    [("state", toJson status.state), ("workspace", toJson ({ root := status.workspace } : Beam.Workspace.Descriptor)),
     ("session_dir", toJson status.sessionDir)] ++
    status.generation?.toList.map (fun value => ("generation", toJson value)) ++
    status.detail?.toList.map (fun value => ("detail", toJson value))

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

private instance : ToJson SessionRecoveryResult where
  toJson result := Json.mkObj <|
    [("state", toJson result.state), ("changed", toJson result.changed)] ++
    result.generation?.toList.map (fun value => ("generation", toJson value)) ++
    result.quarantinedPath?.toList.map (fun value => ("quarantined_path", toJson value)) ++
    result.reason?.toList.map (fun value => ("reason", toJson value))

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
    (storeHandle : Bool := false) : CliM Unit := do
  if textArgs.isEmpty then
    throw <| CliFailure.usage s!"{action} requires path, version, line, character, and text"
      (commandUsage? action)
  let version ← parseNatArg "version" versionText
  let line ← parseNatArg "line" lineText
  let character ← parseNatArg "character" characterText
  let (profile, textArgs) ← parseProfileArg textArgs
  let parsedText ← parseTextArg s!"{action} <path> <version> <line> <character>" textArgs
  let root ← projectRoot opts
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client => do
    let req ← withEnvClientRequestId <|
      leanRunAtRequest path version line character parsedText.text
        (storeHandle := storeHandle) (profile := profile)
    maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
    callBrokerWithProgress root client req (leanRunAtWaitSpec action path line character)
      opts.jsonOutputFormat

private def runLeanRunWith
    (runtime : RuntimeAccess)
    (opts : CliOptions)
    (action path : String)
    (args : List String)
    (linear : Bool := false) : CliM Unit := do
  let textArgs :=
    match args with
    | [] => []
    | "--handle-file" :: _ :: rest => rest
    | _ :: rest => rest
  let (_, profileFreeTextArgs) ← parseProfileArg textArgs
  if handleArgReadsStdin args && textArgReadsStdin profileFreeTextArgs then
    throw <| CliFailure.usage
      "cannot read both handle json and continuation text from stdin; pass the handle inline, use --handle-file, or use --text-file for the text"
      (some (textArgUsage s!"{action} <path> <handle-json|-|--handle-file <path>>"))
  let (handle, textArgs) ← parseHandleInput s!"{action} <path>" args
  let (profile, textArgs) ← parseProfileArg textArgs
  let parsedText ← parseTextArg s!"{action} <path> <handle-json|-|--handle-file <path>>" textArgs
  let root ← projectRoot opts
  let req ← withEnvClientRequestId <|
    leanRunWithRequest path handle parsedText.text (linear := linear) (profile := profile)
  maybeEmitTextDebug req.clientRequestId? action parsedText.source parsedText.text
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBrokerWithProgress root client req (leanRunWithWaitSpec path (linear := linear))
      opts.jsonOutputFormat

private def runLeanRelease
    (runtime : RuntimeAccess)
    (opts : CliOptions)
    (action : String)
    (path : String)
    (args : List String) : CliM Unit := do
  let (handle, extra) ← parseHandleInput s!"{action} <path>" args
  unless extra.isEmpty do
    throw <| CliFailure.usage s!"unexpected {action} arguments: {String.intercalate " " extra}"
      (some (handleArgUsage s!"{action} <path>"))
  let root ← projectRoot opts
  withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
    callBroker root client (leanReleaseRequest path handle) opts.jsonOutputFormat

private def stopProjectSession (runtime : RuntimeAccess) (opts : CliOptions) : CliM Unit := do
  let root ← explicitProjectRoot opts "stop"
  match ← shutdownRegisteredProjectDaemon runtime.control root opts.explicitControlDir? with
  | .absent =>
      printResponse (.success <| toJson ({ state := .absent, changed := false } : SessionTransitionResult))
        none opts.jsonOutputFormat
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
      printResponse (.success <| toJson ({
        state := .stopping
        changed := true
        warning?
      } : SessionTransitionResult)) none opts.jsonOutputFormat

private def recoverProjectSession (runtime : RuntimeAccess) (opts : CliOptions) (args : List String) : CliM Unit := do
  let generation ←
    match args with
    | ["--generation", generation] => pure generation
    | _ =>
        throw <| commandUsageFailure ("recover" :: args)
  let root ← explicitProjectRoot opts "recover"
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
  printResponse (.success <| toJson result) none opts.jsonOutputFormat

/-- Initialize an acquired foreground owner, then hold it until shutdown.
The caller owns the enclosing signal/owner scopes; initialization must reject pre-readiness stops. -/
def runThenHoldUntilInterrupted
    (watcher : InterruptWatcher)
    (owner : ProjectDaemonOwner)
    (act : IO Unit) : IO Unit := do
  -- Initialization owns the pre-readiness cancellation check, including a stop latched
  -- during acquisition. Skipping it would report success without publishing readiness.
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

private def serveProject
    (runtime : RuntimeAccess)
    (opts : CliOptions) : CliM Unit := do
  let root ← projectRoot opts
  withOwnerResponse (fun printReadiness => ExceptT.mk <| withOwnerInterruptWatcher fun watcher =>
    (withProjectDaemonOwner runtime.resolve root
      (explicitControlDir? := opts.explicitControlDir?) fun owner => do
        IO.eprintln "beam: loading Lake workspace configuration..."
        ensureProjectSession watcher root owner.client
        if (← watcher.interrupted) || (← IO.checkCanceled) then
          throw CliFailure.cancelled
        printReadiness <| Response.success <| toJson <|
          mkSessionStatus .running root owner.client.controlDir (some owner.generation)
        IO.eprintln <|
          "beam: serving Beam session; interrupt this process or run when finished:\n" ++
          wrapperSessionCommand root owner.client.controlDir .stop
        runThenHoldUntilInterrupted watcher owner (pure ())).run) opts.jsonOutputFormat

private def sessionStatus (opts : CliOptions) : CliM Unit := do
  let root ← inspectionRoot opts
  let sessionDir ← Beam.Daemon.controlDirFor root opts.explicitControlDir?
  let result : SessionStatus ←
    match ← observeProjectRegistry root opts.explicitControlDir? with
    | .absent => pure <| mkSessionStatus .absent root sessionDir
    | .live entry => pure <| mkSessionStatus .running root sessionDir (some entry.daemonId)
    | .selectorMismatch entry =>
        throw <| selectorMismatchFailure root sessionDir entry
    | .recoveryRequired (.unusable entry .shutdownUnconfirmed) =>
        pure <| mkSessionStatus .shutdownUnconfirmed root sessionDir (some entry.daemonId)
          (some RegistryUnsafeReason.shutdownUnconfirmed.message)
    | .recoveryRequired blocker =>
        pure <| mkSessionStatus .recoveryRequired root sessionDir blocker.generation?
          (some blocker.statusDetail)
    | .unresponsive entry failure =>
        pure <| mkSessionStatus .unresponsive root sessionDir (some entry.daemonId)
          (some failure.detail)
  printResponse (.success (toJson result)) none opts.jsonOutputFormat

private def dispatchCommand (installation : Installation) (opts : CliOptions) : CliM Unit := do
  match installation.admitCommand opts.args with
  | .ok () => pure ()
  | .error rejection => throw <| .usage rejection.message
  let home := installation.home
  let runtime := installation.runtime
  match opts.args with
  | ["-h"] | ["--help"] | ["help"] =>
      IO.println installation.usage
  | "version" :: [] | "--version" :: [] =>
      printVersion installation.cliIdentity
  | "toolchain-build-info" :: [] =>
      printJsonLine compilerBuildInfo opts.jsonOutputFormat
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
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let root ← projectRoot opts
      let action := "hover"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanHoverRequest path version line character)
          (leanHoverWaitSpec path line character action) opts.jsonOutputFormat
  | "signature-help" :: path :: versionText :: line :: character :: [] =>
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let root ← projectRoot opts
      let action := "signature-help"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSignatureHelpRequest path version line character)
          (leanSignatureHelpWaitSpec path line character action) opts.jsonOutputFormat
  | "definition" :: path :: versionText :: line :: character :: [] =>
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let root ← projectRoot opts
      let action := "definition"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDefinitionRequest path version line character)
          (leanDefinitionWaitSpec path line character action) opts.jsonOutputFormat
  | "references" :: path :: versionText :: line :: character :: extra =>
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let includeDeclaration ← parseLeanReferencesArgs extra
      let root ← projectRoot opts
      let action := "references"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanReferencesRequest path version line character includeDeclaration)
          (leanReferencesWaitSpec path line character action) opts.jsonOutputFormat
  | "document-symbols" :: path :: versionText :: [] =>
      let version ← parseNatArg "version" versionText
      let root ← projectRoot opts
      let action := "document-symbols"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanDocumentSymbolsRequest path version)
          (leanDocumentSymbolsWaitSpec path action) opts.jsonOutputFormat
  | "workspace-symbols" :: queryParts =>
      let query ←
        match joinTextArgs queryParts with
        | some query => pure query
        | none => throw <| commandUsageFailure ["workspace-symbols"]
      let root ← projectRoot opts
      let action := "workspace-symbols"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanWorkspaceSymbolsRequest query)
          (leanWorkspaceSymbolsWaitSpec query action) opts.jsonOutputFormat
  | "goals" :: modeText :: path :: versionText :: line :: character :: [] =>
      let mode ← parseLeanGoalsModeArg modeText
      let version ← parseNatArg "version" versionText
      let line ← parseNatArg "line" line
      let character ← parseNatArg "character" character
      let root ← projectRoot opts
      let action := "goals"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanGoalsRequest path version line character mode)
          (leanGoalsWaitSpec path line character mode (some action)) opts.jsonOutputFormat
  | "todo" :: path :: versionText :: rest => do
      let version ← parseNatArg "version" versionText
      -- The range is optional: four positional numbers before any option.
      let (range?, extra) ← match rest with
        | startLine :: startCharacter :: endLine :: endCharacter :: extra =>
            if [startLine, startCharacter, endLine, endCharacter].all (!·.startsWith "--") then
              pure (some ({
                start := {
                  line := ← parseNatArg "startLine" startLine
                  character := ← parseNatArg "startCharacter" startCharacter
                }
                «end» := {
                  line := ← parseNatArg "endLine" endLine
                  character := ← parseNatArg "endCharacter" endCharacter
                }
              } : Lean.Lsp.Range), extra)
            else
              pure (none, rest)
        | _ => pure (none, rest)
      let kinds? ← parseLeanTodoArgs extra
      let root ← projectRoot opts
      let action := "todo"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanTodoRequest path version range? kinds?)
          (leanTodoWaitSpec path range? action)
          opts.jsonOutputFormat
  | "run-with" :: path :: args =>
      runLeanRunWith runtime opts "run-with" path args
  | "run-with-linear" :: path :: args =>
      runLeanRunWith runtime opts "run-with-linear" path args
        (linear := true)
  | "release" :: path :: args =>
      runLeanRelease runtime opts "release" path args
  | "save" :: path :: extra => do
      let diagnosticScope ← parseLeanSaveArgs extra
      let root ← projectRoot opts
      let action := "save"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (action? := some action)) opts.jsonOutputFormat
  | "update" :: path :: [] =>
      let root ← projectRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client (leanUpdateRequest path) opts.jsonOutputFormat
  | "sync" :: path :: extra => do
      let diagnosticScope ← parseLeanSyncArgs extra
      let root ← projectRoot opts
      let action := "sync"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanSyncRequest path diagnosticScope)
          (syncWaitSpec path action) opts.jsonOutputFormat
  | "refresh" :: path :: extra => do
      let diagnosticScope ← parseLeanRefreshArgs extra
      let root ← projectRoot opts
      let action := "refresh"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanRefreshRequest path diagnosticScope)
          (refreshWaitSpec path action) opts.jsonOutputFormat
  | "close" :: path :: [] =>
      let root ← projectRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client (leanCloseRequest path) opts.jsonOutputFormat
  | "close-save" :: path :: extra =>
      let diagnosticScope ← parseLeanCloseSaveArgs extra
      let root ← projectRoot opts
      let action := "close-save"
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBrokerWithProgress root client
          (leanCloseSaveRequest path diagnosticScope)
          (leanSaveWaitSpec path (closeAfter := true) (action? := some action)) opts.jsonOutputFormat
  | "doctor" :: [] =>
      doctor home installation.doctorLines opts
  | "doctor" :: ["--json"] =>
      doctor home installation.doctorLines opts (json := true)
  | "doctor" :: ["--help"] =>
      IO.println ((commandUsage? "doctor").getD "lean-beam doctor [--json]")
  | "open-files" :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.openDocs opts.jsonOutputFormat
  | "cancel" :: requestId :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client (Request.cancel requestId) opts.jsonOutputFormat
  | "stats" :: [] =>
      let root ← inspectionRoot opts
      withProjectDaemon runtime.attachment root (explicitControlDir? := opts.explicitControlDir?) fun client =>
        callBroker root client Request.stats opts.jsonOutputFormat
  | "status" :: [] =>
      sessionStatus opts
  | "stop" :: [] =>
      stopProjectSession runtime opts
  | "recover" :: args =>
      recoverProjectSession runtime opts args
  | args => throw <| commandUsageFailure args

/-- Give local parser failures the relevant command syntax without changing broker failures. -/
def runCommand (installation : Installation) (opts : CliOptions) : CliM UInt32 := do
  try
    match opts.args with
    | "doctor" :: "clients" :: args => ClientDoctor.command opts args
    | _ => dispatchCommand installation opts; return 0
  catch failure =>
    if failure.exitCode == 2 && failure.usage?.isNone then
      throw { failure with
        usage? := opts.args.head?.bind commandUsage?
        jsonOutputFormat := opts.jsonOutputFormat
      }
    else throw { failure with jsonOutputFormat := opts.jsonOutputFormat }

end Beam.Cli
