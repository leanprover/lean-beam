/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Broker.Errors
import Beam.Cli.Args
import Beam.Output
import Beam.Workspace
import Beam.JsonPretty
import Beam.LSP.RunAt

open Lean

namespace Beam.Cli

open Beam.Broker

def boolText (value : Bool) : String :=
  if value then "true" else "false"

private def hexDigit (n : Nat) : Char :=
  if n < 10 then
    Char.ofNat (48 + n)
  else
    Char.ofNat (87 + n)

private def hexByte (byte : UInt8) : String :=
  let n := byte.toNat
  String.singleton (hexDigit (n / 16)) ++ String.singleton (hexDigit (n % 16))

private def utf8Hex (bytes : ByteArray) : String :=
  String.intercalate " " <| Id.run do
    let mut parts : Array String := #[]
    for byte in bytes do
      parts := parts.push (hexByte byte)
    return parts.toList

private def diagnosticSeverityLabel : Option Lsp.DiagnosticSeverity → String
  | some .error => "error"
  | some .warning => "warning"
  | some .information => "info"
  | some .hint => "hint"
  | none => "diagnostic"

private def condenseDiagnosticMessage (message : String) : String :=
  String.intercalate " / " <|
    ((message.split (· == '\n')).toList.map (fun line => line.trimAscii.toString)).filter
      (fun line => !line.isEmpty)

def formatStreamDiagnostic (diagnostic : StreamDiagnostic) : String :=
  let pos := diagnostic.range.start
  let line := pos.line + 1
  let character := pos.character + 1
  let severity := diagnosticSeverityLabel diagnostic.severity?
  let message := condenseDiagnosticMessage diagnostic.message
  let blocking :=
    if diagnostic.completionBlocking then
      " completionBlocking=true"
    else
      ""
  s!"beam: diagnostic {severity}{blocking} {diagnostic.path}:{line}:{character}: {message}"

/-- CLI-only line recovery after a raw-output gap; no text is retained here. -/
structure WorkspaceOutputFormat where
  atLineStart : Bool := true
  skippingLine : Bool := false

def WorkspaceOutputFormat.render (state : WorkspaceOutputFormat)
    (chunk : Beam.WorkspaceOutput.Chunk) : WorkspaceOutputFormat × String := Id.run do
  let marker := if chunk.omittedBefore then
      (if state.atLineStart then "" else "\n") ++ "beam: earlier workspace output omitted\n"
    else ""
  let skipping := state.skippingLine || chunk.omittedBefore
  let afterLine := if skipping then (chunk.text.dropWhile (· != '\n')).toString else ""
  let text := if skipping then (afterLine.drop 1).toString else chunk.text
  let skippingLine := skipping && afterLine.isEmpty
  let atLineStart := if !text.isEmpty then text.endsWith "\n"
    else if chunk.omittedBefore then true else state.atLineStart
  return ({ atLineStart, skippingLine }, marker ++ text)

/-- Public JSON prepared for one final write, with the original outcome retained as evidence. -/
structure PreparedResponse where
  json : Json
  observed : Response
  clientRequestId? : Option String := none

private def responseJson (result : Except Beam.Output.OutputError Json)
    (clientRequestId? : Option String) : Json :=
  let fields := match result with
    | .ok result => [("ok", toJson true), ("result", result)]
    | .error error => [("ok", toJson false), ("error", error.json)]
  Json.mkObj <| fields ++ clientRequestId?.toList.map (fun id => ("client_request_id", toJson id))

/-- Control commands already supply their public result; broker failures use the common presenter. -/
def prepareControlResponse (resp : Response) (clientRequestId? : Option String := none) : PreparedResponse := {
  json := responseJson (match resp with
    | .errorResult failure => .error <| Beam.Output.OutputError.fromControlFailure failure
    | .successResult .. => Beam.Output.projectResponse .opaque resp) clientRequestId?
  observed := resp
  clientRequestId?
}

/-- The production operation preparation path, also exercised by cross-surface contract tests. -/
def prepareOperationResponse
    (operation : Beam.Output.Operation) (resp : Response)
    (clientRequestId? : Option String := none)
    (workspaceRoot? : Option System.FilePath := none) : Except Beam.Output.OutputError PreparedResponse := do
  let result ← Beam.Output.projectResponse operation resp
  let result := match workspaceRoot? with
    | some root => Beam.Workspace.addWorkspaceDescriptor root result
    | none => result
  pure { json := responseJson (.ok result) clientRequestId?, observed := resp, clientRequestId? }

def renderJsonOutput (json : Json) (format : JsonOutputFormat := .compact) : String :=
  match format with
  | .compact => Beam.orderedJsonCompact json
  | .pretty => Beam.orderedJsonPretty json

private def writeResponse (response : PreparedResponse) (format : JsonOutputFormat) : IO Unit := do
  IO.println <| renderJsonOutput response.json format
  (← IO.getStdout).flush

/-- A failed write may have emitted a prefix: preserve the raw outcome and never write a second reply. -/
private def printPreparedResponse (response : PreparedResponse) (format : JsonOutputFormat) : CliM Unit := do
  match ← (writeResponse response format).toBaseIO with
  | .ok () => pure ()
  | .error error =>
      let failure := CliFailure.responseOutput response.observed error response.clientRequestId?
      throw { failure with jsonOutputFormat := format }

/-- Write a control-command response through the same final writer as Lean operation responses. -/
def printResponse
    (resp : Response)
    (clientRequestId? : Option String := none)
    (format : JsonOutputFormat := .compact) : CliM Unit :=
  printPreparedResponse (prepareControlResponse resp clientRequestId?) format

/-- Attach a prepared public operation error to its original broker outcome. Projection and
progress are already complete; retain the raw response separately for later write-failure evidence. -/
def operationOutputFailure
    (response : Response)
    (error : Beam.Output.OutputError)
    (clientRequestId? : Option String := none)
    (failureDiagnostic? : Option String := none)
    (format : JsonOutputFormat := .compact) : CliFailure :=
  let failure : ResponseFailure := match response with
    | .errorResult failure => failure
    | .successResult .. => {
        error := { code := error.code, message := error.message, data? := error.data? }
        fileProgress? := error.documentProgress?
      }
  { CliFailure.broker failure clientRequestId? with
    publicError? := some error
    diagnostic? := failureDiagnostic?
    jsonOutputFormat := format
  }

/-- Project only at the public output edge, after operation and cleanup outcomes have settled. -/
def printOperationResponse
    (operation : Beam.Output.Operation) (resp : Response)
    (clientRequestId? : Option String := none)
    (format : JsonOutputFormat := .compact)
    (workspaceRoot? : Option System.FilePath := none)
    (failureDiagnostic? : Option String := none) : CliM Unit := do
  let prepared ← match prepareOperationResponse operation resp clientRequestId? workspaceRoot? with
    | .ok response => pure response
    | .error error =>
      throw <| operationOutputFailure resp error clientRequestId? failureDiagnostic? format
  printPreparedResponse prepared format

/-- Keep an owner's output-attempt guard alive through acquisition, use, and cleanup.
The supplied writer marks the attempt before writing, even if cleanup later replaces its failure. -/
def withOwnerResponse
    (act : (Response → CliM Unit) → CliM Unit)
    (format : JsonOutputFormat := .compact) : CliM Unit := do
  let responseStarted ← IO.mkRef false
  let printFinalResponse := fun response => do
    responseStarted.set true
    printResponse response none format
  let outcome ← (act printFinalResponse).run.toBaseIO
  match outcome with
  | .ok (.ok ()) => pure ()
  | .ok (.error failure) =>
      throw { failure with responseStarted := failure.responseStarted || (← responseStarted.get) }
  | .error error => throw { CliFailure.internal error with responseStarted := ← responseStarted.get }

/-- Check setup outcomes without emitting an operation result. -/
def failOnError (resp : Response) (clientRequestId? : Option String := none) : CliM Unit := do
  match resp with
  | .successResult .. => pure ()
  | .errorResult failure => throw <| CliFailure.broker failure clientRequestId?

def printJsonLine (json : Json) (format : JsonOutputFormat := .compact) : IO Unit := do
  IO.println <| renderJsonOutput json format

def envClientRequestId? : IO (Option String) := do
  match ← IO.getEnv "BEAM_REQUEST_ID" with
  | some raw =>
      let trimmed := raw.trimAscii.toString
      pure <| if trimmed.isEmpty then none else some trimmed
  | none =>
      pure none

def withEnvClientRequestId (req : Request) : IO Request := do
  pure { req with clientRequestId? := req.clientRequestId? <|> (← envClientRequestId?) }

def annotateRequestMessage (clientRequestId? : Option String) (msg : String) : String :=
  match clientRequestId? with
  | some clientRequestId =>
      if msg.startsWith "beam:" then
        s!"beam[{clientRequestId}]:" ++ (msg.drop 5).toString
      else
        s!"beam[{clientRequestId}]: {msg}"
  | none =>
      msg

private def debugTextEnabled : IO Bool := do
  pure <| (← envFlag? "BEAM_DEBUG_TEXT").getD false

def maybeEmitTextDebug
    (clientRequestId? : Option String)
    (action source text : String) : IO Unit := do
  if !(← debugTextEnabled) then
    pure ()
  else
    let bytes := text.toUTF8
    let containsLiteralBackslashN := hasSubstring text "\\n"
    IO.eprintln <| annotateRequestMessage clientRequestId?
      s!"beam: debug text for {action}: source={source} utf8Bytes={bytes.size} containsNewline={boolText (text.contains '\n')} containsLiteralBackslashN={boolText containsLiteralBackslashN}"
    IO.eprintln <| annotateRequestMessage clientRequestId?
      s!"beam: debug text escaped={(Json.str text).compress}"
    IO.eprintln <| annotateRequestMessage clientRequestId?
      s!"beam: debug text utf8Hex={utf8Hex bytes}"

/-- Why a broker response could not be decoded as the expected typed result. -/
inductive ResponseResultError where
  | broker (failure : ResponseFailure)
  | invalidPayload (detail : String)

/-- Decode a broker response while preserving broker failure and malformed-payload distinctions. -/
def decodeResponseResult [FromJson α] (resp : Response) : Except ResponseResultError α :=
  match resp with
  | .successResult result _ =>
      (fromJson? result).mapError ResponseResultError.invalidPayload
  | .errorResult failure =>
      .error <| .broker failure

def decodeRunAtResult? (resp : Response) : Option Beam.LSP.RunAt.Result :=
  (decodeResponseResult resp).toOption

def responseErrorSummary? (action : String) (resp : Response) : Option String :=
  resp.error?.map fun err =>
    s!"beam: {action} request returned an error ({err.code}): {err.message}"

private def jsonStringArrayField? (json : Json) (field : String) : Option (Array String) := do
  let .ok (.arr values) := json.getObjVal? field
    | none
  values.foldlM (init := #[]) fun acc value =>
    match value with
    | .str text => some (acc.push text)
    | _ => none

private def recoveryPlanText? (steps : Array String) : Option String :=
  if steps.isEmpty then
    none
  else
    let quotedSteps := steps.map fun step => s!"`{step}`"
    some <| "run " ++ String.intercalate "; then " quotedSteps.toList ++
      "; stop if a step fails; after refresh succeeds, inspect its diagnostics and save readiness"

def responseRecoveryHint? (resp : Response) : Option String := do
  let err ← resp.error?
  if err.code == syncBarrierIncompleteCode then
    let recoveryText? :=
      match err.data?.bind (jsonStringArrayField? · "recoveryPlan") with
      | some steps => recoveryPlanText? steps
      | none => none
    recoveryText?.map fun recoveryText => s!"beam: recovery: {recoveryText}"
  else do
    let data ← err.data?
    let .ok recovery := (data.getObjValAs? WorkerRecovery "recovery") | none
    let hint := match recovery with
      | .newHelper => "the Lake helper exited; a new request creates a fresh helper; inspect save state before deciding whether to repeat a save"
      | .newBackend => "the Lean backend exited; a new request starts a fresh backend; prior request completion is not established"
      | .restartWorkspace => "backend exit was not confirmed; drop the MCP workspace or stop and restart its owning serve session before issuing new work"
      | .sync uri => s!"the Lean file worker failed; synchronize {uri} with sync / lean_sync before issuing new work"
    some <| "beam: recovery: " ++ hint

def runAtPayloadSummary? (action noun : String) (resp : Response) : Option String :=
  match decodeRunAtResult? resp with
  | some result =>
      if result.success then
        none
      else
        some s!"beam: {action} {noun} failed inside Lean; the request completed and returned result.success=false"
  | none =>
      none

def maybeEmitLiteralBackslashNewlineHint
    (clientRequestId? : Option String)
    (req : Request)
    (resp : Response) : IO Unit := do
  let text? :=
    match req.payload with
    | .runAt request => some request.text
    | .runWith request => some request.text
    | _ => none
  match text?, decodeRunAtResult? resp with
  | some text, some result =>
      if !result.success && hasSubstring text "\\n" && !text.contains '\n' then
        IO.eprintln <| annotateRequestMessage clientRequestId?
          "beam: hint: the probe text contains the literal characters '\\n'; if you meant a real newline, use --stdin or --text-file."
      else
        pure ()
  | _, _ =>
      pure ()

def decodeSyncFileResult? (resp : Response) : Option SyncFileResult :=
  (decodeResponseResult resp).toOption

def decodeUpdateFileResult (resp : Response) : Except ResponseResultError UpdateFileResult :=
  decodeResponseResult resp

def responseFileProgress? (resp : Response) : Option SyncFileProgress :=
  resp.fileProgress?

def syncFileProgressSuffix (progress? : Option SyncFileProgress) : String :=
  match progress? with
  | none => ""
  | some progress =>
      s!", fp {SyncFileProgress.displayDetails progress (includeDoneTrue := false)}"

/-- Preserve a prepared operation error; only local/control failures still need presentation. -/
def prepareFailureResponse (failure : CliFailure) : PreparedResponse := {
  json := responseJson (.error <| match failure.publicError? with
    | some error => error
    | none => Beam.Output.OutputError.fromControlFailure failure.failure) failure.clientRequestId?
  observed := .errorResult failure.failure
  clientRequestId? := failure.clientRequestId?
}

def renderFailure (failure : CliFailure) : IO UInt32 := do
  unless failure.responseStarted do
    if let .error error ←
        (writeResponse (prepareFailureResponse failure) failure.jsonOutputFormat).toBaseIO then
      IO.eprintln <| escapeDiagnosticText <| annotateRequestMessage failure.clientRequestId?
        s!"beam: could not write the final JSON response: {error}"
  let diagnostic := failure.diagnostic?.getD failure.failure.error.message
  let diagnostic := if diagnostic.startsWith "beam:" then diagnostic else "beam: " ++ diagnostic
  IO.eprintln <| escapeDiagnosticText <| annotateRequestMessage failure.clientRequestId? diagnostic
  if let some command := failure.remedyCommand? then
    let display := escapeDiagnosticText command
    if display == command then IO.eprintln command
    else IO.eprintln s!"remedy (escaped display; exact command in error.data.remedy_command): {display}"
  if let some usage := failure.usage? then IO.eprintln <| escapeDiagnosticText usage
  return failure.exitCode

/-- Catch unexpected IO faults once; they are never reclassified as user input errors. -/
def run (action : CliM UInt32) : IO UInt32 := do
  let outcome ← action.run.toBaseIO
  let failure ← match outcome with
    | .ok (.ok code) => return code
    | .ok (.error failure) => pure failure
    | .error error => pure (CliFailure.internal error)
  -- Rendering gets one attempt. A broken stdout/stderr must not enter a fallback
  -- that appends another JSON response or erases the original exit status.
  match ← (renderFailure failure).toBaseIO with
  | .ok code => pure code
  | .error _ => pure failure.exitCode

end Beam.Cli
