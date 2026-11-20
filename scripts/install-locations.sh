#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# Location validation and write-approval helpers for scripts/install-beam.sh.
# This file is sourced by the installer and intentionally uses its state.
# shellcheck disable=SC2034,SC2154

validate_codex_home() {
  require_absolute_path "$codex_home" "Codex home"
  require_not_root "$codex_home" "Codex home"
  require_absolute_path "$codex_skills_home" "Codex skills home"
  require_path_within "$codex_skills_home" "$codex_home" "Codex skills home"
  require_absolute_path "$codex_mcp_config" "Codex MCP config"
  require_path_within "$codex_mcp_config" "$codex_home" "Codex MCP config"
}

validate_claude_mcp_config_path() {
  require_absolute_path "$claude_mcp_user_config" "Claude Code MCP config"
  require_absolute_path "$claude_mcp_home" "Claude Code MCP config home"
  require_not_root "$claude_mcp_home" "Claude Code MCP config home"
  require_absolute_path "$claude_mcp_backup_home" "Claude Code backup home"
  require_not_root "$claude_mcp_backup_home" "Claude Code backup home"
  if [ "$(basename "$claude_mcp_user_config")" != ".claude.json" ]; then
    die "Claude Code MCP config must be named .claude.json: $claude_mcp_user_config"
  fi
}

validate_claude_home() {
  require_absolute_path "$claude_home" "Claude Code home"
  require_not_root "$claude_home" "Claude Code home"
  require_absolute_path "$claude_skills_home" "Claude Code skills home"
  require_path_within "$claude_skills_home" "$claude_home" "Claude Code skills home"
}

validate_pi_home() {
  require_absolute_path "$pi_home" "Pi Agent home"
  require_not_root "$pi_home" "Pi Agent home"
  require_absolute_path "$pi_skills_home" "Pi Agent skills home"
  require_path_within "$pi_skills_home" "$pi_home" "Pi Agent skills home"
}

validate_opencode_config_dir() {
  require_absolute_path "$opencode_config_dir" "OpenCode config dir"
  require_not_root "$opencode_config_dir" "OpenCode config dir"
  require_absolute_path "$opencode_skills_home" "OpenCode skills home"
  require_path_within "$opencode_skills_home" "$opencode_config_dir" "OpenCode skills home"
}

validate_vibe_home() {
  require_absolute_path "$vibe_home" "Mistral Vibe home"
  require_not_root "$vibe_home" "Mistral Vibe home"
  require_absolute_path "$vibe_skills_home" "Mistral Vibe skills home"
  require_path_within "$vibe_skills_home" "$vibe_home" "Mistral Vibe skills home"
  require_absolute_path "$vibe_mcp_config" "Mistral Vibe MCP config"
  require_path_within "$vibe_mcp_config" "$vibe_home" "Mistral Vibe MCP config"
}

validate_agy_home() {
  require_absolute_path "$agy_home" "Antigravity home"
  require_not_root "$agy_home" "Antigravity home"
  require_absolute_path "$agy_config_dir" "Antigravity config dir"
  require_path_within "$agy_config_dir" "$agy_home" "Antigravity config dir"
  require_absolute_path "$agy_skills_home" "Antigravity skills home"
  require_path_within "$agy_skills_home" "$agy_config_dir" "Antigravity skills home"
  require_absolute_path "$agy_mcp_config" "Antigravity MCP config"
  require_path_within "$agy_mcp_config" "$agy_config_dir" "Antigravity MCP config"
}

validate_requested_location_config() {
  validate_install_config
  if [ "$install_codex_skills" -eq 1 ] || [ "$register_codex_mcp" -eq 1 ]; then
    validate_codex_home
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    validate_claude_home
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    validate_claude_mcp_config_path
  fi
  if [ "$install_pi_skills" -eq 1 ]; then
    validate_pi_home
  fi
  if [ "$install_opencode_skills" -eq 1 ]; then
    validate_opencode_config_dir
  fi
  if [ "$install_vibe_skills" -eq 1 ] || [ "$register_vibe_mcp" -eq 1 ]; then
    validate_vibe_home
  fi
  if [ "$install_agy_skills" -eq 1 ] || [ "$register_agy_mcp" -eq 1 ]; then
    validate_agy_home
  fi
}

verify_requested_install_targets() {
  validate_requested_location_config
  verify_requested_skill_targets
  verify_requested_mcp_clients
  ensure_install_root_claimable
  verify_publish_targets
}

prompt_optional_path_override() {
  local label="$1"
  local current="$2"
  local reply=""
  printf '%s [%s]: ' "$label" "$current" >&2
  IFS= read -r reply || reply=""
  if [ -n "$reply" ]; then
    printf '%s\n' "$reply"
  else
    printf '%s\n' "$current"
  fi
}

prompt_install_location_changes() {
  local selected_path=""

  print_section "$style_blue" "Change Locations"
  printf 'Press Enter to keep the current value.\n' >&2

  selected_path="$(prompt_optional_path_override "Command directory" "$bin_home")"
  set_bin_home "$selected_path"

  selected_path="$(prompt_optional_path_override "Runtime install root" "$install_root")"
  set_install_root "$selected_path"

  if [ "$install_codex_skills" -eq 1 ] || [ "$register_codex_mcp" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Codex home" "$codex_home")"
    set_codex_home "$selected_path"
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Claude Code home" "$claude_home")"
    set_claude_home "$selected_path"
  fi
  if [ "$install_pi_skills" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Pi Agent home" "$pi_home")"
    set_pi_home "$selected_path"
  fi
  if [ "$install_opencode_skills" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "OpenCode config dir" "$opencode_config_dir")"
    set_opencode_config_dir "$selected_path"
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Claude Code user config" "$claude_mcp_user_config")"
    set_claude_mcp_user_config "$selected_path"
  fi
  if [ "$install_vibe_skills" -eq 1 ] || [ "$register_vibe_mcp" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Mistral Vibe home" "$vibe_home")"
    set_vibe_home "$selected_path"
  fi
  if [ "$install_agy_skills" -eq 1 ] || [ "$register_agy_mcp" -eq 1 ]; then
    selected_path="$(prompt_optional_path_override "Antigravity home" "$agy_home")"
    set_agy_home "$selected_path"
  fi

  validate_requested_location_config
}

print_write_locations() {
  print_section "$style_yellow" "Write Locations"
  printf 'Lean Beam will create or update the following locations:\n' >&2
  printf '\n  Core install\n' >&2
  printf '    - Command directory: %s\n' "$bin_home" >&2
  printf '    - Runtime root: %s\n' "$install_root" >&2
  printf '    - Source build output: %s\n' "$repo_root/.lake" >&2

  if [ "$install_codex_skills" -eq 1 ] || [ "$install_claude_skills" -eq 1 ] \
    || [ "$install_pi_skills" -eq 1 ] || [ "$install_opencode_skills" -eq 1 ] \
    || [ "$install_vibe_skills" -eq 1 ] || [ "$install_agy_skills" -eq 1 ]; then
    printf '\n  Agent skills\n' >&2
    if [ "$install_codex_skills" -eq 1 ]; then
      printf '    - Codex skills: %s (%s)\n' "$codex_skills_home" "$(skill_install_names)" >&2
    fi
    if [ "$install_claude_skills" -eq 1 ]; then
      printf '    - Claude Code skills: %s (%s)\n' "$claude_skills_home" "$(skill_install_names)" >&2
    fi
    if [ "$install_pi_skills" -eq 1 ]; then
      printf '    - Pi Agent skills: %s (%s)\n' "$pi_skills_home" "$(skill_install_names)" >&2
    fi
    if [ "$install_opencode_skills" -eq 1 ]; then
      printf '    - OpenCode skills: %s (%s)\n' "$opencode_skills_home" "$(skill_install_names)" >&2
    fi
    if [ "$install_vibe_skills" -eq 1 ]; then
      printf '    - Mistral Vibe skills: %s (%s)\n' "$vibe_skills_home" "$(skill_install_names)" >&2
    fi
    if [ "$install_agy_skills" -eq 1 ]; then
      printf '    - Antigravity skills: %s (%s)\n' "$agy_skills_home" "$(skill_install_names)" >&2
    fi
  fi

  if [ "$register_codex_mcp" -eq 1 ] || [ "$register_claude_mcp" -eq 1 ] \
    || [ "$register_vibe_mcp" -eq 1 ] || [ "$register_agy_mcp" -eq 1 ]; then
    printf '\n  MCP registration\n' >&2
    if [ "$register_codex_mcp" -eq 1 ]; then
      printf '    - Codex home: %s\n' "$codex_home" >&2
      printf '    - Codex config: %s\n' "$codex_mcp_config" >&2
    fi
    if [ "$register_claude_mcp" -eq 1 ]; then
      printf '    - Claude Code config: %s\n' "$claude_mcp_user_config" >&2
      printf '    - Claude Code backups: %s\n' "$claude_mcp_backup_home" >&2
    fi
    if [ "$register_vibe_mcp" -eq 1 ]; then
      printf '    - Mistral Vibe home: %s\n' "$vibe_home" >&2
      printf '    - Mistral Vibe config: %s\n' "$vibe_mcp_config" >&2
    fi
    if [ "$register_agy_mcp" -eq 1 ]; then
      printf '    - Antigravity home: %s\n' "$agy_home" >&2
      printf '    - Antigravity config: %s\n' "$agy_mcp_config" >&2
    fi
  fi

  if [ "$register_opencode_mcp" -eq 1 ]; then
    printf '\n  Manual follow-up\n' >&2
    printf '    - OpenCode MCP registration requires manual steps after install.\n' >&2
  fi
}

write_approval_action=""

prompt_write_approval() {
  local reply=""
  local choice=""
  write_approval_action=""
  printf '\nAllow lean-beam to write to these locations? [y/N/change] ' >&2
  IFS= read -r reply || reply=""
  choice="$(normalize_choice "$reply")"
  case "$choice" in
    y|yes)
      write_approval_action="approve"
      ;;
    c|change|edit)
      write_approval_action="change"
      ;;
    ""|n|no)
      write_approval_action="reject"
      ;;
    *)
      die "unknown write-permission response: $reply"
      ;;
  esac
}

approve_current_write_locations() {
  approved_write_homes=()
  approved_write_home_count=0
  if [ "$install_codex_skills" -eq 1 ]; then
    remember_approved_write_home "$codex_skills_home"
  fi
  if [ "$install_claude_skills" -eq 1 ]; then
    remember_approved_write_home "$claude_skills_home"
  fi
  if [ "$install_pi_skills" -eq 1 ]; then
    remember_approved_write_home "$pi_skills_home"
  fi
  if [ "$install_opencode_skills" -eq 1 ]; then
    remember_approved_write_home "$opencode_skills_home"
  fi
  if [ "$install_vibe_skills" -eq 1 ]; then
    remember_approved_write_home "$vibe_skills_home"
  fi
  if [ "$install_agy_skills" -eq 1 ]; then
    remember_approved_write_home "$agy_skills_home"
  fi
  if [ "$register_codex_mcp" -eq 1 ]; then
    remember_approved_write_home "$codex_home"
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    remember_approved_write_home "$claude_mcp_home"
  fi
  if [ "$register_vibe_mcp" -eq 1 ]; then
    remember_approved_write_home "$vibe_home"
  fi
  if [ "$register_agy_mcp" -eq 1 ]; then
    remember_approved_write_home "$agy_config_dir"
  fi
  runtime_writes_approved=1
  bin_writes_approved=1
  source_build_approved=1
}

remember_approved_write_home() {
  local location="$1"
  if [ "$approved_write_home_count" -eq 0 ] || ! array_contains "$location" ${approved_write_homes[@]+"${approved_write_homes[@]}"}; then
    approved_write_homes+=("$location")
    approved_write_home_count=$((approved_write_home_count + 1))
  fi
}

approve_requested_writes() {
  if [ "$dont_ask" -eq 1 ]; then
    verify_requested_install_targets
    return 0
  fi
  if [ "$runtime_writes_approved" -eq 1 ] && [ "$bin_writes_approved" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "refusing to install without confirmation; rerun with --dont-ask to approve Beam-owned installer edits"
  fi

  while true; do
    validate_requested_location_config
    print_write_locations
    prompt_write_approval
    case "$write_approval_action" in
      approve)
        verify_requested_install_targets
        approve_current_write_locations
        return 0
        ;;
      change)
        prompt_install_location_changes
        ;;
      reject)
        die "cancelled before: Write Locations"
        ;;
    esac
  done
}
