#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

beam_fast_state_root="$(mktemp -d "${TMPDIR:-/tmp}/beam-fast-state-XXXXXX")"
# Match the physical paths reported by installed launchers, including macOS /private/var aliases.
beam_fast_state_root="$(cd "$beam_fast_state_root" && pwd -P)"
beam_fast_cleanup() {
  rm -rf -- "$beam_fast_state_root"
}
trap beam_fast_cleanup EXIT
export BEAM_SESSION_ROOT="$beam_fast_state_root/sessions"

bash scripts/check-daemon-safety.sh
bash scripts/check-task-priority.sh
python3 tests/test-runtime-boundary.py
bash scripts/check-markdown-links.sh
python3 tests/test-skill-budget.py
python3 scripts/ci-toolchains.py > /dev/null
python3 tests/test-toolchain-ci-matrix.py
python3 tests/test-toolchain-registry.py
python3 tests/test-toolchain-compat-owner.py
python3 tests/test-installed-mcp-smoke.py
python3 tests/test-extended-ci.py
python3 tests/test-process-watchdog.py

run_quiet_lake_build() {
  local log
  log="$(mktemp /tmp/beam-fast-build-log-XXXXXX)"
  # Keep successful CI logs compact, but print the full Lake output when the build fails.
  if ! lake build "$@" > "$log" 2>&1; then
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

run_quiet_test() {
  local label="$1"
  shift
  local log
  log="$(mktemp /tmp/beam-fast-test-log-XXXXXX)"
  if ! "$@" > "$log" 2>&1; then
    echo "beam-fast test failed: $label" >&2
    cat "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

run_quiet_test "defensive validation Git isolation" bash tests/test-validate-defensive.sh

run_quiet_lake_build \
  Beam.LSP:shared \
  beam-cli \
  beam-daemon \
  beam-daemon-fixture \
  beam-lake-helper-client-fixture \
  lean-beam-mcp \
  beam-system-contract-test \
  beam-transaction-test \
  beam-prune-lock-test \
  BeamTest.SystemTimeTest \
  BeamTest.Broker.StreamDedupTest \
  BeamTest.Broker.RequestHandleTest \
  beam-backend-process-test \
  beam-transport-test \
  beam-broker-protocol-test \
  beam-broker-pending-test \
  beam-broker-document-state-test \
  beam-closing-model-test \
  beam-publication-test \
  beam-broker-open-docs-test \
  beam-daemon-smoke-test \
  beam-sync-concurrency-test \
  beam-daemon-save-stream-test \
  beam-daemon-stream-contract-test \
  beam-sync-result-test \
  beam-daemon-backend-startup-test \
  beam-cli-daemon-test \
  beam-feedback-test \
  beam-mcp-projection-test \
  beam-installation-construction-test \
  beam-installation-manifest-test \
  beam-installation-lookup-test \
  beam-installation-stage-fixture \
  beam-mcp-protocol-test

export BEAM_TEST_INSTALLATION="$beam_fast_state_root/installation"
export BEAM_TEST_PROJECT="$beam_fast_state_root/project"
run_quiet_test "stage installed test runtime" python3 tests/installation_fixture.py \
  "$BEAM_TEST_INSTALLATION" --project "$BEAM_TEST_PROJECT"
beam_test_cli="$BEAM_TEST_INSTALLATION/bin/lean-beam"
beam_test_mcp="$BEAM_TEST_INSTALLATION/bin/lean-beam-mcp"

# Exercise implicit root discovery at the actual filesystem root, without passing it through argv.
# A regression must fail within the watchdog budget rather than loop forever at a Windows drive root.
python3 - "$BEAM_TEST_INSTALLATION" <<'PY'
import json
from pathlib import Path
import sys

sys.path.insert(0, "tests/lib")
from process_watchdog import run_with_watchdog

repo = Path.cwd().resolve()
root = Path(repo.anchor)
suffix = ".exe" if sys.platform == "win32" else ""
cli = (Path(sys.argv[1]) / "libexec" / ("beam-cli" + suffix)).resolve(strict=True)
has_project = any((root / marker).exists()
                  for marker in ("lean-toolchain", "lakefile.toml", "lakefile.lean"))
result = run_with_watchdog([cli, "status"], timeout=20, cwd=root)
if has_project:
    assert result.returncode == 0, result
    status = json.loads(result.stdout)
    assert status["ok"] and Path(status["result"]["workspace"]).samefile(root), result
else:
    assert result.returncode != 0 and "could not infer project root" in result.stderr, result
print("Filesystem-root project discovery terminated with the expected result")
PY

run_quiet_test "partial-setup doctor" python3 tests/test-beam-doctor.py
run_quiet_test system-contracts python3 tests/test-system-contracts.py
run_quiet_test transaction python3 tests/lib/process_watchdog.py \
  --timeout 30 -- .lake/build/bin/beam-transaction-test
run_quiet_test prune-lock python3 tests/lib/process_watchdog.py \
  --timeout 30 -- .lake/build/bin/beam-prune-lock-test
run_quiet_test backend-process .lake/build/bin/beam-backend-process-test
run_quiet_test broker-transport python3 tests/lib/process_watchdog.py \
  --timeout 30 -- .lake/build/bin/beam-transport-test
run_quiet_test broker-protocol .lake/build/bin/beam-broker-protocol-test
run_quiet_test broker-pending .lake/build/bin/beam-broker-pending-test
run_quiet_test broker-document-state .lake/build/bin/beam-broker-document-state-test
run_quiet_test closing-model .lake/build/bin/beam-closing-model-test
run_quiet_test publication-ownership .lake/build/bin/beam-publication-test
run_quiet_test broker-open-docs .lake/build/bin/beam-broker-open-docs-test
run_quiet_test cli-daemon .lake/build/bin/beam-cli-daemon-test
run_quiet_test interrupt-watcher python3 tests/test-interrupt-watcher.py
run_quiet_test feedback .lake/build/bin/beam-feedback-test
run_quiet_test mcp-projection .lake/build/bin/beam-mcp-projection-test
run_quiet_test installation-manifest python3 tests/test-installation-manifest.py
run_quiet_test installation-construction python3 tests/test-installation-construction.py
run_quiet_test nonstandard-toolchain python3 tests/lib/process_watchdog.py \
  --timeout 180 -- python3 tests/test-nonstandard-toolchain.py
run_quiet_test installation-lookup python3 tests/test-installation-lookup.py
run_quiet_test installation-entrypoints python3 tests/test-installation-entrypoints.py
run_quiet_test lake-helper-lifetime python3 tests/lib/process_watchdog.py \
  --timeout 180 -- python3 tests/test-lake-helper-lifetime.py
run_quiet_test lake-save-preflight python3 tests/test-lake-save-preflight.py
run_quiet_test save-finalization python3 tests/lib/process_watchdog.py \
  --timeout 180 -- python3 tests/test-save-finalization.py
run_quiet_test mcp-protocol python3 tests/lib/process_watchdog.py \
  --timeout "${BEAM_MCP_PROTOCOL_TEST_WATCHDOG_SECONDS:-240}" -- \
  .lake/build/bin/beam-mcp-protocol-test
run_quiet_test mcp-application python3 tests/test-mcp-application.py
run_quiet_test daemon-smoke .lake/build/bin/beam-daemon-smoke-test
run_quiet_test sync-concurrency .lake/build/bin/beam-sync-concurrency-test
run_quiet_test daemon-save-stream .lake/build/bin/beam-daemon-save-stream-test
run_quiet_test daemon-stream-contract .lake/build/bin/beam-daemon-stream-contract-test
run_quiet_test sync-result .lake/build/bin/beam-sync-result-test
run_quiet_test daemon-backend-startup .lake/build/bin/beam-daemon-backend-startup-test

assert_output_contains() {
  local label="$1"
  local output="$2"
  local expected="$3"
  if ! printf '%s\n' "$output" | grep -Fq "$expected"; then
    echo "expected $label to contain: $expected" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

assert_output_omits() {
  local label="$1"
  local output="$2"
  local forbidden="$3"
  if printf '%s\n' "$output" | grep -Fq "$forbidden"; then
    echo "expected $label to omit: $forbidden" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

feedback_failure_output() {
  local label="$1"
  local input="$2"
  shift 2
  local output
  # Capture stderr in memory while discarding any unexpected stdout.
  if output="$(
    printf '%s\n' "$input" \
      | "$beam_test_cli" --root "$BEAM_TEST_PROJECT" feedback-report --stdin "$@" \
          2>&1 > /dev/null
  )"; then
    echo "expected $label" >&2
    return 1
  fi
  printf '%s\n' "$output"
}

source_tree_commit="$(git rev-parse HEAD)"
lean_beam_version="$("$beam_test_cli" --version)"
assert_output_contains "installed lean-beam --version" "$lean_beam_version" "lean-beam 0.2.0-beta"
assert_output_contains "installed lean-beam --version" "$lean_beam_version" "wrapper: $beam_test_cli"
assert_output_contains "installed lean-beam --version" "$lean_beam_version" "beam cli: $BEAM_TEST_INSTALLATION/libexec/beam-cli"
assert_output_contains "installed lean-beam --version" "$lean_beam_version" "runtime payload: "
assert_output_contains "installed lean-beam --version" "$lean_beam_version" "source commit: $source_tree_commit"
assert_output_omits "installed lean-beam --version" "$lean_beam_version" "source branch:"
assert_output_omits "installed lean-beam --version" "$lean_beam_version" "source dirty:"

lean_beam_help="$("$beam_test_cli" --help)"
assert_output_contains "lean-beam --help" "$lean_beam_help" \
  "lean-beam [--root PATH] run-at"
assert_output_omits "lean-beam --help" "$lean_beam_help" "lean-run-at"
assert_output_omits "lean-beam --help" "$lean_beam_help" "reset-stats"

if "$beam_test_cli" feedback --help > /dev/null 2>&1; then
  echo "expected obsolete lean-beam feedback command to be rejected" >&2
  exit 1
fi

feedback_help="$("$beam_test_cli" feedback-report --help)"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "does not upload or submit feedback"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "input must be a JSON object"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "title, summary, reproduction, expected, actual"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "kind values: bug, ux, perf, docs, question"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "severity values: low, medium, high, critical"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "confidential"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "request and response must be JSON objects"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "retain narrative except for HOME-path redaction"
assert_output_contains "lean-beam feedback-report --help" "$feedback_help" "requested bundle paths remain in the local result"

feedback_invalid_output="$(
  feedback_failure_output "lean-beam feedback-report to reject an empty JSON object" '{}'
)"
assert_output_contains "lean-beam feedback-report invalid input" "$feedback_invalid_output" "missing required string field 'title'"

feedback_unknown_input='{"title":"Misspelled privacy field","summary":"Private report.","reproduction":"Call feedback.","expected":"A report.","actual":"An error.","confidental":true}'
feedback_unknown_output="$(
  feedback_failure_output "lean-beam feedback-report to reject unknown JSON fields" \
    "$feedback_unknown_input"
)"
assert_output_contains "lean-beam feedback-report unknown input" "$feedback_unknown_output" "feedback input accepts no undeclared fields: confidental"

feedback_smoke_input='{"title":"CLI feedback fixture","kind":"bug","severity":"medium","summary":"Smoke report.","reproduction":"lean-beam feedback-report --stdin","expected":"A report card is returned.","actual":"A report card is returned."}'
feedback_smoke_output="$(printf '%s\n' "$feedback_smoke_input" | "$beam_test_cli" --root "$BEAM_TEST_PROJECT" feedback-report --stdin)"
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" '"markdown"'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" 'CLI feedback fixture'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" '"kind": "bug"'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" '"severity": "medium"'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" '"daemon"'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" 'Review before posting publicly'
assert_output_contains "lean-beam feedback-report" "$feedback_smoke_output" 'Beam does not submit feedback automatically'

feedback_confidential_secret='PRIVATE_CLI_CODE_57de'
feedback_confidential_input="{\"title\":\"CLI confidential feedback fixture\",\"summary\":\"Private workspace report.\",\"reproduction\":\"lean-beam feedback-report --stdin\",\"expected\":\"A confidential report card is returned.\",\"actual\":\"A confidential report card is returned.\",\"request\":{\"source\":\"$feedback_confidential_secret\"},\"confidential\":true}"
feedback_confidential_output="$(printf '%s\n' "$feedback_confidential_input" | "$beam_test_cli" --root "$BEAM_TEST_PROJECT" feedback-report --stdin)"
assert_output_contains "lean-beam confidential feedback" "$feedback_confidential_output" '"confidential": true'
assert_output_contains "lean-beam confidential feedback" "$feedback_confidential_output" 'do not post this report publicly'
assert_output_contains "lean-beam confidential feedback" "$feedback_confidential_output" '"collection_warnings": []'
assert_output_omits "lean-beam confidential feedback" "$feedback_confidential_output" "$feedback_confidential_secret"
assert_output_omits "lean-beam confidential feedback" "$feedback_confidential_output" '"openFiles"'
assert_output_omits "lean-beam confidential feedback" "$feedback_confidential_output" '"daemon"'

feedback_confidential_non_project_root="$PWD/docs"
if [ -e "$feedback_confidential_non_project_root/lakefile.lean" ] \
    || [ -e "$feedback_confidential_non_project_root/lakefile.toml" ] \
    || [ -e "$feedback_confidential_non_project_root/lean-toolchain" ]; then
  echo "reserved confidential feedback non-project root became a Lean/Lake project" >&2
  exit 1
fi
feedback_confidential_non_project_root_output="$(
  printf '%s\n' "$feedback_confidential_input" \
    | "$beam_test_cli" --root "$feedback_confidential_non_project_root" feedback-report --stdin
)"
assert_output_contains "lean-beam confidential feedback without project root" \
  "$feedback_confidential_non_project_root_output" '"confidential": true'
assert_output_omits "lean-beam confidential feedback without project root" \
  "$feedback_confidential_non_project_root_output" "$feedback_confidential_non_project_root"

feedback_confidential_error_output="$(
  feedback_failure_output "lean-beam confidential feedback to reject --no-redact" \
    "$feedback_confidential_input" --no-redact
)"
assert_output_contains "lean-beam confidential feedback --no-redact" "$feedback_confidential_error_output" "'confidential' cannot be combined with --no-redact"

mcp_wrapper_version="$("$beam_test_mcp" --version)"
assert_output_contains "installed MCP --version" "$mcp_wrapper_version" "lean-beam-mcp 0.2.0-beta"
assert_output_contains "installed MCP --version" "$mcp_wrapper_version" "mcp protocol: 2026-07-28"
assert_output_contains "installed MCP --version" "$mcp_wrapper_version" "wrapper: $beam_test_mcp"
assert_output_contains "installed MCP --version" "$mcp_wrapper_version" "server binary: $BEAM_TEST_INSTALLATION/libexec/lean-beam-mcp"
assert_output_contains "installed MCP --version" "$mcp_wrapper_version" "source commit: $source_tree_commit"

mcp_http_timeout="${BEAM_MCP_HTTP_TIMEOUT:-60}"
python3 tests/test-mcp-http-bridge.py --timeout "$mcp_http_timeout" > /dev/null
python3 tests/lib/process_watchdog.py --timeout "${BEAM_MCP_SMOKE_WATCHDOG_SECONDS:-600}" -- \
  python3 tests/lib/installed-mcp-smoke.py "$beam_test_mcp" "$BEAM_TEST_PROJECT" > /dev/null

mcp_removed_root_err="$(mktemp /tmp/lean-beam-mcp-removed-root-XXXXXX)"
if "$beam_test_mcp" --root "$BEAM_TEST_PROJECT" \
    > /dev/null 2>"$mcp_removed_root_err"; then
  echo "expected lean-beam-mcp to reject the removed --root option" >&2
  rm -f "$mcp_removed_root_err"
  exit 1
fi
if ! grep -Fq "unexpected lean-beam-mcp argument '--root'" "$mcp_removed_root_err"; then
  echo "expected removed MCP --root failure to explain the invalid option" >&2
  cat "$mcp_removed_root_err" >&2
  rm -f "$mcp_removed_root_err"
  exit 1
fi
rm -f "$mcp_removed_root_err"

cli_non_workspace_root="$(mktemp -d /tmp/beam-cli-non-workspace-root-XXXXXX)"
cli_non_workspace_err="$(mktemp /tmp/beam-cli-non-workspace-root-err-XXXXXX)"
if "$beam_test_cli" --root "$cli_non_workspace_root" serve \
    > /dev/null 2>"$cli_non_workspace_err"; then
  echo "expected beam-cli Lean root validation to reject a non-workspace root" >&2
  rm -rf -- "$cli_non_workspace_root"
  rm -f "$cli_non_workspace_err"
  exit 1
fi
if ! grep -Fq 'workspace root is not a Lean/Lake project' "$cli_non_workspace_err"; then
  echo "expected non-workspace CLI root failure to use the shared workspace error" >&2
  cat "$cli_non_workspace_err" >&2
  rm -rf -- "$cli_non_workspace_root"
  rm -f "$cli_non_workspace_err"
  exit 1
fi
rm -rf -- "$cli_non_workspace_root"
rm -f "$cli_non_workspace_err"

python3 - <<'PY'
import json
import os
import select
import subprocess
import sys

REQUEST_TIMEOUT_SECONDS = int(os.environ.get("BEAM_MCP_SMOKE_REQUEST_TIMEOUT", "60"))
SHUTDOWN_TIMEOUT_SECONDS = int(os.environ.get("BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT", "30"))
workspace = {"root": os.environ["BEAM_TEST_PROJECT"]}

proc = subprocess.Popen(
    [os.path.join(os.environ["BEAM_TEST_INSTALLATION"], "bin", "lean-beam-mcp")],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
    bufsize=1,
)

def fail(message):
    proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    stderr = proc.stderr.read()
    raise SystemExit(f"{message}; stderr:\n{stderr}")

def request(payload):
    expected_id = payload.get("id")
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], REQUEST_TIMEOUT_SECONDS)
        if not ready:
            method = payload.get("method")
            fail(f"timed out after {REQUEST_TIMEOUT_SECONDS}s waiting for MCP response id={expected_id} method={method}")
        line = proc.stdout.readline()
        if not line:
            fail(f"missing MCP response for {payload}")
        message = json.loads(line)
        if message.get("id") == expected_id:
            return message

init = request({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "lean-beam-fast-test", "version": "0"},
    },
})
proc.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
proc.stdin.flush()
tools = request({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
server_version = request({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "beam_version", "arguments": {}}})
update = request({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "lean_update", "arguments": {"path": "TodoSmoke.lean", "workspace": workspace}}})
update_content = update.get("result", {}).get("structuredContent", {})
version = update_content.get("version")
if not isinstance(version, int):
    print(f"expected lean_update MCP smoke to return a document version: {update}", file=sys.stderr)
    proc.kill()
    sys.exit(1)
todo = request({
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
        "name": "lean_todo",
        "arguments": {
            "path": "TodoSmoke.lean",
            "version": version,
            "start_line": 13,
            "start_character": 0,
            "end_line": 14,
            "end_character": 0,
            "kinds": ["sorry"],
            "suggest": "none",
            "workspace": workspace,
        },
    },
})
raw_tool = request({"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "$/lean/runAt", "arguments": {}}})
feedback = request({
    "jsonrpc": "2.0",
    "id": 8,
    "method": "tools/call",
    "params": {
        "name": "beam_feedback_report",
        "arguments": {
            "workspace": workspace,
            "title": "MCP feedback fixture",
            "kind": "bug",
            "severity": "medium",
            "summary": "Smoke report.",
            "reproduction": "Call beam_feedback_report through tools/call.",
            "expected": "A report card is returned.",
            "actual": "A report card is returned.",
        },
    },
})
feedback_full = request({
    "jsonrpc": "2.0",
    "id": 9,
    "method": "tools/call",
    "params": {
        "name": "beam_feedback_report",
        "arguments": {
            "workspace": workspace,
            "title": "MCP feedback fixture full",
            "kind": "bug",
            "severity": "medium",
            "summary": "Smoke report with inline collection.",
            "reproduction": "Call beam_feedback_report through tools/call.",
            "expected": "A report card is returned with collected context.",
            "actual": "A report card is returned with collected context.",
            "include_collected": True,
        },
    },
})
if init.get("result", {}).get("protocolVersion") != "2025-11-25":
    print("MCP initialize did not negotiate the expected protocol version", file=sys.stderr)
    proc.kill()
    sys.exit(1)

tool_names = {tool.get("name") for tool in tools.get("result", {}).get("tools", [])}
if (
    "beam_version" not in tool_names
    or "beam_feedback_report" not in tool_names
    or "lean_update" not in tool_names
    or "lean_run_at" not in tool_names
    or "lean_todo" not in tool_names
    or "lean_code_action_resolve" not in tool_names
    or "$/lean/runAt" in tool_names
    or "lean_request_at" in tool_names
):
    print(f"unexpected MCP tool list: {sorted(tool_names)}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

server_version_content = server_version.get("result", {}).get("structuredContent", {})
if not server_version_content.get("wrapper", "").endswith("/bin/lean-beam-mcp"):
    print(f"expected wrapper-launched MCP beam_version to report wrapper path: {server_version}", file=sys.stderr)
    proc.kill()
    sys.exit(1)
expected_commit = subprocess.run(["git", "rev-parse", "HEAD"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout.strip()
if expected_commit and server_version_content.get("source_commit") != expected_commit:
    print(f"expected wrapper-launched MCP beam_version to report source_commit={expected_commit}: {server_version}", file=sys.stderr)
    proc.kill()
    sys.exit(1)
if "source_branch" in server_version_content or "source_dirty" in server_version_content:
    print(f"installed identity must come from its manifest, not a surrounding checkout: {server_version}", file=sys.stderr)
    proc.kill()
    sys.exit(1)
if server_version_content.get("runtime_active") is not False:
    print(f"expected pre-update MCP beam_version to report runtime_active=false: {server_version}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

todo_content = todo.get("result", {}).get("structuredContent", {})
todo_items = todo_content.get("items", [])
if len(todo_items) != 1 or todo_items[0].get("kind") != "sorry":
    print(f"expected lean_todo MCP smoke to return one sorry item: {todo}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if todo_items[0].get("run_at_position") != {"line": 13, "character": 2}:
    print(f"unexpected MCP todo run_at_position: {todo}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "run_at_text" in todo_items[0]:
    print(f"expected MCP todo suggest=none to omit run_at_text: {todo}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

feedback_content = feedback.get("result", {}).get("structuredContent", {})
if "# MCP feedback fixture" not in feedback_content.get("markdown", ""):
    print(f"expected beam_feedback_report MCP smoke to return a report card: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "## Beam Runtime" not in feedback_content.get("markdown", ""):
    print(f"expected compact beam_feedback_report MCP smoke to include runtime summary: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "## Beam Debug Context" in feedback_content.get("markdown", ""):
    print(f"expected compact beam_feedback_report MCP smoke to omit full debug context: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

feedback_metadata = feedback_content.get("metadata", {})
if feedback_metadata.get("kind") != "bug" or feedback_metadata.get("severity") != "medium":
    print(f"expected beam_feedback_report MCP smoke metadata to include kind/severity: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "collected" in feedback_content:
    print(f"expected compact beam_feedback_report MCP smoke to omit collected context: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "collection_warnings" not in feedback_content:
    print(f"expected compact beam_feedback_report MCP smoke to include collection warnings: {feedback}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

feedback_full_content = feedback_full.get("result", {}).get("structuredContent", {})
if "## Beam Debug Context" not in feedback_full_content.get("markdown", ""):
    print(f"expected beam_feedback_report include_collected MCP smoke to include debug markdown: {feedback_full}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if "daemon" not in feedback_full_content.get("collected", {}):
    print(f"expected beam_feedback_report include_collected MCP smoke to include daemon context: {feedback_full}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

if raw_tool.get("error", {}).get("code") != -32602:
    print(f"expected raw LSP tool call to be rejected as invalid params: {raw_tool}", file=sys.stderr)
    proc.kill()
    sys.exit(1)

proc.stdin.close()
try:
    code = proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    stderr = proc.stderr.read()
    print(
        f"expected MCP smoke server to exit within {SHUTDOWN_TIMEOUT_SECONDS}s after EOF; stderr:\n{stderr}",
        file=sys.stderr,
    )
    sys.exit(1)
stderr = proc.stderr.read()
if code != 0:
    print(f"expected MCP smoke server to exit cleanly, got {code}\nstderr:\n{stderr}", file=sys.stderr)
    sys.exit(1)
PY
