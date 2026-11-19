#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

# Maintainer workflow helper for this repository.
# This script is intentionally local contributor tooling, not a product compatibility surface.

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${REPO_ROOT}" ]] || {
  echo "error: run codex-session-start.sh from inside a git worktree" >&2
  exit 1
}

TOOL_LOG="${BEAM_CODEX_TOOL_LOG:-${REPO_ROOT}/.beam/tooling.log}"

log_tool_use() {
  mkdir -p "$(dirname "${TOOL_LOG}")"
  printf '%s\t%s\tcwd=%s\targs=%s\n' \
    "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    "codex-session-start.sh" \
    "${PWD}" \
    "session-start" >> "${TOOL_LOG}" || true
}

die() {
  echo "error: $*" >&2
  exit 1
}

current_root() {
  git -C "${REPO_ROOT}" rev-parse --show-toplevel
}

primary_root() {
  git -C "${REPO_ROOT}" worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

current_branch() {
  git -C "${REPO_ROOT}" branch --show-current
}

tracked_dirty_count() {
  git -C "${REPO_ROOT}" status --short --untracked-files=no | wc -l | tr -d ' '
}

main() {
  log_tool_use

  local current primary branch tracked_dirty
  current="$(current_root)"
  primary="$(primary_root)"
  branch="$(current_branch)"
  tracked_dirty="$(tracked_dirty_count)"

  if [[ "${BEAM_CODEX_ALLOW_PRIMARY_WORKTREE:-0}" != "1" && "${current}" == "${primary}" ]]; then
    die "refusing to start a new agent task from the primary checkout ${primary}; use ./scripts/codex-harness.sh session start <task-id> instead"
  fi

  printf 'repo root: %s\n' "${current}"
  printf 'branch: %s\n' "${branch:-detached}"
  printf 'primary worktree: %s\n' "${primary}"
  printf 'tracked dirty files: %s\n' "${tracked_dirty}"
  if [[ "${current}" == "${primary}" ]]; then
    printf 'primary checkout override: enabled\n'
  else
    printf 'worktree discipline: dedicated task checkout\n'
  fi
}

main "$@"
