#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise HTTP bridge framing through owned fake children, without Lean or an HTTP server."""

import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest import mock

import mcp_http_bridge as bridge
from lib import pipe_lines


@unittest.skipUnless(os.name == "posix", "the HTTP bridge uses POSIX pipe readiness")
class HttpBridgeReaderTest(unittest.TestCase):
    request = {"jsonrpc": "2.0", "id": 9, "method": "fixture"}
    response = {"jsonrpc": "2.0", "id": 9, "result": {"text": "λ"}}

    @contextmanager
    def child(self, action):
        source = (
            "import json, os, sys\n"
            "os.write(2, b'fixture ready\\n')\n"
            "request = json.loads(sys.stdin.buffer.readline())\n"
            + action + "\n"
            "sys.stdin.buffer.read()\n"
            "os._exit(0)\n"
        )
        client = bridge.StdioMcpServer([sys.executable, "-u", "-c", source], Path.cwd(), 5)
        try:
            # Establish setup separately from any intentionally short read deadline.
            deadline = time.monotonic() + 5
            while "fixture ready\n" not in client.stderr:
                if client.proc.poll() is not None or time.monotonic() >= deadline:
                    self.fail(f"fake child was not ready: {client.stderr_tail()}")
                time.sleep(0.005)
            yield client
        finally:
            client.close()
            client.stderr_thread.join(timeout=5)
            for stream in [client.proc.stdin, client.proc.stdout, client.proc.stderr]:
                stream.close()
            self.assertIsNotNone(client.proc.poll(), "fake child was not collected")
            self.assertFalse(client.stderr_thread.is_alive(), "stderr drain did not settle")

    def packet(self, *messages):
        return b"".join(json.dumps(message, ensure_ascii=False).encode() + b"\n"
                        for message in messages)

    def test_notifications_and_reply_in_one_write(self):
        notification = {"jsonrpc": "2.0", "method": "notifications/message", "params": {}}
        packet = self.packet(notification, notification, self.response)
        with self.child(f"os.write(1, {packet!r})") as client:
            self.assertEqual(client.send_request(self.request), self.response)

    def test_partial_line_and_split_utf8(self):
        packet = self.packet(self.response)
        split = packet.index("λ".encode()) + 1
        action = (f"os.write(1, {packet[:split]!r})\n"
                  "sys.stdin.buffer.readline()\n"
                  f"os.write(1, {packet[split:]!r})")
        with self.child(action) as client:
            waiting_for_tail = threading.Event()
            select_pipe = pipe_lines.select.select
            calls = 0

            def observe_wait(*args):
                nonlocal calls
                calls += 1
                if calls == 2:
                    waiting_for_tail.set()
                return select_pipe(*args)

            # The child withholds the tail until the reader has returned to bounded waiting.
            with mock.patch.object(pipe_lines.select, "select", side_effect=observe_wait):
                with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                    response = executor.submit(client.send_request, self.request)
                    try:
                        self.assertTrue(waiting_for_tail.wait(5), "reader blocked on a partial line")
                    finally:
                        client.proc.stdin.write("release tail\n")
                        client.proc.stdin.flush()
                    self.assertEqual(response.result(timeout=5), self.response)

    def test_timeout_with_no_output_or_partial_line(self):
        for prefix in [b"", b'{"jsonrpc":']:
            with self.subTest(prefix=prefix), self.child(f"os.write(1, {prefix!r})") as client:
                client.timeout = 0.05
                with self.assertRaisesRegex(bridge.BridgeError, "timed out waiting"):
                    client.send_request(self.request)

    def test_empty_eof_and_invalid_final_line(self):
        for prefix, error in [(b"", "closed stdout"), (b'{"jsonrpc":', "invalid JSON")]:
            action = f"os.write(1, {prefix!r})\nos.close(1)"
            with self.subTest(prefix=prefix), self.child(action) as client:
                with self.assertRaisesRegex(bridge.BridgeError, error):
                    client.send_request(self.request)

    def test_complete_final_line_without_newline(self):
        packet = self.packet(self.response).rstrip(b"\n")
        with self.child(f"os.write(1, {packet!r})\nos.close(1)") as client:
            self.assertEqual(client.send_request(self.request), self.response)


if __name__ == "__main__":
    unittest.main()
