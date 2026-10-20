#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise the installed MCP smoke reader with a real notification-producing pipe."""

import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
SERVER = '''#!/usr/bin/env python3
import json
import os
import sys
import time

mode = os.environ["BEAM_MCP_READER_TEST_MODE"]
with open(os.environ["BEAM_MCP_READER_TEST_PID"], "a") as stream:
    stream.write(str(os.getpid()) + "\\n")
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
    elif method == "initialize":
        assert request["params"]["protocolVersion"] == "2025-11-25"
        print(json.dumps({"jsonrpc": "2.0", "id": 1,
                          "result": {"protocolVersion": "2025-11-25",
                                     "capabilities": {"tools": {}, "logging": {}}}}), flush=True)
    elif method == "tools/call":
        arguments = request["params"]["arguments"]
        assert arguments["workspace"]["root"] == os.getcwd()
        if arguments["path"] == "__beam_mcp_smoke_missing__.lean":
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": complete({
                "isError": mode != "missing-accepted", "structuredContent": {
                    "code": "invalidInput", "message": "missing " + arguments["path"]}})}), flush=True)
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
            while True:
                print(json.dumps(notice), flush=True)
                time.sleep(0.02)
        if mode == "partial":
            sys.stdout.write('{"jsonrpc":"2.0"')
            sys.stdout.flush()
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
if mode == "teardown-stall":
    time.sleep(60)
if mode == "nonzero-exit":
    sys.stderr.write("fixture shutdown failure\\n")
    sys.exit(7)
'''


class InstalledMcpSmokeReaderTest(unittest.TestCase):
    def run_smoke(self, mode, *, trace=False):
        with tempfile.TemporaryDirectory(prefix="beam-mcp-reader-") as tmp:
            server = Path(tmp) / "fake-mcp"
            server.write_text(SERVER)
            server.chmod(0o755)
            pid_path = Path(tmp) / "server.pid"
            env = dict(os.environ, BEAM_MCP_READER_TEST_MODE=mode,
                       BEAM_MCP_READER_TEST_PID=str(pid_path),
                       BEAM_MCP_SMOKE_TIMEOUT="0.2", BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT="1")
            started = time.monotonic()
            try:
                command = ["python3", str(REPO / "tests/lib/installed-mcp-smoke.py"), str(server), tmp]
                if trace:
                    command.append("--server-trace")
                result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=3)
                result.elapsed = time.monotonic() - started
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
            finally:
                if pid_path.exists():
                    for line in pid_path.read_text().splitlines():
                        try:
                            os.kill(int(line), signal.SIGKILL)
                        except ProcessLookupError:
                            pass

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
        result = self.run_smoke("partial")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting for MCP response id 2", result.stderr)
        self.assertLess(result.elapsed, 3)
        self.assertFalse(result.child_alive)

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

    def test_notifications_do_not_restart_deadline(self):
        result = self.run_smoke("notifications")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out waiting for MCP response id 2", result.stderr)
        self.assertFalse(result.child_alive)

    def test_stalled_eof_shutdown_fails_and_reaps_child(self):
        result = self.run_smoke("teardown-stall")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("to exit after EOF", result.stderr)
        self.assertFalse(result.child_alive)

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
