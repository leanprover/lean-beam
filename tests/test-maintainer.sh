#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 tests/test-extended-ci.py
python3 tests/test-toolchain-compat-owner.py

bash tests/test-task-harness.sh

bash tests/test-validate-defensive.sh
