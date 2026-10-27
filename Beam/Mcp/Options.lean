/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Admission

namespace Beam.Mcp

structure Options where
  showVersion : Bool := false
  /-- Ordinary execution-admission pool; workspace drops and observation keep fixed reserves. -/
  maxUnfinishedRequests : Nat := Admission.defaultOrdinaryLimit

def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp",
    "       lean-beam-mcp --version",
    s!"       lean-beam-mcp --max-unfinished-requests N   (1..{Admission.maxOrdinaryLimit}, default {Admission.defaultOrdinaryLimit})",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "Every workspace-bound tool call carries {\"workspace\":{\"root\":\"/absolute/project\"}}.",
    "--version prints the MCP server version, protocol revision, and available resolved identity paths.",
    "--max-unfinished-requests bounds queued, running, and cancelled-but-unsettled ordinary requests.",
    "Runtime components come exclusively from this installation's recorded target set.",
    "Only curated Lean tools are exposed; raw LSP and broker escape hatches are intentionally absent."
  ]

partial def parseOptions (opts : Options) : List String → Except String Options
  | [] => pure opts
  | "--version" :: rest =>
      parseOptions { opts with showVersion := true } rest
  | "--max-unfinished-requests" :: value :: rest => do
      match Admission.parseOrdinaryLimit value with
      | .ok limit => parseOptions { opts with maxUnfinishedRequests := limit } rest
      | .error err => throw s!"{err}\n\n{usage}"
  | ["--max-unfinished-requests"] =>
      throw s!"--max-unfinished-requests requires a value\n\n{usage}"
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

end Beam.Mcp
