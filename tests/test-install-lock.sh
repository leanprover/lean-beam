#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Run the real installer lifecycle with construction and publication replaced by local fixtures.
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/install-beam.sh
. tests/lib/assertions.sh

if [ "${1:-}" = --run-case ]; then
  scenario="$2"
  case_root="$3"
  set_install_root "$case_root/install"
  setup_styles() { :; }
  parse_args() { :; }
  validate_install_config() { :; }
  confirm_path_edit() { :; }
  prepare_install_environment() {
    mkdir -p "$install_root"
    acquire_install_lock
    if [ "$scenario" = early-exit-release-failure ]; then
      printf 'unexpected contents\n' >"$install_lock_dir/retained.txt"
      exit 0
    fi
  }
  prepare_install_version() {
    case "$scenario" in
      staging-failure)
        printf 'unexpected contents\n' >"$install_lock_dir/retained.txt"
        echo 'construction failed with fixture status 73' >&2
        return 73
        ;;
      staging-cleanup-failure)
        printf 'retained staging\n' >"$1/retained.txt"
        remove_owned_staging_dir() {
          [ -d "$install_lock_dir" ] || {
            echo 'install lock was released before staging cleanup' >&2
            exit 75
          }
          echo 'fixture refused staging cleanup' >&2
          exit 74
        }
        echo 'construction failed with fixture status 73' >&2
        return 73
        ;;
    esac
    rmdir "$1"
    prepared_version_root="$install_root/fixture-runtime"
  }
  publish_runtime() {
    printf 'published\n' >"$case_root/published"
    if [ "$scenario" = publication-failure ]; then
      echo 'publication failed with fixture status 72' >&2
      return 72
    fi
  }
  register_requested_mcp_servers() {
    case "$scenario" in
      blocked-release|operation-and-release-failure)
        printf 'unexpected contents\n' >"$install_lock_dir/retained.txt"
        ;;
      pid-release-failure)
        rm() {
          echo 'fixture refused PID removal' >&2
          return 74
        }
        ;;
    esac
    if [ "$scenario" = operation-and-release-failure ]; then
      echo 'registration failed with fixture status 71' >&2
      return 71
    fi
  }
  install_requested_skills() { :; }
  print_install_summary() { echo 'Install Complete'; }

  if [ "$scenario" = retry-release ]; then
    prepare_install_environment
    printf 'unexpected contents\n' >"$install_lock_dir/retained.txt"
    if release_install_lock; then
      echo 'release accepted unexpected lock contents' >&2
      exit 1
    fi
    [ "$install_lock_owned" -eq 1 ]
    rm "$install_lock_dir/retained.txt"
    release_install_lock
    [ "$install_lock_owned" -eq 0 ]
    exit 0
  fi
  main
  exit 0
fi

tmp_root="$(mktemp -d /tmp/beam-install-lock-XXXXXX)"
trap 'rm -rf -- "$tmp_root"' EXIT

for case_spec in success:0 publication-failure:72 blocked-release:1 operation-and-release-failure:71 \
    staging-failure:73 staging-cleanup-failure:73 pid-release-failure:1 retry-release:0 \
    early-exit-release-failure:1; do
  scenario="${case_spec%:*}"
  expected="${case_spec##*:}"
  case_root="$tmp_root/$scenario"
  mkdir "$case_root"
  set +e
  bash "$repo_root/tests/test-install-lock.sh" --run-case "$scenario" "$case_root" \
    >"$case_root/stdout" 2>"$case_root/stderr"
  status="$?"
  set -e
  if [ "$status" -ne "$expected" ]; then
    cat "$case_root/stderr" >&2
    echo "$scenario: expected status $expected, got $status" >&2
    exit 1
  fi
  if [ "$scenario" = success ]; then
    assert_contains_literal "$case_root/stdout" 'Install Complete'
  else
    assert_not_contains "$case_root/stdout" 'Install Complete'
  fi
  case "$scenario" in
    blocked-release|operation-and-release-failure|staging-failure|early-exit-release-failure)
      assert_contains_literal "$case_root/install/.install-lock/retained.txt" 'unexpected contents'
      assert_not_exists "$case_root/install/.install-lock/pid"
      assert_contains_literal "$case_root/stderr" \
        "failed to release Beam install lock: $case_root/install/.install-lock"
      assert_contains_literal "$case_root/stderr" 'remaining contents were preserved'
      ;;
    pid-release-failure)
      assert_file "$case_root/install/.install-lock/pid"
      assert_contains_literal "$case_root/stderr" 'failed to remove Beam install lock PID file:'
      ;;
    *) assert_not_exists "$case_root/install/.install-lock" ;;
  esac
  case "$scenario" in
    publication-failure) assert_contains_literal "$case_root/stderr" 'publication failed with fixture status 72' ;;
    operation-and-release-failure) assert_contains_literal "$case_root/stderr" 'registration failed with fixture status 71' ;;
    staging-failure|staging-cleanup-failure)
      assert_contains_literal "$case_root/stderr" 'construction failed with fixture status 73'
      ;;
  esac
  if [ "$scenario" = staging-cleanup-failure ]; then
    assert_contains_literal "$case_root/stderr" 'fixture refused staging cleanup'
    assert_contains_literal "$case_root/stderr" 'failed to remove Beam install staging directory:'
    assert_not_contains "$case_root/stderr" 'released before staging cleanup'
    retained_staging="$(find "$case_root/install" -name '.staging-*' -print)"
    assert_contains_literal "$retained_staging/retained.txt" 'retained staging'
  else
    [ -z "$(find "$case_root/install" -name '.staging-*' -print)" ]
  fi
  case "$scenario" in
    staging-failure|staging-cleanup-failure|retry-release|early-exit-release-failure)
      assert_not_exists "$case_root/published"
      ;;
    *) assert_contains_literal "$case_root/published" 'published' ;;
  esac
done

echo 'installer lock cleanup checks passed'
