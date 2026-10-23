#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

# Representative native/process/filesystem checks for macOS pull requests. The workflow also
# runs LSP, MCP, Slow's real two-toolchain installation, and native distribution qualification.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/lib/ci-steps.sh
BEAM_TEST_SUITE=macos-platform
platform_state_root="$(mktemp -d /tmp/beam-macos-platform-XXXXXX)"
trap 'rm -rf -- "$platform_state_root"' EXIT
export BEAM_SESSION_ROOT="$platform_state_root/sessions"

run_step "build platform fixtures" lake build \
  Beam.LSP:shared beam-cli beam-daemon lean-beam-mcp beam-install-runtime \
  beam-lake-helper-client-fixture \
  beam-system-contract-test beam-backend-process-test beam-transport-test \
  beam-prune-lock-test beam-cli-daemon-test \
  beam-installation-construction-test beam-installation-manifest-test \
  beam-installation-lookup-test beam-installation-stage-fixture

run_step "system contracts" python3 tests/test-system-contracts.py
run_step "backend process" .lake/build/bin/beam-backend-process-test
run_step "transport" python3 tests/lib/process_watchdog.py \
  --timeout 30 -- .lake/build/bin/beam-transport-test
run_step "prune lock" python3 tests/lib/process_watchdog.py \
  --timeout 30 -- .lake/build/bin/beam-prune-lock-test
run_step "CLI session lifecycle" .lake/build/bin/beam-cli-daemon-test
run_step "installation manifest" python3 tests/test-installation-manifest.py
run_step "installation staging" python3 tests/test-installation-construction.py
run_step "installation lookup" python3 tests/test-installation-lookup.py
run_step "installed entrypoints" python3 tests/test-installation-entrypoints.py
# Slow already runs the focused shell installation publication checks. Prune is otherwise
# owned by the exhaustive installer suite, so keep its complete guard cases in this PR profile.
run_step "installed prune guards" bash tests/test-beam-prune.sh
