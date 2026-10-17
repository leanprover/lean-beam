#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh
# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh

toolchain="${BEAM_STAGE0_TOOLCHAIN:-lean4-stage0}"
host_home="$HOME"
host_elan_home="${ELAN_HOME:-$host_home/.elan}"

if [ ! -d "$host_elan_home" ]; then
  echo "skip: no host elan home found for $toolchain; set ELAN_HOME to run this smoke" >&2
  exit 0
fi

if ! ELAN_HOME="$host_elan_home" elan run "$toolchain" lean --version >/dev/null 2>&1; then
  echo "skip: elan toolchain is not available: $toolchain" >&2
  exit 0
fi

tmp_root="$(mktemp -d /tmp/beam-stage0-smoke-XXXXXX)"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-stage0-smoke
}

cleanup() {
  expect_owned_tmp_dir "$tmp_root"
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

install_home="$tmp_root/home"
install_root="$tmp_root/install-root"
project_root="$tmp_root/project"
doctor_out=""

mkdir -p "$install_home" "$install_root"

HOME="$install_home" \
  ELAN_HOME="$host_elan_home" \
  BEAM_INSTALL_ROOT="$install_root" \
  bash scripts/install-beam.sh --dont-ask --custom-toolchain "$toolchain" >/dev/null

rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root"/
printf '%s\n' "$toolchain" > "$project_root/lean-toolchain"

doctor_out="$(ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" doctor)"

assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" "project target: $toolchain"
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'target membership: present'
assert_output_contains "stage0 custom toolchain doctor output" "$doctor_out" 'installation root: '

stage0_owner_err="$tmp_root/stage0-owner.err"
ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" serve \
  >/dev/null 2>"$stage0_owner_err" &
stage0_owner_pid="$!"
if ! wait_for_file_text "$stage0_owner_err" "serving Beam session" "stage0 session owner" 600 0.1; then
  exit 1
fi
ELAN_HOME="$host_elan_home" \
  "$install_home/.local/bin/lean-beam" --root "$project_root" stop >/dev/null
wait_for_exit "$stage0_owner_pid" "stage0 session owner" 120 0.1
wait "$stage0_owner_pid"
