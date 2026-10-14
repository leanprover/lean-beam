#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/install-fixtures.sh
. tests/lib/install-fixtures.sh

outside_root="$(mktemp -d /tmp/defensive-outside-XXXXXX)"
fixture_root="$(mktemp -d /tmp/beam-overlay-git-XXXXXX)"
fixture_root="$(cd "$fixture_root" && pwd -P)"

cleanup() {
  rm -rf -- "$outside_root"
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT

if ! bash scripts/validate-defensive.sh -- bash -c '
  if [ ! -d .git ] || [ "$(git rev-parse --absolute-git-dir)" != "$(pwd -P)/.git" ]; then
    echo "validation clone Git metadata points outside its owned directory" >&2
    exit 1
  fi

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

# Both source shapes are explicit fixtures; CI's checkout shape must not choose coverage.
fixture_checkout="$fixture_root/ordinary"
linked_checkout="$fixture_root/linked"
git -c init.defaultBranch=fixture init -q "$fixture_checkout"
mkdir -p "$fixture_checkout/scripts"
cp scripts/validate-defensive.sh "$fixture_checkout/scripts/"
printf '%s\n' 'committed fixture' > "$fixture_checkout/overlay.txt"
git -C "$fixture_checkout" config user.name 'Original Fixture'
git -C "$fixture_checkout" config user.email 'original-fixture@example.invalid'
git -C "$fixture_checkout" add .
git -C "$fixture_checkout" commit --no-gpg-sign -q -m 'create isolated overlay fixture'
git -C "$fixture_checkout" worktree add -q -b linked-fixture "$linked_checkout"
[ -d "$fixture_checkout/.git" ]
[ -f "$linked_checkout/.git" ]

for fixture_source in "$fixture_checkout" "$linked_checkout"; do
  fixture_head="$(git -C "$fixture_source" rev-parse HEAD)"
  fixture_branch="$(git -C "$fixture_source" symbolic-ref HEAD)"
  printf '%s\n' 'uncommitted overlay' > "$fixture_source/overlay.txt"
  fixture_copy="$fixture_root/copy-$(basename "$fixture_source")"
  mkdir -p "$fixture_copy"
  beam_test_overlay_install_source "$fixture_source" "$fixture_copy"
  if [ -e "$fixture_copy/.git" ]; then
    echo "installer source overlay copied foreign Git metadata from $fixture_source" >&2
    exit 1
  fi
  git -c init.defaultBranch=disposable init -q "$fixture_copy"
  if [ ! -d "$fixture_copy/.git" ] ||
      [ "$(git -C "$fixture_copy" rev-parse --absolute-git-dir)" != "$fixture_copy/.git" ]; then
    echo "installer source overlay copied foreign Git metadata from $fixture_source" >&2
    exit 1
  fi
  grep -qxF 'uncommitted overlay' "$fixture_copy/overlay.txt"
  git -C "$fixture_copy" config user.name 'Disposable Fixture'
  git -C "$fixture_copy" config user.email 'disposable-fixture@example.invalid'
  git -C "$fixture_copy" commit --allow-empty --no-gpg-sign -q -m 'commit inside installer copy'
  [ "$(git -C "$fixture_copy" rev-parse HEAD)" != "$fixture_head" ]

  bash "$fixture_source/scripts/validate-defensive.sh" -- bash -c '
    [ -d .git ]
    [ "$(git rev-parse --absolute-git-dir)" = "$(pwd -P)/.git" ]
    grep -qxF "uncommitted overlay" overlay.txt
    fixture_head="$(git rev-parse HEAD)"
    git config user.name "Disposable Validation"
    git config user.email "disposable-validation@example.invalid"
    git commit --allow-empty --no-gpg-sign -q -m "commit inside defensive clone"
    [ "$(git rev-parse HEAD)" != "$fixture_head" ]
  '
  [ "$(git -C "$fixture_source" rev-parse HEAD)" = "$fixture_head" ]
  [ "$(git -C "$fixture_source" symbolic-ref HEAD)" = "$fixture_branch" ]
  [ "$(git -C "$fixture_source" config user.name)" = 'Original Fixture' ]
  [ "$(git -C "$fixture_source" config user.email)" = 'original-fixture@example.invalid' ]
done
