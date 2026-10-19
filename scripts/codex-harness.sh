#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

# Maintainer workflow helper for this repository.
# This script is intentionally local contributor tooling, not a product compatibility surface.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

default_worktree_root() {
  printf '%s\n' "${REPO_ROOT}/.codex-worktrees/lean-beam"
}

WORKTREE_ROOT="${BEAM_CODEX_WORKTREE_ROOT:-$(default_worktree_root)}"
DEFAULT_BASE_REMOTE="origin"
DEFAULT_BASE_BRANCH="main"

die() {
  echo "error: $*" >&2
  exit 1
}

warn() {
  echo "warning: $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/codex-harness.sh session start <task-id> [base-ref]
  ./scripts/codex-harness.sh session start --resume <task-id>
  ./scripts/codex-harness.sh worktree add <task-id> [base-ref]
  ./scripts/codex-harness.sh worktree add --resume <task-id>
  ./scripts/codex-harness.sh worktree list
  ./scripts/codex-harness.sh worktree drop [--force] <task-id>

Commands:
  New task worktrees start from a freshly fetched origin/main unless base-ref is given. If the
  fetch fails, the last fetched origin/main is used and its age is reported on stderr.
  --resume reuses an existing task worktree or task branch instead of refusing it.
  drop refuses to delete a task branch with commits that are neither on any remote nor already
  merged into origin/main; --force deletes it anyway. Uncommitted or untracked changes always
  block drop; ignored files such as .lake and .beam are deleted with the worktree.
  worktree add prints only the worktree path on stdout; session start prints the session summary
  followed by the path. Diagnostics go to stderr.

Environment:
  BEAM_CODEX_WORKTREE_ROOT
  BEAM_CODEX_ALLOW_PRIMARY_WORKTREE=1   Allow session-start in the primary checkout

Note:
  This is maintainer workflow tooling for this repo. It is not part of the public Beam CLI
  and its output is not a compatibility surface.
  By default, worktrees live under .codex-worktrees/lean-beam inside this repo.
  BEAM_CODEX_WORKTREE_ROOT must also point inside this repo when set explicitly.
  Destructive cleanup must stay scoped to harness-owned worktrees under BEAM_CODEX_WORKTREE_ROOT.
  Do not use broad rm/rm -rf against repo-local or user-local state from normal maintainer flows.
EOF
}

primary_root() {
  git -C "${REPO_ROOT}" worktree list --porcelain | awk '/^worktree / { print $2; exit }'
}

sanitize_task_id() {
  local task_id="$1"
  local slug
  slug="$(printf '%s' "${task_id}" | tr '/[:space:]' '-' | tr -cd '[:alnum:]._-')"
  [[ -n "${slug}" ]] || die "task id must contain at least one alphanumeric character"
  printf '%s\n' "${slug}"
}

branch_name_for() {
  printf 'codex/%s\n' "$1"
}

worktree_path_for() {
  printf '%s/%s\n' "${WORKTREE_ROOT}" "$1"
}

realpath_of() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

ensure_safe_worktree_root() {
  local resolved_root resolved_repo resolved_primary
  [[ -n "${WORKTREE_ROOT}" ]] || die "BEAM_CODEX_WORKTREE_ROOT must not be empty"
  case "${WORKTREE_ROOT}" in
    /*)
      ;;
    *)
      die "BEAM_CODEX_WORKTREE_ROOT must be an absolute path: ${WORKTREE_ROOT}"
      ;;
  esac
  resolved_root="$(realpath_of "${WORKTREE_ROOT}")"
  resolved_repo="$(realpath_of "${REPO_ROOT}")"
  resolved_primary="$(realpath_of "$(primary_root)")"
  [[ "${resolved_root}" != "/" ]] || die "BEAM_CODEX_WORKTREE_ROOT must not be /"
  [[ "${resolved_root}" != "${resolved_repo}" ]] || die \
    "BEAM_CODEX_WORKTREE_ROOT must not be the repo root: ${resolved_root}"
  [[ "${resolved_root}" != "${resolved_primary}" ]] || die \
    "BEAM_CODEX_WORKTREE_ROOT must not be the primary worktree: ${resolved_root}"
  python3 - "$resolved_repo" "$resolved_root" <<'PY' >/dev/null || \
    die "BEAM_CODEX_WORKTREE_ROOT must be inside the repo root: ${resolved_root}"
import os, sys
repo, root = sys.argv[1:]
if os.path.commonpath([repo, root]) != repo:
    raise SystemExit(1)
PY
}

ensure_managed_worktree_path() {
  local path="$1"
  local resolved_root resolved_path
  resolved_root="$(realpath_of "${WORKTREE_ROOT}")"
  resolved_path="$(realpath_of "${path}")"
  python3 - "$resolved_root" "$resolved_path" <<'PY' >/dev/null || \
    die "refusing to operate on unmanaged worktree path: ${path}"
import os, sys
root, path = sys.argv[1:]
if os.path.commonpath([root, path]) != root:
    raise SystemExit(1)
PY
}

ensure_primary_tracked_clean() {
  local tracked_status
  tracked_status="$(git -C "$(primary_root)" status --short --untracked-files=no)"
  [[ -z "${tracked_status}" ]] || die \
    "primary checkout has tracked edits; move or commit them before starting a new task worktree"
}

ensure_worktree_root() {
  ensure_safe_worktree_root
  mkdir -p "${WORKTREE_ROOT}"
}

DEFAULT_BASE_REF="refs/remotes/${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}"

# Refreshes DEFAULT_BASE_REF and fails, without exiting, when the fetch fails.
fetch_default_base() {
  # The explicit refspec updates the remote-tracking ref even when the configured refspec omits it.
  local refspec="+refs/heads/${DEFAULT_BASE_BRANCH}:${DEFAULT_BASE_REF}"
  # Agents run without a terminal: fail instead of waiting on a terminal credential prompt or a
  # silently dropped connection. A user-configured ssh command is left alone.
  if [[ -z "${GIT_SSH_COMMAND:-}${GIT_SSH:-}" ]] && ! git -C "${REPO_ROOT}" config --get core.sshCommand >/dev/null; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" \
      git -C "${REPO_ROOT}" fetch --quiet "${DEFAULT_BASE_REMOTE}" "${refspec}" >&2
  else
    GIT_TERMINAL_PROMPT=0 git -C "${REPO_ROOT}" fetch --quiet "${DEFAULT_BASE_REMOTE}" "${refspec}" >&2
  fi
}

last_fetched_base_label() {
  git -C "${REPO_ROOT}" log -1 --format='%h, committed %cr' "${DEFAULT_BASE_REF}"
}

resolve_default_base() {
  if ! fetch_default_base; then
    git -C "${REPO_ROOT}" show-ref --verify --quiet "${DEFAULT_BASE_REF}" || die \
      "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH} and no fetched copy exists; pass an explicit base-ref"
    warn "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; starting from the last fetched copy:" \
      "$(last_fetched_base_label)"
  fi
  printf '%s\n' "${DEFAULT_BASE_REF}"
}

# Prints the branch checked out in path (empty when detached), or fails unless path is the top
# level of a worktree of this repository.
registered_worktree_branch() {
  local path="$1"
  local toplevel common_dir repo_common_dir
  toplevel="$(git -C "${path}" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ "$(realpath_of "${toplevel}")" == "$(realpath_of "${path}")" ]] || return 1
  common_dir="$(git -C "${path}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  repo_common_dir="$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir)"
  [[ "$(realpath_of "${common_dir}")" == "$(realpath_of "${repo_common_dir}")" ]] || return 1
  # The full ref avoids --short's disambiguated output, such as heads/<name> next to a same-name tag.
  local head_ref
  head_ref="$(git -C "${path}" symbolic-ref --quiet HEAD || true)"
  printf '%s\n' "${head_ref#refs/heads/}"
}

unpushed_commit_count() {
  git -C "${REPO_ROOT}" rev-list --count "refs/heads/$1" --not --remotes
}

# Succeeds when merging the branch into the default base would change nothing, which is the case
# after a squash merge even once the merged remote branch has been deleted and pruned.
merged_into_default_base() {
  local branch="$1"
  local merged_tree merge_tree_help
  # `git merge-tree -h` exits non-zero; capture it rather than piping into an early-exiting grep.
  merge_tree_help="$(git -C "${REPO_ROOT}" merge-tree -h 2>&1 || true)"
  if [[ "${merge_tree_help}" != *--write-tree* ]]; then
    warn "detecting squash-merged branches needs Git 2.38 or newer"
    return 1
  fi
  if ! fetch_default_base; then
    if ! git -C "${REPO_ROOT}" show-ref --verify --quiet "${DEFAULT_BASE_REF}"; then
      warn "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; cannot check whether ${branch} is merged"
      return 1
    fi
    warn "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; checking against the last fetched copy:" \
      "$(last_fetched_base_label)"
  fi
  merged_tree="$(git -C "${REPO_ROOT}" merge-tree --write-tree "${DEFAULT_BASE_REF}" "refs/heads/${branch}")" ||
    return 1
  [[ "${merged_tree}" == "$(git -C "${REPO_ROOT}" rev-parse "${DEFAULT_BASE_REF}^{tree}")" ]]
}

add_worktree() {
  local task_id="$1"
  local base_ref="$2"
  local resume="$3"
  local slug branch path current_branch
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  ensure_primary_tracked_clean
  ensure_worktree_root
  ensure_managed_worktree_path "${path}"
  # Forget registrations whose directory was deleted by hand, so the task can be resumed or dropped.
  git -C "${REPO_ROOT}" worktree prune

  if [[ "${resume}" == "1" && -n "${base_ref}" ]]; then
    die "--resume reuses an existing task; it cannot be combined with a base-ref"
  fi

  if [[ -e "${path}" ]]; then
    current_branch="$(registered_worktree_branch "${path}")" || die \
      "${path} exists but is not a registered git worktree; inspect it and remove it manually"
    [[ "${current_branch}" == "${branch}" ]] || die \
      "task worktree ${path} has ${current_branch:-a detached HEAD} checked out, expected ${branch}"
    [[ "${resume}" == "1" ]] || die \
      "task worktree already exists: ${path}; pass --resume to reuse it or choose another task id"
    printf '%s\n' "${path}"
    return
  fi

  if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
    [[ "${resume}" == "1" ]] || die \
      "branch ${branch} already exists; pass --resume to check it out or choose another task id"
    git -C "${REPO_ROOT}" worktree add "${path}" "${branch}" >/dev/null
    printf '%s\n' "${path}"
    return
  fi

  [[ "${resume}" != "1" ]] || die "nothing to resume: no worktree or branch exists for task ${slug}"
  [[ -n "${base_ref}" ]] || base_ref="$(resolve_default_base)"
  # --no-track keeps a plain `git push` from targeting the base branch.
  git -C "${REPO_ROOT}" worktree add --no-track -b "${branch}" "${path}" "${base_ref}" >/dev/null
  printf '%s\n' "${path}"
}

drop_worktree() {
  local task_id="$1"
  local force="$2"
  local slug branch path current_branch unpushed
  local has_worktree="0"
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  ensure_worktree_root
  ensure_managed_worktree_path "${path}"
  # Forget registrations whose directory was deleted by hand; the branch still gets the checks below.
  git -C "${REPO_ROOT}" worktree prune
  if [[ -e "${path}" ]]; then
    current_branch="$(registered_worktree_branch "${path}")" || die \
      "${path} is not a registered git worktree; inspect it and remove it manually"
    [[ "${current_branch}" == "${branch}" ]] || die \
      "task worktree ${path} has ${current_branch:-a detached HEAD} checked out, expected ${branch}; refusing to drop it"
    has_worktree="1"
  else
    git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}" || die \
      "unknown task ${slug}: no worktree at ${path} and no branch ${branch}"
  fi

  if [[ "${force}" != "1" ]]; then
    unpushed="$(unpushed_commit_count "${branch}")"
    [[ "${unpushed}" == "0" ]] || merged_into_default_base "${branch}" || die \
      "branch ${branch} has ${unpushed} commit(s) that are neither on any remote nor merged into ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; push them or pass --force to discard them"
  fi

  if [[ "${has_worktree}" == "1" ]]; then
    # Without --force, git refuses to remove a worktree with uncommitted or untracked changes.
    git -C "${REPO_ROOT}" worktree remove "${path}" >/dev/null || die \
      "could not remove ${path}; commit, push, or discard its changes first"
  fi
  git -C "${REPO_ROOT}" branch -D "${branch}" >/dev/null || die "could not delete branch ${branch}"
}

list_worktrees() {
  git -C "${REPO_ROOT}" worktree list
}

session_start() {
  local path
  path="$(add_worktree "$@")"
  (
    cd "${path}"
    "${SCRIPT_DIR}/codex-session-start.sh"
  )
  printf '%s\n' "${path}"
}

# Parses `[--resume] <task-id> [base-ref]` into TASK_ID, BASE_REF, and RESUME.
parse_add_args() {
  TASK_ID=""
  BASE_REF=""
  RESUME="0"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --resume)
        RESUME="1"
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "${TASK_ID}" ]]; then
          TASK_ID="$1"
        elif [[ -z "${BASE_REF}" ]]; then
          BASE_REF="$1"
        else
          die "unexpected argument: $1"
        fi
        ;;
    esac
    shift
  done
  [[ -n "${TASK_ID}" ]] || die "missing task id"
}

# Parses `[--force] <task-id>` into TASK_ID and FORCE.
parse_drop_args() {
  TASK_ID=""
  FORCE="0"
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --force)
        FORCE="1"
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        [[ -z "${TASK_ID}" ]] || die "unexpected argument: $1"
        TASK_ID="$1"
        ;;
    esac
    shift
  done
  [[ -n "${TASK_ID}" ]] || die "missing task id"
}

main() {
  [[ "$#" -gt 0 ]] || {
    usage
    exit 1
  }

  case "$1" in
    session)
      [[ "${2:-}" == "start" ]] || die "usage: ./scripts/codex-harness.sh session start {<task-id> [base-ref]|--resume <task-id>}"
      shift 2
      parse_add_args "$@"
      session_start "${TASK_ID}" "${BASE_REF}" "${RESUME}"
      ;;
    worktree)
      case "${2:-}" in
        add)
          shift 2
          parse_add_args "$@"
          add_worktree "${TASK_ID}" "${BASE_REF}" "${RESUME}"
          ;;
        list)
          list_worktrees
          ;;
        drop)
          shift 2
          parse_drop_args "$@"
          drop_worktree "${TASK_ID}" "${FORCE}"
          ;;
        *)
          die "usage: ./scripts/codex-harness.sh worktree {add|list|drop} ..."
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: $1"
      ;;
  esac
}

main "$@"
