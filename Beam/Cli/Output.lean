/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Cli.Args
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

/-- Render a CLI response, optionally adding caller-visible correlation at the presentation edge. -/
def responseOutputJson (resp : Response) (clientRequestId? : Option String := none) : Json :=
  match clientRequestId? with
  | some clientRequestId =>
      (toJson resp).setObjVal! "clientRequestId" (toJson clientRequestId)
  | none =>
      toJson resp

def printResponse (resp : Response) (clientRequestId? : Option String := none) : IO Unit := do
  IO.println <| Beam.orderedJsonPretty (responseOutputJson resp clientRequestId?)

def failOnError (resp : Response) (clientRequestId? : Option String := none) : CliM Unit := do
  match resp with
  | .successResult .. => pure ()
  | .errorResult failure => throw <| CliFailure.broker failure clientRequestId?

def printJsonLine (json : Json) : IO Unit := do
  IO.println <| Beam.orderedJsonPretty json

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

def responseErrorSummary? (action failureBoundary : String) (resp : Response) : Option String :=
  resp.error?.map fun err =>
    s!"beam: {action} request failed {failureBoundary} ({err.code}): {err.message}"

private def jsonStringField? (json : Json) (field : String) : Option String := do
  match json.getObjVal? field with
  | .ok (.str value) => some value
  | _ => none

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
    some <| "try " ++ String.intercalate "; then " quotedSteps.toList

private def syncBarrierFallbackRecovery? (data? : Option Json) : Option String :=
  match data?.bind (jsonStringField? · "targetPath") with
  | some targetPath =>
      some <|
        s!"run `lean-beam refresh \"{targetPath}\"` after saving changed dependencies; " ++
        "if that still fails, run `lake build` or fix the upstream module first"
  | none =>
      some "run `lake build` or fix the upstream module first"

def responseRecoveryHint? (resp : Response) : Option String := do
  let err ← resp.error?
  if err.code == syncBarrierIncompleteCode then
    let recoveryText? :=
      match err.data?.bind (jsonStringArrayField? · "recoveryPlan") with
      | some steps => recoveryPlanText? steps
      | none => syncBarrierFallbackRecovery? err.data?
    recoveryText?.map fun recoveryText => s!"beam: recovery: {recoveryText}"
  else
    none

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

def renderFailure (failure : CliFailure) : IO UInt32 := do
  unless failure.responsePublished do
    printResponse (.errorResult failure.failure) failure.clientRequestId?
  let diagnostic := failure.diagnostic?.getD failure.failure.error.message
  let diagnostic := String.intercalate "; " <|
    (diagnostic.splitOn "\n").filter (fun line => !line.isEmpty)
  let diagnostic := if diagnostic.startsWith "beam:" then diagnostic else "beam: " ++ diagnostic
  IO.eprintln <| annotateRequestMessage failure.clientRequestId? diagnostic
  if let some usage := failure.usage? then IO.eprintln usage
  return failure.exitCode

/-- Catch unexpected IO faults once; they are never reclassified as user input errors. -/
def run (action : CliM Unit) : IO UInt32 := do
  let outcome ← action.run.toBaseIO
  match outcome with
  | .ok (.ok ()) => pure 0
  | .ok (.error failure) => renderFailure failure
  | .error error => renderFailure (.internal error)

end Beam.Cli
