#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
source_root="$(pwd)"

# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh
# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh

tmp_root="$(mktemp -d /tmp/beam-codex-harness-XXXXXX)"

cleanup() {
  beam_test_remove_owned_tmp_tree "$tmp_root" beam-codex-harness
}
trap cleanup EXIT

# The harness runs against a throwaway repository with a local bare origin, so the test never
# creates worktrees or branches in the checkout under test and does not depend on network access.
unset BEAM_CODEX_WORKTREE_ROOT BEAM_CODEX_ALLOW_PRIMARY_WORKTREE BEAM_CODEX_TOOL_LOG GIT_SSH_COMMAND GIT_SSH
export GIT_CONFIG_GLOBAL="$tmp_root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Beam Harness Test"
git config --global user.email "beam-harness-test@example.invalid"
git config --global init.defaultBranch main

origin="$tmp_root/origin.git"
repo="$tmp_root/repo"
upstream_clone="$tmp_root/upstream-clone"
git init --quiet --bare "$origin"
git init --quiet "$repo"
mkdir -p "$repo/scripts"
cp "$source_root/scripts/codex-harness.sh" "$source_root/scripts/codex-session-start.sh" "$repo/scripts/"
printf 'fixture\n' > "$repo/README"
# Mirror the repository's ignore rule for the session-start tool log.
printf '.beam/\n' > "$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit --quiet -m "initial"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push --quiet origin main

harness="$repo/scripts/codex-harness.sh"
default_root="$repo/.codex-worktrees/lean-beam"

# Run the harness from the fixture repo, capturing stdout and stderr in files under tmp_root.
run_harness() {
  local name="$1"
  shift
  (cd "$repo" && "$harness" "$@") >"$tmp_root/$name.out" 2>"$tmp_root/$name.err"
}

expect_harness_ok() {
  local name="$1"
  shift
  if ! run_harness "$name" "$@"; then
    echo "expected harness $* to succeed" >&2
    cat "$tmp_root/$name.err" >&2
    exit 1
  fi
}

expect_harness_fails_with() {
  local name="$1"
  local expected="$2"
  shift 2
  if run_harness "$name" "$@"; then
    echo "expected harness $* to fail" >&2
    cat "$tmp_root/$name.out" >&2
    exit 1
  fi
  assert_contains_literal "$tmp_root/$name.err" "$expected"
}

expect_same_commit() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [ "$(git -C "$repo" rev-parse "$actual")" != "$(git -C "$repo" rev-parse "$expected")" ]; then
    echo "expected $label to be at $expected, got $(git -C "$repo" log -1 --format=%h "$actual")" >&2
    exit 1
  fi
}

expect_branch() {
  if ! git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; then
    echo "expected branch $1 to exist" >&2
    exit 1
  fi
}

expect_no_branch() {
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$1"; then
    echo "expected branch $1 to be deleted" >&2
    exit 1
  fi
}

commit_in() {
  local path="$1"
  printf '%s\n' "$2" >> "$path/README"
  git -C "$path" commit --quiet -am "$2"
}

# Advance origin/main past the fixture's local main, which is now stale.
git clone --quiet "$origin" "$upstream_clone"
commit_in "$upstream_clone" "upstream change"
git -C "$upstream_clone" push --quiet origin main
upstream_head="$(git -C "$upstream_clone" rev-parse HEAD)"

# session start creates a task worktree from freshly fetched origin/main, not stale local main.
expect_harness_ok session-start session start fresh
assert_contains_literal "$tmp_root/session-start.out" "$default_root/fresh"
assert_contains_literal "$tmp_root/session-start.out" "worktree discipline: dedicated task checkout"
expect_same_commit "fresh task" codex/fresh "$upstream_head"
if git -C "$default_root/fresh" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  echo "expected task branch not to track the base branch" >&2
  exit 1
fi

# The fetch refreshes origin/main even when the configured refspec does not cover it, as in a
# single-branch clone of another branch.
commit_in "$upstream_clone" "second upstream change"
git -C "$upstream_clone" push --quiet origin main
upstream_head="$(git -C "$upstream_clone" rev-parse HEAD)"
git -C "$repo" config remote.origin.fetch "+refs/heads/other:refs/remotes/origin/other"
expect_harness_ok narrow-refspec worktree add narrow-refspec
expect_same_commit "narrow-refspec task" codex/narrow-refspec "$upstream_head"
git -C "$repo" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

# An explicit base ref is used as given and not fetched.
expect_harness_ok explicit-base worktree add explicit-base main
expect_same_commit "explicit-base task" codex/explicit-base main

# When origin is unreachable, the last fetched origin/main is used with a warning.
git -C "$repo" remote set-url origin "$tmp_root/missing-origin.git"
expect_harness_ok offline worktree add offline
assert_contains_literal "$tmp_root/offline.err" "could not fetch origin/main; starting from the last fetched copy"
expect_same_commit "offline task" codex/offline "$upstream_head"
git -C "$repo" remote set-url origin "$origin"

# An existing task worktree is reused only with --resume.
expect_harness_fails_with existing "pass --resume to reuse it" worktree add fresh
expect_harness_ok resume-existing worktree add --resume fresh
if [ "$(cat "$tmp_root/resume-existing.out")" != "$default_root/fresh" ]; then
  echo "expected --resume to print only the worktree path on stdout" >&2
  cat "$tmp_root/resume-existing.out" >&2
  exit 1
fi
expect_harness_fails_with resume-base "cannot be combined with a base-ref" worktree add --resume fresh main
expect_harness_fails_with resume-missing "nothing to resume" worktree add --resume never-created

# An existing task branch without a worktree is checked out only with --resume.
git -C "$repo" worktree remove "$default_root/explicit-base"
expect_harness_fails_with existing-branch "branch codex/explicit-base already exists" worktree add explicit-base
expect_harness_ok resume-branch session start --resume explicit-base
expect_same_commit "resumed task" codex/explicit-base main

# A worktree path with another branch checked out is neither reused nor dropped.
git -C "$default_root/offline" switch --quiet -c other-work
expect_harness_fails_with wrong-branch-add "expected codex/offline" worktree add --resume offline
expect_harness_fails_with wrong-branch-drop "refusing to drop it" worktree drop offline
git -C "$default_root/offline" switch --quiet codex/offline

# A plain directory at a task path is not treated as a worktree.
mkdir -p "$default_root/plain-dir"
expect_harness_fails_with plain-dir "is not a registered git worktree" worktree add --resume plain-dir

# drop refuses to discard commits that are not on any remote, and keeps the worktree intact.
commit_in "$default_root/fresh" "local task work"
expect_harness_fails_with drop-unpushed "1 commit(s) that are neither on any remote nor merged" worktree drop fresh
expect_branch codex/fresh
assert_file "$default_root/fresh/README"

# Once the task branch is pushed, drop removes the worktree and its branch.
git -C "$default_root/fresh" push --quiet origin codex/fresh
expect_harness_ok drop-pushed worktree drop fresh
assert_not_exists "$default_root/fresh"
expect_no_branch codex/fresh

# A squash-merged task branch can be dropped after its remote branch is deleted and pruned.
commit_in "$default_root/narrow-refspec" "squashed task work"
git -C "$default_root/narrow-refspec" push --quiet origin codex/narrow-refspec
git -C "$upstream_clone" pull --quiet origin main
git -C "$upstream_clone" fetch --quiet origin codex/narrow-refspec
git -C "$upstream_clone" merge --quiet --squash FETCH_HEAD >/dev/null
git -C "$upstream_clone" commit --quiet -m "squash merge narrow-refspec"
git -C "$upstream_clone" push --quiet origin main
git -C "$upstream_clone" push --quiet origin --delete codex/narrow-refspec
git -C "$repo" fetch --quiet --prune origin
expect_harness_ok drop-squashed worktree drop narrow-refspec
assert_not_exists "$default_root/narrow-refspec"
expect_no_branch codex/narrow-refspec

# A tag with the task branch name does not hide the branch's unpushed commits.
commit_in "$default_root/offline" "work behind a same-name tag"
git -C "$repo" tag codex/offline "$upstream_head"
expect_harness_fails_with drop-tag-shadow "1 commit(s) that are neither on any remote nor merged" worktree drop offline
git -C "$repo" tag -d codex/offline >/dev/null
git -C "$default_root/offline" reset --quiet --hard HEAD~1

# --force discards unpushed commits.
commit_in "$default_root/offline" "throwaway work"
expect_harness_ok drop-force worktree drop --force offline
assert_not_exists "$default_root/offline"
expect_no_branch codex/offline

# Uncommitted changes block drop even with --force.
printf 'uncommitted\n' >> "$default_root/explicit-base/README"
expect_harness_fails_with drop-dirty "contains modified or untracked files" worktree drop --force explicit-base
assert_file "$default_root/explicit-base/README"
expect_branch codex/explicit-base

# A worktree directory deleted by hand can still be resumed, and dropped with the same checks.
expect_harness_ok removed-dir worktree add removed-dir
rm -rf -- "$default_root/removed-dir"
expect_harness_ok removed-dir-resume worktree add --resume removed-dir
if [ "$(cat "$tmp_root/removed-dir-resume.out")" != "$default_root/removed-dir" ]; then
  echo "expected --resume of a deleted worktree to print only its path" >&2
  cat "$tmp_root/removed-dir-resume.out" >&2
  exit 1
fi
commit_in "$default_root/removed-dir" "work in a deleted directory"
rm -rf -- "$default_root/removed-dir"
expect_harness_fails_with removed-dir-unpushed "neither on any remote nor merged" worktree drop removed-dir
expect_branch codex/removed-dir
git -C "$repo" push --quiet origin codex/removed-dir
expect_harness_ok removed-dir-drop worktree drop removed-dir
expect_no_branch codex/removed-dir
expect_harness_fails_with unknown-task "unknown task removed-dir" worktree drop removed-dir

# Without a user ssh setting, the fetch uses non-interactive ssh with a connect timeout; a user's
# GIT_SSH wrapper is left alone. Fake ssh programs record their arguments without any network.
fake_bin="$tmp_root/fake-bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/fake-ssh.log"\nexit 1\n' "$tmp_root" > "$fake_bin/ssh"
printf '#!/bin/sh\nprintf "wrapper %%s\\n" "$*" >> "%s/fake-wrapper.log"\nexit 1\n' "$tmp_root" > "$fake_bin/ssh-wrapper"
chmod +x "$fake_bin/ssh" "$fake_bin/ssh-wrapper"
git -C "$repo" remote set-url origin "harness-test.invalid:repo.git"
PATH="$fake_bin:$PATH" expect_harness_ok ssh-default worktree add ssh-default
assert_contains_literal "$tmp_root/fake-ssh.log" "BatchMode=yes -o ConnectTimeout=15"
rm -f -- "$tmp_root/fake-ssh.log"
PATH="$fake_bin:$PATH" GIT_SSH="$fake_bin/ssh-wrapper" expect_harness_ok ssh-wrapper worktree add ssh-wrapper
assert_contains_literal "$tmp_root/fake-wrapper.log" "wrapper "
assert_not_exists "$tmp_root/fake-ssh.log"

# A failed fetch during drop is reported, and the merge check falls back to the last fetched copy.
commit_in "$default_root/ssh-default" "unmerged work"
PATH="$fake_bin:$PATH" expect_harness_fails_with drop-offline "neither on any remote nor merged" worktree drop ssh-default
assert_contains_literal "$tmp_root/drop-offline.err" "checking codex/ssh-default against the last fetched remote branches"
git -C "$repo" update-ref -d refs/remotes/origin/main
PATH="$fake_bin:$PATH" expect_harness_fails_with drop-no-base "neither on any remote nor merged" worktree drop ssh-default
assert_contains_literal "$tmp_root/drop-no-base.err" "no fetched origin/main; cannot check whether codex/ssh-default is merged"
git -C "$repo" remote set-url origin "$origin"
git -C "$repo" fetch --quiet origin

# A pushed task branch deleted on the remote without being merged is no longer treated as pushed,
# even before the local remote-tracking ref is pruned.
expect_harness_ok remote-deleted worktree add remote-deleted
commit_in "$default_root/remote-deleted" "work on a deleted remote branch"
git -C "$default_root/remote-deleted" push --quiet origin codex/remote-deleted
git -C "$upstream_clone" push --quiet origin --delete codex/remote-deleted
expect_harness_fails_with drop-remote-deleted "neither on any remote nor merged" worktree drop remote-deleted
expect_branch codex/remote-deleted

# A squash-merged branch is recognized even after later base commits change nearby lines, which
# makes a three-way merge of the branch conflict.
commit_in "$default_root/remote-deleted" "second line of squashed work"
git -C "$upstream_clone" pull --quiet origin main
git -C "$default_root/remote-deleted" diff "$(git -C "$repo" merge-base origin/main codex/remote-deleted)" codex/remote-deleted |
  git -C "$upstream_clone" apply
git -C "$upstream_clone" commit --quiet -am "squash merge remote-deleted"
printf 'follow-up next to the squashed lines\n' >> "$upstream_clone/README"
git -C "$upstream_clone" commit --quiet -am "follow-up"
git -C "$upstream_clone" push --quiet origin main
expect_harness_ok drop-squashed-moved worktree drop remote-deleted
expect_no_branch codex/remote-deleted

# Cleaning up a deleted task directory leaves unrelated missing worktree registrations alone.
unrelated="$tmp_root/unrelated-worktree"
git -C "$repo" worktree add --quiet --detach "$unrelated" main
rm -rf -- "$unrelated"
expect_harness_ok unrelated-add worktree add unrelated-check
expect_harness_ok unrelated-drop worktree drop unrelated-check
assert_contains_literal <(git -C "$repo" worktree list --porcelain) "worktree $unrelated"
git -C "$repo" worktree prune

# A failure inside session start stops it with one error instead of continuing with an empty base.
git -C "$repo" remote set-url origin "$tmp_root/missing-origin.git"
saved_base="$(git -C "$repo" rev-parse origin/main)"
git -C "$repo" update-ref -d refs/remotes/origin/main
expect_harness_fails_with start-no-base "no fetched copy exists" session start no-base
assert_not_contains "$tmp_root/start-no-base.err" "invalid reference"
assert_not_exists "$default_root/no-base"
git -C "$repo" update-ref refs/remotes/origin/main "$saved_base"
git -C "$repo" remote set-url origin "$origin"

# Tracked edits in the primary checkout block new tasks but not resuming an existing one.
printf 'primary edit\n' >> "$repo/README"
expect_harness_fails_with dirty-primary-new "primary checkout has tracked edits" worktree add dirty-primary
expect_harness_ok dirty-primary-resume worktree add --resume explicit-base
git -C "$repo" checkout --quiet -- README

# A task interrupted during a rebase can be resumed, but not dropped until the rebase is finished.
expect_harness_ok rebasing worktree add rebasing
commit_in "$default_root/rebasing" "commit to replay"
git -C "$default_root/rebasing" rebase --quiet --exec false HEAD~1 >/dev/null 2>&1 || true
expect_harness_ok rebasing-resume worktree add --resume rebasing
assert_contains_literal "$tmp_root/rebasing-resume.err" "a rebase of codex/rebasing is in progress"
expect_harness_fails_with rebasing-drop "finish or abort it before dropping the task" worktree drop --force rebasing
git -C "$default_root/rebasing" rebase --abort

# A locked task worktree is not dropped, and git's reason is reported.
git -C "$repo" worktree lock "$default_root/rebasing"
expect_harness_fails_with locked-drop "see the git error above" worktree drop --force rebasing
assert_contains_literal "$tmp_root/locked-drop.err" "locked"
git -C "$repo" worktree unlock "$default_root/rebasing"

# BEAM_CODEX_WORKTREE_ROOT overrides the default root inside the repo.
override_root="$repo/.codex-worktrees/override"
BEAM_CODEX_WORKTREE_ROOT="$override_root" expect_harness_ok override worktree add override-task
assert_contains_literal "$tmp_root/override.out" "$override_root/override-task"

# The session-start helper refuses the primary checkout without an override.
if (cd "$repo" && scripts/codex-session-start.sh) >"$tmp_root/primary.out" 2>"$tmp_root/primary.err"; then
  echo "expected codex-session-start in the primary checkout to fail without override" >&2
  exit 1
fi
assert_contains_literal "$tmp_root/primary.err" "use ./scripts/codex-harness.sh session start <task-id> instead"

# Unsafe worktree roots are rejected.
BEAM_CODEX_WORKTREE_ROOT="/" expect_harness_fails_with unsafe-root \
  "BEAM_CODEX_WORKTREE_ROOT must not be /" worktree add unsafe-root
BEAM_CODEX_WORKTREE_ROOT="$tmp_root/outside-repo" expect_harness_fails_with outside-root \
  "BEAM_CODEX_WORKTREE_ROOT must be inside the repo root" worktree add outside-root

echo "codex harness tests passed"
