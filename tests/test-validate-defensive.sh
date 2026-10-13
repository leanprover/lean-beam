#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

outside_root="$(mktemp -d /tmp/defensive-outside-XXXXXX)"

cleanup() {
  rm -rf -- "$outside_root"
}
trap cleanup EXIT

if ! bash scripts/validate-defensive.sh -- bash -c '
  case "$(git rev-parse --absolute-git-dir)" in
    /tmp/beam-validate-*/clone/.git)
      ;;
    *)
      echo "validation clone Git metadata points outside its owned directory" >&2
      exit 1
      ;;
  esac

  case "$HOME" in
    /tmp/beam-validate-*/home)
      ;;
    *)
      echo "unexpected HOME inside defensive validation: $HOME" >&2
      exit 1
      ;;
  esac

  case "$CODEX_HOME" in
    /tmp/beam-validate-*/codex)
      ;;
    *)
      echo "unexpected CODEX_HOME inside defensive validation: $CODEX_HOME" >&2
      exit 1
      ;;
  esac

  case "$CLAUDE_HOME" in
    /tmp/beam-validate-*/claude)
      ;;
    *)
      echo "unexpected CLAUDE_HOME inside defensive validation: $CLAUDE_HOME" >&2
      exit 1
      ;;
  esac

  case "$TMPDIR" in
    /tmp/beam-validate-*/tmp)
      ;;
    *)
      echo "unexpected TMPDIR inside defensive validation: $TMPDIR" >&2
      exit 1
      ;;
  esac

  mkdir -p "$HOME/allowed-dir"
  rm -rf "$HOME/allowed-dir"

  rewritten_tmp="$(mktemp -d /tmp/beam-rewrite-XXXXXX)"
  case "$rewritten_tmp" in
    /tmp/beam-validate-*/tmp/beam-rewrite-*)
      ;;
    *)
      echo "expected mktemp template rewrite into validation root, got $rewritten_tmp" >&2
      exit 1
      ;;
  esac
  rm -rf "$rewritten_tmp"

  blocked_path="'"$outside_root"'"
  if rm -rf "$blocked_path" > /dev/null 2>&1; then
    echo "expected defensive validation wrapper to block rm outside the validation root" >&2
    exit 1
  fi
'; then
  echo "expected defensive validation smoke test to succeed" >&2
  exit 1
fi

if [ ! -d "$outside_root" ]; then
  echo "expected defensive validation wrapper to leave outside temp root intact" >&2
  exit 1
fi

# Linked worktrees have a .git file, which must not replace the validation clone's .git directory.
fixture_repo="$outside_root/repo"
fixture_worktree="$outside_root/worktree"
mkdir -p "$fixture_repo/scripts"
cp scripts/validate-defensive.sh "$fixture_repo/scripts/"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" add scripts/validate-defensive.sh
git -C "$fixture_repo" -c user.name='Beam Defensive Test' \
  -c user.email=beam-defensive-test@example.invalid \
  commit --no-gpg-sign -q -m 'defensive validation fixture'
git -C "$fixture_repo" worktree add -q -b linked "$fixture_worktree"
fixture_head="$(git -C "$fixture_worktree" rev-parse HEAD)"
(
  cd "$fixture_worktree"
  bash scripts/validate-defensive.sh -- bash -c '
    if [ ! -d .git ]; then
      echo "expected linked-worktree validation to retain an independent Git directory" >&2
      exit 1
    fi
    git -c user.name="Beam Defensive Test" -c user.email=beam-defensive-test@example.invalid \
      commit --allow-empty --no-gpg-sign -q -m "validation clone commit"
  '
)
if [ "$(git -C "$fixture_worktree" rev-parse HEAD)" != "$fixture_head" ]; then
  echo "defensive validation changed the source worktree HEAD" >&2
  exit 1
fi
