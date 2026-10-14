/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Cli.ClientDoctor.Types
import Beam.Cli.ClientDoctor.Parse

namespace Beam.Cli.ClientDoctor

structure ConfigSource where
  path : System.FilePath
  format : Format
  purpose : String := "user configuration"
  conditional : Bool := false
  settingsOnly : Bool := false

structure Locations where
  configs : Array ConfigSource := #[]
  skills : Array System.FilePath := #[]

/-- The installer location conventions. Keep parity with scripts/install-beam.sh under fake homes. -/
def clientHome (context : Context) : Client → System.FilePath
  | .codex => context.location "CODEX_HOME" (context.userHome / ".codex")
  | .claude => context.location "CLAUDE_HOME" (context.userHome / ".claude")
  | .pi => context.location "PI_CODING_AGENT_DIR" (context.userHome / ".pi" / "agent")
  | .opencode => context.location "OPENCODE_CONFIG_DIR" (
      context.location "XDG_CONFIG_HOME" (context.userHome / ".config") / "opencode")
  | .vibe => context.location "VIBE_HOME" (context.userHome / ".vibe")

/-- A bounded ancestor walk, stopping at the nearest Git boundary or the user's home. -/
def workspaceDirectories (context : Context) : IO (Array System.FilePath) := do
  let mut dirs := #[]
  let mut dir := context.workspace
  for _ in [:64] do
    dirs := dirs.push dir
    if dir == context.userHome || (← (dir / ".git").pathExists) then break
    let parent := dir.parent.getD dir
    if parent == dir then break
    dir := parent
  return dirs.reverse

private def config (path : System.FilePath) (format : Format)
    (purpose : String := "user configuration") (conditional : Bool := false)
    (settingsOnly : Bool := false) : ConfigSource :=
  { path, format, purpose, conditional, settingsOnly }

def locations (context : Context) (client : Client)
    (dirs : Array System.FilePath) : Locations := Id.run do
  let home := clientHome context client
  let mut result : Locations := { skills := #[home / "skills" / "lean-beam" / "SKILL.md"] }
  match client with
  | .codex =>
      result := { result with configs := #[config (home / "config.toml") .toml] }
      result := { result with skills := result.skills.push (
        context.userHome / ".agents" / "skills" / "lean-beam" / "SKILL.md") }
      for dir in dirs do
        if dir / ".codex" != home then
          result := { result with configs := result.configs.push (
            config (dir / ".codex" / "config.toml") .toml "project configuration (trust-dependent)" true) }
        result := { result with skills := result.skills.push (
          dir / ".agents" / "skills" / "lean-beam" / "SKILL.md") }
  | .claude =>
      result := { result with configs := #[
        config (context.location "BEAM_CLAUDE_MCP_CONFIG" (context.userHome / ".claude.json")) .json,
        config (home / "settings.json") .json "user settings" false true] }
      for dir in dirs do
        result := { result with configs := result.configs ++ #[
          config (dir / ".mcp.json") .json "project MCP configuration (approval-dependent)" true,
          config (dir / ".claude" / "settings.json") .json "project settings" false true,
          config (dir / ".claude" / "settings.local.json") .json "local settings" false true] }
        result := { result with skills := result.skills.push (
          dir / ".claude" / "skills" / "lean-beam" / "SKILL.md") }
  | .pi =>
      result := { result with configs := #[
        config (home / "settings.json") .json "user settings" false true,
        config (context.workspace / ".pi" / "settings.json") .json "project settings (trust-dependent)" true true] }
      result := { result with skills := result.skills.push (
        context.workspace / ".pi" / "skills" / "lean-beam" / "SKILL.md") }
      result := { result with skills := result.skills.push (
        context.userHome / ".agents" / "skills" / "lean-beam" / "SKILL.md") }
      for dir in dirs do
        result := { result with skills := result.skills.push (
          dir / ".agents" / "skills" / "lean-beam" / "SKILL.md") }
  | .opencode =>
      -- OPENCODE_CONFIG_DIR is an additional client directory, rather than a replacement for XDG.
      let globalHome := context.location "XDG_CONFIG_HOME" (context.userHome / ".config") / "opencode"
      for suffix in ["opencode.json", "opencode.jsonc"] do
        result := { result with configs := result.configs.push (config (globalHome / suffix) .jsonc) }
      if let some path := context.env? "OPENCODE_CONFIG" then
        result := { result with configs := result.configs.push (
          config (System.FilePath.mk path) .jsonc "OPENCODE_CONFIG override") }
      for dir in dirs do
        for suffix in ["opencode.json", "opencode.jsonc"] do
          result := { result with configs := result.configs.push (
            config (dir / suffix) .jsonc "project configuration") }
      for dir in dirs do
        for suffix in ["opencode.json", "opencode.jsonc"] do
          result := { result with configs := result.configs.push (
            config (dir / ".opencode" / suffix) .jsonc "project .opencode configuration") }
        result := { result with skills := result.skills.push (
          dir / ".opencode" / "skills" / "lean-beam" / "SKILL.md") }
      if home != globalHome then
        for suffix in ["opencode.json", "opencode.jsonc"] do
          result := { result with configs := result.configs.push (
            config (home / suffix) .jsonc "OPENCODE_CONFIG_DIR configuration") }
      result := { result with skills := result.skills.push (globalHome / "skills" / "lean-beam" / "SKILL.md") }
  | .vibe =>
      result := { result with configs := #[
        config (home / "config.toml") .toml,
        config (context.workspace / ".vibe" / "config.toml") .toml "project configuration (trust-dependent)" true] }
      result := { result with skills := result.skills.push (
        context.workspace / ".vibe" / "skills" / "lean-beam" / "SKILL.md") }
  -- The same file can be both a home and workspace candidate. Inspect it only once.
  result := { result with
    configs := result.configs.foldl (fun acc source =>
      if acc.any (·.path == source.path) then acc else acc.push source) #[]
    skills := result.skills.foldl (fun acc path =>
      if acc.contains path then acc else acc.push path) #[] }
  return result

end Beam.Cli.ClientDoctor
