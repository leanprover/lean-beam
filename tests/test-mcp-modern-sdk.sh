#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-mcp-modern-sdk}"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  echo "error: Node.js and npm are required to run the official MCP SDK test" >&2
  exit 1
fi

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [ "$node_major" -lt 20 ]; then
  echo "error: the official MCP TypeScript SDK requires Node.js 20 or newer" >&2
  exit 1
fi

tmp_dir="$(mktemp -d /tmp/lean-beam-mcp-modern-sdk-XXXXXX)"
sdk_root="$tmp_dir/sdk"
project_root="$tmp_dir/project"
installation_root="$tmp_dir/installation"
npm_cache="${MCP_SDK_NPM_CACHE:-$tmp_dir/npm-cache}"
sdk_package="${MCP_SDK_PACKAGE:-@modelcontextprotocol/client@2.0.0}"

cleanup() {
  case "$tmp_dir" in
    /tmp/lean-beam-mcp-modern-sdk-*)
      rm -rf -- "$tmp_dir"
      ;;
    *)
      echo "refusing to clean unexpected temp dir: $tmp_dir" >&2
      ;;
  esac
}
trap cleanup EXIT

install_sdk() {
  mkdir -p "$sdk_root" "$npm_cache"
  npm_config_cache="$npm_cache" npm_config_update_notifier=false \
    npm install --prefix "$sdk_root" --no-audit --no-fund --no-save --no-package-lock "$sdk_package"
}

run_sdk_mode() {
  local mode="$1"
  node tests/mcp-modern-sdk-client.mjs \
    --sdk-root "$sdk_root" \
    --server "$installation_root/bin/lean-beam-mcp" \
    --server-cwd "$project_root" \
    --root "$project_root" \
    --mode "$mode"
}

run_step "build MCP installation fixture" lake build Beam.LSP:shared beam-cli beam-daemon lean-beam-mcp beam-installation-stage-fixture
run_step "stage MCP installation and project" python3 tests/installation_fixture.py "$installation_root" --project "$project_root"
run_step "install official MCP TypeScript client" install_sdk
run_step "official SDK automatic negotiation" run_sdk_mode auto
run_step "official SDK pinned modern negotiation" run_sdk_mode pin
