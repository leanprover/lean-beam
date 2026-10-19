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

tmp_root="$(mktemp -d /tmp/beam-task-harness-XXXXXX)"

cleanup() {
  beam_test_remove_owned_tmp_tree "$tmp_root" beam-task-harness
}
trap cleanup EXIT

# The harness runs against a throwaway repository with a local bare origin, so the test never
# creates worktrees or branches in the checkout under test and does not depend on network access.
unset BEAM_TASK_WORKTREE_ROOT BEAM_TASK_ALLOW_PRIMARY GIT_SSH_COMMAND GIT_SSH
export GIT_CONFIG_GLOBAL="$tmp_root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
git config --global user.name "Beam Harness Test"
git config --global user.email "beam-harness-test@example.invalid"
git config --global init.defaultBranch main

# Git records resolved paths, and /tmp is a symlink on macOS, so fixture paths use the resolved root.
fixture_root="$(cd "$tmp_root" && pwd -P)"
origin="$fixture_root/origin.git"
repo="$fixture_root/repo"
upstream_clone="$fixture_root/upstream-clone"
git init --quiet --bare "$origin"
git init --quiet "$repo"
mkdir -p "$repo/scripts"
cp "$source_root/scripts/task-harness.sh" "$repo/scripts/"
printf 'fixture\n' > "$repo/README"
# Mirror the repository's ignore rule for the task worktree root.
printf '/.worktrees/\n' > "$repo/.gitignore"
git -C "$repo" add .
git -C "$repo" commit --quiet -m "initial"
git -C "$repo" remote add origin "$origin"
git -C "$repo" push --quiet origin main

harness="$repo/scripts/task-harness.sh"
default_root="$repo/.worktrees"

# Run the harness from a directory (the fixture repo by default), capturing stdout and stderr in
# files under tmp_root. HARNESS_CWD and HARNESS_STDIN select the directory and stdin file.
run_harness() {
  local name="$1"
  shift
  (cd "${HARNESS_CWD:-$repo}" && "$harness" "$@") \
    <"${HARNESS_STDIN:-/dev/null}" >"$tmp_root/$name.out" 2>"$tmp_root/$name.err"
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

# Path-printing commands must print exactly the worktree path on stdout.
expect_stdout_path() {
  local name="$1"
  local expected="$2"
  if [ "$(cat "$tmp_root/$name.out")" != "$expected" ]; then
    echo "expected $name stdout to be exactly $expected" >&2
    cat "$tmp_root/$name.out" >&2
    exit 1
  fi
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

# start creates a task worktree from freshly fetched origin/main, not stale local main.
expect_harness_ok start start fresh
expect_stdout_path start "$default_root/fresh"
assert_contains_literal "$tmp_root/start.err" "branch: task/fresh"
expect_same_commit "fresh task" task/fresh "$upstream_head"
if git -C "$default_root/fresh" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
  echo "expected task branch not to track the base branch" >&2
  exit 1
fi

# The task worktree's own copy of the harness still uses the primary checkout's root.
(cd "$default_root/fresh" && scripts/task-harness.sh start nested) >"$tmp_root/nested.out" 2>"$tmp_root/nested.err"
expect_stdout_path nested "$default_root/nested"
assert_not_exists "$default_root/fresh/.worktrees"

# The fetch refreshes origin/main even when the configured refspec does not cover it, as in a
# single-branch clone of another branch.
commit_in "$upstream_clone" "second upstream change"
git -C "$upstream_clone" push --quiet origin main
upstream_head="$(git -C "$upstream_clone" rev-parse HEAD)"
git -C "$repo" config remote.origin.fetch "+refs/heads/other:refs/remotes/origin/other"
expect_harness_ok narrow-refspec start narrow-refspec
expect_same_commit "narrow-refspec task" task/narrow-refspec "$upstream_head"
git -C "$repo" config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"

# Tracked edits in the primary checkout only produce a warning.
printf 'primary edit\n' >> "$repo/README"
expect_harness_ok dirty-primary start dirty-primary
assert_contains_literal "$tmp_root/dirty-primary.err" "has tracked edits; they are not part of the new task"
expect_same_commit "dirty-primary task" task/dirty-primary "$upstream_head"
git -C "$repo" checkout --quiet -- README

# An explicit base ref is used as given and not fetched.
expect_harness_ok explicit-base start explicit-base main
expect_same_commit "explicit-base task" task/explicit-base main

# When origin is unreachable, the last fetched origin/main is used with a warning.
git -C "$repo" remote set-url origin "$tmp_root/missing-origin.git"
expect_harness_ok offline start offline
assert_contains_literal "$tmp_root/offline.err" "could not fetch origin/main; using the last fetched copy"
expect_same_commit "offline task" task/offline "$upstream_head"
git -C "$repo" remote set-url origin "$origin"

# An existing task worktree is reused only with --resume.
expect_harness_fails_with existing "pass --resume to reuse it" start fresh
expect_harness_ok resume-existing start --resume fresh
expect_stdout_path resume-existing "$default_root/fresh"
expect_harness_fails_with resume-base "cannot be combined with a base-ref" start --resume fresh main
expect_harness_fails_with resume-missing "nothing to resume" start --resume never-created

# An existing task branch without a worktree is checked out only with --resume.
git -C "$repo" worktree remove "$default_root/explicit-base"
expect_harness_fails_with existing-branch "branch task/explicit-base already exists" start explicit-base
expect_harness_ok resume-branch start --resume explicit-base
expect_same_commit "resumed task" task/explicit-base main

# A worktree path with another branch checked out is neither reused nor dropped.
git -C "$default_root/offline" switch --quiet -c other-work
expect_harness_fails_with wrong-branch-start "expected task/offline" start --resume offline
expect_harness_fails_with wrong-branch-drop "expected task/offline" drop offline
git -C "$default_root/offline" switch --quiet task/offline

# A plain directory at a task path is not treated as a worktree.
mkdir -p "$default_root/plain-dir"
expect_harness_fails_with plain-dir "is not a registered git worktree" start --resume plain-dir

# drop refuses to discard commits that are not on any remote, and keeps the worktree intact.
commit_in "$default_root/fresh" "local task work"
expect_harness_fails_with drop-unpushed "1 commit(s) not found on any origin branch and not merged" drop fresh
expect_branch task/fresh
assert_file "$default_root/fresh/README"

# Once the task branch is pushed, drop removes the worktree and its branch.
git -C "$default_root/fresh" push --quiet origin task/fresh
# drop changes no remote-tracking refs other than origin/main, such as pull request refs.
git -C "$repo" update-ref refs/remotes/origin/pr/7 HEAD
expect_harness_ok drop-pushed drop fresh
if ! git -C "$repo" show-ref --verify --quiet refs/remotes/origin/pr/7; then
  echo "expected drop to keep refs/remotes/origin/pr/7" >&2
  exit 1
fi
assert_not_exists "$default_root/fresh"
expect_no_branch task/fresh

# A squash-merged task branch can be dropped after its remote branch is deleted and pruned.
commit_in "$default_root/narrow-refspec" "squashed task work"
git -C "$default_root/narrow-refspec" push --quiet origin task/narrow-refspec
git -C "$upstream_clone" pull --quiet origin main
git -C "$upstream_clone" fetch --quiet origin task/narrow-refspec
git -C "$upstream_clone" merge --quiet --squash FETCH_HEAD >/dev/null
git -C "$upstream_clone" commit --quiet -m "squash merge narrow-refspec"
git -C "$upstream_clone" push --quiet origin main
git -C "$upstream_clone" push --quiet origin --delete task/narrow-refspec
git -C "$repo" fetch --quiet --prune origin
upstream_head="$(git -C "$upstream_clone" rev-parse HEAD)"
expect_harness_ok drop-squashed drop narrow-refspec
assert_not_exists "$default_root/narrow-refspec"
expect_no_branch task/narrow-refspec

# A tag with the task branch name does not hide the branch's unpushed commits.
commit_in "$default_root/offline" "work behind a same-name tag"
git -C "$repo" tag task/offline "$upstream_head"
expect_harness_fails_with drop-tag-shadow "1 commit(s) not found on any origin branch and not merged" drop offline
git -C "$repo" tag -d task/offline >/dev/null
git -C "$default_root/offline" reset --quiet --hard HEAD~1

# --force discards unpushed commits.
commit_in "$default_root/offline" "throwaway work"
expect_harness_ok drop-force drop --force offline
assert_not_exists "$default_root/offline"
expect_no_branch task/offline

# Uncommitted changes block drop even with --force.
printf 'uncommitted\n' >> "$default_root/explicit-base/README"
expect_harness_fails_with drop-dirty "contains modified or untracked files" drop --force explicit-base
assert_file "$default_root/explicit-base/README"
expect_branch task/explicit-base

# A task directory deleted by hand is reported with the git command that cleans it up.
expect_harness_ok removed-dir start removed-dir
rm -rf -- "$default_root/removed-dir"
expect_harness_fails_with removed-dir-drop "run git worktree prune" drop removed-dir
git -C "$repo" worktree prune
git -C "$repo" branch -D task/removed-dir >/dev/null

# Without a user ssh setting, the fetch uses non-interactive ssh with a connect timeout; a user's
# GIT_SSH wrapper is left alone. Fake ssh programs record their arguments without any network.
fake_bin="$tmp_root/fake-bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/fake-ssh.log"\nexit 1\n' "$tmp_root" > "$fake_bin/ssh"
printf '#!/bin/sh\nprintf "wrapper %%s\\n" "$*" >> "%s/fake-wrapper.log"\nexit 1\n' "$tmp_root" > "$fake_bin/ssh-wrapper"
chmod +x "$fake_bin/ssh" "$fake_bin/ssh-wrapper"
git -C "$repo" remote set-url origin "harness-test.invalid:repo.git"
PATH="$fake_bin:$PATH" expect_harness_ok ssh-default start ssh-default
assert_contains_literal "$tmp_root/fake-ssh.log" "BatchMode=yes -o ConnectTimeout=15"
rm -f -- "$tmp_root/fake-ssh.log"
PATH="$fake_bin:$PATH" GIT_SSH="$fake_bin/ssh-wrapper" expect_harness_ok ssh-wrapper start ssh-wrapper
assert_contains_literal "$tmp_root/fake-wrapper.log" "wrapper "
assert_not_exists "$tmp_root/fake-ssh.log"

# When origin cannot be reached, only a merge into the last fetched origin/main confirms that a task
# branch is safe to delete.
PATH="$fake_bin:$PATH" expect_harness_ok drop-offline-merged drop ssh-wrapper
assert_contains_literal "$tmp_root/drop-offline-merged.err" "could not list origin's branches"
expect_no_branch task/ssh-wrapper
commit_in "$default_root/ssh-default" "unmerged work"
PATH="$fake_bin:$PATH" expect_harness_fails_with drop-offline \
  "could not confirm that branch task/ssh-default is pushed or merged" drop ssh-default
assert_contains_literal "$tmp_root/drop-offline.err" "using the last fetched copy"
git -C "$repo" update-ref -d refs/remotes/origin/main
PATH="$fake_bin:$PATH" expect_harness_fails_with drop-no-base \
  "could not confirm that branch task/ssh-default is pushed or merged" drop ssh-default
git -C "$repo" remote set-url origin "$origin"
git -C "$repo" fetch --quiet origin

# A pushed task branch deleted on the remote without being merged is no longer treated as pushed,
# even before the local remote-tracking ref is pruned.
expect_harness_ok remote-deleted start remote-deleted
commit_in "$default_root/remote-deleted" "work on a deleted remote branch"
git -C "$default_root/remote-deleted" push --quiet origin task/remote-deleted
git -C "$upstream_clone" push --quiet origin --delete task/remote-deleted
expect_harness_fails_with drop-remote-deleted "not found on any origin branch and not merged" drop remote-deleted
expect_branch task/remote-deleted

# Once later base commits change lines next to a squash merge, merging the branch would conflict,
# so drop cannot confirm the merge and asks for --force instead of guessing.
commit_in "$default_root/remote-deleted" "second line of squashed work"
git -C "$upstream_clone" pull --quiet origin main
git -C "$default_root/remote-deleted" diff "$(git -C "$repo" merge-base origin/main task/remote-deleted)" task/remote-deleted |
  git -C "$upstream_clone" apply
git -C "$upstream_clone" commit --quiet -am "squash merge remote-deleted"
printf 'follow-up next to the squashed lines\n' >> "$upstream_clone/README"
git -C "$upstream_clone" commit --quiet -am "follow-up"
git -C "$upstream_clone" push --quiet origin main
upstream_head="$(git -C "$upstream_clone" rev-parse HEAD)"
expect_harness_fails_with drop-squashed-moved "pass --force to discard them" drop remote-deleted
expect_branch task/remote-deleted
expect_harness_ok drop-squashed-moved-force drop --force remote-deleted
expect_no_branch task/remote-deleted

# A failure inside start stops it with one error instead of continuing with an empty base.
git -C "$repo" remote set-url origin "$tmp_root/missing-origin.git"
saved_base="$(git -C "$repo" rev-parse origin/main)"
git -C "$repo" update-ref -d refs/remotes/origin/main
expect_harness_fails_with start-no-base "no fetched copy exists" start no-base
assert_not_contains "$tmp_root/start-no-base.err" "invalid reference"
assert_not_exists "$default_root/no-base"
git -C "$repo" update-ref refs/remotes/origin/main "$saved_base"
git -C "$repo" remote set-url origin "$origin"

# Resuming with tracked edits in the primary checkout does not repeat the new-task warning.
printf 'primary edit\n' >> "$repo/README"
expect_harness_ok dirty-primary-resume start --resume explicit-base
assert_not_contains "$tmp_root/dirty-primary-resume.err" "has tracked edits"
git -C "$repo" checkout --quiet -- README

# adopt turns a clean detached worktree made by another tool into a task branch from the base.
external="$fixture_root/external-worktree"
git -C "$repo" worktree add --quiet --detach "$external" main
HARNESS_CWD="$external" expect_harness_ok adopt adopt adopted
expect_stdout_path adopt "$external"
expect_same_commit "adopted task" task/adopted "$upstream_head"
if [ "$(git -C "$external" symbolic-ref --short HEAD)" != "task/adopted" ]; then
  echo "expected adopt to check out task/adopted in place" >&2
  exit 1
fi
HARNESS_CWD="$external" expect_harness_ok adopt-again adopt adopted
expect_stdout_path adopt-again "$external"
HARNESS_CWD="$external" expect_harness_fails_with adopt-other "already has branch task/adopted checked out" \
  adopt another
HARNESS_CWD="$repo" expect_harness_fails_with adopt-primary "refusing to adopt the primary checkout" adopt primary
dirty_external="$fixture_root/dirty-external-worktree"
git -C "$repo" worktree add --quiet --detach "$dirty_external" main
printf 'stray\n' > "$dirty_external/stray"
HARNESS_CWD="$dirty_external" expect_harness_fails_with adopt-dirty "adopt needs a clean checkout" adopt dirty
HARNESS_CWD="$tmp_root" expect_harness_fails_with adopt-outside "run adopt from inside a worktree" adopt outside

# The Claude Code WorktreeCreate hook starts a task from the hook name and prints only its path.
printf '{"hook_event_name":"WorktreeCreate","cwd":"%s","name":"bold-oak-a3f2"}\n' "$repo" > "$tmp_root/create.json"
HARNESS_STDIN="$tmp_root/create.json" expect_harness_ok hook-create hook claude-worktree-create
expect_stdout_path hook-create "$default_root/bold-oak-a3f2"
expect_same_commit "hook task" task/bold-oak-a3f2 "$upstream_head"
# Asking for the same name again resumes the task instead of failing.
HARNESS_STDIN="$tmp_root/create.json" expect_harness_ok hook-create-again hook claude-worktree-create
expect_stdout_path hook-create-again "$default_root/bold-oak-a3f2"
printf '{"hook_event_name":"WorktreeCreate"}\n' > "$tmp_root/create-no-name.json"
HARNESS_STDIN="$tmp_root/create-no-name.json" expect_harness_fails_with hook-create-no-name \
  "hook input has no name field" hook claude-worktree-create

# The WorktreeRemove hook refuses unpushed work and paths outside the task root.
commit_in "$default_root/bold-oak-a3f2" "hook task work"
printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s"}\n' "$default_root/bold-oak-a3f2" > "$tmp_root/remove.json"
HARNESS_STDIN="$tmp_root/remove.json" expect_harness_fails_with hook-remove-unpushed \
  "not found on any origin branch and not merged" hook claude-worktree-remove
assert_file "$default_root/bold-oak-a3f2/README"
printf '{"hook_event_name":"WorktreeRemove","worktree_path":"%s"}\n' "$external" > "$tmp_root/remove-external.json"
HARNESS_STDIN="$tmp_root/remove-external.json" expect_harness_fails_with hook-remove-external \
  "is not a task worktree under" hook claude-worktree-remove
assert_file "$external/README"
git -C "$default_root/bold-oak-a3f2" push --quiet origin task/bold-oak-a3f2
HARNESS_STDIN="$tmp_root/remove.json" expect_harness_ok hook-remove hook claude-worktree-remove
assert_not_exists "$default_root/bold-oak-a3f2"
expect_no_branch task/bold-oak-a3f2

# check reports a dedicated task worktree and refuses the primary checkout without an override.
HARNESS_CWD="$default_root/nested" expect_harness_ok check-task check
assert_contains_literal "$tmp_root/check-task.out" "worktree discipline: dedicated task checkout"
expect_harness_fails_with check-primary "use ./scripts/task-harness.sh start <task-id> instead" check
BEAM_TASK_ALLOW_PRIMARY=1 expect_harness_ok check-primary-override check
assert_contains_literal "$tmp_root/check-primary-override.out" "primary checkout override: enabled"

# BEAM_TASK_WORKTREE_ROOT overrides the default root inside the primary checkout.
override_root="$repo/.worktrees-override"
BEAM_TASK_WORKTREE_ROOT="$override_root" expect_harness_ok override start override-task
expect_stdout_path override "$override_root/override-task"

# Unsafe worktree roots are rejected.
BEAM_TASK_WORKTREE_ROOT="/" expect_harness_fails_with unsafe-root \
  "BEAM_TASK_WORKTREE_ROOT must not be /" start unsafe-root
BEAM_TASK_WORKTREE_ROOT="$tmp_root/outside-repo" expect_harness_fails_with outside-root \
  "BEAM_TASK_WORKTREE_ROOT must be inside the primary checkout" start outside-root

echo "task harness tests passed"
