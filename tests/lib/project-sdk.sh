#!/usr/bin/env bash
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Bind a test oracle to its fixture's project context, not the SDK used to build Beam.
beam_test_project_command() {
  local root="$1"
  local tool="$2"
  local elan_bin selected
  case "$tool" in
    lean|lake) ;;
    *) echo "unsupported project SDK command: $tool" >&2; return 1 ;;
  esac
  if [ ! -f "$root/lean-toolchain" ] || [ ! -r "$root/lean-toolchain" ]; then
    echo "fixture requires a readable lean-toolchain: $root" >&2
    return 1
  fi
  elan_bin="$(command -v elan)" || {
    echo "fixture SDK resolution requires elan" >&2
    return 1
  }
  selected="$(
    cd "$root" || exit 1
    unset ELAN_TOOLCHAIN
    "$elan_bin" which "$tool"
  )" || return $?
  if [ ! -f "$selected" ] || [ ! -x "$selected" ]; then
    echo "fixture SDK command is not executable: $selected" >&2
    return 1
  fi
  printf '%s\n' "$selected"
}
