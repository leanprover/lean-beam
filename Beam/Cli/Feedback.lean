/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Client
import Beam.Cli.Args
import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Cli.Project
import Beam.Daemon.Debug
import Beam.Daemon.Paths
import Beam.Feedback
import Beam.Feedback.Broker
import Beam.System
import Beam.Version

open Lean

namespace Beam.Cli.Feedback

open Beam.Broker

private structure Options where
  input? : Option String := none
  bundle? : Option Beam.Feedback.BundleMode := none
  outputDir? : Option System.FilePath := none
  redact? : Option Bool := none

private def usage : String :=
  "usage: lean-beam [--pretty] [--root PATH] feedback-report --stdin|--input <path> [--bundle none|dir|zip] [--output-dir <path>] [--no-redact]"

private def inputShapeHelp : String :=
  s!"input must be a JSON object with required string fields: {Beam.Feedback.requiredInputFieldsText}"

private def help : String :=
  String.intercalate "\n" [
    usage,
    "",
    "Beam does not upload or submit feedback. This command prints report JSON to stdout and, if requested, writes a local evidence bundle.",
    "",
    inputShapeHelp,
    s!"optional fields: {String.intercalate ", " Beam.Feedback.optionalInputFields.toList}",
    "request and response must be JSON objects when supplied",
    "kind values: bug, ux, perf, docs, question",
    "severity values: low, medium, high, critical",
    "privacy: non-confidential output may contain project context and caller payloads, so review it before posting",
    "confidential: set true for non-public workspaces; forces HOME-path redaction and omits automatically collected project debug context, request/response payloads, and evidence",
    "confidential reports retain narrative except for HOME-path redaction; review it for secrets; requested bundle paths remain in the local result; never post a confidential report publicly",
    "example:",
    "  {\"title\":\"Daemon startup failure\",\"kind\":\"bug\",\"severity\":\"high\",\"summary\":\"Beam failed to start\",\"reproduction\":\"lean-beam run-at Demo.lean 1 0\",\"expected\":\"A response is returned.\",\"actual\":\"The daemon closed the connection.\"}"
  ]

private def parseBundleMode (raw : String) : CliM Beam.Feedback.BundleMode := do
  match fromJson? (α := Beam.Feedback.BundleMode) (Json.str raw) with
  | .ok mode => pure mode
  | .error err => throw <| CliFailure.usage s!"invalid feedback bundle mode: {err}"

private partial def parseOptions (opts : Options) : List String → CliM Options
  | [] => pure opts
  | "--stdin" :: rest => do
      let text ← (← IO.getStdin).readToEnd
      parseOptions { opts with input? := some text } rest
  | "--input" :: path :: rest => do
      let text ← readCliFile "--input" path
      parseOptions { opts with input? := some text } rest
  | "--input" :: _ => throw <| CliFailure.usage "--input requires PATH" (some usage)
  | "--bundle" :: mode :: rest => do
      parseOptions { opts with bundle? := some (← parseBundleMode mode) } rest
  | "--bundle" :: _ => throw <| CliFailure.usage "--bundle requires MODE" (some usage)
  | "--output-dir" :: path :: rest => do
      parseOptions { opts with outputDir? := some (System.FilePath.mk path) } rest
  | "--output-dir" :: _ => throw <| CliFailure.usage "--output-dir requires PATH" (some usage)
  | "--no-redact" :: rest =>
      parseOptions { opts with redact? := some false } rest
  | args => throw <| CliFailure.usage s!"invalid feedback-report arguments: {String.intercalate " " args}" (some usage)

private def confidentialIdentityJson : Json :=
  ({ name := Beam.Version.cliName } : Beam.Version.Identity).asJson

private def feedbackDaemonRequestTimeoutMs : Nat :=
  5000

private def collectDaemonRequest
    (label : String)
    (client : ProjectDaemonClient)
    (request : Request)
    (warnings : Array String) : IO (Json × Array String) := do
  let response ← sendRequestWithStreamTimeoutResult client.endpoint
    (client.sealRequest request) feedbackDaemonRequestTimeoutMs (fun _ => pure ())
    (.wrapper client.identity)
  pure <| Beam.Feedback.clientResponsePayloadOrWarning label response warnings

private def collectDaemonPayload
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath)
    (warnings : Array String) : IO (Json × Json × Array String) := do
  match ← observeProjectRegistry root explicitControlDir? with
  | .live entry =>
      let controlDir ← Beam.Daemon.controlDirFor root explicitControlDir?
      let client := ProjectDaemonClient.ofSessionDescriptor entry controlDir
      let (stats, warnings) ← collectDaemonRequest "stats" client Request.stats warnings
      let (openDocs, warnings) ←
        collectDaemonRequest "open-files" client Request.openDocs warnings
      pure (stats, openDocs, warnings)
  | .absent =>
      pure (Json.null, Json.null, warnings.push "no live Beam daemon was available for stats/open-files")
  | .unresponsive entry failure =>
      pure (Json.null, Json.null, warnings.push
        s!"Beam session {entry.daemonId} endpoint did not validate: {failure.detail}")
  | .selectorMismatch entry =>
      let controlDir ← Beam.Daemon.controlDirFor root explicitControlDir?
      pure (Json.null, Json.null, warnings.push <|
        sessionSelectorMismatchMessage root controlDir entry)
  | .recoveryRequired blocker =>
      let controlDir ← Beam.Daemon.controlDirFor root explicitControlDir?
      pure (Json.null, Json.null, warnings.push <| blocker.message root controlDir)

private def collectNonConfidential
    (identity : IO Beam.Version.Identity)
    (root? : Option System.FilePath)
    (explicitControlDir? : Option System.FilePath)
    (warnings : Array String) : IO Beam.Feedback.Collection := do
  let generatedAt ← Beam.utcTimestamp
  let identity := (← identity).asJson
  let (stats, openDocs, daemon, warnings) ←
    match root? with
    | none =>
        pure (Json.null, Json.null, Json.null,
          warnings.push "could not infer project root; daemon debug context was not collected")
    | some root => do
        let daemon ← Beam.Daemon.daemonDebugContextJson root explicitControlDir?
        let (stats, openDocs, warnings) ← collectDaemonPayload root explicitControlDir? warnings
        pure (stats, openDocs, daemon, warnings)
  pure {
    generatedAt
    activeRoot? := root?.map (·.toString)
    data := Json.mkObj [
      ("identity", identity),
      ("stats", stats),
      ("openFiles", openDocs),
      ("daemon", daemon)
    ]
    warnings
  }

private def collectConfidential : IO Beam.Feedback.Collection := do
  pure {
    generatedAt := ← Beam.utcTimestamp
    data := Json.mkObj [("identity", confidentialIdentityJson)]
  }

private def applyOverrides
    (input : Beam.Feedback.Input)
    (opts : Options) : Except String Beam.Feedback.Input := do
  if input.confidential && opts.redact? == some false then
    throw "'confidential' cannot be combined with --no-redact"
  let input :=
    match opts.bundle? with
    | some bundle => { input with bundle }
    | none => input
  pure <|
    match opts.redact? with
    | some redact => { input with redact }
    | none => input

def run (identity : IO Beam.Version.Identity) (cliOpts : CliOptions) (args : List String) : CliM Unit := do
  if args == ["--help"] || args == ["-h"] then
    IO.println help
    return
  let opts ← parseOptions {} args
  let inputText ←
    match opts.input? with
    | some text => pure text
    | none => throw <| CliFailure.usage "feedback-report requires --stdin or --input PATH" (some usage)
  let json ←
    try
      parseJsonText "feedback input json" inputText
    catch failure =>
      throw <| CliFailure.usage s!"invalid feedback input: {inputShapeHelp}; {failure.failure.error.message}"
  let input ←
    match fromJson? (α := Beam.Feedback.Input) json with
    | .ok input => pure input
    | .error err => throw <| CliFailure.usage s!"invalid feedback input: {err}"
  let input ←
    match applyOverrides input opts with
    | .ok input => pure input
    | .error err => throw <| CliFailure.usage s!"invalid feedback input: {err}"
  let needsRoot := !input.confidential || (input.bundle != .none && opts.outputDir?.isNone)
  let (root?, warnings) ←
    if needsRoot then
      try
        let root ← inspectionRoot cliOpts
        pure (some root, #[])
      catch e =>
        pure (none, #[e.failure.error.message])
    else
      pure (none, #[])
  let collection ←
    if input.confidential then collectConfidential
    else collectNonConfidential identity root? cliOpts.explicitControlDir? warnings
  let allowedRoots ←
    if Beam.Feedback.Internal.needsEvidenceRoots input then
      match root? with
      | some root => do
          let control ← Beam.Daemon.controlDirFor root cliOpts.explicitControlDir?
          pure #[root, control]
      | none => pure #[]
    else
      pure #[]
  let result ← Beam.Feedback.buildResult input collection {
    root?
    outputDir? := opts.outputDir?
    allowedRoots
  }
  printJsonLine (Beam.Feedback.Result.toJson result) cliOpts.jsonOutputFormat

end Beam.Cli.Feedback
