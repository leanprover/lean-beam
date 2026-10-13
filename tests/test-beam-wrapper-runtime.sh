#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

primary_root="$(beam_wrapper_prepare_project_root runtime-primary)"
other_root="$(beam_wrapper_prepare_project_root runtime-other)"
signal_root="$(beam_wrapper_prepare_project_root_with_scenario_docs runtime-signal)"

run_sigint_probe() {
  local project_root="$1"
  local snapshot="$2"
  local out_path="$3"
  local err_path="$4"
  local progress_enabled="$5"
  local request_id="$6"
  local wait_mode="$7"
  python3 - "$beam_script" "$project_root" "$snapshot" "$out_path" "$err_path" "$progress_enabled" "$request_id" "$wait_mode" <<'PY'
import os
import signal
import subprocess
import sys
import time

beam_script, project_root, snapshot, out_path, err_path, progress_enabled, request_id, wait_mode = sys.argv[1:]
env = os.environ.copy()
if progress_enabled == "1":
    env["BEAM_PROGRESS"] = "1"
else:
    env.pop("BEAM_PROGRESS", None)
if request_id:
    env["BEAM_REQUEST_ID"] = request_id
else:
    env.pop("BEAM_REQUEST_ID", None)

def wait_for_stderr(needle, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with open(err_path, "r", encoding="utf-8", errors="replace") as err_file:
                if needle in err_file.read():
                    return
        except FileNotFoundError:
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    raise TimeoutError(f"timed out waiting for stderr marker: {needle}")

with open(out_path, "wb") as out, open(err_path, "wb") as err:
    proc = subprocess.Popen(
        [
            beam_script,
            "--root",
            project_root,
            "run-at",
            "tests/scenario/docs/SlowPoll.lean",
            snapshot,
            "25",
            "2",
            "poll_sleep_cmd",
        ],
        stdout=out,
        stderr=err,
        env=env,
    )
    if wait_mode == "stderr":
        wait_for_stderr("running run-at")
    elif wait_mode == "sleep":
        time.sleep(1.0)
    else:
        raise ValueError(f"unknown wait mode: {wait_mode}")

    if proc.poll() is not None:
        rc = "early-exit"
    else:
        proc.send_signal(signal.SIGINT)
        try:
            rc = proc.wait(timeout=30.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            rc = "timeout"

print(rc)
PY
}

expect_sigint_aborted() {
  local label="$1"
  local out_path="$2"
  local err_path="$3"
  local expected_client_request_id="$4"
  if [ -s "$out_path" ]; then
    echo "expected $label not to fabricate a terminal broker response after disconnect" >&2
    cat "$out_path" >&2
    cat "$err_path" >&2
    exit 1
  fi
  if [ -n "$expected_client_request_id" ]; then
    if ! grep -q "beam\[$expected_client_request_id\]" "$err_path"; then
      echo "expected $label to preserve its explicit clientRequestId annotation" >&2
      cat "$err_path" >&2
      exit 1
    fi
  elif grep -q 'beam\[' "$err_path"; then
    echo "expected $label stderr not to include a clientRequestId annotation" >&2
    cat "$err_path" >&2
    exit 1
  fi
  if grep -q 'beam-wrapper-' "$out_path" "$err_path"; then
    echo "expected $label not to leak the generated cancellation id" >&2
    cat "$out_path" >&2
    cat "$err_path" >&2
    exit 1
  fi
  if ! grep -q 'interrupting broker request' "$err_path" ||
      ! grep -q 'Beam request interrupted' "$err_path"; then
    echo "expected $label to report bounded connection-owned interruption" >&2
    cat "$err_path" >&2
    exit 1
  fi
}

beam_wrapper_start_owner "$primary_root"
primary_owner_pid="$beam_wrapper_last_owner_pid"
(
  cd "$primary_root"
  "$beam_script" stats > /dev/null
)

primary_registry="$(beam_wrapper_registry_path "$primary_root")"
beam_wrapper_expect_file "$primary_registry"
pid1="$(read_json_field "$primary_registry" pid)"
port1="$(read_json_field "$primary_registry" port)"

beam_wrapper_start_owner "$signal_root"
signal_owner_pid="$beam_wrapper_last_owner_pid"
(
  cd "$signal_root"
  slow_snapshot="$(beam_wrapper_update_snapshot "signal SlowPoll" "$beam_script" --root "$signal_root" update tests/scenario/docs/SlowPoll.lean)"
  command_snapshot="$(beam_wrapper_update_snapshot "signal CommandA" "$beam_script" --root "$signal_root" update tests/scenario/docs/CommandA.lean)"

  interrupt_out="$(beam_wrapper_mktemp_file interrupt-out)"
  interrupt_err="$(beam_wrapper_mktemp_file interrupt-err)"
  interrupt_status="$(run_sigint_probe "$signal_root" "$slow_snapshot" "$interrupt_out" "$interrupt_err" 1 wrapper-sigint stderr)"
  if [ "$interrupt_status" = "timeout" ] || [ "$interrupt_status" = "early-exit" ]; then
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi
  if [ "$interrupt_status" = "0" ]; then
    echo "expected wrapper run-at SIGINT path to exit non-zero after connection interruption" >&2
    cat "$interrupt_out" >&2
    cat "$interrupt_err" >&2
    exit 1
  fi
  expect_sigint_aborted "wrapper SIGINT path" "$interrupt_out" "$interrupt_err" wrapper-sigint

  interrupt_anon_out="$(beam_wrapper_mktemp_file interrupt-anon-out)"
  interrupt_anon_err="$(beam_wrapper_mktemp_file interrupt-anon-err)"
  interrupt_anon_status="$(run_sigint_probe "$signal_root" "$slow_snapshot" "$interrupt_anon_out" "$interrupt_anon_err" 1 "" stderr)"
  if [ "$interrupt_anon_status" = "timeout" ] || [ "$interrupt_anon_status" = "early-exit" ]; then
    cat "$interrupt_anon_out" >&2
    cat "$interrupt_anon_err" >&2
    exit 1
  fi
  if [ "$interrupt_anon_status" = "0" ]; then
    echo "expected anonymous wrapper run-at SIGINT path to exit non-zero after connection interruption" >&2
    cat "$interrupt_anon_out" >&2
    cat "$interrupt_anon_err" >&2
    exit 1
  fi
  expect_sigint_aborted "anonymous wrapper SIGINT path" "$interrupt_anon_out" "$interrupt_anon_err" ""

  post_interrupt_hover="$("$beam_script" --root "$signal_root" hover tests/scenario/docs/CommandA.lean "$command_snapshot" 0 4)"
  if [ "$(BEAM_JSON_PAYLOAD="$post_interrupt_hover" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper SIGINT interruption to preserve the isolated Beam daemon session" >&2
    printf '%s\n' "$post_interrupt_hover" >&2
    exit 1
  fi

  interrupt_quiet_out="$(beam_wrapper_mktemp_file interrupt-quiet-out)"
  interrupt_quiet_err="$(beam_wrapper_mktemp_file interrupt-quiet-err)"
  interrupt_quiet_status="$(python3 - "$beam_script" "$signal_root" "$slow_snapshot" "$command_snapshot" "$interrupt_quiet_out" "$interrupt_quiet_err" <<'PY'
import os
import signal
import subprocess
import sys
import time

beam_script, project_root, slow_snapshot, command_snapshot, out_path, err_path = sys.argv[1:]
base_request_id = "wrapper-sigint-quiet"
max_attempts = 5
setup_race_count = 0


def read_file(path):
    try:
        with open(path, "rb") as handle:
            return handle.read().decode("utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def append_failure_detail(message, target_text, duplicate_text):
    with open(err_path, "ab") as err_file:
        err_file.write(f"\n{message}\n".encode("utf-8"))
        if target_text:
            err_file.write(b"\nlast target output/stderr:\n")
            err_file.write(target_text.encode("utf-8", errors="replace"))
        if duplicate_text:
            err_file.write(b"\nlast duplicate output/stderr:\n")
            err_file.write(duplicate_text.encode("utf-8", errors="replace"))


def request_id_for_attempt(attempt):
    if attempt == 1:
        return base_request_id
    return f"{base_request_id}-{attempt}"


for attempt in range(1, max_attempts + 1):
    request_id = request_id_for_attempt(attempt)
    env = os.environ.copy()
    env.pop("BEAM_PROGRESS", None)
    env["BEAM_REQUEST_ID"] = request_id
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        proc = subprocess.Popen(
            [
                beam_script,
                "--root",
                project_root,
                "run-at",
                "tests/scenario/docs/SlowPoll.lean",
                slow_snapshot,
                "25",
                "2",
                "poll_sleep_cmd",
            ],
            stdout=out,
            stderr=err,
            env=env,
        )
    duplicate_env = os.environ.copy()
    duplicate_env.pop("BEAM_PROGRESS", None)
    duplicate_env["BEAM_REQUEST_ID"] = request_id
    deadline = time.monotonic() + 20.0
    active = False
    duplicate_text = ""
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        duplicate = subprocess.run(
            [
                beam_script,
                "--root",
                project_root,
                "hover",
                "tests/scenario/docs/CommandA.lean",
                command_snapshot,
                "0",
                "4",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=duplicate_env,
            timeout=10.0,
        )
        duplicate_text = (
            duplicate.stdout.decode("utf-8", errors="replace")
            + duplicate.stderr.decode("utf-8", errors="replace")
        )
        if duplicate.returncode != 0 and "already active" in duplicate_text:
            active = True
            break
        time.sleep(0.1)
    if not active:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        target_text = read_file(out_path) + read_file(err_path)
        if "already active" in target_text:
            setup_race_count += 1
            if attempt < max_attempts:
                continue
            append_failure_detail(
                f"quiet SIGINT readiness probe lost the setup race {setup_race_count} times",
                target_text,
                duplicate_text,
            )
        else:
            append_failure_detail(
                "missing active-request marker before SIGINT",
                target_text,
                duplicate_text,
            )
        rc = "active-timeout"
        break
    else:
        proc.send_signal(signal.SIGINT)
        try:
            rc = proc.wait(timeout=30.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            rc = "timeout"
        break

print(f"{rc} {request_id}")
PY
)"
  interrupt_quiet_request_id="${interrupt_quiet_status#* }"
  interrupt_quiet_status="${interrupt_quiet_status%% *}"
  if [ "$interrupt_quiet_status" = "timeout" ] || [ "$interrupt_quiet_status" = "active-timeout" ]; then
    cat "$interrupt_quiet_out" >&2
    cat "$interrupt_quiet_err" >&2
    exit 1
  fi
  if [ "$interrupt_quiet_status" = "0" ]; then
    echo "expected non-progress wrapper run-at SIGINT path to exit non-zero after connection interruption" >&2
    cat "$interrupt_quiet_out" >&2
    cat "$interrupt_quiet_err" >&2
    exit 1
  fi

  expect_sigint_aborted "non-progress wrapper SIGINT path" "$interrupt_quiet_out" "$interrupt_quiet_err" "$interrupt_quiet_request_id"

  interrupt_quiet_anon_out="$(beam_wrapper_mktemp_file interrupt-quiet-anon-out)"
  interrupt_quiet_anon_err="$(beam_wrapper_mktemp_file interrupt-quiet-anon-err)"
  interrupt_quiet_anon_status="$(run_sigint_probe "$signal_root" "$slow_snapshot" "$interrupt_quiet_anon_out" "$interrupt_quiet_anon_err" 0 "" sleep)"
  if [ "$interrupt_quiet_anon_status" = "timeout" ] || [ "$interrupt_quiet_anon_status" = "early-exit" ]; then
    cat "$interrupt_quiet_anon_out" >&2
    cat "$interrupt_quiet_anon_err" >&2
    exit 1
  fi
  if [ "$interrupt_quiet_anon_status" = "0" ]; then
    echo "expected anonymous non-progress wrapper run-at SIGINT path to exit non-zero after connection interruption" >&2
    cat "$interrupt_quiet_anon_out" >&2
    cat "$interrupt_quiet_anon_err" >&2
    exit 1
  fi
  expect_sigint_aborted "anonymous non-progress wrapper SIGINT path" "$interrupt_quiet_anon_out" "$interrupt_quiet_anon_err" ""

  "$beam_script" --root "$signal_root" stop > /dev/null 2>&1 || true
)
wait_for_exit "$signal_owner_pid" "first signal-test session owner" 120 0.1
wait "$signal_owner_pid"
beam_wrapper_unregister_pid "$signal_owner_pid"

beam_wrapper_start_owner "$signal_root"
signal_owner_pid="$beam_wrapper_last_owner_pid"
(
  cd "$signal_root"
  slow_snapshot="$(beam_wrapper_update_snapshot "duplicate SlowPoll" "$beam_script" --root "$signal_root" update tests/scenario/docs/SlowPoll.lean)"
  command_snapshot="$(beam_wrapper_update_snapshot "duplicate CommandA" "$beam_script" --root "$signal_root" update tests/scenario/docs/CommandA.lean)"

  duplicate_slow_out="$(beam_wrapper_mktemp_file duplicate-slow-out)"
  duplicate_slow_err="$(beam_wrapper_mktemp_file duplicate-slow-err)"
  duplicate_out="$(beam_wrapper_mktemp_file duplicate-out)"
  duplicate_err="$(beam_wrapper_mktemp_file duplicate-err)"
  BEAM_PROGRESS=1 BEAM_REQUEST_ID=wrapper-duplicate-active \
    "$beam_script" --root "$signal_root" run-at tests/scenario/docs/SlowPoll.lean "$slow_snapshot" 25 2 "poll_sleep_cmd" \
    >"$duplicate_slow_out" 2>"$duplicate_slow_err" &
  duplicate_slow_pid=$!
  sleep 1

  if BEAM_REQUEST_ID=wrapper-duplicate-active \
      "$beam_script" --root "$signal_root" hover tests/scenario/docs/CommandA.lean "$command_snapshot" 0 4 \
      >"$duplicate_out" 2>"$duplicate_err"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to fail" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi

  duplicate_json="$(cat "$duplicate_out")"
  if [ "$(BEAM_JSON_PAYLOAD="$duplicate_json" read_json_text_field error.code)" != "invalidParams" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to report invalidParams" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$duplicate_json" read_json_text_field clientRequestId)" != "wrapper-duplicate-active" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper response to echo clientRequestId" >&2
    printf '%s\n' "$duplicate_json" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi
  if ! grep -q "already active" "$duplicate_out"; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper request to explain the conflict" >&2
    cat "$duplicate_out" >&2
    cat "$duplicate_err" >&2
    kill "$duplicate_slow_pid" > /dev/null 2>&1 || true
    wait "$duplicate_slow_pid" 2>/dev/null || true
    exit 1
  fi

  cancel_json="$("$beam_script" --root "$signal_root" cancel wrapper-duplicate-active)"
  if [ "$(BEAM_JSON_PAYLOAD="$cancel_json" read_json_text_field result.cancelled)" != "true" ]; then
    echo "expected duplicate active BEAM_REQUEST_ID cancel to report cancelled=true" >&2
    printf '%s\n' "$cancel_json" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  if ! wait_for_exit "$duplicate_slow_pid" "duplicate active slow wrapper request"; then
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  if wait "$duplicate_slow_pid"; then
    echo "expected duplicate active slow wrapper request to exit non-zero after cancellation" >&2
    cat "$duplicate_slow_out" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi

  duplicate_slow_json="$(cat "$duplicate_slow_out")"
  if [ "$(BEAM_JSON_PAYLOAD="$duplicate_slow_json" read_json_text_field error.code)" != "requestCancelled" ]; then
    echo "expected cancelled duplicate active slow wrapper request to report requestCancelled" >&2
    printf '%s\n' "$duplicate_slow_json" >&2
    cat "$duplicate_slow_err" >&2
    exit 1
  fi
  stats_out="$("$beam_script" --root "$signal_root" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.invalidParamsCount)" -lt 1 ]; then
    echo "expected duplicate active BEAM_REQUEST_ID wrapper conflict to increment invalidParamsCount" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  "$beam_script" --root "$signal_root" stop > /dev/null 2>&1 || true
)
wait_for_exit "$signal_owner_pid" "second signal-test session owner" 120 0.1
wait "$signal_owner_pid"
beam_wrapper_unregister_pid "$signal_owner_pid"

beam_wrapper_start_owner "$other_root"
(
  cd "$other_root"
  "$beam_script" stats > /dev/null
)

other_registry="$(beam_wrapper_registry_path "$other_root")"
beam_wrapper_expect_file "$other_registry"
pid2="$(read_json_field "$other_registry" pid)"
port2="$(read_json_field "$other_registry" port)"
if [ "$pid1" = "$pid2" ]; then
  echo "expected distinct Beam daemon processes per project" >&2
  exit 1
fi
if [ "$port1" = "$port2" ]; then
  echo "expected distinct Beam daemon ports per project" >&2
  exit 1
fi

(
  cd "$primary_root"
  "$beam_script" --root "$primary_root" stop > /dev/null
)
wait_for_exit "$primary_owner_pid" "primary session owner" 120 0.1
wait "$primary_owner_pid"
beam_wrapper_unregister_pid "$primary_owner_pid"

if [ -f "$primary_registry" ]; then
  echo "expected shutdown to remove the project Beam daemon registry" >&2
  exit 1
fi
if kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be gone after shutdown" >&2
  exit 1
fi
