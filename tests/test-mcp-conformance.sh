#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-mcp-conformance}"

if ! command -v npx >/dev/null 2>&1; then
  echo "error: npx is required to run MCP conformance tests" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/lean-beam-mcp-conformance-XXXXXX)"
installation_root="$tmp_dir/installation"
npm_cache="${MCP_CONFORMANCE_NPM_CACHE:-$tmp_dir/npm-cache}"
conformance_package="${MCP_CONFORMANCE_PACKAGE:-@modelcontextprotocol/conformance@0.1.16}"
protocol_version="${MCP_CONFORMANCE_PROTOCOL_VERSION:-2025-11-25}"
bridge_era="${MCP_CONFORMANCE_BRIDGE_ERA:-legacy}"
conformance_suite="${MCP_CONFORMANCE_SUITE:-}"
bridge_pid=""
bridge_url=""

cleanup() {
  if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" >/dev/null 2>&1; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  case "$tmp_dir" in
    /tmp/lean-beam-mcp-conformance-*)
      rm -rf -- "$tmp_dir"
      ;;
    *)
      echo "refusing to clean unexpected temp dir: $tmp_dir" >&2
      ;;
  esac
}
trap cleanup EXIT

wait_for_ready_url() {
  local ready_file="$1"
  python3 - "$ready_file" <<'PY'
import json
import pathlib
import sys
import time

ready = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    if ready.exists():
        print(json.loads(ready.read_text())["url"])
        raise SystemExit(0)
    time.sleep(0.05)
raise SystemExit("timed out waiting for MCP bridge ready file")
PY
}

stop_bridge() {
  if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" >/dev/null 2>&1; then
    kill "$bridge_pid" >/dev/null 2>&1 || true
    wait "$bridge_pid" >/dev/null 2>&1 || true
  fi
  bridge_pid=""
  bridge_url=""
}

start_bridge() {
  local scenario="$1"
  local scenario_dir ready_file
  scenario_dir="$tmp_dir/$scenario"
  ready_file="$scenario_dir/ready.json"
  mkdir -p "$scenario_dir" || return
  python3 tests/mcp_http_bridge.py \
    --server "$installation_root/bin/lean-beam-mcp" \
    --protocol-era "$bridge_era" \
    --ready-file "$ready_file" \
    > "$scenario_dir/bridge.stdout" \
    2> "$scenario_dir/bridge.stderr" &
  bridge_pid="$!"
  bridge_url="$(wait_for_ready_url "$ready_file")" || return
}

run_step "build MCP installation fixture" lake build Beam.LSP:shared beam-cli beam-daemon lean-beam-mcp beam-installation-stage-fixture
run_step "stage MCP installation" python3 tests/installation_fixture.py "$installation_root"
mkdir -p "$npm_cache"

scenarios="${MCP_CONFORMANCE_SCENARIOS:-server-initialize ping tools-list}"
run_conformance_scenario() {
  local scenario="$1"
  local url
  local rc=0
  local -a suite_args=()
  if ! start_bridge "$scenario"; then
    stop_bridge
    return 1
  fi
  url="$bridge_url"
  if [ -n "$conformance_suite" ]; then
    suite_args=(--suite "$conformance_suite")
  fi
  if [ -n "${MCP_CONFORMANCE_EXPECTED_FAILURES:-}" ]; then
    npm_config_cache="$npm_cache" npm_config_update_notifier=false \
      npx -y "$conformance_package" server \
      --url "$url" \
      --scenario "$scenario" \
      --spec-version "$protocol_version" \
      ${suite_args[@]+"${suite_args[@]}"} \
      --expected-failures "$MCP_CONFORMANCE_EXPECTED_FAILURES" || rc=$?
  else
    npm_config_cache="$npm_cache" npm_config_update_notifier=false \
      npx -y "$conformance_package" server \
      --url "$url" \
      --scenario "$scenario" \
      --spec-version "$protocol_version" \
      ${suite_args[@]+"${suite_args[@]}"} || rc=$?
  fi
  stop_bridge
  return "$rc"
}

for scenario in $scenarios; do
  run_step "scenario: $scenario" run_conformance_scenario "$scenario"
done
