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
with open(os.environ["BEAM_MCP_READER_TEST_PID"], "w") as stream:
    stream.write(str(os.getpid()))
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        assert request["params"]["protocolVersion"] == "2025-11-25"
        print(json.dumps({"jsonrpc": "2.0", "id": 1,
                          "result": {"protocolVersion": "2025-11-25"}}), flush=True)
    elif method == "tools/call":
        notice = {"jsonrpc": "2.0", "method": "notifications/message",
                  "params": {"level": "notice", "logger": "beam.status",
                             "data": {"message": "lean_sync is still working."}}}
        response = {"jsonrpc": "2.0", "id": 3 if mode.startswith("wrong-id") else 2,
                    "result": {"structuredContent": {
                        "document_progress": {"updates": 0, "done": True}}}}
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
'''


class InstalledMcpSmokeReaderTest(unittest.TestCase):
    def run_smoke(self, mode):
        with tempfile.TemporaryDirectory(prefix="beam-mcp-reader-") as tmp:
            server = Path(tmp) / "fake-mcp"
            server.write_text(SERVER)
            server.chmod(0o755)
            pid_path = Path(tmp) / "server.pid"
            env = dict(os.environ, BEAM_MCP_READER_TEST_MODE=mode,
                       BEAM_MCP_READER_TEST_PID=str(pid_path),
                       BEAM_MCP_SMOKE_TIMEOUT="2", BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT="1")
            started = time.monotonic()
            pid = None
            try:
                result = subprocess.run(
                    ["python3", str(REPO / "tests/lib/installed-mcp-smoke.py"),
                     str(server), tmp], env=env, capture_output=True, text=True, timeout=8)
                result.elapsed = time.monotonic() - started
                self.assertTrue(pid_path.exists(), result.stderr)
                pid = int(pid_path.read_text())
                try:
                    os.kill(pid, 0)
                    result.child_alive = True
                except ProcessLookupError:
                    result.child_alive = False
                return result
            finally:
                if pid is None and pid_path.exists():
                    pid = int(pid_path.read_text())
                if pid is not None:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def assert_smoke_passes(self, mode):
        result = self.run_smoke(mode)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            "ok": True, "progress": {"updates": 0, "done": True}})

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
        self.assertLess(result.elapsed, 8)
        self.assertFalse(result.child_alive)

    def test_stderr_flood_drains_before_quiet_assertion(self):
        result = self.run_smoke("stderr-flood")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("timed out", result.stderr)
        self.assertIn("stderr", result.stderr)
        self.assertFalse(result.child_alive)

    def test_wrong_id_reaps_noncooperative_child(self):
        result = self.run_smoke("wrong-id-stall")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(result.child_alive)


if __name__ == "__main__":
    unittest.main()
