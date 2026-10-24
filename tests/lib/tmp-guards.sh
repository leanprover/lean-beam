#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

beam_test_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

beam_test_tmp_prefix_matches() {
  if [ "$#" -lt 2 ]; then
    return 1
  fi
  local path="$1"
  shift
  local prefix
  for prefix in "$@"; do
    case "$path" in
      /tmp/"$prefix"-*|/tmp/beam-validate-*/tmp/"$prefix"-*)
        return 0
        ;;
    esac
  done
  return 1
}

beam_test_expect_owned_tmp_dir() {
  if [ "$#" -lt 2 ]; then
    echo "missing temp guard prefix for: ${1:-<missing>}" >&2
    exit 1
  fi
  local path="$1"
  shift
  if beam_test_tmp_prefix_matches "$path" "$@"; then
    return 0
  fi
  echo "refusing to touch unexpected temp dir: $path" >&2
  exit 1
}

beam_test_expect_path_within_owned_tmp_dir() {
  if [ "$#" -lt 3 ]; then
    echo "missing temp path guard arguments" >&2
    exit 1
  fi
  local path="$1"
  local root="$2"
  shift 2
  beam_test_expect_owned_tmp_dir "$root" "$@"
  case "$path" in
    "$root"|"$root"/*)
      ;;
    *)
      echo "refusing to touch path outside temp root $root: $path" >&2
      exit 1
      ;;
  esac
}

beam_test_remove_owned_tmp_tree() {
  local path="$1"
  shift
  beam_test_expect_owned_tmp_dir "$path" "$@"
  rm -rf -- "$path"
}

beam_test_remove_tmp_tree_within_owned_tmp_dir() {
  local path="$1"
  local root="$2"
  shift 2
  beam_test_expect_path_within_owned_tmp_dir "$path" "$root" "$@"
  rm -rf -- "$path"
}

# Successful fixtures release their scratch tree; failed fixtures keep evidence after owner cleanup.
# Return the original failure, or a cleanup error when the fixture itself succeeded.
beam_test_finish_workspace() {
  local result="$1"
  local path="$2"
  shift 2
  beam_test_expect_owned_tmp_dir "$path" "$@"
  if [ "$result" -ne 0 ]; then
    printf 'retained failed test workspace (exit %s): %s\n' "$result" "$path" >&2 || true
    return "$result"
  fi
  beam_test_remove_owned_tmp_tree "$path" "$@"
}
