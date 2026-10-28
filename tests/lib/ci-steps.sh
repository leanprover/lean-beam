#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

run_step() {
  local label="$1"
  shift
  local start
  local end
  local rc
  local restore_errexit

  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::group::%s\n' "$label"
  fi
  start="$(date +%s)"
  printf '[%s] %s\n' "${BEAM_TEST_SUITE:-beam-test}" "$label"

  restore_errexit=false
  case "$-" in
    *e*)
      restore_errexit=true
      ;;
  esac
  # Keep running long enough to print timing and close any GitHub log group. Multi-command
  # step functions must return the command failure explicitly instead of relying on set -e.
  set +e
  "$@"
  rc=$?
  if [ "$restore_errexit" = "true" ]; then
    set -e
  else
    set +e
  fi

  end="$(date +%s)"
  printf '[%s] %s finished in %ss\n' "${BEAM_TEST_SUITE:-beam-test}" "$label" "$((end - start))"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::endgroup::\n'
  fi

  return "$rc"
}

# Capture only the command, leaving run_step's timing visible. Call with external commands;
# compound shell functions must propagate failures explicitly, as with run_step.
_beam_test_capture_step() {
  local label="$1"
  shift
  local log rc cleanup_rc=0
  log="$(mktemp "${TMPDIR:-/tmp}/beam-step-log-XXXXXX")" || return "$?"
  if "$@" > "$log" 2>&1; then
    rc=0
  else
    rc=$?
    printf '[%s] %s failed with exit status %s\n' "${BEAM_TEST_SUITE:-beam-test}" "$label" "$rc" >&2
    cat "$log" >&2
  fi
  rm -f -- "$log" || cleanup_rc=$?
  if [ "$rc" -eq 0 ]; then
    rc="$cleanup_rc"
  fi
  return "$rc"
}

run_quiet_step() {
  local label="$1"
  shift
  run_step "$label" _beam_test_capture_step "$label" "$@"
}
