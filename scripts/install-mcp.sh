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
    "vibe|Mistral Vibe|v mistral mistral-vibe" \
    "agy|Antigravity|antigravity")"
  register_codex_mcp=0
  register_claude_mcp=0
  register_opencode_mcp=0
  register_vibe_mcp=0
  register_agy_mcp=0
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
      agy)
        register_agy_mcp=1
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

cleanup_toml_stage() {
  local stage="$1"
  local tmp_config="$2"
  rm -f -- "$tmp_config" "$stage/original"
  rmdir "$stage" 2>/dev/null || true
}

write_toml_mcp_config() {
  local config="$1" approval_action="$2" edit="$3"
  shift 3
  local stage="" tmp_config="" input_config="-"
  stage="$(mktemp -d "${config}.lean-beam-XXXXXX")" || return
  tmp_config="$stage/${config##*/}"
  if [ -f "$config" ]; then
    if ! cp -p "$config" "$stage/original"; then
      cleanup_toml_stage "$stage" "$tmp_config"
      return 1
    fi
    input_config="$stage/original"
  fi
  if ! (umask 077; "$construction_tool" "$edit" "$config" "$input_config" "$@" >"$tmp_config"); then
    cleanup_toml_stage "$stage" "$tmp_config"
    return 1
  fi
  if [ -n "$approval_action" ]; then
    if ! (confirm_edit "$approval_action" "$config"); then
      cleanup_toml_stage "$stage" "$tmp_config"
      return 1
    fi
  fi
  if [ -L "$config" ] || { [ -e "$config" ] && [ ! -f "$config" ]; }; then
    cleanup_toml_stage "$stage" "$tmp_config"
    die "refusing to replace a symlink or non-file MCP config at $config"
  fi
  if [ -f "$stage/original" ]; then
    if ! cmp -s "$stage/original" "$config"; then
      cleanup_toml_stage "$stage" "$tmp_config"
      die "MCP config changed during registration at $config; retry the installer"
    fi
  elif [ -e "$config" ]; then
    cleanup_toml_stage "$stage" "$tmp_config"
    die "MCP config appeared during registration at $config; retry the installer"
  fi
  # Renaming by basename in the parent prevents mv from nesting inside a directory at config.
  if ! mv -f "$tmp_config" "${config%/*}/"; then
    cleanup_toml_stage "$stage" "$tmp_config"
    die "could not publish MCP config at $config"
  fi
  cleanup_toml_stage "$stage" "$tmp_config"
}

set_codex_parallel_tool_calls() {
  if [ -L "$codex_mcp_config" ] || [ ! -f "$codex_mcp_config" ]; then
    die "Codex did not write a regular MCP config at $codex_mcp_config"
  fi
  write_toml_mcp_config "$codex_mcp_config" "" codex-mcp
}

register_codex_mcp_server() {
  ensure_mcp_config_dir "$codex_home" "Codex home" || return
  ensure_codex_mcp_config_replaceable
  if [ "$mcp_toolset" = "core" ]; then
    CODEX_HOME="$codex_home" codex mcp add lean-beam -- "$bin_home/lean-beam-mcp" --toolset core >/dev/null || return
  else
    CODEX_HOME="$codex_home" codex mcp add lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null || return
  fi
  set_codex_parallel_tool_calls || return
  registered_mcp_targets+=("Codex: lean-beam")
}

cleanup_claude_backup() {
  local backup_dir="$1"
  local backup="$2"
  if [ -n "$backup_dir" ]; then
    rm -f -- "$backup"
    rmdir "$backup_dir" 2>/dev/null || true
  fi
}

write_claude_mcp_registration() {
  local backup_dir="" backup="" registration="absent" operation="add" status=0
  validate_claude_mcp_config_path
  ensure_mcp_config_dir "$claude_mcp_home" "Claude Code MCP config home" || return
  if [ -f "$claude_mcp_user_config" ]; then
    backup_dir="$(mktemp -d "$claude_mcp_home/.claude.json.lean-beam-XXXXXX")" || return
    backup="$backup_dir/.claude.json"
    if ! cp -p "$claude_mcp_user_config" "$backup"; then
      cleanup_claude_backup "$backup_dir" "$backup"
      return 1
    fi
    if ! registration="$("$construction_tool" claude-mcp "$backup")"; then
      cleanup_claude_backup "$backup_dir" "$backup"
      return 1
    fi
    if ! cmp -s "$backup" "$claude_mcp_user_config"; then
      cleanup_claude_backup "$backup_dir" "$backup"
      die "Claude Code MCP config changed during registration at $claude_mcp_user_config; retry the installer"
    fi
  fi
  if [ "$registration" = present ]; then
    operation="remove"
    HOME="$claude_mcp_home" claude mcp remove --scope user lean-beam >/dev/null || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    operation="add"
    if [ "$mcp_toolset" = "core" ]; then
      HOME="$claude_mcp_home" claude mcp add --scope user lean-beam -- "$bin_home/lean-beam-mcp" --toolset core >/dev/null || status=$?
    else
      HOME="$claude_mcp_home" claude mcp add --scope user lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null || status=$?
    fi
  fi
  if [ "$status" -ne 0 ]; then
    if [ -n "$backup" ] && ! cmp -s "$backup" "$claude_mcp_user_config"; then
      if ! mv -f "$backup" "$claude_mcp_home/"; then
        die "Claude Code MCP $operation failed (exit $status) and config restoration failed; original config retained at $backup"
      fi
    fi
    cleanup_claude_backup "$backup_dir" "$backup"
    die "Claude Code MCP $operation failed for lean-beam (exit $status)"
  fi
  cleanup_claude_backup "$backup_dir" "$backup"
}

register_claude_mcp_server() {
  write_claude_mcp_registration || return
  registered_mcp_targets+=("Claude Code: lean-beam")
}

register_opencode_mcp_server() {
  manual_mcp_targets+=("OpenCode: lean-beam")
}

register_vibe_mcp_server() {
  local approval_action=""
  local preview_args=()
  local mcp_command="$bin_home/lean-beam-mcp"
  case "$mcp_command" in
    *'"'*|*\\*)
      die "refusing to write Mistral Vibe MCP command path containing quotes or backslashes: $mcp_command"
      ;;
  esac
  ensure_mcp_config_dir "$vibe_home" "Mistral Vibe home" || return
  ensure_vibe_mcp_config_replaceable
  if [ "$dont_ask" -eq 0 ] && [ -t 0 ]; then
    preview_args=(--preview)
    approval_action="register lean-beam MCP server in the Mistral Vibe config"
  fi
  write_toml_mcp_config "$vibe_mcp_config" "$approval_action" vibe-mcp "$mcp_command" --toolset "$mcp_toolset" \
    ${preview_args[@]+"${preview_args[@]}"} || return
  registered_mcp_targets+=("Mistral Vibe: lean-beam")
}

plan_agy_mcp_registration() {
  local plan_args=()
  local reply=""
  if [ "$register_agy_mcp" -eq 0 ]; then
    return 0
  fi
  preflight_agy_mcp_config
  if [ -z "$agy_approved_config" ]; then
    agy_approved_config="$agy_physical_config"
  fi
  plan_args=(agy-mcp plan "$agy_physical_config" "$bin_home/lean-beam-mcp" --toolset "$mcp_toolset")
  if [ "$dont_ask" -eq 0 ]; then
    plan_args+=(--preview)
  fi
  agy_plan_token="$("$construction_tool" ${plan_args[@]+"${plan_args[@]}"})" || return
  case "$agy_plan_token" in
    noop) return 0 ;;
    *$'\n'*) die "invalid Antigravity MCP registration plan" ;;
    absent|[0-9]*:[0-9]*) ;;
    *) die "invalid Antigravity MCP registration plan" ;;
  esac
  if [ "$dont_ask" -eq 0 ]; then
    if [ ! -t 0 ]; then
      die "refusing to edit Antigravity MCP config without confirmation; rerun with --dont-ask"
    fi
    printf 'Allow this edit? [y/N] ' >&2
    IFS= read -r reply || reply=""
    case "$reply" in
      [yY]|[yY][eE][sS]) ;;
      *) die "cancelled before editing Antigravity MCP config at $agy_physical_config" ;;
    esac
  fi
}

register_agy_mcp_server() {
  local parent_dir=""
  local tmp_config=""
  local mode=""
  if [ "$agy_plan_token" = noop ]; then
    return 0
  fi
  preflight_agy_mcp_config
  parent_dir="${agy_physical_config%/*}"
  if [ ! -d "$parent_dir" ]; then
    mkdir -p "$parent_dir" || die "cannot create Antigravity config dir at $parent_dir"
  fi
  tmp_config="$(mktemp "$parent_dir/.mcp_config.json.lean-beam-XXXXXX")"
  if ! "$construction_tool" agy-mcp render "$agy_physical_config" "$bin_home/lean-beam-mcp" \
      --toolset "$mcp_toolset" "$agy_plan_token" >"$tmp_config"; then
    rm -f -- "$tmp_config"
    return 1
  fi
  if [ "$agy_plan_token" = absent ]; then
    if ! ln "$tmp_config" "$agy_physical_config" 2>/dev/null; then
      rm -f -- "$tmp_config"
      if [ -e "$agy_physical_config" ] || [ -L "$agy_physical_config" ]; then
        die "Antigravity MCP config changed before writing $agy_physical_config; rerun the installer"
      fi
      die "cannot create Antigravity MCP config at $agy_physical_config"
    fi
    rm -f -- "$tmp_config"
  else
    mode="$(stat -c '%a' "$agy_physical_config" 2>/dev/null || stat -f '%Lp' "$agy_physical_config" 2>/dev/null)" || mode=""
    if [ -z "$mode" ]; then
      rm -f -- "$tmp_config"
      die "cannot read Antigravity MCP config permissions at $agy_physical_config"
    fi
    if ! chmod "$mode" "$tmp_config"; then
      rm -f -- "$tmp_config"
      die "cannot preserve Antigravity MCP config mode at $agy_physical_config"
    fi
    if [ -L "$agy_physical_config" ]; then
      rm -f -- "$tmp_config"
      die "refusing to edit symlinked Antigravity MCP config at $agy_physical_config"
    fi
    if ! mv "$tmp_config" "$agy_physical_config"; then
      rm -f -- "$tmp_config"
      die "cannot replace Antigravity MCP config at $agy_physical_config"
    fi
  fi
  registered_mcp_targets+=("Antigravity: lean-beam")
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
  if [ "$register_agy_mcp" -eq 1 ]; then
    register_agy_mcp_server
  fi
}
