#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

run_wrapper_slice() {
  local label="$1"
  local script="$2"
  echo "[beam-wrapper] starting $label"
  if ! bash "$script"; then
    echo "[beam-wrapper] failed: $label ($script)" >&2
    return 1
  fi
  echo "[beam-wrapper] passed: $label"
}

run_wrapper_slice "probe" tests/test-beam-wrapper-probe.sh
run_wrapper_slice "runtime" tests/test-beam-wrapper-runtime.sh
run_wrapper_slice "toolchain selection" tests/test-beam-wrapper-toolchain.sh
run_wrapper_slice "sync/save" tests/test-beam-wrapper-sync-save.sh
run_wrapper_slice "handles" tests/test-beam-wrapper-handle.sh
run_wrapper_slice "diagnostics" tests/test-beam-wrapper-diagnostics.sh
