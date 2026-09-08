/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Lean.Operation
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

def parseNatArg (name value : String) : IO Nat := do
  let some n := value.toNat?
    | throw <| IO.userError s!"invalid {name} '{value}'"
  pure n

def parseLeanDocumentArgs (path snapshotText : String) : IO Beam.Lean.DocumentInput := do
  pure { path, snapshot := ← IO.ofExcept <| SnapshotRef.decode snapshotText }

def parseLeanPositionArgs
    (path snapshotText lineText characterText : String) : IO Beam.Lean.PositionInput := do
  pure {
    toDocumentInput := ← parseLeanDocumentArgs path snapshotText
    line := ← parseNatArg "line" lineText
    character := ← parseNatArg "character" characterText
  }

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

def parseTextArg (cmdHead : String) (args : List String) : IO ParsedTextArg := do
  match args with
  | [] => throw <| IO.userError (textArgUsage cmdHead)
  | ["--stdin"] =>
      pure { text := ← (← IO.getStdin).readToEnd, source := "stdin" }
  | ["--text-file", path] =>
      pure { text := ← IO.FS.readFile (System.FilePath.mk path), source := s!"text-file:{path}" }
  | "--" :: rest => do
      let some text := joinTextArgs rest
        | throw <| IO.userError (textArgUsage cmdHead)
      pure { text, source := "argv" }
  | "--stdin" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | "--text-file" :: _ =>
      throw <| IO.userError (textArgUsage cmdHead)
  | _ => do
      let some text := joinTextArgs args
        | throw <| IO.userError (textArgUsage cmdHead)
      pure { text, source := "argv" }

def parseJsonText (label text : String) : IO Json := do
  match Json.parse text with
  | .ok json => pure json
  | .error err => throw <| IO.userError s!"invalid {label}: {err}"

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

def parseHandleText (raw : String) : IO Handle := do
  let json ← parseJsonText "handle json" raw
  match fromJson? (extractHandleJson json) with
  | .ok handle => pure handle
  | .error err =>
      throw <| IO.userError s!"invalid handle payload: {err}"

def parseHandleArg (arg : String) : IO Handle := do
  let raw ←
    if arg == "-" then
      (← IO.getStdin).readToEnd
    else
      pure arg
  parseHandleText raw

def parseHandleInput (cmdHead : String) (args : List String) : IO (Handle × List String) := do
  match args with
  | [] =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | "--handle-file" :: path :: rest =>
      pure ((← parseHandleText (← IO.FS.readFile (System.FilePath.mk path))), rest)
  | "--handle-file" :: _ =>
      throw <| IO.userError (handleArgUsage cmdHead)
  | arg :: rest =>
      pure ((← parseHandleArg arg), rest)

private def parseLeanDiagnosticScopeArgs
    (command : String)
    (args : List String) : IO Beam.Broker.DiagnosticScope :=
  let usage := s!"usage: lean-beam [--root PATH] {command} <path> [+all-diagnostics]"
  match args with
  | [] => pure Beam.Broker.DiagnosticScope.errors
  | ["+all-diagnostics"] => pure Beam.Broker.DiagnosticScope.all
  | _ => throw <| IO.userError usage

def parseLeanSyncArgs (args : List String) : IO Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "sync" args

def parseLeanRefreshArgs (args : List String) : IO Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "refresh" args

def parseLeanSaveArgs (args : List String) : IO Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "save" args

def parseLeanCloseSaveArgs (args : List String) : IO Beam.Broker.DiagnosticScope :=
  parseLeanDiagnosticScopeArgs "close-save" args

def leanReferencesUsage : String :=
  "usage: lean-beam [--root PATH] references <path> <snapshot> <line> <character> [--include-declaration|--exclude-declaration]"

def parseLeanReferencesArgs (args : List String) : IO Bool := do
  match args with
  | [] => pure true
  | ["--include-declaration"] => pure true
  | ["--exclude-declaration"] => pure false
  | _ => throw <| IO.userError leanReferencesUsage

def leanGoalsUsage : String :=
  "usage: lean-beam [--root PATH] goals before|after <path> <snapshot> <line> <character>"

def parseLeanGoalsModeArg (mode : String) : IO GoalMode := do
  match mode with
  | "before" => pure .before
  | "after" => pure .after
  | _ => throw <| IO.userError leanGoalsUsage

private def parseTodoKindArg (value : String) : IO Beam.LSP.Todo.TodoKind := do
  match fromJson? (α := Beam.LSP.Todo.TodoKind) (Json.str value) with
  | .ok kind => pure kind
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoKind.allKeys.toList
      throw <| IO.userError s!"invalid todo kind '{value}' (expected one of: {allowed}): {err}"

private def parseTodoSuggestArg (value : String) : IO Beam.LSP.Todo.TodoSuggestMode := do
  match fromJson? (α := Beam.LSP.Todo.TodoSuggestMode) (Json.str value) with
  | .ok mode => pure mode
  | .error err =>
      let allowed := String.intercalate ", " Beam.LSP.Todo.TodoSuggestMode.allKeys.toList
      throw <| IO.userError s!"invalid todo suggest mode '{value}' (expected one of: {allowed}): {err}"

def leanTodoUsage : String :=
  "usage: lean-beam [--root PATH] todo <path> <snapshot> <startLine> <startCharacter> <endLine> <endCharacter> [--kind <kind> ...] [--suggest none|basic]"

def parseLeanTodoArgs (args : List String) :
    IO (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
  let rec loop
      (args : List String)
      (kinds : Array Beam.LSP.Todo.TodoKind)
      (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) :
      IO (Option (Array Beam.LSP.Todo.TodoKind) × Option Beam.LSP.Todo.TodoSuggestMode) := do
    match args with
    | [] =>
        pure (if kinds.isEmpty then none else some kinds, suggest?)
    | "--kind" :: kind :: rest =>
        loop rest (kinds.push (← parseTodoKindArg kind)) suggest?
    | "--kind" :: _ =>
        throw <| IO.userError leanTodoUsage
    | "--suggest" :: mode :: rest =>
        loop rest kinds (some (← parseTodoSuggestArg mode))
    | "--suggest" :: _ =>
        throw <| IO.userError leanTodoUsage
    | _ =>
        throw <| IO.userError leanTodoUsage
  loop args #[] none

def shellQuote (text : String) : String :=
  "'" ++ text.replace "'" "'\\''" ++ "'"

inductive WrapperSessionCommand where
  | serve (backend : Backend)
  | status
  | stop
  | recoverGeneration (generation : String)
  | recoverForce

private def WrapperSessionCommand.text : WrapperSessionCommand → String
  | .serve .lean => "serve"
  | .serve .rocq => "serve rocq"
  | .status => "status"
  | .stop => "stop"
  | .recoverGeneration generation =>
      s!"recover --generation {shellQuote generation}"
  | .recoverForce => "recover --force"

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

private def resolveExplicitRootArg (root : String) : IO System.FilePath := do
  try
    Beam.resolveExistingPath <| System.FilePath.mk root
  catch err =>
    throw <| IO.userError s!"workspace root does not resolve: {err.toString}"

private def resolveSessionDirArg (dir : String) : IO System.FilePath := do
  let path := System.FilePath.mk dir
  unless path.isAbsolute do
    throw <| IO.userError s!"--session-dir requires an absolute path, got '{path}'"
  try
    let metadata ← path.symlinkMetadata
    match metadata.type with
    | .symlink =>
        throw <| IO.userError <|
          s!"--session-dir does not accept a symbolic-link leaf: '{path}'"
    | .dir | .file | .other =>
        Beam.resolveExistingPath path
  catch
  | .noFileOrDirectory .. => Beam.resolvePathForCreation path
  | err => throw err

partial def parseCliOptions (opts : CliOptions) : List String → IO CliOptions
  | "--root" :: root :: rest => do
      let root ← resolveExplicitRootArg root
      parseCliOptions { opts with explicitRoot? := some root } rest
  | "--session-dir" :: dir :: rest => do
      let dir ← resolveSessionDirArg dir
      parseCliOptions { opts with explicitControlDir? := some dir } rest
  | rest =>
      -- Global selectors are prefixes. Once the command starts, its complete argument tail is
      -- opaque here, including a command-level `--` and any Lean text that follows it.
      pure { opts with args := rest }

end Beam.Cli
