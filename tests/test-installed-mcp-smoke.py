#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise the installed MCP smoke reader with a real notification-producing pipe."""

from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from lib.process_watchdog import run_with_watchdog


REPO = Path(__file__).resolve().parents[1]
SETUP_TIMEOUT = 5
RESPONSE_TIMEOUT = 0.2
SHUTDOWN_TIMEOUT = 1
DEADLINE_SCHEDULING_RESERVE = 2
# The full helper runs two families, each with three valid requests and EOF shutdown.
# close() can wait twice and join two readers; timeout diagnostics can run ps for five seconds.
CLOSE_BUDGET = 2 * SHUTDOWN_TIMEOUT + 2
DIAGNOSTIC_BUDGET = 5
WATCHDOG_RESERVE = 5
SMOKE_WATCHDOG_TIMEOUT = (
    2 * (3 * SETUP_TIMEOUT + SHUTDOWN_TIMEOUT + CLOSE_BUDGET)
    + DIAGNOSTIC_BUDGET + WATCHDOG_RESERVE
)

spec = importlib.util.spec_from_file_location("smoke_reader_stdio", REPO / "tests/test-mcp-stdio.py")
stdio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stdio)

SERVER = f"#!/usr/bin/env python3\nFIXTURE_LIFETIME = {SMOKE_WATCHDOG_TIMEOUT + WATCHDOG_RESERVE}\n" + '''
import json
import os
from pathlib import Path
import sys
import threading
import time

mode = os.environ["BEAM_MCP_READER_TEST_MODE"]
fixture_root = os.getcwd()

def stop_with_fixture():
    # Fallback after a failed fixture, never evidence that the client reaped this process.
    deadline = time.monotonic() + FIXTURE_LIFETIME
    while os.path.isdir(fixture_root) and time.monotonic() < deadline:
        time.sleep(0.02)
    os._exit(124)

threading.Thread(target=stop_with_fixture, daemon=True).start()
with open(os.environ["BEAM_MCP_READER_TEST_PID"], "a") as stream:
    stream.write(str(os.getpid()) + "\\n")

def mark_phase(name, request_id=None):
    path = Path(fixture_root) / f"{os.getpid()}-{name}.phase"
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text("" if request_id is None else str(request_id))
    temporary.replace(path)

if mode == "early-exit":
    sys.stderr.write("fixture early exit\\n")
    sys.exit(7)

def complete(result):
    result.update(resultType="complete", _meta={
        "io.modelcontextprotocol/serverInfo": {"name": "lean-beam-mcp"}})
    return result

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "server/discover":
        assert request["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] == "2026-07-28"
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"],
                          "result": complete({"supportedVersions": ["2026-07-28"]})}), flush=True)
        mark_phase("setup", request["id"])
    elif method == "initialize":
        assert request["params"]["protocolVersion"] == "2025-11-25"
        print(json.dumps({"jsonrpc": "2.0", "id": 1,
                          "result": {"protocolVersion": "2025-11-25",
                                     "capabilities": {"tools": {}, "logging": {}}}}), flush=True)
        mark_phase("setup", request["id"])
    elif method == "tools/call":
        arguments = request["params"]["arguments"]
        assert arguments["workspace"]["root"] == os.getcwd()
        if arguments["path"] == "__beam_mcp_smoke_missing__.lean":
            result = complete({
                "isError": mode != "missing-accepted", "structuredContent": {
                    "code": "workerExited" if mode == "missing-wrong-code" else "internalError",
                    "message": "missing " + arguments["path"]}})
            if mode == "missing-invalid-result-type":
                result["resultType"] = "incomplete"
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
            continue
        assert arguments["path"] == "PositionEmptyLine.lean"
        notice = {"jsonrpc": "2.0", "method": "notifications/message",
                  "params": {"level": "notice", "logger": "beam.status",
                             "data": {"message": "lean_sync is still working."}}}
        response = {"jsonrpc": "2.0", "id": 3 if mode.startswith("wrong-id") else 2,
                    "result": complete({"isError": "false" if mode == "string-is-error" else False,
                        "structuredContent": {"document_progress": None if mode == "null-progress" else {
                            "updates": "zero" if mode == "invalid-progress" else 0,
                            "done": mode != "in-progress"}}})}
        if mode == "invalid-jsonrpc":
            response["jsonrpc"] = "1.0"
        if mode == "invalid-result-type":
            response["result"]["resultType"] = "incomplete"
        if mode == "notifications":
            print(json.dumps(notice), flush=True)
            mark_phase("notifications", request["id"])
            while True:
                print(json.dumps(notice), flush=True)
                time.sleep(0.02)
        if mode == "partial":
            sys.stdout.write('{"jsonrpc":"2.0"')
            sys.stdout.flush()
            mark_phase("partial", request["id"])
            time.sleep(60)
        elif mode == "fragmented":
            frame = json.dumps(response) + "\\n"
            sys.stdout.write(frame[:len(frame)//2])
            sys.stdout.flush()
            time.sleep(0.05)
            sys.stdout.write(frame[len(frame)//2:])
            sys.stdout.flush()
        elif mode == "stderr-flood":
            sys.stderr.write("x" * (256 * 1024) + "\\n")
            sys.stderr.flush()
            print(json.dumps(response), flush=True)
        elif mode == "plain":
            print(json.dumps(response), flush=True)
        elif mode == "separate":
            print(json.dumps(notice), flush=True)
            time.sleep(0.05)
            print(json.dumps(response), flush=True)
        else:
            sys.stdout.write(json.dumps(notice) + "\\n" + json.dumps(response) + "\\n")
            sys.stdout.flush()
        if mode == "wrong-id-stall":
            time.sleep(60)
mark_phase("eof")
if mode == "teardown-stall":
    time.sleep(60)
if mode == "nonzero-exit":
    sys.stderr.write("fixture shutdown failure\\n")
    sys.exit(7)
'''


class InstalledMcpSmokeReaderTest(unittest.TestCase):
    @contextmanager
    def fake_server(self, mode):
        with tempfile.TemporaryDirectory(prefix="beam-mcp-reader-") as tmp:
            root = Path(tmp).resolve()
            server = root / "fake-mcp"
            server.write_text(SERVER)
            server.chmod(0o755)
            env = dict(os.environ, BEAM_MCP_READER_TEST_MODE=mode,
                       BEAM_MCP_READER_TEST_PID=str(root / "server.pid"),
                       BEAM_MCP_SMOKE_TIMEOUT=str(SETUP_TIMEOUT),
                       BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT=str(SHUTDOWN_TIMEOUT))
            yield server, root, env

    def run_smoke(self, mode, *, trace=False):
        with self.fake_server(mode) as (server, root, env):
            started = time.monotonic()
            command = [sys.executable, str(REPO / "tests/lib/installed-mcp-smoke.py"), str(server), str(root)]
            if trace:
                command.append("--server-trace")
            try:
                result = run_with_watchdog(command, env=env, timeout=SMOKE_WATCHDOG_TIMEOUT)
            except subprocess.TimeoutExpired as error:
                phases = sorted(path.name for path in root.glob("*.phase"))
                self.fail(f"whole smoke fixture watchdog expired; phases={phases}\n"
                          f"{error.output or ''}\n{error.stderr or ''}")
            result.elapsed = time.monotonic() - started
            pid_path = root / "server.pid"
            self.assertTrue(pid_path.exists(), result.stderr)
            pids = [int(line) for line in pid_path.read_text().splitlines()]
            result.child_alive = False
            for pid in pids:
                try:
                    os.kill(pid, 0)
                    result.child_alive = True
                except ProcessLookupError:
                    pass
            return result

    def wait_phase(self, client, root, name, request_id=None):
        marker = root / f"{client.proc.pid}-{name}.phase"
        deadline = time.monotonic() + SETUP_TIMEOUT
        while not marker.exists():
            if client.proc.poll() is not None:
                self.fail(f"fixture setup exited before phase {name}: {client.proc.returncode}")
            if request_id is not None and client.response_ready(request_id):
                self.fail(f"fixture setup returned a complete response before phase {name}")
            if time.monotonic() >= deadline:
                self.fail(f"fixture setup did not reach phase {name}\n{client._diagnostic_context()}")
            time.sleep(0.01)
        self.assertEqual(marker.read_text(), "" if request_id is None else str(request_id))

    @contextmanager
    def reader(self, mode, modern):
        with self.fake_server(mode) as (server, root, env):
            client = stdio.McpClient(
                root, root, SETUP_TIMEOUT, label="smoke-reader-fixture",
                server_command=[sys.executable, str(server)], extra_env=env,
                shutdown_timeout=SHUTDOWN_TIMEOUT,
            )
            try:
                if modern:
                    discovery = stdio.expect_result(client.modern_request("server/discover"))
                    stdio.require_modern_result_envelope(discovery, "fixture discovery")
                    self.assertEqual(discovery.get("supportedVersions"), [stdio.MCP_MODERN_PROTOCOL_VERSION])
                else:
                    client.initialize()
                self.wait_phase(client, root, "setup", 1)
                yield client, root
            finally:
                try:
                    client.close()
                finally:
                    if client.proc.poll() is None:
                        client.proc.kill()
                    client.proc.wait(timeout=SHUTDOWN_TIMEOUT)
                    for thread in [client.stdout_thread, client.stderr_thread]:
                        if thread is not None:
                            thread.join(timeout=1)
                            self.assertFalse(thread.is_alive(), "fixture reader survived child cleanup")
                    for stream in [client.proc.stdin, client.proc.stdout, client.proc.stderr]:
                        if stream is not None:
                            stream.close()

    def send_sync(self, client, root, modern):
        params = {"name": "lean_sync", "arguments": {
            "path": "PositionEmptyLine.lean", "workspace": {"root": str(root)}}}
        if modern:
            params = stdio.with_modern_metadata(params)
        return client.send_request("tools/call", params)

    def assert_response_timeout(self, client, request_id):
        # Measure the reader deadline, excluding the separate host-process diagnostic.
        with patch.object(client, "_process_snapshot", return_value="<fixture process>"):
            started = time.monotonic()
            message = f"timed out waiting for MCP response id {request_id} "
            with self.assertRaisesRegex(RuntimeError, message):
                client.read_response(request_id, timeout=RESPONSE_TIMEOUT)
            self.assertLess(time.monotonic() - started,
                            RESPONSE_TIMEOUT + DEADLINE_SCHEDULING_RESERVE)

    def assert_smoke_passes(self, mode, *, trace=False):
        result = self.run_smoke(mode, trace=trace)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "ok": True, "progress": {
                family: {"updates": 0, "done": mode != "in-progress"}
                for family in ["modern", "legacy"]}})
        self.assertFalse(result.child_alive)

    def test_notification_then_separate_response(self):
        self.assert_smoke_passes("separate")

    def test_response_without_notification(self):
        self.assert_smoke_passes("plain")

    def test_notification_and_response_in_one_flush(self):
        self.assert_smoke_passes("coalesced")

    def test_notification_does_not_hide_wrong_response_id(self):
        result = self.run_smoke("wrong-id")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("response for unknown request id 3", result.stderr)
        self.assertIn("'id': 3", result.stderr)

    def test_fragmented_response(self):
        self.assert_smoke_passes("fragmented")

    def test_partial_frame_respects_deadline(self):
        for modern in [True, False]:
            with self.subTest(modern=modern), self.reader("partial", modern) as (client, root):
                request_id = self.send_sync(client, root, modern)
                self.wait_phase(client, root, "partial", request_id)
                self.assert_response_timeout(client, request_id)
                self.assertIsNone(client.proc.poll(), "partial-frame fault ended before cleanup")

    def test_missing_partial_phase_is_setup_failure(self):
        for modern in [True, False]:
            with self.subTest(modern=modern), self.reader("plain", modern) as (client, root):
                request_id = self.send_sync(client, root, modern)
                with self.assertRaisesRegex(AssertionError, "fixture setup .*before phase partial"):
                    self.wait_phase(client, root, "partial", request_id)
                result = stdio.expect_result(client.read_response(request_id))
                self.assertIs(result.get("isError"), False)

    def test_stderr_flood_drains_before_quiet_assertion(self):
        result = self.run_smoke("stderr-flood")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("timed out", result.stderr)
        self.assertIn("stderr", result.stderr)
        self.assertFalse(result.child_alive)

    def test_traced_stderr_is_drained(self):
        self.assert_smoke_passes("stderr-flood", trace=True)

    def test_valid_incomplete_progress(self):
        self.assert_smoke_passes("in-progress")

    def test_malformed_responses(self):
        for mode, message in [("string-is-error", "expected lean_sync success"),
                              ("null-progress", "missing document_progress"),
                              ("invalid-progress", "invalid document_progress updates"),
                              ("invalid-jsonrpc", "bad JSON-RPC message"),
                              ("invalid-result-type", "missing resultType")]:
            with self.subTest(mode=mode):
                result = self.run_smoke(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(result.child_alive)

    def test_missing_file_must_fail(self):
        result = self.run_smoke("missing-accepted")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing file was accepted", result.stderr)
        self.assertFalse(result.child_alive)

    def test_missing_file_error_contract(self):
        for mode, message in [("missing-wrong-code", "unexpected missing-file error code"),
                              ("missing-invalid-result-type", "missing resultType")]:
            with self.subTest(mode=mode):
                result = self.run_smoke(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(result.child_alive)

    def test_notifications_do_not_restart_deadline(self):
        for modern in [True, False]:
            with self.subTest(modern=modern), self.reader("notifications", modern) as (client, root):
                request_id = self.send_sync(client, root, modern)
                self.wait_phase(client, root, "notifications", request_id)
                stdio.wait_for_status_log(client, None, SETUP_TIMEOUT, "fixture notification setup")
                self.assert_response_timeout(client, request_id)
                self.assertIsNone(client.proc.poll(), "notification fault ended before cleanup")

    def test_stalled_eof_shutdown_fails_and_reaps_child(self):
        for modern in [True, False]:
            with self.subTest(modern=modern), self.reader("teardown-stall", modern) as (client, root):
                request_id = self.send_sync(client, root, modern)
                result = stdio.expect_result(client.read_response(request_id))
                self.assertIs(result.get("isError"), False)
                client.close_input()
                self.wait_phase(client, root, "eof")
                with patch.object(client, "_process_snapshot", return_value="<fixture process>"):
                    started = time.monotonic()
                    with self.assertRaisesRegex(RuntimeError, "to exit after EOF"):
                        client.wait_for_exit_after_eof(SHUTDOWN_TIMEOUT)
                    self.assertLess(time.monotonic() - started,
                                    SHUTDOWN_TIMEOUT + DEADLINE_SCHEDULING_RESERVE)
                self.assertIsNone(client.proc.poll(), "EOF fault ended before cleanup")

    def test_nonzero_exit_retains_diagnostics(self):
        result = self.run_smoke("nonzero-exit", trace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("exited with code 7", result.stderr)
        self.assertIn("fixture shutdown failure", result.stderr)
        self.assertFalse(result.child_alive)

    def test_early_exit_retains_diagnostics(self):
        result = self.run_smoke("early-exit", trace=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture early exit", result.stderr)
        self.assertFalse(result.child_alive)

    def test_wrong_id_reaps_noncooperative_child(self):
        result = self.run_smoke("wrong-id-stall")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.child_alive)


if __name__ == "__main__":
    unittest.main()
