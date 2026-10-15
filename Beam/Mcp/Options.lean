/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

namespace Beam.Mcp

structure Options where
  leanCmd? : Option String := none
  leanPlugin? : Option String := none
  beamCli? : Option String := none
  selfCheckPath? : Option String := none
  showVersion : Bool := false

def usage : String :=
  String.intercalate "\n" [
    "usage: lean-beam-mcp [--beam-cli PATH | --lean-cmd CMD --lean-plugin PATH]",
    "       lean-beam-mcp [--beam-cli PATH | --lean-cmd CMD --lean-plugin PATH] --self-check <lean-file>",
    "       lean-beam-mcp --version",
    "",
    "Runs the experimental Lean Beam MCP server over newline-delimited JSON-RPC on stdio.",
    "Every workspace-bound tool call carries {\"workspace\":{\"root\":\"/absolute/project\"}}.",
    "--self-check starts a child MCP server and calls lean_sync for the current Lean project.",
    "Self-check uses best-effort waits of 120000 ms by default; override with LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS.",
    "This setting does not bound total command duration; blocking I/O and cleanup may outlast it.",
    "--version prints the MCP server version, protocol revision, and available resolved identity paths.",
    "The installed wrapper passes --beam-cli automatically so project-specific Lean bundles resolve on demand.",
    "Only curated Lean tools are exposed; raw LSP and broker escape hatches are intentionally absent."
  ]

partial def parseOptions (opts : Options) : List String → Except String Options
  | [] => pure opts
  | "--lean-cmd" :: leanCmd :: rest =>
      parseOptions { opts with leanCmd? := some leanCmd } rest
  | "--lean-plugin" :: leanPlugin :: rest =>
      parseOptions { opts with leanPlugin? := some leanPlugin } rest
  | "--beam-cli" :: beamCli :: rest =>
      parseOptions { opts with beamCli? := some beamCli } rest
  | "--self-check" :: path :: rest =>
      parseOptions { opts with selfCheckPath? := some path } rest
  | "--version" :: rest =>
      parseOptions { opts with showVersion := true } rest
  | "-h" :: _ | "--help" :: _ =>
      throw usage
  | arg :: _ =>
      throw s!"unexpected lean-beam-mcp argument '{arg}'\n\n{usage}"

end Beam.Mcp
