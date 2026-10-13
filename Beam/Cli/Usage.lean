/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Cli

def usage : String :=
  String.intercalate "\n" [
    "usage:",
    "  lean-beam --version",
    "  lean-beam version",
    "  lean-beam [--root PATH] [--session-dir DIR] serve [lean|rocq]",
    "  lean-beam [--root PATH] run-at <path> <snapshot> <line> <character> (--stdin | --text-file <path> | -- <text...> | <text...>)",
    "  lean-beam [--root PATH] run-at-handle <path> <snapshot> <line> <character> (--stdin | --text-file <path> | -- <text...> | <text...>)",
    "  lean-beam [--root PATH] hover <path> <snapshot> <line> <character>",
    "  lean-beam [--root PATH] signature-help <path> <snapshot> <line> <character>",
    "  lean-beam [--root PATH] definition <path> <snapshot> <line> <character>",
    "  lean-beam [--root PATH] references <path> <snapshot> <line> <character> [--include-declaration|--exclude-declaration]",
    "  lean-beam [--root PATH] document-symbols <path> <snapshot>",
    "  lean-beam [--root PATH] workspace-symbols <query...>",
    "  lean-beam [--root PATH] goals before|after <path> <snapshot> <line> <character>",
    "  lean-beam [--root PATH] todo <path> <snapshot> <startLine> <startCharacter> <endLine> <endCharacter> [--kind <kind> ...] [--suggest none|basic]",
    "  lean-beam [--root PATH] run-with <path> <handle-json|-|--handle-file <path>> (--stdin | --text-file <path> | -- <text...> | <text...>)",
    "  lean-beam [--root PATH] run-with-linear <path> <handle-json|-|--handle-file <path>> (--stdin | --text-file <path> | -- <text...> | <text...>)",
    "  lean-beam [--root PATH] release <path> <handle-json|-|--handle-file <path>>",
    "  lean-beam [--root PATH] update <path>",
    "  lean-beam [--root PATH] sync <path> [+all-diagnostics]",
    "  lean-beam [--root PATH] refresh <path> [+all-diagnostics]",
    "  lean-beam [--root PATH] save <path> [+all-diagnostics]",
    "  lean-beam [--root PATH] close <path>",
    "  lean-beam [--root PATH] close-save <path> [+all-diagnostics]",
    "  lean-beam [--root PATH] rocq-goals-after <path> <line> <character> [text...]",
    "  lean-beam [--root PATH] rocq-goals-prev <path> <line> <character> [text...]",
    "  lean-beam [--root PATH] feedback-report --stdin|--input <path> [--bundle none|dir|zip] [--output-dir <path>] [--no-redact]",
    "  lean-beam prune [--apply] [--bundles]",
    "  lean-beam validated-toolchains [lean]",
    "  lean-beam compatible-release-lines",
    "  lean-beam [--root PATH] doctor [lean|rocq]",
    "  lean-beam [--root PATH] open-files",
    "  lean-beam [--root PATH] cancel <request-id>",
    "  lean-beam [--root PATH] stats",
    "  lean-beam [--root PATH] [--session-dir DIR] status",
    "  lean-beam --root PATH [--session-dir DIR] stop",
    "  lean-beam --root PATH [--session-dir DIR] recover --generation ID | --force",
    "",
    "Project-session commands accept an absolute --session-dir DIR as an exact alternate session selection.",
    "Use the same --root and --session-dir for serving, attachment, diagnostics, stopping, and recovery.",
    "Beam never applies source edits to `.lean` files on disk; the client applies source edits.",
    "Lean edit loop: save the file, then run update for a broker source snapshot.",
    "Run sync when you need the diagnostics/readiness barrier. save is sync plus a",
    "workspace-module checkpoint, refresh is close plus sync, and close-save",
    "adds closing the tracked file afterward.",
    "Run update first, then pass its returned snapshot to Lean position/range/document probes.",
    "Separate run-at calls are independent probes on the broker source snapshot they name.",
    "For exact speculative chaining, use run-at-handle and then run-with / run-with-linear.",
    "For multiline text-carrying Lean probes, prefer --stdin or --text-file <path>; use -- before",
    "text that itself starts with --.",
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
