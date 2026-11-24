/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Admission
import Beam.Mcp.Projection

namespace Beam.Mcp

structure Options where
  showVersion : Bool := false
  /-- Ordinary execution-admission pool; workspace drops and observation keep fixed reserves. -/
  maxUnfinishedRequests : Nat := Admission.defaultOrdinaryLimit
  /-- Tool profile exposed by `tools/list` and accepted by `tools/call`. -/
  toolset : Toolset := .full

def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp",
    "       lean-beam-mcp --version",
    s!"       lean-beam-mcp --max-unfinished-requests N   (1..{Admission.maxOrdinaryLimit}, default {Admission.defaultOrdinaryLimit})",
    "       lean-beam-mcp --toolset <full|core>         (default full)",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "Every workspace-bound tool call carries {\"workspace\":{\"root\":\"/absolute/project\"}}.",
    "--version prints the MCP server version, protocol revision, and available resolved identity paths.",
    "--max-unfinished-requests bounds queued, running, and cancelled-but-unsettled ordinary requests.",
    "--toolset core exposes only the compact authoring toolset (beam_version/sync/update/refresh/run_at/goals/todo/save/close_save/close/drop_workspace).",
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
  | "--toolset" :: value :: rest => do
      match Toolset.parse? value with
      | some toolset => parseOptions { opts with toolset } rest
      | none => throw s!"--toolset expects 'full' or 'core', got '{value}'\n\n{usage}"
  | ["--toolset"] =>
      throw s!"--toolset requires a value ('full' or 'core')\n\n{usage}"
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

end Beam.Mcp
