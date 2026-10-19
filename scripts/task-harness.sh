#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

# Maintainer workflow helper for this repository, shared by humans and coding agents.
# This script is intentionally local contributor tooling, not a product compatibility surface.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Task worktrees always belong to the primary checkout, even when this script runs from a task
# worktree; otherwise each task would nest its own worktree root.
REPO_ROOT="$(git -C "${SCRIPT_DIR}" worktree list --porcelain | awk '/^worktree / { print substr($0, 10); exit }')"
[[ -n "${REPO_ROOT}" ]] || {
  echo "error: could not resolve the primary checkout from ${SCRIPT_DIR}" >&2
  exit 1
}

WORKTREE_ROOT="${BEAM_TASK_WORKTREE_ROOT:-${REPO_ROOT}/.worktrees}"
BRANCH_PREFIX="task/"
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
  ./scripts/task-harness.sh start [--resume] <task-id> [base-ref]
  ./scripts/task-harness.sh adopt <task-id> [base-ref]
  ./scripts/task-harness.sh check
  ./scripts/task-harness.sh list
  ./scripts/task-harness.sh drop [--force] <task-id>
  ./scripts/task-harness.sh hook claude-worktree-create
  ./scripts/task-harness.sh hook claude-worktree-remove

Commands:
  start   Create the task worktree <root>/<task-id> on branch task/<task-id>. New task branches
          start from a freshly fetched origin/main unless base-ref is given; if the fetch fails,
          the last fetched origin/main is used and named on stderr. Tracked edits in the primary
          checkout block new tasks. --resume reuses an existing task worktree or task branch
          instead of refusing it.
  adopt   Turn the current worktree, created by another tool such as the Codex app, into task
          <task-id>: create branch task/<task-id> there from the same base as start. The worktree
          must be clean and have a detached HEAD. Its location and lifetime stay with that tool.
  check   Report whether the current checkout is a dedicated task worktree; fails in the
          primary checkout.
  list    List the worktrees of this repository.
  drop    Remove a task worktree and its branch, only when all its commits are on a branch
          origin has right now or merging it into a freshly fetched origin/main would change
          nothing; otherwise --force is needed. Uncommitted or untracked changes always block it;
          ignored files such as .lake and .beam are deleted with the worktree.
  hook    Adapters for Claude Code WorktreeCreate and WorktreeRemove hooks. They read the hook
          JSON on stdin; create starts or resumes the task named by the hook, remove drops the
          task worktree without --force.

start, adopt, and the create hook print only the worktree path on stdout; diagnostics go to
stderr.

Environment:
  BEAM_TASK_WORKTREE_ROOT        Task worktree root; must be inside the primary checkout.
                                 Defaults to <primary checkout>/.worktrees.
  BEAM_TASK_ALLOW_PRIMARY=1      Let check pass in the primary checkout.

Note:
  This is maintainer workflow tooling for this repo. It is not part of the public Beam CLI
  and its output is not a compatibility surface.
  Destructive cleanup must stay scoped to harness-owned worktrees under the task worktree root.
  Do not use broad rm/rm -rf against repo-local or user-local state from normal maintainer flows.
EOF
}

sanitize_task_id() {
  local task_id="$1"
  local slug
  slug="$(printf '%s' "${task_id}" | tr '/[:space:]' '-' | tr -cd '[:alnum:]._-')"
  [[ -n "${slug}" ]] || die "task id must contain at least one alphanumeric character"
  printf '%s\n' "${slug}"
}

branch_name_for() {
  printf '%s%s\n' "${BRANCH_PREFIX}" "$1"
}

worktree_path_for() {
  printf '%s/%s\n' "${WORKTREE_ROOT}" "$1"
}

realpath_of() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

ensure_safe_worktree_root() {
  local resolved_root resolved_repo
  [[ -n "${WORKTREE_ROOT}" ]] || die "BEAM_TASK_WORKTREE_ROOT must not be empty"
  case "${WORKTREE_ROOT}" in
    /*)
      ;;
    *)
      die "BEAM_TASK_WORKTREE_ROOT must be an absolute path: ${WORKTREE_ROOT}"
      ;;
  esac
  resolved_root="$(realpath_of "${WORKTREE_ROOT}")"
  resolved_repo="$(realpath_of "${REPO_ROOT}")"
  [[ "${resolved_root}" != "/" ]] || die "BEAM_TASK_WORKTREE_ROOT must not be /"
  [[ "${resolved_root}" != "${resolved_repo}" ]] || die \
    "BEAM_TASK_WORKTREE_ROOT must not be the primary checkout: ${resolved_root}"
  python3 - "$resolved_repo" "$resolved_root" <<'PY' >/dev/null || \
    die "BEAM_TASK_WORKTREE_ROOT must be inside the primary checkout: ${resolved_root}"
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
  tracked_status="$(git -C "${REPO_ROOT}" status --short --untracked-files=no)"
  [[ -z "${tracked_status}" ]] || die \
    "primary checkout has tracked edits; move or commit them before starting a new task worktree"
}

ensure_worktree_root() {
  ensure_safe_worktree_root
  mkdir -p "${WORKTREE_ROOT}"
}

DEFAULT_BASE_REF="refs/remotes/${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}"

# Runs a git command that talks to the default base remote. Agents run without a terminal, so it
# fails instead of prompting; unless the user configured an ssh command, ssh also fails fast.
remote_git() {
  if [[ -z "${GIT_SSH_COMMAND:-}${GIT_SSH:-}" ]] && ! git -C "${REPO_ROOT}" config --get core.sshCommand >/dev/null; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15" git -C "${REPO_ROOT}" "$@"
  else
    GIT_TERMINAL_PROMPT=0 git -C "${REPO_ROOT}" "$@"
  fi
}

# Fetches DEFAULT_BASE_REF, falling back to the last fetched copy with a warning. Fails when no copy
# exists. The explicit refspec updates the ref even when the configured refspec omits it.
refresh_default_base() {
  if remote_git fetch --quiet "${DEFAULT_BASE_REMOTE}" \
    "+refs/heads/${DEFAULT_BASE_BRANCH}:${DEFAULT_BASE_REF}" >&2; then
    return
  fi
  git -C "${REPO_ROOT}" show-ref --verify --quiet "${DEFAULT_BASE_REF}" || return 1
  warn "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; using the last fetched copy," \
    "$(git -C "${REPO_ROOT}" log -1 --format='%h "%s"' "${DEFAULT_BASE_REF}")"
}

resolve_default_base() {
  refresh_default_base || die \
    "could not fetch ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH} and no fetched copy exists; pass an explicit base-ref"
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
  repo_common_dir="$(git -C "${REPO_ROOT}" rev-parse --path-format=absolute --git-common-dir)" || return 1
  [[ "$(realpath_of "${common_dir}")" == "$(realpath_of "${repo_common_dir}")" ]] || return 1
  checked_out_branch "${path}"
}

# Prints the branch checked out in path, or nothing when detached. The full ref avoids --short's
# disambiguated output, such as heads/<name> next to a same-name tag.
checked_out_branch() {
  local head_ref
  head_ref="$(git -C "$1" symbolic-ref --quiet HEAD || true)"
  printf '%s\n' "${head_ref#refs/heads/}"
}

branch_exists() {
  git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/$1"
}

# Prints how many commits of the branch are not reachable from the branches origin has right now,
# or fails when origin cannot be listed. Asking origin avoids trusting local remote-tracking refs,
# which survive the deletion of a remote branch.
unpushed_commit_count() {
  local branch="$1"
  local remote_heads
  remote_heads="$(remote_git ls-remote --heads "${DEFAULT_BASE_REMOTE}")" || return 1
  {
    printf 'refs/heads/%s\n' "${branch}"
    # Only commits present locally can be excluded; newer commits pushed from elsewhere are skipped.
    printf '%s\n' "${remote_heads}" | cut -f 1 |
      git -C "${REPO_ROOT}" cat-file --batch-check='%(objectname) %(objecttype)' |
      awk '$2 == "commit" { print "^" $1 }'
  } | git -C "${REPO_ROOT}" rev-list --count --stdin
}

# Succeeds when merging the branch into the default base would change nothing, as after a squash
# merge. Needs Git 2.38 or newer for `merge-tree --write-tree`; older Git counts as unmerged.
merged_into_default_base() {
  local branch="$1"
  local merged_tree base_tree
  refresh_default_base || return 1
  merged_tree="$(git -C "${REPO_ROOT}" merge-tree --write-tree "${DEFAULT_BASE_REF}" "refs/heads/${branch}")" ||
    return 1
  base_tree="$(git -C "${REPO_ROOT}" rev-parse "${DEFAULT_BASE_REF}^{tree}")" || return 1
  [[ "${merged_tree}" == "${base_tree}" ]]
}

# Fails unless the branch is pushed to origin or merged into the default base.
ensure_safe_to_delete_branch() {
  local branch="$1"
  local unpushed
  if unpushed="$(unpushed_commit_count "${branch}")"; then
    [[ "${unpushed}" == "0" ]] || merged_into_default_base "${branch}" || die \
      "branch ${branch} has ${unpushed} commit(s) not found on any ${DEFAULT_BASE_REMOTE} branch and not merged into ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; push them, or pass --force to discard them"
  else
    warn "could not list ${DEFAULT_BASE_REMOTE}'s branches to check whether ${branch} is pushed"
    merged_into_default_base "${branch}" || die \
      "could not confirm that branch ${branch} is pushed or merged into ${DEFAULT_BASE_REMOTE}/${DEFAULT_BASE_BRANCH}; pass --force to delete it anyway"
  fi
}

# Fails unless path is a task worktree with the task branch checked out.
ensure_task_worktree() {
  local path="$1"
  local branch="$2"
  local current_branch
  current_branch="$(registered_worktree_branch "${path}")" || die \
    "${path} exists but is not a registered git worktree; inspect it and remove it manually"
  [[ "${current_branch}" == "${branch}" ]] || die \
    "task worktree ${path} has ${current_branch:-a detached HEAD} checked out, expected ${branch}"
}

start_task() {
  local task_id="$1"
  local base_ref="$2"
  local resume="$3"
  local slug branch path
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  ensure_worktree_root
  ensure_managed_worktree_path "${path}"
  if [[ "${resume}" == "1" && -n "${base_ref}" ]]; then
    die "--resume reuses an existing task; it cannot be combined with a base-ref"
  fi

  if [[ -e "${path}" ]]; then
    ensure_task_worktree "${path}" "${branch}"
    [[ "${resume}" == "1" ]] || die \
      "task worktree already exists: ${path}; pass --resume to reuse it or choose another task id"
  elif branch_exists "${branch}"; then
    [[ "${resume}" == "1" ]] || die \
      "branch ${branch} already exists; pass --resume to check it out or choose another task id"
    git -C "${REPO_ROOT}" worktree add "${path}" "${branch}" >&2 || die \
      "could not check out ${branch} at ${path}; see the git error above"
  else
    [[ "${resume}" != "1" ]] || die "nothing to resume: no worktree or branch exists for task ${slug}"
    # Resuming never reads the primary checkout, so only new tasks are guarded.
    ensure_primary_tracked_clean
    [[ -n "${base_ref}" ]] || base_ref="$(resolve_default_base)"
    # --no-track keeps a plain `git push` from targeting the base branch.
    git -C "${REPO_ROOT}" worktree add --no-track -b "${branch}" "${path}" "${base_ref}" >&2 || die \
      "could not create ${branch} at ${path} from ${base_ref}; see the git error above"
  fi
  report_checkout "${path}" >&2
  printf '%s\n' "${path}"
}

adopt_task() {
  local task_id="$1"
  local base_ref="$2"
  local slug branch path current_branch status
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run adopt from inside a worktree of this repository"

  current_branch="$(registered_worktree_branch "${path}")" || die \
    "${path} is not a worktree of ${REPO_ROOT}"
  [[ "$(realpath_of "${path}")" != "$(realpath_of "${REPO_ROOT}")" ]] || die \
    "refusing to adopt the primary checkout; use ./scripts/task-harness.sh start <task-id> instead"
  if [[ "${current_branch}" == "${branch}" ]]; then
    printf '%s\n' "${path}"
    return
  fi
  [[ -z "${current_branch}" ]] || die \
    "${path} already has branch ${current_branch} checked out; adopt needs a detached HEAD"
  status="$(git -C "${path}" status --porcelain)" || die "could not read the status of ${path}"
  [[ -z "${status}" ]] || die \
    "${path} has uncommitted or untracked changes; adopt needs a clean checkout"
  ! branch_exists "${branch}" || die \
    "branch ${branch} already exists; use ./scripts/task-harness.sh start --resume ${slug} or choose another task id"

  [[ -n "${base_ref}" ]] || base_ref="$(resolve_default_base)"
  git -C "${path}" switch --quiet --no-track -c "${branch}" "${base_ref}" >&2 || die \
    "could not create ${branch} in ${path} from ${base_ref}; see the git error above"
  report_checkout "${path}" >&2
  printf '%s\n' "${path}"
}

drop_task() {
  local task_id="$1"
  local force="$2"
  local slug branch path
  slug="$(sanitize_task_id "${task_id}")"
  branch="$(branch_name_for "${slug}")"
  path="$(worktree_path_for "${slug}")"

  ensure_worktree_root
  ensure_managed_worktree_path "${path}"
  [[ -d "${path}" ]] || die \
    "unknown worktree path: ${path}; if its directory was deleted by hand, run git worktree prune"
  ensure_task_worktree "${path}" "${branch}"
  [[ "${force}" == "1" ]] || ensure_safe_to_delete_branch "${branch}"

  # Without --force, git refuses to remove a worktree with uncommitted or untracked changes.
  git -C "${REPO_ROOT}" worktree remove "${path}" >/dev/null || die \
    "could not remove ${path}; see the git error above"
  git -C "${REPO_ROOT}" branch -D "${branch}" >/dev/null || die \
    "could not delete branch ${branch}; see the git error above"
}

report_checkout() {
  local path="$1"
  printf 'task worktree: %s\n' "${path}"
  printf 'branch: %s\n' "$(checked_out_branch "${path}" | grep . || echo detached)"
  printf 'base: %s\n' "$(git -C "${path}" log -1 --format='%h %s' HEAD)"
  printf 'primary checkout: %s\n' "${REPO_ROOT}"
}

check_checkout() {
  local current
  current="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run check from inside a git worktree"
  if [[ "$(realpath_of "${current}")" == "$(realpath_of "${REPO_ROOT}")" ]]; then
    [[ "${BEAM_TASK_ALLOW_PRIMARY:-0}" == "1" ]] || die \
      "refusing to work in the primary checkout ${REPO_ROOT}; use ./scripts/task-harness.sh start <task-id> instead"
    printf 'primary checkout override: enabled\n'
  else
    printf 'worktree discipline: dedicated task checkout\n'
  fi
  printf 'checkout: %s\n' "${current}"
  printf 'branch: %s\n' "$(checked_out_branch "${current}" | grep . || echo detached)"
  printf 'tracked dirty files: %s\n' "$(git -C "${current}" status --short --untracked-files=no | wc -l | tr -d ' ')"
}

# Prints one string field of the hook JSON object on stdin.
hook_input_field() {
  python3 -c '
import json, sys
value = json.load(sys.stdin).get(sys.argv[1])
if not isinstance(value, str) or not value:
    sys.exit("hook input has no %s field" % sys.argv[1])
print(value)
' "$1"
}

# Claude Code reads the last stdout line as the worktree path and fails creation on a non-zero exit.
claude_worktree_create() {
  local name slug resume="0"
  name="$(hook_input_field name)"
  slug="$(sanitize_task_id "${name}")"
  # The hook runs when Claude Code asks for this name, so an existing task is resumed.
  if [[ -e "$(worktree_path_for "${slug}")" ]] || branch_exists "$(branch_name_for "${slug}")"; then
    resume="1"
  fi
  start_task "${slug}" "" "${resume}"
}

# Claude Code keeps the worktree when this exits non-zero and the directory still exists.
claude_worktree_remove() {
  local path resolved_root resolved_path
  path="$(hook_input_field worktree_path)"
  resolved_root="$(realpath_of "${WORKTREE_ROOT}")"
  resolved_path="$(realpath_of "${path}")"
  [[ "$(dirname "${resolved_path}")" == "${resolved_root}" ]] || die \
    "refusing to remove ${path}: it is not a task worktree under ${WORKTREE_ROOT}"
  drop_task "$(basename "${resolved_path}")" "0"
}

# Parses `[--resume] <task-id> [base-ref]` into TASK_ID, BASE_REF, and RESUME.
parse_task_args() {
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
    usage >&2
    exit 1
  }

  local command="$1"
  shift
  case "${command}" in
    start)
      parse_task_args "$@"
      start_task "${TASK_ID}" "${BASE_REF}" "${RESUME}"
      ;;
    adopt)
      parse_task_args "$@"
      [[ "${RESUME}" != "1" ]] || die "adopt does not take --resume"
      adopt_task "${TASK_ID}" "${BASE_REF}"
      ;;
    check)
      [[ "$#" -eq 0 ]] || die "check takes no arguments"
      check_checkout
      ;;
    list)
      git -C "${REPO_ROOT}" worktree list
      ;;
    drop)
      parse_drop_args "$@"
      drop_task "${TASK_ID}" "${FORCE}"
      ;;
    hook)
      case "${1:-}" in
        claude-worktree-create)
          claude_worktree_create
          ;;
        claude-worktree-remove)
          claude_worktree_remove
          ;;
        *)
          die "usage: ./scripts/task-harness.sh hook {claude-worktree-create|claude-worktree-remove}"
          ;;
      esac
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "unknown command: ${command}"
      ;;
  esac
}

main "$@"
