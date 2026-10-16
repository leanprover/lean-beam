#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init
root="$(beam_wrapper_prepare_project_root toolchain-selection)"
real_elan="$(command -v elan)"
shim="$beam_wrapper_tmp_root/shim"
mkdir -p "$shim"
cat > "$shim/elan" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "which" ] && [ "${2:-}" = "lean" ]; then
  printf '%s\n' "$BEAM_TEST_FOREIGN_LEAN"
else
  exec "$BEAM_TEST_REAL_ELAN" "$@"
fi
SH
chmod +x "$shim/elan"

with_override() {
  PATH="$shim:$PATH" ELAN_TOOLCHAIN=beam-test-ambient-override \
    BEAM_TEST_REAL_ELAN="$real_elan" BEAM_TEST_FOREIGN_LEAN="$shim/foreign-lean" "$@"
}

baseline="$(env -u ELAN_TOOLCHAIN "$beam_script" --root "$root" mcp-config)"
overridden="$(with_override "$beam_script" --root "$root" mcp-config)"
BEAM_TEST_BASELINE="$baseline" BEAM_TEST_OVERRIDDEN="$overridden" python3 - <<'PY'
import json
import os

baseline = json.loads(os.environ["BEAM_TEST_BASELINE"])
overridden = json.loads(os.environ["BEAM_TEST_OVERRIDDEN"])
assert overridden == baseline, (baseline, overridden)
PY

doctor="$(with_override "$beam_script" --root "$root" doctor)"
expected_lean="$(json_text_field "$baseline" lean_cmd)"
if ! printf '%s\n' "$doctor" | grep -Fq "lean binary: $expected_lean"; then
  echo "doctor must report the compiler selected with the bundle" >&2
  printf '%s\n' "$doctor" >&2
  exit 1
fi

with_override beam_wrapper_start_owner "$root"
owner_pid="$beam_wrapper_last_owner_pid"
updated="$(with_override "$beam_script" --root "$root" update PositionEmptyLine.lean)"
version="$(json_text_field "$updated" result.version)"
probe="$(with_override "$beam_script" --root "$root" run-at PositionEmptyLine.lean "$version" 1 0 -- '#check answer')"
if [ "$(json_text_field "$probe" ok)" != "true" ]; then
  printf '%s\n' "$probe" >&2
  exit 1
fi
with_override "$beam_script" --root "$root" stop > /dev/null
wait "$owner_pid"
beam_wrapper_unregister_pid "$owner_pid"
