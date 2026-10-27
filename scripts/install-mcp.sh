#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# MCP client selection and registration helpers for scripts/install-beam.sh.
# This file is sourced by the installer and intentionally uses its state.
# shellcheck disable=SC2034,SC2154

prompt_mcp_registration_selection() {
  local selection=""
  local target=""
  selection="$(prompt_agent_target_multi_choice \
    "MCP Registration" \
    "Register lean-beam-mcp with:" \
    "MCP clients" \
    "MCP registration" \
    "codex|Codex|c" \
    "claude|Claude Code|claude-code" \
    "opencode|OpenCode|o open-code" \
    "vibe|Mistral Vibe|v mistral mistral-vibe")"
  register_codex_mcp=0
  register_claude_mcp=0
  register_opencode_mcp=0
  register_vibe_mcp=0
  for target in $selection; do
    case "$target" in
      none)
        ;;
      codex)
        register_codex_mcp=1
        ;;
      claude)
        register_claude_mcp=1
        ;;
      opencode)
        register_opencode_mcp=1
        ;;
      vibe)
        register_vibe_mcp=1
        ;;
    esac
  done
}

verify_requested_mcp_clients() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    validate_codex_home
    ensure_codex_mcp_config_replaceable
    if ! command -v codex >/dev/null 2>&1; then
      die "cannot register Codex MCP server because codex is not on PATH"
    fi
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    validate_claude_mcp_config_path
    if ! command -v claude >/dev/null 2>&1; then
      die "cannot register Claude Code MCP server because claude is not on PATH"
    fi
  fi
  if [ "$register_vibe_mcp" -eq 1 ]; then
    validate_vibe_home
    ensure_vibe_mcp_config_replaceable
  fi
}

ensure_codex_mcp_config_replaceable() {
  if [ -L "$codex_mcp_config" ]; then
    die "refusing to edit symlinked Codex MCP config at $codex_mcp_config"
  fi
  if [ -e "$codex_mcp_config" ] && [ ! -f "$codex_mcp_config" ]; then
    die "refusing to edit non-file Codex MCP config at $codex_mcp_config"
  fi
}

ensure_vibe_mcp_config_replaceable() {
  if [ -L "$vibe_mcp_config" ]; then
    die "refusing to edit symlinked Mistral Vibe config at $vibe_mcp_config"
  fi
  if [ -e "$vibe_mcp_config" ] && [ ! -f "$vibe_mcp_config" ]; then
    die "refusing to edit non-file Mistral Vibe config at $vibe_mcp_config"
  fi
  require_vibe_mcp_servers_appendable
}

# TOML forbids extending an inline `mcp_servers = [...]` array with [[mcp_servers]]
# tables. The installer removes Vibe's default empty assignment, but refuses to
# rewrite inline entries it cannot merge safely.
require_vibe_mcp_servers_appendable() {
  if [ ! -f "$vibe_mcp_config" ]; then
    return 0
  fi
  if awk '
    /^[[:space:]]*\[/ { exit 0 }
    /^[[:space:]]*mcp_servers[[:space:]]*=/ {
      if ($0 !~ /^[[:space:]]*mcp_servers[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*(#.*)?$/) {
        exit 1
      }
    }
  ' "$vibe_mcp_config"; then
    return 0
  fi
  die "refusing to edit Mistral Vibe config with inline mcp_servers entries at $vibe_mcp_config; move them to [[mcp_servers]] tables first"
}

ensure_mcp_config_dir() {
  local path="$1"
  local label="$2"
  require_absolute_path "$path" "$label"
  require_not_root "$path" "$label"
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      die "refusing to use non-directory $label at $path"
    fi
    return 0
  fi
  mkdir -p "$path"
}

set_codex_parallel_tool_calls() {
  local tmp_config=""
  if [ -L "$codex_mcp_config" ] || [ ! -f "$codex_mcp_config" ]; then
    die "Codex did not write a regular MCP config at $codex_mcp_config"
  fi
  tmp_config="$(mktemp "$codex_home/.config.toml.lean-beam-XXXXXX")"
  if ! awk '
    BEGIN {
      single_quote = sprintf("%c", 39)
      mcp_key = "(mcp_servers|\"mcp_servers\"|" single_quote "mcp_servers" single_quote ")"
      server_key = "(lean-beam|\"lean-beam\"|" single_quote "lean-beam" single_quote ")"
      target_table = "^\\[" mcp_key "\\." server_key "\\]$"
    }
    {
      compact_header = $0
      sub(/\][[:space:]]*#.*$/, "]", compact_header)
      gsub(/[[:space:]]/, "", compact_header)
    }
    compact_header ~ target_table {
      print
      print "supports_parallel_tool_calls = true"
      saw_target = 1
      in_target = 1
      next
    }
    /^[[:space:]]*\[/ {
      in_target = 0
      print
      next
    }
    in_target && /^[[:space:]]*supports_parallel_tool_calls[[:space:]]*=/ { next }
    { print }
    END { if (!saw_target) exit 2 }
  ' "$codex_mcp_config" >"$tmp_config"; then
    rm -f -- "$tmp_config"
    die "Codex MCP config does not contain the registered lean-beam server table: $codex_mcp_config"
  fi
  mv "$tmp_config" "$codex_mcp_config"
}

register_codex_mcp_server() {
  ensure_mcp_config_dir "$codex_home" "Codex home"
  ensure_codex_mcp_config_replaceable
  CODEX_HOME="$codex_home" codex mcp add lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  set_codex_parallel_tool_calls
  registered_mcp_targets+=("Codex: lean-beam")
}

register_claude_mcp_server() {
  ensure_mcp_config_dir "$claude_mcp_home" "Claude Code MCP config home"
  HOME="$claude_mcp_home" claude mcp remove --scope user lean-beam >/dev/null 2>&1 || true
  HOME="$claude_mcp_home" claude mcp add --scope user lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  registered_mcp_targets+=("Claude Code: lean-beam")
}

register_opencode_mcp_server() {
  manual_mcp_targets+=("OpenCode: lean-beam")
}

# Print the Mistral Vibe config with any existing lean-beam [[mcp_servers]] block,
# the top-level default empty `mcp_servers = []` assignment, and trailing blank
# lines removed, so re-registration replaces instead of duplicating and the
# appended [[mcp_servers]] table stays valid TOML.
vibe_mcp_config_without_lean_beam_server() {
  awk '
    function flush_block() {
      if (in_block && !block_is_lean_beam) {
        printf "%s", block
      }
      block = ""
      in_block = 0
      block_is_lean_beam = 0
    }
    /^[[:space:]]*\[\[[[:space:]]*mcp_servers[[:space:]]*\]\][[:space:]]*(#.*)?$/ {
      seen_table = 1
      flush_block()
      in_block = 1
      block = $0 "\n"
      next
    }
    /^[[:space:]]*\[/ {
      seen_table = 1
      flush_block()
      print
      next
    }
    {
      if (in_block) {
        block = block $0 "\n"
        if ($0 ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*"lean-beam"[[:space:]]*(#.*)?$/) {
          block_is_lean_beam = 1
        }
      } else if (seen_table \
        || $0 !~ /^[[:space:]]*mcp_servers[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*(#.*)?$/) {
        print
      }
    }
    END { flush_block() }
  ' "$1" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) {
        last--
      }
      for (i = 1; i <= last; i++) {
        print lines[i]
      }
    }
  '
}

register_vibe_mcp_server() {
  local tmp_config=""
  local tmp_config_has_content=0
  local mcp_command="$bin_home/lean-beam-mcp"
  case "$mcp_command" in
    *'"'*|*\\*)
      die "refusing to write Mistral Vibe MCP command path containing quotes or backslashes: $mcp_command"
      ;;
  esac
  ensure_mcp_config_dir "$vibe_home" "Mistral Vibe home"
  ensure_vibe_mcp_config_replaceable
  confirm_path_edit "register lean-beam MCP server in the Mistral Vibe config" "$vibe_mcp_config"
  tmp_config="$(mktemp "$vibe_home/.config.toml.lean-beam-XXXXXX")"
  if [ -f "$vibe_mcp_config" ]; then
    vibe_mcp_config_without_lean_beam_server "$vibe_mcp_config" >"$tmp_config"
  fi
  if [ -s "$tmp_config" ]; then
    tmp_config_has_content=1
  fi
  {
    if [ "$tmp_config_has_content" -eq 1 ]; then
      printf '\n'
    fi
    printf '[[mcp_servers]]\n'
    printf 'name = "lean-beam"\n'
    printf 'transport = "stdio"\n'
    printf 'command = ["%s"]\n' "$mcp_command"
    printf 'args = []\n'
    printf 'tool_timeout_sec = 600\n'
  } >>"$tmp_config"
  mv "$tmp_config" "$vibe_mcp_config"
  registered_mcp_targets+=("Mistral Vibe: lean-beam")
}

register_requested_mcp_servers() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    register_codex_mcp_server
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    register_claude_mcp_server
  fi
  if [ "$register_opencode_mcp" -eq 1 ]; then
    register_opencode_mcp_server
  fi
  if [ "$register_vibe_mcp" -eq 1 ]; then
    register_vibe_mcp_server
  fi
}
