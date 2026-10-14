#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise the installed MCP smoke reader with a real notification-producing pipe."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SERVER = '''#!/usr/bin/env python3
import json
import os
import sys
import time

mode = os.environ["BEAM_MCP_READER_TEST_MODE"]
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method == "initialize":
        print(json.dumps({"jsonrpc": "2.0", "id": 1,
                          "result": {"protocolVersion": "2025-11-25"}}), flush=True)
    elif method == "tools/call":
        notice = {"jsonrpc": "2.0", "method": "notifications/message",
                  "params": {"level": "notice", "logger": "beam.status",
                             "data": {"message": "lean_sync is still working."}}}
        response = {"jsonrpc": "2.0", "id": 3 if mode == "wrong-id" else 2,
                    "result": {"structuredContent": {
                        "document_progress": {"updates": 0, "done": True}}}}
        if mode == "plain":
            print(json.dumps(response), flush=True)
        elif mode == "separate":
            print(json.dumps(notice), flush=True)
            time.sleep(0.05)
            print(json.dumps(response), flush=True)
        else:
            sys.stdout.write(json.dumps(notice) + "\\n" + json.dumps(response) + "\\n")
            sys.stdout.flush()
'''


class InstalledMcpSmokeReaderTest(unittest.TestCase):
    def run_smoke(self, mode):
        with tempfile.TemporaryDirectory(prefix="beam-mcp-reader-") as tmp:
            server = Path(tmp) / "fake-mcp"
            server.write_text(SERVER)
            server.chmod(0o755)
            env = dict(os.environ, BEAM_MCP_READER_TEST_MODE=mode)
            return subprocess.run(
                ["python3", str(REPO / "tests/lib/installed-mcp-smoke.py"),
                 str(server), tmp], env=env, capture_output=True, text=True, timeout=35)

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
        self.assertIn("expected response id 2", result.stderr)
        self.assertIn("'id': 3", result.stderr)


if __name__ == "__main__":
    unittest.main()
