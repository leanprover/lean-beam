/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Cli.Error
import Beam.Path
import Beam.LSP.Todo

open Lean

namespace Beam.Cli

open Beam.Broker

structure CliOptions where
  explicitRoot? : Option System.FilePath := none
  explicitControlDir? : Option System.FilePath := none
  args : List String := []

structure ParsedTextArg where
  text : String
  source : String := "argv"

def parseNatArg (name value : String) : CliM Nat := do
  let some n := value.toNat?
    | throw <| CliFailure.usage s!"invalid {name} '{value}'"
  pure n

def joinTextArgs (args : List String) : Option String :=
  if args.isEmpty then none else some <| String.intercalate " " args

def hasSubstring (text needle : String) : Bool :=
  match text.splitOn needle with
  | [_] => false
  | _ => true

def textArgUsage (cmdHead : String) : String :=
  s!"usage: lean-beam [--root PATH] {cmdHead} (--stdin | --text-file <path> | -- <text...> | <text...>)"

def textArgReadsStdin (args : List String) : Bool :=
  match args with
  | ["--stdin"] => true
  | _ => false

def parseTextArg (cmdHead : String) (args : List String) : CliM ParsedTextArg := do
  match args with
  | [] => throw <| CliFailure.usage s!"missing or invalid text arguments for {cmdHead}: {String.intercalate " " args}" (some (textArgUsage cmdHead))
  | ["--stdin"] =>
      pure { text := ← (← IO.getStdin).readToEnd, source := "stdin" }
  | ["--text-file", path] =>
      pure { text := ← readCliFile "--text-file" path, source := s!"text-file:{path}" }
  | "--" :: rest => do
      let some text := joinTextArgs rest
        | throw <| CliFailure.usage s!"missing or invalid text arguments for {cmdHead}: {String.intercalate " " args}" (some (textArgUsage cmdHead))
      pure { text, source := "argv" }
  | "--stdin" :: _ =>
      throw <| CliFailure.usage s!"missing or invalid text arguments for {cmdHead}: {String.intercalate " " args}" (some (textArgUsage cmdHead))
  | "--text-file" :: _ =>
      throw <| CliFailure.usage s!"missing or invalid text arguments for {cmdHead}: {String.intercalate " " args}" (some (textArgUsage cmdHead))
  | _ => do
      let some text := joinTextArgs args
        | throw <| CliFailure.usage s!"missing or invalid text arguments for {cmdHead}: {String.intercalate " " args}" (some (textArgUsage cmdHead))
      pure { text, source := "argv" }

def parseJsonText (label text : String) : CliM Json := do
  match Json.parse text with
  | .ok json => pure json
  | .error err => throw <| CliFailure.usage s!"invalid {label}: {err}"

def handleArgUsage (cmdHead : String) : String :=
  s!"usage: lean-beam [--root PATH] {cmdHead} <handle-json|-|--handle-file <path>>"

def handleArgReadsStdin (args : List String) : Bool :=
  match args with
  | "-" :: _ => true
  | _ => false

private def extractHandleJson (json : Json) : Json :=
  match json.getObjVal? "handle" with
  | .ok handle => handle
  | .error _ =>
      match json.getObjVal? "result" with
      | .ok result =>
          match result.getObjVal? "handle" with
          | .ok handle => handle
          | .error _ => json
      | .error _ => json

def parseHandleText (raw : String) : CliM Handle := do
  let json ← parseJsonText "handle json" raw
  match fromJson? (extractHandleJson json) with
  | .ok handle => pure handle
  | .error err =>
      throw <| CliFailure.usage s!"invalid handle payload: {err}"

def parseHandleArg (arg : String) : CliM Handle := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseHandleText raw

def parseHandleInput (cmdHead : String) (args : List String) : CliM (Handle × List String) := do
  match args with
  | [] =>
      throw <| CliFailure.usage s!"missing handle input for {cmdHead}" (some (handleArgUsage cmdHead))
  | "--handle-file" :: path :: rest =>
      pure ((← parseHandleText (← readCliFile "--handle-file" path)), rest)
  | "--handle-file" :: _ =>
      throw <| CliFailure.usage s!"missing handle input for {cmdHead}" (some (handleArgUsage cmdHead))
  | arg :: rest =>
      pure ((← parseHandleArg arg), rest)

private def parseLeanDiagnosticScopeArgs
    (command : String)
    (args : List String) : CliM Beam.Broker.DiagnosticScope :=
  let usage := s!"usage: lean-beam [--root PATH] {command} <path> [+all-diagnostics]"
  match args with
  | [] => pure Beam.Broker.DiagnosticScope.errors
  | ["+all-diagnostics"] => pure Beam.Broker.DiagnosticScope.all
  | _ => throw <| CliFailure.usage s!"invalid {command} arguments: {String.intercalate " " args}" (some usage)

def parseLeanSyncArgs (args : List String) : CliM Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "sync" args

def parseLeanRefreshArgs (args : List String) : CliM Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "refresh" args

def parseLeanSaveArgs (args : List String) : CliM Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "save" args

def parseLeanCloseSaveArgs (args : List String) : CliM Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "close-save" args

def leanReferencesUsage : String :=
  "usage: lean-beam [--root PATH] references <path> <version> <line> <character> [--include-declaration|--exclude-declaration]"

def parseLeanReferencesArgs (args : List String) : CliM Bool := do
  match args with
  | [] => pure true
  | ["--include-declaration"] => pure true
  | ["--exclude-declaration"] => pure false
  | _ => throw <| CliFailure.usage s!"invalid references arguments: {String.intercalate " " args}" (some leanReferencesUsage)

def leanGoalsUsage : String :=
  "usage: lean-beam [--root PATH] goals before|after <path> <version> <line> <character>"

def parseLeanGoalsModeArg (mode : String) : CliM GoalMode := do
  match mode with
  | "before" => pure .before
  | "after" => pure .after
  | _ => throw <| CliFailure.usage s!"invalid goals mode '{mode}'" (some leanGoalsUsage)

private def parseTodoKindArg (value : String) : CliM Beam.LSP.Todo.TodoKind := do
  match fromJson? (α := Beam.LSP.Todo.TodoKind) (Json.str value) with
  | .ok kind => pure kind
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoKind.allKeys.toList
      throw <| CliFailure.usage s!"invalid todo kind '{value}' (expected one of: {allowed}): {err}"

private def parseTodoSuggestArg (value : String) : CliM Beam.LSP.Todo.TodoSuggestMode := do
  match fromJson? (α := Beam.LSP.Todo.TodoSuggestMode) (Json.str value) with
  | .ok mode => pure mode
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoSuggestMode.allKeys.toList
      throw <| CliFailure.usage s!"invalid todo suggest mode '{value}' (expected one of: {allowed}): {err}"

def leanTodoUsage : String :=
  "usage: lean-beam [--root PATH] todo <path> <version> <startLine> <startCharacter> <endLine> <endCharacter> [--kind <kind> ...] [--suggest none|basic]"

def parseLeanTodoArgs (args : List String) :
    CliM (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
  let rec loop
      (args : List String)
      (kinds : Array Beam.LSP.Todo.TodoKind)
      (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) :
      CliM (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
    match args with
    | [] =>
        pure (if kinds.isEmpty then none else some kinds, suggest?)
    | "--kind" :: kind :: rest =>
        loop rest (kinds.push (← parseTodoKindArg kind)) suggest?
    | "--kind" :: _ =>
        throw <| CliFailure.usage s!"invalid todo arguments: {String.intercalate " " args}" (some leanTodoUsage)
    | "--suggest" :: mode :: rest =>
        loop rest kinds (some (← parseTodoSuggestArg mode))
    | "--suggest" :: _ =>
        throw <| CliFailure.usage s!"invalid todo arguments: {String.intercalate " " args}" (some leanTodoUsage)
    | _ =>
        throw <| CliFailure.usage s!"invalid todo arguments: {String.intercalate " " args}" (some leanTodoUsage)
  loop args #[] none

def shellQuote (text : String) : String :=
  "'" ++ text.replace "'" "'\\''" ++ "'"

inductive WrapperSessionCommand where
  | serve
  | status
  | stop
  | recoverGeneration (generation : String)

private def WrapperSessionCommand.text : WrapperSessionCommand → String
  | .serve => "serve"
  | .status => "status"
  | .stop => "stop"
  | .recoverGeneration generation =>
      s!"recover --generation {shellQuote generation}"

/-- Render one exact public wrapper-session command selector. -/
def wrapperSessionCommand
    (root sessionDir : System.FilePath)
    (command : WrapperSessionCommand) : String :=
  s!"lean-beam --root {shellQuote root.toString} " ++
    s!"--session-dir {shellQuote sessionDir.toString} {command.text}"

def parseEnvFlag (raw : String) : Bool :=
  let normalized := raw.trimAscii.toString.toLower
  !(normalized.isEmpty || normalized == "0" || normalized == "false" || normalized == "no")

def envFlag? (name : String) : IO (Option Bool) := do
  match ← IO.getEnv name with
  | some raw => pure <| some (parseEnvFlag raw)
  | none => pure none

private def resolveExplicitRootArg (root : String) : CliM System.FilePath := do
  let path ← match ← (Beam.resolveExistingPath (System.FilePath.mk root)).toBaseIO with
    | .ok path => pure path
    | .error error => throw <| .usage s!"workspace root does not resolve (--root '{root}'): {error}"
  unless ← path.isDir do
    throw <| .usage s!"workspace root is not a directory (--root '{root}')"
  pure path

private def resolveSessionDirArg (dir : String) : CliM System.FilePath := do
  let path := System.FilePath.mk dir
  unless path.isAbsolute do
    throw <| .usage s!"--session-dir requires an absolute path, got '{path}'"
  match ← path.symlinkMetadata.toBaseIO with
  | .ok metadata =>
      if metadata.type == .symlink then
        throw <| .usage s!"--session-dir does not accept a symbolic-link leaf: '{path}'"
      Beam.resolveExistingPath path
  | .error (.noFileOrDirectory ..) => Beam.resolvePathForCreation path
  | .error error => throw <| .usage s!"cannot inspect --session-dir '{path}': {error}"

partial def parseCliOptions (opts : CliOptions) : List String → CliM CliOptions
  | "--root" :: root :: rest => do
      let root ← resolveExplicitRootArg root
      parseCliOptions { opts with explicitRoot? := some root } rest
  | ["--root"] => throw <| .usage "--root requires PATH" (some "usage: lean-beam --root PATH <command> ...")
  | "--session-dir" :: dir :: rest => do
      let dir ← resolveSessionDirArg dir
      parseCliOptions { opts with explicitControlDir? := some dir } rest
  | ["--session-dir"] => throw <| .usage "--session-dir requires DIR" (some "usage: lean-beam [--root PATH] --session-dir DIR <command> ...")
  | rest =>
      -- Global selectors are prefixes; command-level Lean text remains opaque here.
      pure { opts with args := rest }

end Beam.Cli
