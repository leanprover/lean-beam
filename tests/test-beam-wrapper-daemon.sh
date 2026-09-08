#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_script="$PWD/scripts/lean-beam"
beam_cli="$PWD/.lake/build/bin/beam-cli"

if [ ! -x "$beam_script" ]; then
  echo "missing lean-beam wrapper at $beam_script" >&2
  exit 1
fi
if [ ! -x "$beam_cli" ]; then
  echo "missing beam-cli at $beam_cli" >&2
  exit 1
fi

tmp1="$(mktemp -d /tmp/beam-wrapper-daemon-owner-a-XXXXXX)"
tmp2="$(mktemp -d /tmp/beam-wrapper-daemon-owner-b-XXXXXX)"
owned_bundle_dir=""
if [ -z "${BEAM_INSTALL_BUNDLE_DIR:-}" ]; then
  owned_bundle_dir="$(mktemp -d /tmp/beam-wrapper-daemon-owner-bundles-XXXXXX)"
  export BEAM_INSTALL_BUNDLE_DIR="$owned_bundle_dir"
fi
hold_pid=""
root_removed="false"
active_request_pid=""
paused_daemon_pid=""
busy_pid=""
busy_port_file=""

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

start_slow_request() {
  local root="$1"
  local label="$2"
  local request_id="$3"
  local snapshot
  snapshot="$(beam_wrapper_update_snapshot "$label SlowPoll" \
    "$beam_script" --root "$root" update tests/scenario/docs/SlowPoll.lean)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID="$request_id" "$beam_script" --root "$root" \
    run-at tests/scenario/docs/SlowPoll.lean "$snapshot" 25 2 poll_sleep_cmd \
    >"$root/$label.out" 2>"$root/$label.err" &
  active_request_pid="$!"
  if ! wait_for_file_text "$root/$label.err" "running run-at" \
      "$label request progress" 150 0.1; then
    cat "$root/$label.out" >&2
    cat "$root/$label.err" >&2
    exit 1
  fi
  if ! kill -0 "$active_request_pid" 2>/dev/null; then
    echo "expected $label request to remain active before session close" >&2
    cat "$root/$label.out" >&2
    cat "$root/$label.err" >&2
    exit 1
  fi
}

expect_slow_request_cancelled() {
  local root="$1"
  local label="$2"
  local request_id="$3"
  local status=0
  set +e
  wait "$active_request_pid"
  status="$?"
  set -e
  active_request_pid=""
  if [ "$status" -eq 0 ]; then
    echo "expected $label request to exit non-zero after session close" >&2
    cat "$root/$label.out" >&2
    exit 1
  fi
  assert_json_file_field_equals "$label cancellation code" "$root/$label.out" \
    error.code requestCancelled "$root/$label.err"
  assert_json_file_field_equals "$label request id" "$root/$label.out" \
    clientRequestId "$request_id" "$root/$label.err"
}

stop_hold_process() {
  local require_clean_exit="${1:-false}"
  local registry_path="${2:-}"
  local stderr_path="${3:-}"
  if [ -z "$hold_pid" ]; then
    return
  fi
  kill -INT "$hold_pid" > /dev/null 2>&1 || true
  if [ "$require_clean_exit" = "true" ] && [ -n "$registry_path" ]; then
    local acknowledged="false"
    local lifecycle=""
    for _ in $(seq 1 100); do
      if ! kill -0 "$hold_pid" > /dev/null 2>&1 || [ ! -e "$registry_path" ]; then
        acknowledged="true"
        break
      fi
      if lifecycle="$(read_json_field "$registry_path" lifecycle 2>/dev/null)" && \
          [ "$lifecycle" = "draining" ]; then
        acknowledged="true"
        break
      fi
      sleep 0.05
    done
    if [ "$acknowledged" != "true" ]; then
      echo "expected serve owner to acknowledge SIGINT by entering session teardown" >&2
      if [ -n "$stderr_path" ] && [ -f "$stderr_path" ]; then
        cat "$stderr_path" >&2
      fi
      if [ -f "$registry_path" ]; then
        cat "$registry_path" >&2
      fi
      kill "$hold_pid" > /dev/null 2>&1 || true
      wait "$hold_pid" 2>/dev/null || true
      hold_pid=""
      return 1
    fi
  fi
  # Owner cleanup allows ten seconds for graceful drain and two seconds for forced reaping.
  if ! wait_for_exit "$hold_pid" "serve owner" 300 0.05; then
    kill "$hold_pid" > /dev/null 2>&1 || true
    wait "$hold_pid" 2>/dev/null || true
    hold_pid=""
    if [ "$require_clean_exit" = "true" ]; then
      echo "expected serve owner to complete its bounded cleanup after SIGINT" >&2
      if [ -n "$stderr_path" ] && [ -f "$stderr_path" ]; then
        cat "$stderr_path" >&2
      fi
      if [ -n "$registry_path" ] && [ -f "$registry_path" ]; then
        cat "$registry_path" >&2
      fi
      return 1
    fi
    return
  fi
  local status=0
  set +e
  wait "$hold_pid"
  status="$?"
  set -e
  hold_pid=""
  if [ "$require_clean_exit" = "true" ] && [ "$status" -ne 0 ]; then
    echo "expected serve owner to exit cleanly, got $status" >&2
    return 1
  fi
}

cleanup() {
  if [ -n "$busy_pid" ]; then
    kill "$busy_pid" > /dev/null 2>&1 || true
    wait "$busy_pid" 2>/dev/null || true
    busy_pid=""
  fi
  if [ -n "$busy_port_file" ]; then
    rm -f -- "$busy_port_file"
    busy_port_file=""
  fi
  if [ -n "$paused_daemon_pid" ]; then
    kill -CONT "$paused_daemon_pid" > /dev/null 2>&1 || true
    paused_daemon_pid=""
  fi
  if [ -n "$active_request_pid" ]; then
    kill "$active_request_pid" > /dev/null 2>&1 || true
    wait "$active_request_pid" 2>/dev/null || true
    active_request_pid=""
  fi
  stop_hold_process
  if [ "$root_removed" != "true" ]; then
    "$beam_script" --root "$tmp1" stop > /dev/null 2>&1 || true
    remove_owned_tmp_tree "$tmp1"
  fi
  "$beam_script" --root "$tmp2" stop > /dev/null 2>&1 || true
  remove_owned_tmp_tree "$tmp2"
  if [ -n "$owned_bundle_dir" ]; then
    remove_owned_tmp_tree "$owned_bundle_dir"
  fi
}
trap cleanup EXIT

if [ -n "$owned_bundle_dir" ]; then
  expect_owned_tmp_dir "$owned_bundle_dir"
fi
for tmp in "$tmp1" "$tmp2"; do
  expect_owned_tmp_dir "$tmp"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$tmp"/
  remove_tmp_tree_within "$tmp/.beam" "$tmp"
  mkdir -p "$tmp/.beam"
  chmod 700 "$tmp/.beam"
  mkdir -p "$tmp/tests/scenario/docs"
  cp tests/scenario/docs/SlowPoll.lean "$tmp/tests/scenario/docs/SlowPoll.lean"
done
resolved_tmp1="$(beam_test_realpath "$tmp1")"
resolved_tmp2="$(beam_test_realpath "$tmp2")"

fixture_toolchain="$(awk 'NR==1 {print $1}' tests/save_olean_project/lean-toolchain)"
"$beam_cli" bundle-install "$fixture_toolchain"

invalid_backend_out="$tmp1/invalid-backend.out"
invalid_backend_err="$tmp1/invalid-backend.err"
if "$beam_script" --root "$tmp1" serve typo > "$invalid_backend_out" 2> "$invalid_backend_err"; then
  echo "expected an unknown owner backend to be rejected" >&2
  cat "$invalid_backend_out" >&2
  exit 1
fi
if ! grep -Fq "expected backend 'lean' or 'rocq'" "$invalid_backend_err"; then
  echo "expected unknown-backend diagnostics to list the valid backend names" >&2
  cat "$invalid_backend_err" >&2
  exit 1
fi

# An attaching command observes descriptor state but does not acquire the mutation lock or create
# control-plane files when no owner exists.
remove_tmp_tree_within "$tmp1/.beam" "$tmp1"
missing_owner_out="$tmp1/missing-owner.out"
missing_owner_err="$tmp1/missing-owner.err"
if "$beam_script" --root "$tmp1" stats > "$missing_owner_out" 2> "$missing_owner_err"; then
  echo "expected an ordinary wrapper command to require a session owner" >&2
  cat "$missing_owner_out" >&2
  exit 1
fi
missing_owner_command="lean-beam --root '$resolved_tmp1' --session-dir '$resolved_tmp1/.beam' serve"
if ! grep -Fq "$missing_owner_command" "$missing_owner_err"; then
  echo "expected missing-owner error to preserve the exact session selector" >&2
  cat "$missing_owner_err" >&2
  exit 1
fi
missing_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals "absent session status response" "$missing_status" ok true
assert_json_field_equals "absent session status state" "$missing_status" result.state absent
absent_stop="$("$beam_script" --root "$tmp1" stop)"
assert_json_field_equals "absent session stop response" "$absent_stop" ok true
assert_json_field_equals "absent session stop state" "$absent_stop" result.state absent
assert_json_field_equals "absent session stop changed" "$absent_stop" result.changed false
absent_recover="$("$beam_script" --root "$tmp1" recover --force)"
assert_json_field_equals "absent session recovery response" "$absent_recover" ok true
assert_json_field_equals "absent session recovery state" "$absent_recover" result.state absent
assert_json_field_equals "absent session recovery change" "$absent_recover" result.changed false
if [ -e "$tmp1/.beam" ]; then
  echo "expected absent status, stop, and recovery not to create the project session directory" >&2
  find "$tmp1/.beam" -maxdepth 2 -print >&2 || true
  exit 1
fi

# A feedback bundle can be the first writer below `.beam`. It must establish the same private
# project-state boundary expected by a later wrapper session rather than creating an incompatible
# umask-derived directory.
feedback_private_input='{"title":"Private Beam state","summary":"Check feedback state setup.","reproduction":"feedback before serve","expected":"Private shared state.","actual":"Private shared state."}'
feedback_private_json="$(printf '%s\n' "$feedback_private_input" | \
  "$beam_script" --root "$tmp1" feedback-report --stdin --bundle dir)"
assert_json_field_equals "feedback bundle mode" "$feedback_private_json" metadata.bundle dir
if [ "$(file_mode "$tmp1/.beam")" != "700" ]; then
  echo "expected feedback to create the shared Beam state directory with mode 700" >&2
  exit 1
fi
feedback_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals \
  "feedback-created state remains a valid session selection" "$feedback_status" result.state absent
remove_tmp_tree_within "$tmp1/.beam/feedback" "$tmp1"
rmdir "$tmp1/.beam"

mkdir -p "$tmp1/.beam"
chmod 700 "$tmp1/.beam"
"$beam_script" --root "$tmp1" stop > /dev/null
"$beam_script" --root "$tmp1" recover --force > /dev/null
if [ -e "$tmp1/.beam/lock" ]; then
  echo "expected absent lifecycle commands not to create a lock in an existing session directory" >&2
  exit 1
fi
rmdir "$tmp1/.beam"

# A session path is an exact security boundary, not a redirect. Reject a symlinked default path
# without changing the target or creating any session files through it.
symlink_control_target="$tmp2/symlink-control-target"
mkdir -p "$symlink_control_target"
chmod 755 "$symlink_control_target"
symlink_target_mode_before="$(file_mode "$symlink_control_target")"
ln -s "$symlink_control_target" "$tmp1/.beam"
if "$beam_script" --root "$tmp1" recover --force \
    > "$tmp1/symlink-control.out" 2> "$tmp1/symlink-control.err"; then
  echo "expected a symlinked default control directory to be rejected" >&2
  exit 1
fi
if ! grep -Fq "symbolic links are not accepted" "$tmp1/symlink-control.err"; then
  echo "expected symlinked control rejection to explain the exact-path boundary" >&2
  cat "$tmp1/symlink-control.err" >&2
  exit 1
fi
if [ "$(file_mode "$symlink_control_target")" != "$symlink_target_mode_before" ]; then
  echo "symlinked control rejection changed the target directory mode" >&2
  exit 1
fi
if find "$symlink_control_target" -mindepth 1 -print -quit | grep -q .; then
  echo "symlinked control rejection created files in the target directory" >&2
  find "$symlink_control_target" -mindepth 1 -maxdepth 2 -print >&2
  exit 1
fi
rm -f -- "$tmp1/.beam"
rmdir "$symlink_control_target"

# A private session directory may already contain diagnostics from an earlier run. Refuse a
# symlinked startup-log leaf without truncating its target or publishing a session descriptor.
mkdir -p "$tmp1/.beam"
chmod 700 "$tmp1/.beam"
startup_log_target="$tmp2/startup-log-target"
printf '%s\n' "startup-log-sentinel" > "$startup_log_target"
ln -s "$startup_log_target" "$tmp1/.beam/beam-daemon-startup.log"
if "$beam_script" --root "$tmp1" serve \
    > "$tmp1/symlink-startup-log.out" 2> "$tmp1/symlink-startup-log.err"; then
  echo "expected a symlinked daemon startup log to be rejected" >&2
  exit 1
fi
if ! grep -Fq "startup log" "$tmp1/symlink-startup-log.err" || \
    ! grep -Fq "symbolic links are not accepted" "$tmp1/symlink-startup-log.err"; then
  echo "expected symlinked startup-log rejection to explain the no-follow boundary" >&2
  cat "$tmp1/symlink-startup-log.err" >&2
  exit 1
fi
if [ "$(cat "$startup_log_target")" != "startup-log-sentinel" ]; then
  echo "symlinked startup-log rejection changed the target file" >&2
  exit 1
fi
if [ -e "$tmp1/.beam/beam-daemon.json" ]; then
  echo "symlinked startup-log rejection published a session descriptor" >&2
  exit 1
fi
remove_tmp_tree_within "$tmp1/.beam" "$tmp1"
rm -f -- "$startup_log_target"

start_owner() {
  local root="$1"
  local label="$2"
  local out="$root/$label.out"
  local err="$root/$label.err"
  "$beam_script" --root "$root" serve > "$out" 2> "$err" &
  hold_pid="$!"
  local registry="$root/.beam/beam-daemon.json"
  local attempts="${BEAM_TEST_HOLD_READY_ATTEMPTS:-1800}"
  case "$attempts" in
    ''|*[!0-9]*|0)
      echo "BEAM_TEST_HOLD_READY_ATTEMPTS must be a positive integer" >&2
      exit 1
      ;;
  esac
  for _ in $(seq 1 "$attempts"); do
    if [ -s "$out" ] && [ -f "$registry" ]; then
      break
    fi
    if ! kill -0 "$hold_pid" 2>/dev/null; then
      echo "session owner exited before becoming ready" >&2
      cat "$err" >&2
      exit 1
    fi
    sleep 0.1
  done
  if [ ! -s "$out" ] || [ ! -f "$registry" ]; then
    echo "expected serve to publish its response and registry" >&2
    cat "$err" >&2
    exit 1
  fi
  assert_json_field_equals "serve response" "$(cat "$out")" ok true "$err"
  assert_json_field_equals "serve state" "$(cat "$out")" result.state running "$err"
  assert_json_field_equals \
    "serve workspace" "$(cat "$out")" result.workspace "$(beam_test_realpath "$root")" "$err"
  assert_json_field_equals \
    "serve session directory" "$(cat "$out")" result.sessionDir \
    "$(beam_test_realpath "$root")/.beam" "$err"
  assert_json_field_equals \
    "serve generation" "$(cat "$out")" result.generation \
    "$(read_json_field "$registry" daemonId)" "$err"
  assert_json_field_absent "serve response" "$(cat "$out")" result.workspace_id "$err"
  assert_json_field_absent "serve response" "$(cat "$out")" result.epoch "$err"
}

registry="$tmp1/.beam/beam-daemon.json"
start_owner "$tmp1" "owner-1"
owner1_pid="$hold_pid"
daemon1_pid="$(read_json_field "$registry" pid)"
daemon1_id="$(read_json_field "$registry" daemonId)"
recorded_owner_pid="$(read_json_field "$registry" ownerPid)"
case "$recorded_owner_pid" in
  ''|*[!0-9]*|0)
    echo "expected registry to record a positive session-owner PID" >&2
    cat "$registry" >&2
    exit 1
    ;;
esac
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "expected both the wrapper owner and daemon to remain alive" >&2
  exit 1
fi

stats_json="$("$beam_script" --root "$tmp1" stats)"
assert_json_field_equals "owned stats response" "$stats_json" ok true
status_json="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals "running session status response" "$status_json" ok true
assert_json_field_equals "running session status state" "$status_json" result.state running
assert_json_field_equals "running session status generation" "$status_json" result.generation "$daemon1_id"
assert_json_field_equals "running session status workspace" "$status_json" result.workspace "$resolved_tmp1"
assert_json_field_equals \
  "running session status directory" "$status_json" result.sessionDir "$resolved_tmp1/.beam"

python3 - "$registry" "$tmp1" <<'PY'
import json
import os
import sys

registry, root = sys.argv[1:]
with open(registry, encoding="utf-8") as stream:
    entry = json.load(stream)
if entry.get("schemaVersion") != 4:
    raise SystemExit(f"unexpected session schema: {entry.get('schemaVersion')}")
workspace = entry.get("workspace")
if not isinstance(workspace, dict):
    raise SystemExit(f"unexpected workspace binding: {workspace!r}")
if workspace.get("root") != os.path.realpath(root):
    raise SystemExit(f"unexpected workspace root: {workspace!r}")
if workspace.get("workspaceId") != "beam-cli-project":
    raise SystemExit(f"unexpected workspace id: {workspace!r}")
PY

control_dir_mode="$(file_mode "$tmp1/.beam")"
registry_mode="$(file_mode "$registry")"
if [ "$control_dir_mode" != "700" ]; then
  echo "expected the capability control directory to use mode 700, got $control_dir_mode" >&2
  exit 1
fi
if [ "$registry_mode" != "600" ]; then
  echo "expected the capability-bearing registry to use mode 600, got $registry_mode" >&2
  exit 1
fi
startup_log_mode="$(file_mode "$tmp1/.beam/beam-daemon-startup.log")"
if [ "$startup_log_mode" != "600" ]; then
  echo "expected the daemon startup log to use mode 600, got $startup_log_mode" >&2
  exit 1
fi

cross_root_descriptor="$tmp2/cross-root-recovery.before"
cp -- "$registry" "$cross_root_descriptor"
if "$beam_script" --root "$tmp2" --session-dir "$tmp1/.beam" status \
    > "$tmp2/cross-root-status.out" 2> "$tmp2/cross-root-status.err"; then
  echo "expected status through a mismatched session selector to fail" >&2
  exit 1
fi
if ! grep -Fq "sessionSelectorMismatch" "$tmp2/cross-root-status.err" || \
    ! grep -Fq -- "--root '$resolved_tmp1' --session-dir '$resolved_tmp1/.beam' status" \
      "$tmp2/cross-root-status.err"; then
  echo "expected cross-root status rejection to identify the selector mismatch and exact selector" >&2
  cat "$tmp2/cross-root-status.err" >&2
  exit 1
fi
if ! cmp -s -- "$cross_root_descriptor" "$registry"; then
  echo "cross-root status must preserve the descriptor byte-for-byte" >&2
  exit 1
fi
if "$beam_script" --root "$tmp2" --session-dir "$tmp1/.beam" \
    recover --generation "$daemon1_id" \
    > "$tmp2/cross-root-recovery.out" 2> "$tmp2/cross-root-recovery.err"; then
  echo "expected recovery through a non-member root to fail closed" >&2
  exit 1
fi
if ! grep -Fq "is not the workspace in session $daemon1_id" \
    "$tmp2/cross-root-recovery.err" || \
    ! grep -Fq "$tmp1" "$tmp2/cross-root-recovery.err"; then
  echo "expected cross-root recovery rejection to name the session and its recorded root" >&2
  cat "$tmp2/cross-root-recovery.err" >&2
  exit 1
fi
if ! cmp -s -- "$cross_root_descriptor" "$registry"; then
  echo "cross-root recovery must preserve the descriptor byte-for-byte" >&2
  exit 1
fi
cross_root_stats_json="$("$beam_script" --root "$tmp1" stats)"
assert_json_field_equals "stats after rejected cross-root recovery" "$cross_root_stats_json" ok true
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "cross-root recovery rejection must preserve the live owner and daemon" >&2
  exit 1
fi

if "$beam_script" --root "$tmp1" recover --generation "$daemon1_id" \
    > "$tmp1/live-recover.out" 2> "$tmp1/live-recover.err"; then
  echo "expected explicit recovery to refuse a responding generation" >&2
  exit 1
fi
if ! grep -Fq "still responds" "$tmp1/live-recover.err"; then
  echo "expected live-generation recovery refusal to explain the active endpoint" >&2
  cat "$tmp1/live-recover.err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon1_id" ] || \
    ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "live-generation recovery refusal must preserve the owner and descriptor" >&2
  exit 1
fi

if BEAM_SESSION_ROOT=relative-control-root \
    "$beam_script" --root "$tmp1" stats \
    > "$tmp1/relative-control-root.out" 2> "$tmp1/relative-control-root.err"; then
  echo "expected relative BEAM_SESSION_ROOT to be rejected" >&2
  exit 1
fi
if ! grep -Fq "BEAM_SESSION_ROOT must be an absolute path" \
    "$tmp1/relative-control-root.err"; then
  echo "expected relative BEAM_SESSION_ROOT rejection to explain the stable-path requirement" >&2
  cat "$tmp1/relative-control-root.err" >&2
  exit 1
fi

environment_session_base="$tmp2/environment-session-base"
environment_session_alias="$tmp2/environment-session-alias"
mkdir -p "$environment_session_base"
ln -s "$environment_session_base" "$environment_session_alias"
environment_status="$(BEAM_SESSION_ROOT="$environment_session_alias" \
  "$beam_script" --root "$tmp1" status)"
environment_session_dir="$(json_text_field "$environment_status" result.sessionDir)"
case "$environment_session_dir" in
  "$(beam_test_realpath "$environment_session_base")"/*) ;;
  *)
    echo "expected BEAM_SESSION_ROOT to publish a canonical derived session selector" >&2
    printf '%s\n' "$environment_status" >&2
    exit 1
    ;;
esac
rm -f -- "$environment_session_alias"
rmdir "$environment_session_base"

port1="$(read_json_field "$registry" port)"
python3 - "$port1" <<'PY'
import json
import socket
import sys
import time

port = int(sys.argv[1])

def receive_frame(sock):
    header = bytearray()
    while not header.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("daemon closed before returning a framed error")
        header.extend(chunk)
    size = int(header[:-1])
    payload = bytearray()
    while len(payload) < size:
        chunk = sock.recv(size - len(payload))
        if not chunk:
            raise RuntimeError("daemon closed during its framed error")
        payload.extend(chunk)
    return json.loads(payload)

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    hello = receive_frame(sock)
    if hello.get("schemaVersion") != 1:
        raise RuntimeError(f"unexpected daemon greeting: {hello}")
    request = json.dumps({
        "op": "shutdown",
        "daemonCapability": "not-the-owner-capability",
    }).encode()
    sock.sendall(str(len(request)).encode() + b"\n" + request)
    response = receive_frame(sock)
    payload = response.get("payload", {})
    if payload.get("ok") is not False:
        raise RuntimeError(f"unauthorized shutdown unexpectedly succeeded: {response}")
    message = payload.get("error", {}).get("message", "")
    if "invalid Beam daemon capability" not in message:
        raise RuntimeError(f"unexpected unauthorized-shutdown response: {response}")

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    receive_frame(sock)
    sock.sendall(b"16777217\n")
    response = receive_frame(sock)
    if "exceeds 16777216 bytes" not in response.get("payload", {}).get("error", {}).get("message", ""):
        raise RuntimeError(f"unexpected oversized-frame response: {response}")

with socket.create_connection(("127.0.0.1", port), timeout=3) as sock:
    receive_frame(sock)
    time.sleep(5.5)
    response = receive_frame(sock)
    if "initial request timed out" not in response.get("payload", {}).get("error", {}).get("message", ""):
        raise RuntimeError(f"unexpected first-message-timeout response: {response}")
PY

stats_after_security_probes_json="$("$beam_script" --root "$tmp1" stats)"
assert_json_field_equals \
  "stats after unauthorized shutdown and transport limit probes" \
  "$stats_after_security_probes_json" ok true
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "expected unauthorized shutdown to preserve both owner and daemon" >&2
  exit 1
fi

second_owner_out="$tmp1/second-owner.out"
second_owner_err="$tmp1/second-owner.err"
if "$beam_script" --root "$tmp1" serve > "$second_owner_out" 2> "$second_owner_err"; then
  echo "expected a second foreground owner to be rejected" >&2
  cat "$second_owner_out" >&2
  exit 1
fi
if ! grep -Fq "already owned" "$second_owner_err"; then
  echo "expected duplicate-owner failure to identify the active owner" >&2
  cat "$second_owner_err" >&2
  exit 1
fi

stale_registry="$tmp2/.beam/beam-daemon.json"
REGISTRY_TEMPLATE="$registry" STALE_REGISTRY="$stale_registry" STALE_ROOT="$tmp2" python3 - <<'PY'
import json
import os

with open(os.environ["REGISTRY_TEMPLATE"], encoding="utf-8") as stream:
    entry = json.load(stream)
entry["workspace"]["root"] = os.path.realpath(os.environ["STALE_ROOT"])
replacement = os.environ["STALE_REGISTRY"] + ".replacement"
with open(replacement, "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(replacement, os.environ["STALE_REGISTRY"])
PY
stale_shutdown_out="$tmp2/stale-cross-root-shutdown.out"
stale_shutdown_err="$tmp2/stale-cross-root-shutdown.err"
if "$beam_script" --root "$tmp2" stop \
    > "$stale_shutdown_out" 2> "$stale_shutdown_err"; then
  echo "expected shutdown to reject a registry whose endpoint serves another root" >&2
  cat "$stale_shutdown_out" >&2
  exit 1
fi
if ! grep -Fq "serves another root" "$stale_shutdown_err"; then
  echo "expected cross-root registry rejection to explain the identity mismatch" >&2
  cat "$stale_shutdown_err" >&2
  exit 1
fi
if [ ! -e "$stale_registry" ]; then
  echo "cross-root registry rejection must preserve the unsafe registry as recovery evidence" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "cross-root registry rejection must not stop the daemon or owner serving the other root" >&2
  exit 1
fi
stale_recovery_before="$(cat "$stale_registry")"
if "$beam_script" --root "$tmp2" recover --generation "$daemon1_id" \
    > "$tmp2/authenticated-mismatch-recovery.out" \
    2> "$tmp2/authenticated-mismatch-recovery.err"; then
  echo "expected recovery to refuse an authenticated endpoint serving another root" >&2
  exit 1
fi
if ! grep -Fq "authenticated endpoint that serves another root" \
    "$tmp2/authenticated-mismatch-recovery.err"; then
  echo "expected authenticated endpoint mismatch recovery to explain the preserved authority" >&2
  cat "$tmp2/authenticated-mismatch-recovery.err" >&2
  exit 1
fi
if [ "$(cat "$stale_registry")" != "$stale_recovery_before" ] || \
    ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "authenticated endpoint mismatch recovery must preserve the descriptor and live session" >&2
  exit 1
fi
rm -f -- "$stale_registry"

LEGACY_REGISTRY="$stale_registry" LEGACY_ROOT="$tmp2" python3 - <<'PY'
import json
import os

entry = {
    "daemonId": "legacy-generation",
    "pid": 999999999,
    "ownerPid": 999999999,
    "port": 42424,
    "root": os.path.realpath(os.environ["LEGACY_ROOT"]),
    "configHash": "legacy-config",
    "startedAt": "2026-08-27T00:00:00Z",
}
with open(os.environ["LEGACY_REGISTRY"], "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
PY
legacy_before="$(cat "$stale_registry")"
legacy_owner_out="$tmp2/legacy-owner.out"
legacy_owner_err="$tmp2/legacy-owner.err"
if "$beam_script" --root "$tmp2" serve \
    > "$legacy_owner_out" 2> "$legacy_owner_err"; then
  echo "expected owner startup to reject a schema-less session descriptor" >&2
  cat "$legacy_owner_out" >&2
  exit 1
fi
if ! grep -Fq "session descriptor has no schemaVersion" "$legacy_owner_err"; then
  echo "expected schema-less descriptor rejection to explain the missing schema" >&2
  cat "$legacy_owner_err" >&2
  exit 1
fi
if [ "$(cat "$stale_registry")" != "$legacy_before" ]; then
  echo "schema-less descriptor rejection must preserve the recovery evidence" >&2
  cat "$stale_registry" >&2
  exit 1
fi
legacy_recover_json="$("$beam_script" --root "$tmp2" recover --force)"
assert_json_field_equals "opaque registry recovery response" "$legacy_recover_json" ok true
assert_json_field_equals "opaque registry recovery state" "$legacy_recover_json" result.state absent
assert_json_field_equals "opaque registry recovery change" "$legacy_recover_json" result.changed true
if [ -e "$stale_registry" ]; then
  echo "expected explicit opaque recovery to quarantine the legacy descriptor" >&2
  exit 1
fi
legacy_quarantine="$(json_text_field "$legacy_recover_json" result.quarantinedPath)"
if [ ! -f "$legacy_quarantine" ]; then
  echo "expected opaque recovery to preserve quarantined evidence" >&2
  printf '%s\n' "$legacy_recover_json" >&2
  exit 1
fi

# Once stop commits its draining fence, a delivery failure must remain a successful, typed
# transition result rather than obscuring the state change. This fixture answers the identity
# probe, then drops the separate shutdown connection.
busy_port_file="$(mktemp "$tmp2/drop-shutdown-port-XXXXXX")"
python3 - "$busy_port_file" "$resolved_tmp2" <<'PY' &
import json
import socketserver
import sys

port_file, root = sys.argv[1:]
daemon_id = "delivery-failure-generation"
config_hash = "delivery-failure-config"

def receive_frame(sock):
    header = bytearray()
    while not header.endswith(b"\n"):
        chunk = sock.recv(1)
        if not chunk:
            raise RuntimeError("client closed before sending a frame header")
        header.extend(chunk)
    size = int(header[:-1])
    payload = bytearray()
    while len(payload) < size:
        chunk = sock.recv(size - len(payload))
        if not chunk:
            raise RuntimeError("client closed during its frame")
        payload.extend(chunk)
    return json.loads(payload)

def send_frame(sock, payload):
    encoded = json.dumps(payload, separators=(",", ":")).encode()
    sock.sendall(str(len(encoded)).encode() + b"\n" + encoded)

class Server(socketserver.TCPServer):
    allow_reuse_address = True

with Server(("127.0.0.1", 0), socketserver.BaseRequestHandler) as server:
    with open(port_file, "w", encoding="utf-8") as stream:
        print(server.server_address[1], file=stream, flush=True)
    conn, _ = server.get_request()
    with conn:
        send_frame(conn, {
            "schemaVersion": 1,
            "identity": {"daemonId": daemon_id, "configHash": config_hash},
        })
        request = receive_frame(conn)
        if request.get("op") != "stats":
            raise RuntimeError(f"expected stats probe, got {request!r}")
        send_frame(conn, {
            "kind": "response",
            "payload": {
                "ok": True,
                "result": {
                    "root": root,
                    "daemonIdentity": {
                        "daemonId": daemon_id,
                        "configHash": config_hash,
                    },
                },
            },
        })
    conn, _ = server.get_request()
    with conn:
        send_frame(conn, {
            "schemaVersion": 1,
            "identity": {"daemonId": daemon_id, "configHash": config_hash},
        })
        receive_frame(conn)
        # Deliberately close without a response after the caller has committed `draining`.
PY
busy_pid="$!"
if ! wait_for_nonempty_file "$busy_port_file" "shutdown-delivery fixture"; then
  exit 1
fi
busy_port="$(cat "$busy_port_file")"
DELIVERY_REGISTRY="$stale_registry" DELIVERY_ROOT="$resolved_tmp2" \
    DELIVERY_PORT="$busy_port" python3 - <<'PY'
import json
import os

entry = {
    "schemaVersion": 4,
    "lifecycle": "live",
    "daemonId": "delivery-failure-generation",
    "capability": "delivery-failure-capability",
    "pid": 999999999,
    "ownerPid": 999999999,
    "port": int(os.environ["DELIVERY_PORT"]),
    "workspace": {
        "workspaceId": "beam-cli-project",
        "root": os.environ["DELIVERY_ROOT"],
        "rocqCmd": "coq-lsp",
        "bundleId": "delivery-fixture",
    },
    "configHash": "delivery-failure-config",
    "daemonBin": "/fixture/beam-daemon",
    "startedAt": "2026-08-30T00:00:00Z",
}
with open(os.environ["DELIVERY_REGISTRY"], "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
PY
delivery_stop_json="$("$beam_script" --root "$tmp2" stop)"
assert_json_field_equals "committed delivery-failure stop response" "$delivery_stop_json" ok true
assert_json_field_equals \
  "committed delivery-failure stop state" "$delivery_stop_json" result.state stopping
assert_json_field_equals \
  "committed delivery-failure stop change" "$delivery_stop_json" result.changed true
assert_json_field_equals \
  "committed delivery-failure stop warning" "$delivery_stop_json" \
  result.warning.code shutdownDeliveryFailed
if [ "$(read_json_field "$stale_registry" lifecycle)" != "draining" ]; then
  echo "expected shutdown delivery failure to preserve the committed draining fence" >&2
  cat "$stale_registry" >&2
  exit 1
fi
wait "$busy_pid"
busy_pid=""
rm -f -- "$busy_port_file"
busy_port_file=""
delivery_recover_json="$(
  "$beam_script" --root "$tmp2" recover --generation delivery-failure-generation
)"
assert_json_field_equals \
  "delivery-failure fence recovery" "$delivery_recover_json" result.changed true

start_slow_request "$tmp1" "shutdown-active" "shutdown-active"

# The desired owner configuration includes installed bundle paths. An ordinary attaching command
# must use the descriptor's frozen configuration without rebuilding a local desired hash. A second
# owner still computes its proposed configuration and reports the mismatch without disturbing the
# running generation.
drift_bundle_dir="$tmp2/config-drift-bundles"
mkdir -p "$drift_bundle_dir"
rsync -a "$BEAM_INSTALL_BUNDLE_DIR/" "$drift_bundle_dir/"
drift_out="$tmp1/config-drift.out"
drift_err="$tmp1/config-drift.err"
if ! BEAM_INSTALL_BUNDLE_DIR="$drift_bundle_dir" \
    "$beam_script" --root "$tmp1" stats > "$drift_out" 2> "$drift_err"; then
  echo "expected ordinary attachment to use the owner's frozen configuration" >&2
  cat "$drift_err" >&2
  exit 1
fi
assert_json_file_field_equals \
  "frozen-configuration attachment" "$drift_out" ok true "$drift_err"
drift_owner_out="$tmp1/config-drift-owner.out"
drift_owner_err="$tmp1/config-drift-owner.err"
if BEAM_INSTALL_BUNDLE_DIR="$drift_bundle_dir" \
    "$beam_script" --root "$tmp1" serve \
      > "$drift_owner_out" 2> "$drift_owner_err"; then
  echo "expected a mismatched replacement owner to be rejected" >&2
  cat "$drift_owner_out" >&2
  exit 1
fi
if ! grep -Fq "current owner was preserved" "$drift_owner_err"; then
  echo "expected replacement-owner drift diagnostics to preserve the current owner" >&2
  cat "$drift_owner_err" >&2
  exit 1
fi
if [ -s "$drift_err" ]; then
  echo "ordinary frozen-configuration attachment produced unexpected diagnostics" >&2
  cat "$drift_out" >&2
  cat "$drift_err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon1_id" ] || \
    [ "$(read_json_field "$registry" pid)" != "$daemon1_pid" ]; then
  echo "configuration-drift lookup changed the live daemon generation" >&2
  cat "$registry" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null || \
    ! kill -0 "$active_request_pid" 2>/dev/null; then
  echo "configuration-drift lookup terminated the owner, daemon, or active request" >&2
  exit 1
fi

if (
  cd "$tmp1"
  "$beam_script" stop > "$tmp1/implicit-stop.out" 2> "$tmp1/implicit-stop.err"
); then
  echo "expected stop to require an explicit root" >&2
  exit 1
fi
if ! grep -Fq "stop requires an explicit --root PATH" "$tmp1/implicit-stop.err"; then
  echo "expected implicit stop rejection to explain the explicit selector" >&2
  cat "$tmp1/implicit-stop.err" >&2
  exit 1
fi
if ! kill -0 "$owner1_pid" 2>/dev/null || ! kill -0 "$daemon1_pid" 2>/dev/null; then
  echo "implicit stop rejection must preserve the running session" >&2
  exit 1
fi

stop_json="$("$beam_script" --root "$tmp1" stop)"
assert_json_field_equals "explicit session stop" "$stop_json" ok true
assert_json_field_equals "explicit session stop state" "$stop_json" result.state stopping
assert_json_field_equals "explicit session stop changed" "$stop_json" result.changed true
expect_slow_request_cancelled "$tmp1" "shutdown-active" "shutdown-active"
if ! wait_for_exit "$hold_pid" "owner after explicit shutdown" 200 0.05; then
  cat "$tmp1/owner-1.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
owner_status="$?"
set -e
hold_pid=""
if [ "$owner_status" -ne 0 ]; then
  echo "expected owner to exit cleanly after explicit shutdown, got $owner_status" >&2
  cat "$tmp1/owner-1.err" >&2
  exit 1
fi
if ! wait_for_exit "$daemon1_pid" "daemon after explicit session shutdown" 200 0.05; then
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected owner shutdown to remove its registry" >&2
  cat "$registry" >&2
  exit 1
fi
stopped_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals "stopped session status state" "$stopped_status" result.state absent

start_owner "$tmp1" "owner-2"
daemon2_pid="$(read_json_field "$registry" pid)"
daemon2_id="$(read_json_field "$registry" daemonId)"
if [ "$daemon2_id" = "$daemon1_id" ]; then
  echo "expected a new owner to publish a new daemon generation" >&2
  exit 1
fi

kill -KILL "$daemon2_pid"
if ! wait_for_exit "$hold_pid" "owner after unexpected daemon crash" 200 0.05; then
  cat "$tmp1/owner-2.err" >&2
  exit 1
fi
set +e
wait "$hold_pid"
crashed_owner_status="$?"
set -e
hold_pid=""
if [ "$crashed_owner_status" -eq 0 ]; then
  echo "expected the owner to report an unexpected daemon crash" >&2
  exit 1
fi
if ! grep -Fq "owned Beam daemon exited with status" "$tmp1/owner-2.err"; then
  echo "expected the owner crash report to include the daemon exit status" >&2
  cat "$tmp1/owner-2.err" >&2
  exit 1
fi
if [ ! -e "$registry" ]; then
  echo "expected an unexpected daemon crash to preserve its exact session fence" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$daemon2_id" ] || \
    [ "$(read_json_field "$registry" lifecycle)" != "live" ]; then
  echo "expected an unexpected daemon crash to preserve its live generation fence" >&2
  cat "$registry" >&2
  exit 1
fi
crash_status_json="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals \
  "unexpected-crash session status" "$crash_status_json" result.state recoveryRequired
assert_json_field_equals \
  "unexpected-crash session generation" "$crash_status_json" result.generation "$daemon2_id"
if "$beam_script" --root "$tmp1" serve \
    > "$tmp1/crash-replacement.out" 2> "$tmp1/crash-replacement.err"; then
  echo "expected crash-fenced state to reject a replacement owner" >&2
  exit 1
fi
crash_recovery_json="$("$beam_script" --root "$tmp1" recover --generation "$daemon2_id")"
assert_json_field_equals "unexpected-crash recovery response" "$crash_recovery_json" ok true
assert_json_field_equals "unexpected-crash recovery state" "$crash_recovery_json" result.state absent
assert_json_field_equals "unexpected-crash recovery change" "$crash_recovery_json" result.changed true
if [ -e "$registry" ]; then
  echo "expected exact-generation crash recovery to quarantine the fence" >&2
  exit 1
fi

# If the daemon exits abnormally after drain begins, leader exit is not proof of successful cleanup.
# Restore the exact generation to a conservative recovery-required fence instead of admitting a
# replacement owner.
start_owner "$tmp1" "owner-failed-drain"
failed_drain_daemon_pid="$(read_json_field "$registry" pid)"
failed_drain_daemon_id="$(read_json_field "$registry" daemonId)"
kill -STOP "$failed_drain_daemon_pid"
paused_daemon_pid="$failed_drain_daemon_pid"
kill -INT "$hold_pid"
for _ in $(seq 1 40); do
  if [ -e "$registry" ] && [ "$(read_json_field "$registry" lifecycle)" = "draining" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -e "$registry" ] || [ "$(read_json_field "$registry" lifecycle)" != "draining" ]; then
  echo "expected interrupted owner to publish the failed-drain fence before cleanup" >&2
  cat "$registry" >&2
  exit 1
fi
kill -KILL "$failed_drain_daemon_pid"
paused_daemon_pid=""
if ! wait_for_exit "$hold_pid" "owner after abnormal exit during drain" 80 0.05; then
  cat "$tmp1/owner-failed-drain.err" >&2
  exit 1
fi
wait "$hold_pid"
hold_pid=""
if ! wait_for_exit "$failed_drain_daemon_pid" "daemon after abnormal exit during drain" 40 0.05; then
  exit 1
fi
if [ ! -e "$registry" ] || \
    [ "$(read_json_field "$registry" daemonId)" != "$failed_drain_daemon_id" ] || \
    [ "$(read_json_field "$registry" lifecycle)" != "live" ]; then
  echo "expected abnormal drain exit to preserve the exact recovery fence" >&2
  if [ -e "$registry" ]; then cat "$registry" >&2; fi
  exit 1
fi
failed_drain_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals \
  "failed-drain session status" "$failed_drain_status" result.state recoveryRequired
assert_json_field_equals \
  "failed-drain session generation" "$failed_drain_status" \
  result.generation "$failed_drain_daemon_id"
if "$beam_script" --root "$tmp1" serve \
    > "$tmp1/failed-drain-replacement.out" 2> "$tmp1/failed-drain-replacement.err"; then
  echo "expected failed-drain recovery fence to reject a replacement owner" >&2
  exit 1
fi
failed_drain_recovery="$(
  "$beam_script" --root "$tmp1" recover --generation "$failed_drain_daemon_id"
)"
assert_json_field_equals \
  "failed-drain recovery" "$failed_drain_recovery" result.changed true

start_owner "$tmp1" "owner-draining-fence"
draining_daemon_pid="$(read_json_field "$registry" pid)"
draining_daemon_id="$(read_json_field "$registry" daemonId)"
start_slow_request "$tmp1" "draining-process-tree" "draining-process-tree"
draining_backend_pids="$(pgrep -P "$draining_daemon_pid" || true)"
if [ -z "$draining_backend_pids" ]; then
  echo "expected the active request to create a daemon-owned backend process" >&2
  exit 1
fi
kill -STOP "$draining_daemon_pid"
paused_daemon_pid="$draining_daemon_pid"
kill -INT "$hold_pid"
for _ in $(seq 1 40); do
  if [ -e "$registry" ] && [ "$(read_json_field "$registry" lifecycle)" = "draining" ]; then
    break
  fi
  sleep 0.05
done
if [ ! -e "$registry" ] || [ "$(read_json_field "$registry" lifecycle)" != "draining" ]; then
  echo "expected an interrupted owner to retain a draining generation fence" >&2
  cat "$registry" >&2
  exit 1
fi
if ! kill -0 "$hold_pid" 2>/dev/null || ! kill -0 "$draining_daemon_pid" 2>/dev/null; then
  echo "expected the paused daemon and its owner to remain alive during the drain check" >&2
  exit 1
fi
draining_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals "draining session status" "$draining_status" result.state stopping
assert_json_field_equals \
  "draining session status generation" "$draining_status" result.generation "$draining_daemon_id"
repeated_stop_json="$("$beam_script" --root "$tmp1" stop)"
assert_json_field_equals "repeated session stop response" "$repeated_stop_json" ok true
assert_json_field_equals "repeated session stop state" "$repeated_stop_json" result.state stopping
assert_json_field_equals "repeated session stop changed" "$repeated_stop_json" result.changed false
draining_lookup_out="$tmp1/draining-lookup.out"
draining_lookup_err="$tmp1/draining-lookup.err"
if "$beam_script" --root "$tmp1" stats > "$draining_lookup_out" 2> "$draining_lookup_err"; then
  echo "expected an ordinary command not to attach to a draining generation" >&2
  cat "$draining_lookup_out" >&2
  exit 1
fi
if ! grep -Fq "is draining" "$draining_lookup_err"; then
  echo "expected ordinary commands to report the draining generation" >&2
  cat "$draining_lookup_err" >&2
  exit 1
fi
replacement_owner_out="$tmp1/replacement-during-drain.out"
replacement_owner_err="$tmp1/replacement-during-drain.err"
if "$beam_script" --root "$tmp1" serve \
    > "$replacement_owner_out" 2> "$replacement_owner_err"; then
  echo "expected a draining generation to fence out a replacement owner" >&2
  cat "$replacement_owner_out" >&2
  exit 1
fi
if ! grep -Fq "is draining" "$replacement_owner_err"; then
  echo "expected replacement-owner rejection to identify the draining generation" >&2
  cat "$replacement_owner_err" >&2
  exit 1
fi
if [ "$(read_json_field "$registry" daemonId)" != "$draining_daemon_id" ] || \
    [ "$(read_json_field "$registry" pid)" != "$draining_daemon_pid" ]; then
  echo "replacement attempt changed the draining generation fence" >&2
  cat "$registry" >&2
  exit 1
fi
if ! wait_for_exit "$hold_pid" "owner after forced draining-fence cleanup" 300 0.05; then
  cat "$tmp1/owner-draining-fence.err" >&2
  exit 1
fi
wait "$hold_pid"
hold_pid=""
paused_daemon_pid=""
if ! wait_for_exit "$draining_daemon_pid" "daemon after forced draining-fence cleanup" 40 0.05; then
  exit 1
fi
for backend_pid in $draining_backend_pids; do
  if ! wait_for_exit "$backend_pid" "backend after forced draining-fence cleanup" 40 0.05; then
    echo "forced owner cleanup left backend pid $backend_pid alive" >&2
    exit 1
  fi
done
set +e
wait "$active_request_pid"
draining_request_status="$?"
set -e
active_request_pid=""
if [ "$draining_request_status" -eq 0 ]; then
  echo "expected the active request to fail when forced drain kills its process group" >&2
  exit 1
fi
if [ -e "$registry" ]; then
  echo "expected the draining fence to disappear only after the daemon was reaped" >&2
  cat "$registry" >&2
  exit 1
fi

start_owner "$tmp1" "owner-3"
daemon3_pid="$(read_json_field "$registry" pid)"
start_slow_request "$tmp1" "owner-loss-active" "owner-loss-active"
kill -KILL "$hold_pid"
set +e
wait "$hold_pid"
set -e
hold_pid=""
if ! wait_for_exit "$daemon3_pid" "daemon after owner death" 200 0.05; then
  echo "expected owner-pipe EOF to stop the daemon" >&2
  exit 1
fi
expect_slow_request_cancelled "$tmp1" "owner-loss-active" "owner-loss-active"
owner_loss_out="$tmp1/owner-loss.out"
owner_loss_err="$tmp1/owner-loss.err"
if "$beam_script" --root "$tmp1" stats > "$owner_loss_out" 2> "$owner_loss_err"; then
  echo "expected a command after owner loss to preserve the abnormal-session fence" >&2
  cat "$owner_loss_out" >&2
  exit 1
fi
owner_loss_generation="$(read_json_field "$registry" daemonId)"
owner_loss_status="$("$beam_script" --root "$tmp1" status)"
assert_json_field_equals \
  "owner-loss session status" "$owner_loss_status" result.state recoveryRequired
assert_json_field_equals \
  "owner-loss session status generation" "$owner_loss_status" result.generation "$owner_loss_generation"
if ! grep -Fq "Beam daemon connect failed" "$owner_loss_err"; then
  echo "expected the ordinary call itself to report the unavailable endpoint" >&2
  cat "$owner_loss_err" >&2
  exit 1
fi
if [ ! -e "$registry" ]; then
  echo "ordinary owner-loss lookup must not mutate the stale registry" >&2
  exit 1
fi
if "$beam_script" --root "$tmp1" recover --generation wrong-generation \
    > "$tmp1/recover-wrong.out" 2> "$tmp1/recover-wrong.err"; then
  echo "expected recovery with the wrong generation to fail closed" >&2
  exit 1
fi
if [ ! -e "$registry" ]; then
  echo "wrong-generation recovery must preserve the session fence" >&2
  exit 1
fi
recover_json="$("$beam_script" --root "$tmp1" recover --generation "$owner_loss_generation")"
assert_json_field_equals "exact-generation recovery response" "$recover_json" ok true
assert_json_field_equals "exact-generation recovery state" "$recover_json" result.state absent
assert_json_field_equals "exact-generation recovery change" "$recover_json" result.changed true
if [ -e "$registry" ]; then
  echo "expected explicit recovery to quarantine the stale session descriptor" >&2
  exit 1
fi
quarantined_registry="$(json_text_field "$recover_json" result.quarantinedPath)"
if [ ! -f "$quarantined_registry" ]; then
  echo "expected explicit recovery to preserve quarantined evidence" >&2
  printf '%s\n' "$recover_json" >&2
  exit 1
fi

explicit_control="$tmp2/shared-control"
nonprivate_control="$tmp2/nonprivate-control"
explicit_symlink="$tmp2/session-link"
ln -s "$tmp2/.beam" "$explicit_symlink"
if "$beam_script" --root "$tmp2" --session-dir "$explicit_symlink" stats \
    > "$tmp2/symlink-session.out" 2> "$tmp2/symlink-session.err"; then
  echo "expected an explicit symbolic-link session directory to be rejected" >&2
  exit 1
fi
if ! grep -Fq "does not accept a symbolic-link leaf" "$tmp2/symlink-session.err"; then
  echo "expected explicit session-directory rejection to name the symbolic-link boundary" >&2
  cat "$tmp2/symlink-session.err" >&2
  exit 1
fi
rm -f -- "$explicit_symlink"
mkdir -p "$nonprivate_control"
chmod 755 "$nonprivate_control"
nonprivate_mode_before="$(file_mode "$nonprivate_control")"
if "$beam_script" --root "$tmp2" --session-dir "$nonprivate_control" recover --force \
    > "$tmp2/nonprivate-control.out" 2> "$tmp2/nonprivate-control.err"; then
  echo "expected an existing non-private control directory to be rejected" >&2
  exit 1
fi
if "$beam_script" --root "$tmp2" --session-dir "$nonprivate_control" stats \
    > "$tmp2/nonprivate-observation.out" 2> "$tmp2/nonprivate-observation.err"; then
  echo "expected ordinary attachment to reject a non-private session directory" >&2
  exit 1
fi
if ! grep -Fq "existing mode is 0755, expected 0700" "$tmp2/nonprivate-observation.err"; then
  echo "expected ordinary attachment to apply the session-directory security boundary" >&2
  cat "$tmp2/nonprivate-observation.err" >&2
  exit 1
fi
if ! grep -Fq "existing mode is 0755, expected 0700" "$tmp2/nonprivate-control.err"; then
  echo "expected non-private control rejection to explain the required mode" >&2
  cat "$tmp2/nonprivate-control.err" >&2
  exit 1
fi
if [ "$(file_mode "$nonprivate_control")" != "$nonprivate_mode_before" ]; then
  echo "non-private control rejection changed the existing directory mode" >&2
  exit 1
fi
if find "$nonprivate_control" -mindepth 1 -print -quit | grep -q .; then
  echo "non-private control rejection created files in the existing directory" >&2
  find "$nonprivate_control" -mindepth 1 -maxdepth 2 -print >&2
  exit 1
fi

# An absent exact control leaf is safe to create and privatize before descriptor publication.
"$beam_script" --root "$tmp2" --session-dir "$explicit_control" serve \
  > "$tmp2/explicit-control-owner.out" 2> "$tmp2/explicit-control-owner.err" &
hold_pid="$!"
explicit_registry="$explicit_control/beam-daemon.json"
if ! wait_for_nonempty_file "$explicit_registry" "explicit control-directory session descriptor"; then
  cat "$tmp2/explicit-control-owner.err" >&2
  exit 1
fi
explicit_stats="$("$beam_script" --root "$tmp2" --session-dir "$explicit_control" stats)"
assert_json_field_equals "explicit control-directory attachment" "$explicit_stats" ok true
if [ "$(file_mode "$explicit_control")" != "700" ] || \
    [ "$(file_mode "$explicit_registry")" != "600" ]; then
  echo "expected a newly created explicit control directory and descriptor to use modes 700/600" >&2
  exit 1
fi
chmod 755 "$explicit_control"
if "$beam_script" --root "$tmp2" --session-dir "$explicit_control" stats \
    > "$tmp2/changed-mode.out" 2> "$tmp2/changed-mode.err"; then
  chmod 700 "$explicit_control"
  echo "expected attachment to reject session-directory permission drift" >&2
  exit 1
fi
chmod 700 "$explicit_control"
if ! grep -Fq "existing mode is 0755, expected 0700" "$tmp2/changed-mode.err"; then
  echo "expected permission-drift rejection to explain the session-directory boundary" >&2
  cat "$tmp2/changed-mode.err" >&2
  exit 1
fi
explicit_stop_command="lean-beam --root '$resolved_tmp2' --session-dir '$(beam_test_realpath "$explicit_control")' stop"
if ! grep -Fq "$explicit_stop_command" "$tmp2/explicit-control-owner.err"; then
  echo "expected the foreground owner to print its exact stop command" >&2
  cat "$tmp2/explicit-control-owner.err" >&2
  exit 1
fi
if "$beam_script" --root "$tmp2" stats \
    > "$tmp2/default-control-stats.out" 2> "$tmp2/default-control-stats.err"; then
  echo "expected the default and explicit control selections to remain distinct" >&2
  exit 1
fi
if [ -e "$tmp2/.beam/beam-daemon.json" ]; then
  echo "explicit control-directory ownership must not publish a project-local descriptor" >&2
  exit 1
fi
if [ ! -f "$explicit_control/beam-daemon-startup.log" ]; then
  echo "expected explicit control-directory startup diagnostics beside the descriptor" >&2
  exit 1
fi
stop_hold_process true "$explicit_registry" "$tmp2/explicit-control-owner.err"
if [ -e "$explicit_registry" ]; then
  echo "expected normal explicit-control teardown to remove its descriptor" >&2
  exit 1
fi

generation_registry="$tmp2/.beam/beam-daemon.json"
start_owner "$tmp2" "owner-generation"
generation_daemon_pid="$(read_json_field "$generation_registry" pid)"
generation_id="$(read_json_field "$generation_registry" daemonId)"
replacement_generation_id="$generation_id-replacement"
replacement_generation_capability="replacement-generation-capability"
python3 - "$generation_registry" "$replacement_generation_id" \
    "$replacement_generation_capability" <<'PY'
import json
import os
import sys

path, replacement_id, replacement_capability = sys.argv[1:]
with open(path, "r", encoding="utf-8") as stream:
    entry = json.load(stream)
entry["daemonId"] = replacement_id
entry["capability"] = replacement_capability
replacement = path + ".replacement"
with open(replacement, "w", encoding="utf-8") as stream:
    json.dump(entry, stream, separators=(",", ":"))
    stream.write("\n")
os.replace(replacement, path)
PY
if ! wait_for_exit "$hold_pid" "owner after generation replacement" 200 0.05; then
  cat "$tmp2/owner-generation.err" >&2
  exit 1
fi
wait "$hold_pid"
hold_pid=""
if ! wait_for_exit "$generation_daemon_pid" "daemon after generation replacement" 200 0.05; then
  exit 1
fi
if [ "$(read_json_field "$generation_registry" daemonId)" != "$replacement_generation_id" ]; then
  echo "expected old-owner cleanup to preserve the replacement registry generation" >&2
  cat "$generation_registry" >&2
  exit 1
fi
if [ "$(read_json_field "$generation_registry" capability)" != \
    "$replacement_generation_capability" ]; then
  echo "expected old-owner cleanup to preserve the replacement capability" >&2
  cat "$generation_registry" >&2
  exit 1
fi
rm -f -- "$generation_registry"

start_owner "$tmp1" "owner-4"
daemon4_pid="$(read_json_field "$registry" pid)"
remove_owned_tmp_tree "$tmp1"
root_removed="true"
if ! wait_for_exit "$daemon4_pid" "daemon whose project root disappeared" 200 0.05; then
  echo "expected root disappearance to stop the owned daemon" >&2
  exit 1
fi
if ! wait_for_exit "$hold_pid" "owner whose project root disappeared" 200 0.05; then
  echo "expected root disappearance to release the foreground owner" >&2
  exit 1
fi
set +e
wait "$hold_pid"
root_owner_status="$?"
set -e
hold_pid=""
if [ "$root_owner_status" -ne 0 ]; then
  echo "expected root-disappearance owner to exit cleanly, got $root_owner_status" >&2
  exit 1
fi
if [ -e "$tmp1" ]; then
  echo "owner cleanup recreated the removed project root" >&2
  exit 1
fi
