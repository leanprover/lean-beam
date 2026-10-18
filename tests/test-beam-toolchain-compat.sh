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
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh
# shellcheck source=tests/lib/toolchain-compat-owner.sh
. tests/lib/toolchain-compat-owner.sh
# shellcheck source=tests/lib/toolchain-registry.sh
. tests/lib/toolchain-registry.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-beam-toolchain-compat}"
bundle_timeout="${BEAM_TOOLCHAIN_COMPAT_TIMEOUT:-600}"
keep_tmp_on_failure="${BEAM_TOOLCHAIN_COMPAT_KEEP_TMP_ON_FAILURE:-0}"
toolchain="${1:-}"
if [ -z "$toolchain" ]; then
  echo "usage: bash tests/test-beam-toolchain-compat.sh <toolchain>" >&2
  exit 1
fi
case "$bundle_timeout" in
  ''|*[!0-9]*)
    echo "invalid BEAM_TOOLCHAIN_COMPAT_TIMEOUT: $bundle_timeout" >&2
    exit 1
    ;;
esac

if ! validated_registry_entries="$(beam_test_read_registry_entries validated-lean-toolchains)"; then
  echo "failed to read validated Lean toolchain registry" >&2
  exit 1
fi

tmp_bundle_dir="$(mktemp -d /tmp/beam-toolchain-bundles-XXXXXX)"
tmp_env_root="$(mktemp -d /tmp/beam-toolchain-env-XXXXXX)"
build_stdout="$tmp_env_root/build.stdout"
build_stderr="$tmp_env_root/build.stderr"
bundle_stdout="$tmp_env_root/bundle-install.stdout"
bundle_stderr="$tmp_env_root/bundle-install.stderr"
admission_stdout="$tmp_env_root/admission.stdout"
admission_stderr="$tmp_env_root/admission.stderr"
stale_project_root="$tmp_env_root/stale-diagnostic-project"
stale_build_stdout="$tmp_env_root/stale-build.stdout"
stale_build_stderr="$tmp_env_root/stale-build.stderr"
stale_sync_stdout="$tmp_env_root/stale-sync.stdout"
stale_sync_stderr="$tmp_env_root/stale-sync.stderr"
stale_owner_stdout="$tmp_env_root/stale-owner.stdout"
stale_owner_stderr="$tmp_env_root/stale-owner.stderr"
stale_owner_pid=""
module_build_stdout="$tmp_env_root/module-build.stdout"
module_build_stderr="$tmp_env_root/module-build.stderr"
module_save_stdout="$tmp_env_root/module-save.stdout"
module_save_stderr="$tmp_env_root/module-save.stderr"
module_saved_trace="$tmp_env_root/module-saved.trace"
toolchain_failed=false

if [ -z "${ELAN_HOME:-}" ] && [ -d "$HOME/.elan" ]; then
  export ELAN_HOME="$HOME/.elan"
fi
host_elan_home="${ELAN_HOME:-$HOME/.elan}"

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-toolchain-bundles beam-toolchain-env
}

cleanup() {
  cleanup_stale_owner
  if [ "$toolchain_failed" = "true" ]; then
    case "$keep_tmp_on_failure" in
      1|true|True|TRUE|yes|Yes|YES|on|On|ON)
        echo "preserving toolchain compatibility temp roots after failure:" >&2
        echo "  bundle dir: $tmp_bundle_dir" >&2
        echo "  env root: $tmp_env_root" >&2
        return 0
        ;;
    esac
  fi
  expect_owned_tmp_dir "$tmp_bundle_dir"
  expect_owned_tmp_dir "$tmp_env_root"
  rm -rf -- "$tmp_bundle_dir" "$tmp_env_root"
}
trap cleanup EXIT

mkdir -p "$tmp_env_root/home" "$tmp_env_root/codex" "$tmp_env_root/claude"

tail_file() {
  local label="$1"
  local path="$2"
  if [ -s "$path" ]; then
    echo "--- $label: $path ---" >&2
    tail -n 120 "$path" >&2
  else
    echo "--- $label: $path is empty or missing ---" >&2
  fi
}

print_toolchain_context() {
  local label="$1"
  toolchain_failed=true
  echo "toolchain compatibility failure: $label" >&2
  echo "toolchain: $toolchain" >&2
  echo "bundle timeout: ${bundle_timeout}s" >&2
  echo "keep tmp on failure: $keep_tmp_on_failure" >&2
  echo "bundle dir: $tmp_bundle_dir" >&2
  echo "env root: $tmp_env_root" >&2
  echo "home: $tmp_env_root/home" >&2
  echo "codex home: $tmp_env_root/codex" >&2
  echo "claude home: $tmp_env_root/claude" >&2
  echo "platform: $(uname -a)" >&2
  tail_file "build stdout" "$build_stdout"
  tail_file "build stderr" "$build_stderr"
  tail_file "bundle stdout" "$bundle_stdout"
  tail_file "bundle stderr" "$bundle_stderr"
  tail_file "admission stdout" "$admission_stdout"
  tail_file "admission stderr" "$admission_stderr"
  tail_file "stale build stdout" "$stale_build_stdout"
  tail_file "stale build stderr" "$stale_build_stderr"
  tail_file "stale sync stdout" "$stale_sync_stdout"
  tail_file "stale sync stderr" "$stale_sync_stderr"
  tail_file "stale owner stdout" "$stale_owner_stdout"
  tail_file "stale owner stderr" "$stale_owner_stderr"
  tail_file "module build stdout" "$module_build_stdout"
  tail_file "module build stderr" "$module_build_stderr"
  tail_file "module save stdout" "$module_save_stdout"
  tail_file "module save stderr" "$module_save_stderr"
  tail_file "module saved trace" "$module_saved_trace"
}

run_build() {
  if ! lake build beam-cli > "$build_stdout" 2> "$build_stderr"; then
    print_toolchain_context "beam-cli build failed"
    return 1
  fi
}

run_with_timeout() {
  local timeout="$1"
  local stdout_path="$2"
  local stderr_path="$3"
  shift 3
  python3 - "$timeout" "$stdout_path" "$stderr_path" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
stdout_path = sys.argv[2]
stderr_path = sys.argv[3]
cmd = sys.argv[4:]

with open(stdout_path, "wb") as out, open(stderr_path, "wb") as err:
    proc = subprocess.Popen(cmd, stdout=out, stderr=err)
    try:
        rc = proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        print(f"timed out after {timeout}s: {' '.join(cmd)}", file=sys.stderr)
        sys.exit(124)
sys.exit(rc)
PY
}

run_bundle_install() {
  local rc=0
  (
    unset BEAM_HOME BEAM_SESSION_ROOT
    export HOME="$tmp_env_root/home"
    export CODEX_HOME="$tmp_env_root/codex"
    export CLAUDE_HOME="$tmp_env_root/claude"
    export BEAM_INSTALL_BUNDLE_DIR="$tmp_bundle_dir"
    run_with_timeout "$bundle_timeout" "$bundle_stdout" "$bundle_stderr" \
      ./.lake/build/bin/beam-cli bundle-install "$toolchain"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "bundle install failed"
    return "$rc"
  fi
}

run_toolchain_admission_check() {
  local expected_admission="release-line"
  local expected_release_line=""
  prepare_stale_diagnostic_project
  if grep -qxF -- "$toolchain" <<< "$validated_registry_entries"; then
    expected_admission="validated"
  fi
  if ! run_stale_wrapper doctor > "$admission_stdout" 2> "$admission_stderr"; then
    print_toolchain_context "toolchain admission doctor failed"
    return 1
  fi
  if ! grep -q "project toolchain admission: $expected_admission" "$admission_stdout"; then
    print_toolchain_context "toolchain admission classification changed"
    return 1
  fi
  if ! grep -q 'project toolchain accepted: true' "$admission_stdout"; then
    print_toolchain_context "accepted toolchain was rejected by doctor"
    return 1
  fi
  if ! grep -q 'bundle ready: true' "$admission_stdout"; then
    print_toolchain_context "qualified bundle was not marked ready"
    return 1
  fi
  if [ "$expected_admission" = "release-line" ]; then
    expected_release_line="$(printf '%s\n' "$toolchain" | sed -E 's#^leanprover/lean4:v([0-9]+\.[0-9]+)\..*$#\1#')"
    if ! grep -q "project toolchain release line: $expected_release_line" "$admission_stdout"; then
      print_toolchain_context "release-line doctor classification changed"
      return 1
    fi
  fi
}

prepare_stale_diagnostic_project() {
  rm -rf -- "$stale_project_root"
  mkdir -p "$stale_project_root"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$stale_project_root"/
  printf '%s\n' "$toolchain" > "$stale_project_root/lean-toolchain"
  rm -rf -- "$stale_project_root/.beam"
  mkdir -p "$stale_project_root/.beam"
  chmod 700 "$stale_project_root/.beam"
}

assert_stale_diagnostic_payload() {
  python3 - "$stale_sync_stdout" <<'PY'
import json
import sys

expected = 'Imports are out of date and should be rebuilt; use the "Restart File" command in your editor.'
path = sys.argv[1]
try:
    with open(path) as f:
        payload = json.load(f)
except Exception as ex:
    raise SystemExit(f"expected stale sync stdout to be JSON, got {ex}")

error = payload.get("error")
if not isinstance(error, dict):
    raise SystemExit(f"expected stale sync response to be an error, got {payload!r}")
if error.get("code") != "syncBarrierIncomplete":
    raise SystemExit(f"expected syncBarrierIncomplete, got {error.get('code')!r}")
data = error.get("data")
if not isinstance(data, dict):
    raise SystemExit(f"expected error.data object, got {data!r}")
diagnostics = data.get("completionBlockingDiagnostics")
if not isinstance(diagnostics, list):
    raise SystemExit(f"expected completionBlockingDiagnostics array, got {diagnostics!r}")
messages = [diag.get("message") for diag in diagnostics if isinstance(diag, dict)]
if expected not in messages:
    raise SystemExit(
        "expected Lean stale-import diagnostic wording in completionBlockingDiagnostics; "
        f"messages were {messages!r}"
    )
PY
}

stale_wrapper_command=(
  env
  "HOME=$tmp_env_root/home"
  "CODEX_HOME=$tmp_env_root/codex"
  "CLAUDE_HOME=$tmp_env_root/claude"
  "ELAN_HOME=$host_elan_home"
  "BEAM_INSTALL_BUNDLE_DIR=$tmp_bundle_dir"
  ./scripts/lean-beam --root "$stale_project_root"
)

run_stale_wrapper() {
  ${stale_wrapper_command[@]+"${stale_wrapper_command[@]}"} "$@"
}

run_stale_wrapper_checked() {
  local label="$1"
  shift
  if ! run_stale_wrapper "$@" > "$stale_sync_stdout" 2> "$stale_sync_stderr"; then
    print_toolchain_context "$label"
    return 1
  fi
}

stop_stale_owner() {
  if [ -z "$stale_owner_pid" ]; then
    return 0
  fi
  if ! run_stale_wrapper stop > /dev/null 2> "$stale_sync_stderr"; then
    print_toolchain_context "explicit session owner failed to shut down"
    return 1
  fi
  if ! wait_for_exit "$stale_owner_pid" "toolchain compatibility session owner" 120 0.1; then
    print_toolchain_context "explicit session owner did not exit"
    return 1
  fi
  if ! wait "$stale_owner_pid"; then
    print_toolchain_context "explicit session owner exited unsuccessfully"
    return 1
  fi
  stale_owner_pid=""
}

run_stale_diagnostic_compat() {
  local rc=0
  prepare_stale_diagnostic_project
  cat > "$stale_project_root/SaveSmoke/B.lean" <<'EOF'
def old : Nat := 1
EOF
  cat > "$stale_project_root/SaveSmoke/A.lean" <<'EOF'
import SaveSmoke.B

def aVal : Nat := old
EOF
  (
    cd "$stale_project_root"
    lake build SaveSmoke/A.lean > "$stale_build_stdout" 2> "$stale_build_stderr"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "stale diagnostic fixture build failed"
    return "$rc"
  fi

  if ! start_stale_owner; then
    return 1
  fi

  if ! run_stale_wrapper_checked "initial dependency sync failed" sync SaveSmoke/B.lean; then
    return 1
  fi
  if ! run_stale_wrapper_checked "initial importer sync failed" sync SaveSmoke/A.lean; then
    return 1
  fi

  cat > "$stale_project_root/SaveSmoke/B.lean" <<'EOF'
def new : Nat := 2
EOF
  cat > "$stale_project_root/SaveSmoke/A.lean" <<'EOF'
import SaveSmoke.B

def aVal : Nat := new
EOF
  if ! run_stale_wrapper_checked "changed dependency sync failed" sync SaveSmoke/B.lean; then
    return 1
  fi
  if ! run_stale_wrapper_checked "changed dependency save failed" save SaveSmoke/B.lean; then
    return 1
  fi
  (
    cd "$stale_project_root"
    lake build SaveSmoke/A.lean > "$stale_build_stdout" 2> "$stale_build_stderr"
  ) || rc=$?
  if [ "$rc" -ne 0 ]; then
    print_toolchain_context "changed stale diagnostic fixture build failed"
    return "$rc"
  fi

  rc=0
  run_stale_wrapper sync SaveSmoke/A.lean > "$stale_sync_stdout" 2> "$stale_sync_stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    print_toolchain_context "stale diagnostic sync unexpectedly succeeded"
    return 1
  fi
  if ! assert_stale_diagnostic_payload; then
    print_toolchain_context "stale diagnostic wording changed"
    return 1
  fi
  stop_stale_owner
}

run_module_artifact_compat() {
  # Use the same cache policy in the owner and the batch probes, as in test-beam-save-olean.sh.
  # A warmed artifact cache must not hide whether Lake reuses the broker-written trace.
  local LAKE_ARTIFACT_CACHE=false
  export LAKE_ARTIFACT_CACHE
  local signature="$stale_project_root/.lake/build/lib/lean/SaveSmoke/ModuleB.ir.sig"
  prepare_stale_diagnostic_project
  if ! (cd "$stale_project_root" && LAKE_ARTIFACT_CACHE=false lake --no-cache build \
      SaveSmoke/ModuleB.lean > "$module_build_stdout" 2> "$module_build_stderr"); then
    print_toolchain_context "module fixture build failed"
    return 1
  fi
  if [ ! -f "$signature" ]; then
    print_toolchain_context "module fixture omitted its required IR signature"
    return 1
  fi
  rm -f -- "$signature"
  # The file is not open in a broker yet. Change it before starting the owner, then save its
  # current elaboration with the old module signature removed so leftover batch outputs cannot
  # hide a missing companion artifact.
  sed 's/public def moduleBVal : Nat := 1/public def moduleBVal : Nat := 2/' \
    tests/save_olean_project/SaveSmoke/ModuleB.lean > "$stale_project_root/SaveSmoke/ModuleB.lean"
  if ! start_stale_owner; then
    return 1
  fi
  if ! run_stale_wrapper close-save SaveSmoke/ModuleB.lean \
      > "$module_save_stdout" 2> "$module_save_stderr"; then
    print_toolchain_context "module close-save failed"
    return 1
  fi
  if ! python3 - "$module_save_stdout" "$module_saved_trace" <<'PY'
import json
import pathlib
import sys

saved = json.loads(pathlib.Path(sys.argv[1]).read_text())["result"]["saved"]
for key in ["olean", "oleanServer", "oleanPrivate", "ir", "irSig", "ilean", "c", "trace"]:
    if not pathlib.Path(saved[key]).is_file():
        raise SystemExit(f"module save omitted {key}: {saved}")
metadata = json.loads(pathlib.Path(saved["trace"]).read_text())
pathlib.Path(sys.argv[2]).write_text(json.dumps(metadata, indent=2) + "\n")
if "rs" not in metadata["outputs"]:
    raise SystemExit("module save trace omitted IR signature descriptor")
PY
  then
    print_toolchain_context "module artifact family was incomplete"
    return 1
  fi
  if ! stop_stale_owner; then
    return 1
  fi
  if ! (cd "$stale_project_root" && LAKE_ARTIFACT_CACHE=false lake --no-cache build -v \
      SaveSmoke/ModuleB.lean > "$module_build_stdout" 2> "$module_build_stderr" &&
      lake env lean CheckModuleB.lean >> "$module_build_stdout" 2>> "$module_build_stderr"); then
    print_toolchain_context "saved module replay or import failed"
    return 1
  fi
  if ! grep -Eq 'Replayed SaveSmoke\.ModuleB' "$module_build_stdout" "$module_build_stderr" ||
      grep -Eq 'Built SaveSmoke\.ModuleB|Building SaveSmoke\.ModuleB' \
        "$module_build_stdout" "$module_build_stderr"; then
    print_toolchain_context "saved module was rebuilt instead of replayed"
    return 1
  fi
  if ! (cd "$stale_project_root" && lake --no-cache build checkModuleBNative >> "$module_build_stdout" 2>> "$module_build_stderr" &&
      test "$(.lake/build/bin/checkModuleBNative)" = 2); then
    print_toolchain_context "saved module native compilation or execution failed"
    return 1
  fi
}

run_step "build beam-cli" run_build
run_step "bundle install $toolchain" run_bundle_install
run_step "toolchain admission $toolchain" run_toolchain_admission_check
run_step "module artifact replay $toolchain" run_module_artifact_compat
run_step "stale diagnostic wording $toolchain" run_stale_diagnostic_compat
