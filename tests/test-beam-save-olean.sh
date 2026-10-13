#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh

beam_script="$PWD/scripts/lean-beam"
lake_cmd="$(command -v lake)"
ci_timeout_tracker="https://github.com/leanprover/lean-beam/issues/110"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi

if [ -z "$lake_cmd" ]; then
  echo "missing lake on PATH" >&2
  exit 1
fi

lake_build() {
  # This test distinguishes local rebuilds from broker-written trace replay. Lake's artifact cache
  # can otherwise satisfy edited fixture content and hide that distinction on warmed machines.
  LAKE_ARTIFACT_CACHE=false "$lake_cmd" --no-cache build "$@"
}

beam() {
  # Keep the daemon-side Lake checks under the same cache policy as direct Lake probes in this test.
  LAKE_ARTIFACT_CACHE=false "$beam_script" "$@"
}

declare -a beam_owner_pids=()
beam_owner_last_pid=""

beam_start_owner() {
  local root="$1"
  local owner_out="$root/.beam-test-owner.out"
  local owner_err="$root/.beam-test-owner.err"
  beam --root "$root" serve >"$owner_out" 2>"$owner_err" &
  beam_owner_last_pid="$!"
  beam_owner_pids+=("$beam_owner_last_pid")
  if ! wait_for_file_text "$owner_err" "serving Beam session" "save-replay session owner" 600 0.1; then
    cat "$owner_out" >&2
    cat "$owner_err" >&2
    exit 1
  fi
}

expect_owned_tmp_path() {
  case "$1" in
    /tmp/beam-save-olean-*|/tmp/tmp.*|/tmp/beam-validate-*/tmp/beam-save-olean-*|/tmp/beam-validate-*/tmp/tmp.*)
      ;;
    *)
      echo "refusing to touch unexpected path: $1" >&2
      exit 1
      ;;
  esac
}

remove_owned_tmp_tree() {
  local path="$1"
  expect_owned_tmp_path "$path"
  rm -rf -- "$path"
}

remove_owned_tmp_file() {
  local path="$1"
  expect_owned_tmp_path "$path"
  rm -f -- "$path"
}

mkproj() {
  local dest="$1"
  expect_owned_tmp_path "$dest"
  remove_owned_tmp_tree "$dest"
  mkdir -p "$dest"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$dest"/
}

mk_setup_sensitive_proj() {
  local dest="$1"
  expect_owned_tmp_path "$dest"
  remove_owned_tmp_tree "$dest"
  mkdir -p "$dest/BatchOnly" "$dest/StructuredSetup"
  cat > "$dest/lean-toolchain" <<'EOF'
leanprover/lean4:v4.30.0
EOF
  cat > "$dest/lakefile.lean" <<'EOF'
import Lake
open Lake DSL

package "SetupSensitive"

lean_lib BatchOnly where
  moreLeanArgs := #["-Dweak.batchOnlySetup=true"]

lean_lib StructuredSetup where
  leanOptions := #[⟨`weak.structuredSetup, true⟩]
EOF
  cat > "$dest/BatchOnly/Option.lean" <<'EOF'
import Lean

register_option batchOnlySetup : Bool := {
  defValue := false
  descr := "test-only batch option"
}
EOF
  cat > "$dest/BatchOnly/NeedsBatch.lean" <<'EOF'
import BatchOnly.Option

open Lean Elab Command

elab "#batch_only_decl" : command => do
  if batchOnlySetup.get (← getOptions) then
    liftCoreM <| addDecl <| Declaration.defnDecl {
      name := `batchOnlyValue
      levelParams := []
      type := mkConst ``Nat
      value := mkNatLit 7
      hints := ReducibilityHints.opaque
      safety := DefinitionSafety.safe
    }

#batch_only_decl
EOF
  cat > "$dest/CheckBatchOnly.lean" <<'EOF'
import BatchOnly.NeedsBatch

#check batchOnlyValue
EOF
  cat > "$dest/StructuredSetup/Option.lean" <<'EOF'
import Lean

register_option structuredSetup : Bool := {
  defValue := false
  descr := "test-only structured setup option"
}
EOF
  cat > "$dest/StructuredSetup/UsesOption.lean" <<'EOF'
import StructuredSetup.Option

open Lean Elab Command

elab "#structured_option_decl" : command => do
  if structuredSetup.get (← getOptions) then
    liftCoreM <| addDecl <| Declaration.defnDecl {
      name := `structuredOptionValue
      levelParams := []
      type := mkConst ``Nat
      value := mkNatLit 11
      hints := ReducibilityHints.opaque
      safety := DefinitionSafety.safe
    }

#structured_option_decl

def structuredSetupRevision : Nat := 1
EOF
  cat > "$dest/CheckStructured.lean" <<'EOF'
import StructuredSetup.UsesOption

#check structuredOptionValue
EOF
}

edit_structured_setup() {
  local dest="$1"
  python3 - "$dest/StructuredSetup/UsesOption.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("def structuredSetupRevision : Nat := 1", "def structuredSetupRevision : Nat := 2")
path.write_text(text)
PY
  cat > "$dest/CheckStructured.lean" <<'EOF'
import StructuredSetup.UsesOption

#check structuredOptionValue
example : structuredSetupRevision = 2 := rfl
EOF
}

edit_b() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("def bVal : Nat := 1", "def bVal : Nat := 2")
path.write_text(text)
PY
}

edit_b_slow() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("""import Lean

open Lean Elab Command

elab "save_sleep_cmd" : command => do
  if let some path ← IO.getEnv "LEAN_BEAM_SAVE_RACE_SENTINEL" then
    IO.FS.writeFile path "started\n"
  IO.sleep 1500

def bVal : Nat := 2

save_sleep_cmd
""")
PY
}

edit_b_final() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/B.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text("def bVal : Nat := 3\n")
PY
}

edit_module_b() {
  local dest="$1"
  python3 - "$dest/SaveSmoke/ModuleB.lean" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace("public def moduleBVal : Nat := 1", "public def moduleBVal : Nat := 2")
path.write_text(text)
PY
}

print_diag_section() {
  printf '\n--- %s ---\n' "$1" >&2
}

dump_file() {
  local label="$1"
  local path="$2"
  print_diag_section "$label: $path"
  if [ -e "$path" ]; then
    ls -l "$path" >&2 || true
    cat "$path" >&2 || true
  else
    echo "(missing)" >&2
  fi
}

dump_file_head() {
  local label="$1"
  local path="$2"
  print_diag_section "$label: $path"
  if [ -e "$path" ]; then
    ls -l "$path" >&2 || true
    sed -n '1,120p' "$path" >&2 || true
  else
    echo "(missing)" >&2
  fi
}

dump_file_tail() {
  local label="$1"
  local path="$2"
  print_diag_section "$label: $path"
  if [ -e "$path" ]; then
    ls -l "$path" >&2 || true
    tail -n 120 "$path" >&2 || true
  else
    echo "(missing)" >&2
  fi
}

dump_runtime_context() {
  print_diag_section "runtime context"
  uname -a >&2 || true
  if command -v sysctl >/dev/null 2>&1; then
    printf 'hw.logicalcpu=' >&2
    sysctl -n hw.logicalcpu >&2 2>/dev/null || true
  fi
  if command -v nproc >/dev/null 2>&1; then
    printf 'nproc=' >&2
    nproc >&2 || true
  fi
  uptime >&2 || true
  printf 'GITHUB_ACTIONS=%s\n' "${GITHUB_ACTIONS:-<unset>}" >&2
  printf 'RUNNER_OS=%s\n' "${RUNNER_OS:-<unset>}" >&2
  printf 'RUNNER_ARCH=%s\n' "${RUNNER_ARCH:-<unset>}" >&2
  printf 'LEAN_NUM_THREADS=%s\n' "${LEAN_NUM_THREADS:-<unset>}" >&2
  printf 'LEAN_OPTIONS=%s\n' "${LEAN_OPTIONS:-<unset>}" >&2
  printf 'BEAM_SAVE_RACE_SENTINEL_TIMEOUT=%s\n' "${BEAM_SAVE_RACE_SENTINEL_TIMEOUT:-<unset>}" >&2
}

dump_process_snapshot() {
  print_diag_section "Beam/Lean process snapshot"
  # shellcheck disable=SC2009 # Keep full command lines for CI failure diagnostics.
  ps -ef | grep -E 'beam-daemon|beam-cli|lean --server|scripts/lean-beam' | grep -v grep >&2 || true
}

dump_ci_timeout_tracker_hint() {
  print_diag_section "CI timeout tracker"
  printf '%s\n' \
    "Comment on ${ci_timeout_tracker} if this scheduler-sensitive timeout hits an unrelated CI PR." \
    "Include:" \
    "  - PR URL and branch" \
    "  - failing GitHub Actions run URL and job URL" \
    "  - job name, runner OS/arch, run attempt, and commit SHA" \
    "  - failing test/scenario and this failure headline" \
    "  - save sentinel state, daemon registry, daemon log tail, save stdout/stderr," \
    "    diagnostics-barrier watchdog lines, and process snapshot" \
    "  - rerun URL and whether the rerun passed or reproduced" \
    >&2
}

dump_save_sentinel_context() {
  local label="$1"
  local root="$2"
  local sentinel="$3"
  local save_pid="$4"
  local save_out="$5"
  local save_err="$6"
  print_diag_section "$label"
  printf 'root=%s\n' "$root" >&2
  printf 'sentinel=%s\n' "$sentinel" >&2
  printf 'save_pid=%s\n' "$save_pid" >&2
  if kill -0 "$save_pid" 2>/dev/null; then
    echo "save process is still running" >&2
  else
    echo "save process is not running" >&2
  fi
  dump_runtime_context
  dump_process_snapshot
  dump_ci_timeout_tracker_hint
  dump_file "sentinel file" "$sentinel"
  dump_file_head "SaveSmoke/B.lean" "$root/SaveSmoke/B.lean"
  dump_file "daemon registry" "$root/.beam/beam-daemon.json"
  dump_file_tail "daemon startup log" "$root/.beam/beam-daemon-startup.log"
  dump_file_tail "save stdout" "$save_out"
  dump_file_tail "save stderr" "$save_err"
}

tmp1="$(mktemp -d /tmp/beam-save-olean-build-XXXXXX)"
tmp2="$(mktemp -d /tmp/beam-save-olean-broker-XXXXXX)"
tmp3="$(mktemp -d /tmp/beam-save-olean-race-XXXXXX)"
tmp4="$(mktemp -d /tmp/beam-save-olean-cancel-XXXXXX)"
tmp5="$(mktemp -d /tmp/beam-save-olean-stale-XXXXXX)"
tmp6="$(mktemp -d /tmp/beam-save-olean-stale-trace-XXXXXX)"
tmp7="$(mktemp -d /tmp/beam-save-olean-unsupported-setup-XXXXXX)"
tmp8="$(mktemp -d /tmp/beam-save-olean-module-XXXXXX)"
race_sentinel="$(mktemp /tmp/beam-save-olean-race-sentinel-XXXXXX)"
cancel_sentinel="$(mktemp /tmp/beam-save-olean-cancel-sentinel-XXXXXX)"
log1="$(mktemp /tmp/beam-save-olean-build-log-XXXXXX)"
log2="$(mktemp /tmp/beam-save-olean-broker-log-XXXXXX)"
log3="$(mktemp /tmp/beam-save-olean-race-log-XXXXXX)"
log4="$(mktemp /tmp/beam-save-olean-exact-log-XXXXXX)"
log5="$(mktemp /tmp/beam-save-olean-downstream-log-XXXXXX)"
log6="$(mktemp /tmp/beam-save-olean-module-log-XXXXXX)"
race_save_out="$(mktemp /tmp/beam-save-olean-race-save-out-XXXXXX)"
race_save_err="$(mktemp /tmp/beam-save-olean-race-save-err-XXXXXX)"
save_race_broker_trace="${BEAM_SAVE_RACE_BROKER_TRACE:-1}"
save_race_watchdog_ms="${BEAM_SAVE_RACE_WAIT_DIAGNOSTICS_WATCHDOG_MS:-10000}"

cleanup() {
  local root owner_pid
  for root in "$tmp2" "$tmp3" "$tmp4" "$tmp5" "$tmp6" "$tmp7" "$tmp8"; do
    if [ -d "$root" ]; then
      beam --root "$root" stop > /dev/null 2>&1 || true
    fi
  done
  for owner_pid in ${beam_owner_pids[@]+"${beam_owner_pids[@]}"}; do
    kill -INT "$owner_pid" > /dev/null 2>&1 || true
    wait "$owner_pid" 2>/dev/null || true
  done
  remove_owned_tmp_tree "$tmp1"
  remove_owned_tmp_tree "$tmp2"
  remove_owned_tmp_tree "$tmp3"
  remove_owned_tmp_tree "$tmp4"
  remove_owned_tmp_tree "$tmp5"
  remove_owned_tmp_tree "$tmp6"
  remove_owned_tmp_tree "$tmp7"
  remove_owned_tmp_tree "$tmp8"
  remove_owned_tmp_file "$race_sentinel"
  remove_owned_tmp_file "$cancel_sentinel"
  remove_owned_tmp_file "$log1"
  remove_owned_tmp_file "$log2"
  remove_owned_tmp_file "$log3"
  remove_owned_tmp_file "$log4"
  remove_owned_tmp_file "$log5"
  remove_owned_tmp_file "$log6"
  remove_owned_tmp_file "$race_save_out"
  remove_owned_tmp_file "$race_save_err"
}
trap cleanup EXIT

mkproj "$tmp1"
mkproj "$tmp2"
mkproj "$tmp3"
mkproj "$tmp4"
mkproj "$tmp5"
mkproj "$tmp6"
mk_setup_sensitive_proj "$tmp7"
mkproj "$tmp8"

(cd "$tmp1" && lake_build > /dev/null)
edit_b "$tmp1"
if ! (cd "$tmp1" && lake_build >"$log1" 2>&1); then
  :
fi
if ! grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log1"; then
  echo "expected normal lake build after edit to rebuild SaveSmoke.B" >&2
  cat "$log1" >&2
  exit 1
fi

(cd "$tmp2" && lake_build > /dev/null)
edit_b "$tmp2"
beam_start_owner "$tmp2"
(
  cd "$tmp2"
  save_json="$(beam --root "$tmp2" close-save SaveSmoke/B.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["BEAM_JSON_PAYLOAD"])["result"]["saved"]["snapshot"])
PY
)" = "" ]; then
    echo "expected close-save to report its saved snapshot" >&2
    printf '%s\n' "$save_json" >&2
    exit 1
  fi
  if [ -z "$(BEAM_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["BEAM_JSON_PAYLOAD"])["result"]["saved"]["sourceHash"])
PY
)" ]; then
    echo "expected close-save to report a non-empty sourceHash" >&2
    printf '%s\n' "$save_json" >&2
    exit 1
  fi
  trace_path="$(BEAM_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["BEAM_JSON_PAYLOAD"])["result"]["saved"]["trace"])
PY
)"
  readonly_trace="${trace_path}.readonly"
  mv "$trace_path" "$readonly_trace"
  chmod 444 "$readonly_trace"
  ln -s "$(basename "$readonly_trace")" "$trace_path"
  if ! beam --root "$tmp2" save SaveSmoke/B.lean > /dev/null; then
    echo "expected save to replace an unwritable trace symlink before artifact publication" >&2
    exit 1
  fi
  if [ -L "$trace_path" ] || [ ! -f "$trace_path" ]; then
    echo "expected save to publish a regular replacement trace" >&2
    exit 1
  fi
  chmod 644 "$readonly_trace"
  rm -f "$readonly_trace"
  ilean_path="$(BEAM_JSON_PAYLOAD="$save_json" python3 - <<'PY'
import json, os
print(json.loads(os.environ["BEAM_JSON_PAYLOAD"])["result"]["saved"]["ilean"])
PY
)"
  saved_ilean="${ilean_path}.before-blocked-save"
  mv "$ilean_path" "$saved_ilean"
  mkdir "$ilean_path"
  blocked_save_out="$(mktemp "$tmp2/blocked-save-out-XXXXXX")"
  blocked_save_err="$(mktemp "$tmp2/blocked-save-err-XXXXXX")"
  if beam --root "$tmp2" save SaveSmoke/B.lean \
      >"$blocked_save_out" 2>"$blocked_save_err"; then
    echo "expected save to reject an artifact target that is a directory" >&2
    cat "$blocked_save_out" >&2
    cat "$blocked_save_err" >&2
    exit 1
  fi
  if [ -e "$trace_path" ] || [ -L "$trace_path" ]; then
    echo "expected failed artifact publication to leave the prior trace invalidated" >&2
    cat "$blocked_save_out" >&2
    cat "$blocked_save_err" >&2
    exit 1
  fi
  rmdir "$ilean_path"
  mv "$saved_ilean" "$ilean_path"
  rm -f "$blocked_save_out" "$blocked_save_err"
  if ! beam --root "$tmp2" save SaveSmoke/B.lean > /dev/null; then
    echo "expected save to republish the trace after the artifact target is restored" >&2
    exit 1
  fi
  if [ ! -f "$trace_path" ]; then
    echo "expected successful retry to publish a replacement trace" >&2
    exit 1
  fi
  beam --root "$tmp2" stop > /dev/null 2>&1 || true
  lake_build -v SaveSmoke/B.lean >"$log4" 2>&1
  rm -f .lake/build/lib/lean/SaveSmoke/A.olean .lake/build/lib/lean/SaveSmoke/A.ilean .lake/build/lib/lean/SaveSmoke/A.trace .lake/build/ir/SaveSmoke/A.c
  lake_build -v SaveSmoke/A.lean >"$log5" 2>&1
  lake_build >"$log2" 2>&1
  beam --root "$tmp2" stop > /dev/null 2>&1 || true
)
if ! grep -Eq "Replayed SaveSmoke\\.B" "$log4"; then
  echo "expected exact-target lake build to replay SaveSmoke.B after broker save" >&2
  cat "$log4" >&2
  exit 1
fi
if grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log4"; then
  echo "expected exact-target lake build not to rebuild SaveSmoke.B after broker save" >&2
  cat "$log4" >&2
  exit 1
fi
if ! grep -Eq "Replayed SaveSmoke\\.B" "$log5"; then
  echo "expected downstream rebuild to reuse saved SaveSmoke.B artifact after daemon shutdown" >&2
  cat "$log5" >&2
  exit 1
fi
if ! grep -Eq "Built SaveSmoke\\.A|Building SaveSmoke\\.A" "$log5"; then
  echo "expected downstream rebuild to rebuild SaveSmoke.A after deleting its outputs" >&2
  cat "$log5" >&2
  exit 1
fi
if grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log2"; then
  echo "expected broker save_olean path to leave SaveSmoke.B up to date for lake build" >&2
  cat "$log2" >&2
  exit 1
fi

(cd "$tmp8" && lake_build SaveSmoke/ModuleB.lean > /dev/null)
edit_module_b "$tmp8"
beam_start_owner "$tmp8"
(
  cd "$tmp8"
  module_save_json="$(beam --root "$tmp8" close-save SaveSmoke/ModuleB.lean)"
  for artifact_key in olean oleanServer oleanPrivate ir; do
    artifact="$(BEAM_JSON_PAYLOAD="$module_save_json" BEAM_ARTIFACT_KEY="$artifact_key" python3 - <<'PY'
import json, os
saved = json.loads(os.environ["BEAM_JSON_PAYLOAD"])["result"]["saved"]
print(saved[os.environ["BEAM_ARTIFACT_KEY"]])
PY
)"
    if [ ! -f "$artifact" ]; then
      echo "expected module save artifact $artifact_key at $artifact" >&2
      exit 1
    fi
  done
  beam --root "$tmp8" stop > /dev/null 2>&1 || true
  lake_build -v SaveSmoke/ModuleB.lean >"$log6" 2>&1
  LAKE_ARTIFACT_CACHE=false "$lake_cmd" env lean CheckModuleB.lean > /dev/null
)
if ! grep -Eq "Replayed SaveSmoke\\.ModuleB" "$log6"; then
  echo "expected lake build to replay the complete saved module artifact family" >&2
  cat "$log6" >&2
  exit 1
fi
if grep -Eq "Built SaveSmoke\\.ModuleB|Building SaveSmoke\\.ModuleB" "$log6"; then
  echo "expected complete module artifacts to remain current after broker save" >&2
  cat "$log6" >&2
  exit 1
fi

(cd "$tmp7" && lake_build BatchOnly/NeedsBatch.lean StructuredSetup/UsesOption.lean > /dev/null)
(cd "$tmp7" && LAKE_ARTIFACT_CACHE=false "$lake_cmd" env lean CheckBatchOnly.lean > /dev/null)
(cd "$tmp7" && LAKE_ARTIFACT_CACHE=false "$lake_cmd" env lean CheckStructured.lean > /dev/null)
edit_structured_setup "$tmp7"
beam_start_owner "$tmp7"
(
  cd "$tmp7"
  structured_save="$(beam --root "$tmp7" save StructuredSetup/UsesOption.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$structured_save" python3 - <<'PY'
import json, os
print(json.loads(os.environ["BEAM_JSON_PAYLOAD"])["ok"])
PY
)" != "True" ]; then
    echo "expected save to reuse an LSP snapshot with structured Lake options" >&2
    printf '%s\n' "$structured_save" >&2
    exit 1
  fi
  LAKE_ARTIFACT_CACHE=false "$lake_cmd" env lean CheckStructured.lean > /dev/null

  unsupported_save_out="$(mktemp /tmp/beam-save-olean-unsupported-save-out-XXXXXX)"
  unsupported_save_err="$(mktemp /tmp/beam-save-olean-unsupported-save-err-XXXXXX)"
  if beam --root "$tmp7" save BatchOnly/NeedsBatch.lean \
      >"$unsupported_save_out" 2>"$unsupported_save_err"; then
    echo "expected save to reject batch-only moreLeanArgs" >&2
    cat "$unsupported_save_out" >&2
    cat "$unsupported_save_err" >&2
    remove_owned_tmp_file "$unsupported_save_out"
    remove_owned_tmp_file "$unsupported_save_err"
    exit 1
  fi
  if ! grep -q '"code": "saveUnsupportedSetup"' "$unsupported_save_out"; then
    echo "expected unsupported setup failure to expose saveUnsupportedSetup" >&2
    cat "$unsupported_save_out" >&2
    cat "$unsupported_save_err" >&2
    remove_owned_tmp_file "$unsupported_save_out"
    remove_owned_tmp_file "$unsupported_save_err"
    exit 1
  fi
  if ! grep -q 'Move shared -D settings from moreLeanArgs to leanOptions' "$unsupported_save_out"; then
    echo "expected unsupported setup failure to explain the leanOptions migration" >&2
    cat "$unsupported_save_out" >&2
    cat "$unsupported_save_err" >&2
    remove_owned_tmp_file "$unsupported_save_out"
    remove_owned_tmp_file "$unsupported_save_err"
    exit 1
  fi
  if ! grep -q 'intentionally batch-only' "$unsupported_save_out"; then
    echo "expected unsupported setup failure to recommend lake build for batch-only arguments" >&2
    cat "$unsupported_save_out" >&2
    cat "$unsupported_save_err" >&2
    remove_owned_tmp_file "$unsupported_save_out"
    remove_owned_tmp_file "$unsupported_save_err"
    exit 1
  fi
  remove_owned_tmp_file "$unsupported_save_out"
  remove_owned_tmp_file "$unsupported_save_err"
  LAKE_ARTIFACT_CACHE=false "$lake_cmd" env lean CheckBatchOnly.lean > /dev/null
  beam --root "$tmp7" stop > /dev/null 2>&1 || true
)

(cd "$tmp3" && lake_build > /dev/null)
remove_owned_tmp_file "$race_sentinel"
LEAN_BEAM_BROKER_TRACE="$save_race_broker_trace" \
  LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS="$save_race_watchdog_ms" \
  LEAN_BEAM_SAVE_RACE_SENTINEL="$race_sentinel" \
  beam_start_owner "$tmp3"
(
  cd "$tmp3"
  LEAN_BEAM_BROKER_TRACE="$save_race_broker_trace" \
    LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS="$save_race_watchdog_ms" \
    LEAN_BEAM_SAVE_RACE_SENTINEL="$race_sentinel" \
    beam --root "$tmp3" sync SaveSmoke/B.lean > /dev/null
)
edit_b_slow "$tmp3"
(
  cd "$tmp3"
  : > "$race_save_out"
  : > "$race_save_err"
  LEAN_BEAM_SAVE_RACE_SENTINEL="$race_sentinel" \
    beam --root "$tmp3" close-save SaveSmoke/B.lean >"$race_save_out" 2>"$race_save_err" &
  save_pid=$!
  if ! wait_for_file "$race_sentinel" "save_olean race sentinel" "${BEAM_SAVE_RACE_SENTINEL_TIMEOUT:-60}" 0.05; then
    dump_save_sentinel_context "save_olean race sentinel timeout" \
      "$tmp3" "$race_sentinel" "$save_pid" "$race_save_out" "$race_save_err"
    kill "$save_pid" 2>/dev/null || true
    wait "$save_pid" 2>/dev/null || true
    exit 1
  fi
  edit_b_final "$tmp3"
  if ! wait "$save_pid"; then
    dump_save_sentinel_context "save_olean race save command failed" \
      "$tmp3" "$race_sentinel" "$save_pid" "$race_save_out" "$race_save_err"
    exit 1
  fi
  lake_build -v SaveSmoke/A.lean >"$log3" 2>&1
  beam --root "$tmp3" stop > /dev/null 2>&1 || true
)
if ! grep -Eq "Built SaveSmoke\\.B|Building SaveSmoke\\.B" "$log3"; then
  echo "expected save_olean race to leave SaveSmoke.B stale for downstream builds" >&2
  cat "$log3" >&2
  exit 1
fi

(cd "$tmp4" && lake_build > /dev/null)
edit_b_slow "$tmp4"
remove_owned_tmp_file "$cancel_sentinel"
LEAN_BEAM_BROKER_TRACE="$save_race_broker_trace" \
  LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS="$save_race_watchdog_ms" \
  LEAN_BEAM_SAVE_RACE_SENTINEL="$cancel_sentinel" \
  beam_start_owner "$tmp4"
(
  cd "$tmp4"
  close_out="$(mktemp /tmp/beam-close-save-cancel-out-XXXXXX)"
  close_err="$(mktemp /tmp/beam-close-save-cancel-err-XXXXXX)"
  LEAN_BEAM_SAVE_RACE_SENTINEL="$cancel_sentinel" BEAM_REQUEST_ID=cancel-close-save \
    beam --root "$tmp4" close-save SaveSmoke/B.lean >"$close_out" 2>"$close_err" &
  close_pid=$!
  if ! wait_for_file "$cancel_sentinel" "cancel save sentinel" "${BEAM_SAVE_RACE_SENTINEL_TIMEOUT:-60}" 0.05; then
    dump_save_sentinel_context "cancel save sentinel timeout" \
      "$tmp4" "$cancel_sentinel" "$close_pid" "$close_out" "$close_err"
    kill "$close_pid" 2>/dev/null || true
    wait "$close_pid" 2>/dev/null || true
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  cancel_json="$(beam --root "$tmp4" cancel cancel-close-save)"
  if ! printf '%s\n' "$cancel_json" | grep -q '"cancelled": true'; then
    echo "expected explicit cancel to report cancelled=true for close-save" >&2
    printf '%s\n' "$cancel_json" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  if wait "$close_pid"; then
    echo "expected cancelled close-save to exit non-zero" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  if ! grep -q '"code": "requestCancelled"' "$close_out"; then
    echo "expected cancelled close-save to report requestCancelled" >&2
    cat "$close_out" >&2
    cat "$close_err" >&2
    rm -f "$close_out" "$close_err"
    exit 1
  fi
  beam --root "$tmp4" stats > /dev/null
  beam --root "$tmp4" stop > /dev/null
  rm -f "$close_out" "$close_err"
)

(cd "$tmp6" && lake_build SaveSmoke/A.lean > /dev/null)
beam_start_owner "$tmp6"
(
  cd "$tmp6"
  beam --root "$tmp6" sync SaveSmoke/A.lean > /dev/null
  edit_b "$tmp6"
  save_out="$(mktemp /tmp/beam-stale-trace-save-out-XXXXXX)"
  save_err="$(mktemp /tmp/beam-stale-trace-save-err-XXXXXX)"
  if beam --root "$tmp6" save SaveSmoke/A.lean >"$save_out" 2>"$save_err"; then
    echo "expected save to reject an importer whose Lake save trace is stale" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$save_out" "$save_err"
    exit 1
  fi
  if ! grep -q '"code": "saveTraceStale"' "$save_out"; then
    echo "expected stale trace save to report saveTraceStale" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$save_out" "$save_err"
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$save_err"; then
    echo "expected stale trace save to preserve the daemon connection" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$save_out" "$save_err"
    exit 1
  fi
  beam --root "$tmp6" stats > /dev/null
  beam --root "$tmp6" stop > /dev/null
  rm -f "$save_out" "$save_err"
)

(cd "$tmp5" && lake_build SaveSmoke/A.lean > /dev/null)
printf 'def bVal : Nat := "broken"\n' > "$tmp5/SaveSmoke/B.lean"
beam_start_owner "$tmp5"
(
  cd "$tmp5"
  sync_out="$(mktemp /tmp/beam-stale-sync-out-XXXXXX)"
  sync_err="$(mktemp /tmp/beam-stale-sync-err-XXXXXX)"
  save_out="$(mktemp /tmp/beam-stale-save-out-XXXXXX)"
  save_err="$(mktemp /tmp/beam-stale-save-err-XXXXXX)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID=concurrent-stale-sync \
    beam --root "$tmp5" sync SaveSmoke/A.lean >"$sync_out" 2>"$sync_err" &
  sync_pid=$!
  wait_for_file_text "$sync_err" "syncing SaveSmoke/A.lean" "concurrent stale sync start" 300 0.05
  BEAM_REQUEST_ID=concurrent-stale-save \
    beam --root "$tmp5" save SaveSmoke/A.lean >"$save_out" 2>"$save_err" &
  save_pid=$!
  if wait "$sync_pid"; then
    echo "expected concurrent stale sync to fail" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if wait "$save_pid"; then
    echo "expected concurrent stale save to fail" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$sync_out"; then
    echo "expected concurrent stale sync to report syncBarrierIncomplete" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if ! grep -q '"code": "syncBarrierIncomplete"' "$save_out"; then
    echo "expected concurrent stale save to report syncBarrierIncomplete" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$sync_err"; then
    echo "expected concurrent stale sync to preserve the daemon connection" >&2
    cat "$sync_out" >&2
    cat "$sync_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  if grep -q 'Beam daemon connection closed' "$save_err"; then
    echo "expected concurrent stale save to preserve the daemon connection" >&2
    cat "$save_out" >&2
    cat "$save_err" >&2
    rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
    exit 1
  fi
  beam --root "$tmp5" stats > /dev/null
  beam --root "$tmp5" stop > /dev/null
  rm -f "$sync_out" "$sync_err" "$save_out" "$save_err"
)
