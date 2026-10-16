#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# The compatibility script supplies the wrapper command array, log paths, and failure reporter.
# shellcheck disable=SC2154

# The compatibility suite starts two successive owners using the same log paths.
start_stale_owner() {
  # Clear readiness synchronously: a background redirection can run after the first poll.
  : > "$stale_owner_stderr"
  # Start the command directly so the tracked PID belongs to the owner, not a shell function.
  ${stale_wrapper_command[@]+"${stale_wrapper_command[@]}"} serve > "$stale_owner_stdout" 2> "$stale_owner_stderr" &
  stale_owner_pid="$!"
  if ! wait_for_file_text "$stale_owner_stderr" "serving Beam session" \
      "toolchain compatibility session owner" 600 0.1; then
    print_toolchain_context "explicit session owner failed to start"
    return 1
  fi
}

cleanup_stale_owner() {
  if [ -z "${stale_owner_pid:-}" ]; then
    return 0
  fi
  if kill -0 "$stale_owner_pid" 2>/dev/null; then
    kill -INT "$stale_owner_pid" 2>/dev/null || true
    # A failed startup or request must not leave the EXIT trap waiting forever.
    if ! wait_for_exit "$stale_owner_pid" "compatibility owner cleanup" 150 0.1; then
      kill -TERM "$stale_owner_pid" 2>/dev/null || true
      if ! wait_for_exit "$stale_owner_pid" "compatibility owner termination" 20 0.1; then
        kill -KILL "$stale_owner_pid" 2>/dev/null || true
      fi
    fi
  fi
  wait "$stale_owner_pid" 2>/dev/null || true
  stale_owner_pid=""
}
