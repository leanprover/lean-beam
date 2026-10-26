/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Error

namespace Beam.Cli

def commandUsages : List (String × String) := [
  ("--version", "lean-beam --version"),
  ("version", "lean-beam version"),
  ("serve", "lean-beam [--pretty] [--root PATH] [--session-dir DIR] serve"),
  ("run-at", "lean-beam [--pretty] [--root PATH] run-at <path> <version> <line> <character> (--stdin | --text-file <path> | -- <text...> | <text...>)"),
  ("run-at-handle", "lean-beam [--pretty] [--root PATH] run-at-handle <path> <version> <line> <character> (--stdin | --text-file <path> | -- <text...> | <text...>)"),
  ("hover", "lean-beam [--pretty] [--root PATH] hover <path> <version> <line> <character>"),
  ("signature-help", "lean-beam [--pretty] [--root PATH] signature-help <path> <version> <line> <character>"),
  ("definition", "lean-beam [--pretty] [--root PATH] definition <path> <version> <line> <character>"),
  ("references", "lean-beam [--pretty] [--root PATH] references <path> <version> <line> <character> [--include-declaration|--exclude-declaration]"),
  ("document-symbols", "lean-beam [--pretty] [--root PATH] document-symbols <path> <version>"),
  ("workspace-symbols", "lean-beam [--pretty] [--root PATH] workspace-symbols <query...>"),
  ("goals", "lean-beam [--pretty] [--root PATH] goals before|after <path> <version> <line> <character>"),
  ("todo", "lean-beam [--pretty] [--root PATH] todo <path> <version> [<startLine> <startCharacter> <endLine> <endCharacter>] [--kind <kind> ...] [--suggest none|basic]"),
  ("run-with", "lean-beam [--pretty] [--root PATH] run-with <path> <handle-json|-|--handle-file <path>> (--stdin | --text-file <path> | -- <text...> | <text...>)"),
  ("run-with-linear", "lean-beam [--pretty] [--root PATH] run-with-linear <path> <handle-json|-|--handle-file <path>> (--stdin | --text-file <path> | -- <text...> | <text...>)"),
  ("release", "lean-beam [--pretty] [--root PATH] release <path> <handle-json|-|--handle-file <path>>"),
  ("update", "lean-beam [--pretty] [--root PATH] update <path>"),
  ("sync", "lean-beam [--pretty] [--root PATH] sync <path> [+all-diagnostics]"),
  ("refresh", "lean-beam [--pretty] [--root PATH] refresh <path> [+all-diagnostics]"),
  ("save", "lean-beam [--pretty] [--root PATH] save <path> [+all-diagnostics]"),
  ("close", "lean-beam [--pretty] [--root PATH] close <path>"),
  ("close-save", "lean-beam [--pretty] [--root PATH] close-save <path> [+all-diagnostics]"),
  ("feedback-report", "lean-beam [--pretty] [--root PATH] feedback-report --stdin|--input <path> [--bundle none|dir|zip] [--output-dir <path>] [--no-redact]"),
  ("doctor", "lean-beam [--pretty] [--root PATH] doctor"),
  ("open-files", "lean-beam [--pretty] [--root PATH] open-files"),
  ("cancel", "lean-beam [--pretty] [--root PATH] cancel <request-id>"),
  ("stats", "lean-beam [--pretty] [--root PATH] stats"),
  ("status", "lean-beam [--pretty] [--root PATH] [--session-dir DIR] status"),
  ("stop", "lean-beam --root PATH [--session-dir DIR] stop"),
  ("recover", "lean-beam --root PATH [--session-dir DIR] recover --generation ID")
]

def commandUsage? (command : String) : Option String :=
  ((commandUsages.find? (fun entry => entry.1 == command)).map ("usage: " ++ ·.2)) <|>
    (if command == "prune" then some "usage: lean-beam prune [--apply]" else none)

def commandUsageFailure (args : List String) : CliFailure :=
  let general := "usage: lean-beam [--pretty] [--root PATH] [--session-dir DIR] <command> ...\nRun 'lean-beam --help' for commands."
  match args with
  | [] => .usage "a command is required" (some general)
  | command :: rest =>
      match commandUsage? command with
      | some usage => .usage s!"invalid arguments for '{command}': {String.intercalate " " rest}" (some usage)
      | none => .usage s!"unknown command '{command}'" (some general)

def usage (maintenance : List String) : String :=
  String.intercalate "\n" <| ["usage:"] ++
    (commandUsages.map ("  " ++ ·.2)) ++ maintenance ++ [
    "",
    "Project-session commands accept an absolute --session-dir DIR as an exact alternate session selection.",
    "Use the same --root and --session-dir for serving, attachment, diagnostics, stopping, and recovery.",
    "Beam never applies source edits to `.lean` files on disk; the client applies source edits.",
    "Lean edit loop: save the file, then run update for a broker document version.",
    "Run sync when you need the diagnostics/readiness barrier. save is sync plus a",
    "workspace-module checkpoint. refresh reads saved source before reopening the tracked",
    "document for fresh diagnostics. close-save adds closing after the checkpoint.",
    "Run update first, then pass its returned version to Lean position/range/document probes.",
    "Separate run-at calls are independent probes on the broker document version they name.",
    "For exact speculative chaining, use run-at-handle and then run-with / run-with-linear.",
    "For multiline text-carrying Lean probes, prefer --stdin or --text-file <path>; use -- before",
    "text that itself starts with --.",
    "JSON output is compact by default. --pretty is a global option; place it before the command",
    "for indented JSON.",
    "For handle-based commands, use --handle-file <path> when you do not want to inline handle json.",
    "Wrapper commands require one live session owner. Start serve in a foreground process",
    "and keep it running across wrapper invocations; interrupt it or run stop when finished.",
    "Abnormal session state remains fenced until recover --generation ID quarantines that record.",
    "Beam does not upload or submit feedback. Use feedback-report to print a pasteable report",
    "with cheap version, stats, open-files, daemon registry, and daemon incident context.",
    "Review non-confidential reports before posting because they may contain project context and",
    "caller-supplied payloads.",
    "Feedback input must be a JSON object with required string fields: title, summary,",
    "reproduction, expected, and actual.",
    "Set confidential=true for non-public workspaces; confidential cards force HOME-path redaction",
    "and omit automatically collected project debug context, request/response payloads, and evidence.",
    "They retain other caller narrative, so review it for secrets and never post the card publicly.",
    "For sync / refresh / save / close-save, diagnostics always stream for the",
    "current request;",
    "diagnostic scope defaults to errors; +all-diagnostics also streams warnings, info, and hints.",
    "Wrapper diagnostics and progress are human-facing on stderr.",
    "Set BEAM_DEBUG_TEXT=1 to print the exact escaped text and UTF-8 bytes sent for text-carrying",
    "Lean probe requests.",
    "For the Lean workflow contract and anti-patterns, see skills/lean-beam/SKILL.md."
  ]

end Beam.Cli
