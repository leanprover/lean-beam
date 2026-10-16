#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 tests/test-extended-ci.py
python3 tests/test-toolchain-compat-owner.py

if [ -n "$(git status --short --untracked-files=no)" ]; then
  echo "[maintainer] skipping tests/test-codex-harness.sh because the current checkout has tracked edits" >&2
else
  bash tests/test-codex-harness.sh
fi

bash tests/test-validate-defensive.sh
