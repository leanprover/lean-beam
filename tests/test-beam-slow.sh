#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh
# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-beam-slow}"

if [ -z "${ELAN_HOME:-}" ] && [ -d "$HOME/.elan" ]; then
  export ELAN_HOME="$HOME/.elan"
fi

tmp_env_root="$(mktemp -d /tmp/beam-daemon-env-XXXXXX)"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-daemon-env
}

remove_owned_tmp_tree() {
  local path="$1"
  beam_test_remove_owned_tmp_tree "$path" beam-daemon-env
}

cleanup() {
  remove_owned_tmp_tree "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
fixture_toolchain="$(awk 'NR==1 {print $1}' tests/save_olean_project/lean-toolchain)"
# Fake agent homes isolate install state; the wrapper still needs the host Lean toolchain cache.
host_elan_home="${ELAN_HOME:-$HOME/.elan}"

run_step "install publication" bash tests/test-install-publication.sh
run_step "install lock cleanup" bash tests/test-install-lock.sh

run_step "build" lake build \
  Beam.LSP:shared \
  beam-cli \
  beam-daemon \
  beam-lake-helper-client-fixture \
  lean-beam-mcp \
  beam-install-runtime

run_step "construct complete test installation" env \
  HOME="$tmp_env_root/home" ELAN_HOME="$host_elan_home" \
  BEAM_INSTALL_ROOT="$tmp_env_root/install-root" BEAM_BIN_HOME="$tmp_env_root/bin" \
  bash scripts/install-beam.sh --dont-ask --toolchain "$toolchain" --toolchain "$fixture_toolchain"
BEAM_TEST_INSTALLATION="$(cd -P "$tmp_env_root/install-root/current" && pwd)"
export BEAM_TEST_INSTALLATION

mcp_stdio_timeout="${BEAM_MCP_STDIO_TIMEOUT:-60}"
mcp_stdio_env=()
if [ "${BEAM_MCP_STDIO_SERVER_TRACE:-1}" != "0" ]; then
  mcp_stdio_env+=("BEAM_MCP_SERVER_TRACE=1")
  mcp_stdio_env+=("LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS=${BEAM_MCP_STDIO_WAIT_DIAGNOSTICS_WATCHDOG_MS:-10000}")
fi
run_step "MCP stdio stress" env ${mcp_stdio_env[@]+"${mcp_stdio_env[@]}"} \
  python3 tests/test-mcp-stdio.py \
    --iterations 4 \
    --restart-cycles 3 \
    --timeout "$mcp_stdio_timeout"

run_step "MCP multi-toolchain workspaces" \
  python3 tests/test-mcp-stdio.py \
    --scenario multi-toolchain-workspaces \
    --timeout "$mcp_stdio_timeout"

run_step "wrapper daemon tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" \
  bash tests/test-beam-wrapper-daemon.sh

run_step "wrapper tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" \
  bash tests/test-beam-wrapper.sh

if [ "$(uname -s)" = "Linux" ]; then
  run_step "sandbox wrapper tests" env \
    HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
    ELAN_HOME="$host_elan_home" \
    bash tests/test-beam-wrapper-sandbox.sh
fi

run_step "save replay tests" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" \
  bash tests/test-beam-save-olean.sh

run_step "checkpoint output hashes" env \
  HOME="$tmp_env_root/home" CODEX_HOME="$tmp_env_root/codex" CLAUDE_HOME="$tmp_env_root/claude" \
  ELAN_HOME="$host_elan_home" \
  python3 tests/lib/process_watchdog.py --timeout 300 -- python3 tests/test-beam-checkpoint-hashes.py
