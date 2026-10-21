#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

from pathlib import Path
import json
import os
import select
import signal
import socket
import subprocess
import sys
import threading
import unittest


REPO_ROOT = Path(__file__).resolve().parent.parent


class InterruptWatcherTest(unittest.TestCase):
    binary = REPO_ROOT / ".lake/build/bin/beam-cli-daemon-test"

    def check_mode(self, mode, final_signal=signal.SIGINT):
        result = subprocess.run(
            [str(self.binary.resolve()), "--interrupt-watcher", mode],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=15,
        )
        details = f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        self.assertIn("watcher cleanup complete", result.stdout, details)
        expected = 0 if sys.platform == "win32" else -final_signal
        self.assertEqual(result.returncode, expected, details)

    def test_return_releases_waiter_and_restores_sigint(self):
        self.check_mode("return")

    def test_throw_releases_waiter_and_restores_sigint(self):
        self.check_mode("throw-INT")

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_throw_restores_other_owner_signals(self):
        for name in ["TERM", "HUP"]:
            with self.subTest(signal=name):
                self.check_mode("throw-" + name, getattr(signal, "SIG" + name))

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_delivery_and_later_watcher_are_isolated(self):
        for name in ["INT", "TERM", "HUP"]:
            with self.subTest(signal=name):
                self.check_mode("signal-" + name, getattr(signal, "SIG" + name))

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_repeated_signals_leave_owner_scope_alive(self):
        for termination in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
            with self.subTest(signal=termination):
                with subprocess.Popen(
                    [str(self.binary.resolve()), "--interrupt-watcher", "owner-held"],
                    cwd=REPO_ROOT, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                ) as child:
                    try:
                        self.assertTrue(select.select([child.stdout], [], [], 5)[0],
                                        "owner watcher did not become ready")
                        self.assertEqual(child.stdout.readline(), b"owner watcher ready\n")
                        child.send_signal(termination)
                        self.assertTrue(select.select([child.stdout], [], [], 5)[0],
                                        "owner watcher did not latch the first signal")
                        self.assertEqual(child.stdout.readline(), b"owner stop latched\n")
                        child.send_signal(termination)
                        # This is a survival check, not an acknowledgement or count of delivery.
                        # The scope stays open until fixture cleanup; no signal can race teardown.
                        with self.assertRaises(subprocess.TimeoutExpired):
                            child.wait(timeout=0.2)
                    finally:
                        if child.poll() is None:
                            child.kill()
                        child.wait(timeout=5)

    def test_cancellation_during_owner_acquisition_fails_before_readiness(self):
        result = subprocess.run(
            [str(self.binary.resolve()), "--interrupt-watcher", "owner-acquisition"],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=30,
        )
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "", "cancelled owner published readiness")
        self.assertIn("Beam request interrupted", result.stderr)

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_initial_progress_has_an_active_interrupt_watcher(self):
        # Gate the actual rendering boundary, so the signal cannot miss the startup window.
        # A listening socket keeps any connection racing signal delivery pending until cancellation.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            with subprocess.Popen(
                [str(self.binary.resolve()), "--blocked-output", "progress-start",
                 str(listener.getsockname()[1])],
                cwd=REPO_ROOT, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, env=dict(os.environ, BEAM_PROGRESS="1"),
            ) as child:
                try:
                    self.assertTrue(select.select([child.stdout], [], [], 5)[0],
                                    "request did not reach its initial progress write")
                    self.assertEqual(child.stdout.readline(), b"progress start reached\n")
                    child.send_signal(signal.SIGINT)
                    stdout, stderr = child.communicate(input=b"release\n", timeout=5)
                    self.assertEqual(stdout, b"", stderr)
                    self.assertNotEqual(child.returncode, 0, stderr)
                    self.assertIn(b"interrupting broker request", stderr)
                    self.assertIn(b"Beam request interrupted", stderr)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)

    def check_blocked_output(self, stream, termination, *, repeat=False):
        """A real request must remain terminable when its output consumer stops reading."""
        errors = []
        requests = []
        release = threading.Event()

        def send_frame(connection, value):
            payload = json.dumps(value).encode()
            connection.sendall(str(len(payload)).encode() + b"\n" + payload)

        def serve(listener):
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(5)
                    send_frame(connection, {"schemaVersion": 1, "identity": {
                        "daemonId": "test-generation", "configHash": "test-config",
                    }})
                    with connection.makefile("rb") as incoming:
                        size = int(incoming.readline())
                        request = json.loads(incoming.read(size))
                        requests.append(request)
                        if stream == "stderr":
                            value = {"kind": "diagnostic", "payload": {
                                "path": "Main.lean", "uri": "file:///Main.lean",
                                "range": {"start": {"line": 0, "character": 0},
                                          "end": {"line": 0, "character": 1}},
                                "message": "x" * (1024 * 1024),
                                "completionBlocking": False,
                            }}
                        else:
                            value = {"kind": "response", "payload": {
                                "ok": True, "result": "x" * (1024 * 1024),
                            }}
                        if "clientRequestId" in request:
                            value["clientRequestId"] = request["clientRequestId"]
                        send_frame(connection, value)
                        release.wait(5)
            except Exception as error:
                errors.append(error)

        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            server = threading.Thread(target=serve, args=(listener,))
            server.start()
            child = None
            try:
                child = subprocess.Popen(
                    [str(self.binary.resolve()), "--blocked-output", stream,
                     str(listener.getsockname()[1])],
                    cwd=REPO_ROOT, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE if stream != "stderr" else subprocess.DEVNULL,
                    stderr=subprocess.PIPE if stream == "stderr" else subprocess.DEVNULL,
                    env=dict(os.environ, BEAM_PROGRESS="0"), start_new_session=True,
                )
                output = child.stderr if stream == "stderr" else child.stdout
                # Do not drain the pipe. Readability establishes that rendering has begun;
                # the megabyte payload exceeds the supported platforms' pipe buffers.
                self.assertTrue(select.select([output], [], [], 5)[0], errors)
                self.assertIsNone(child.poll(), errors)
                child.send_signal(termination)
                if repeat:
                    with self.assertRaises(subprocess.TimeoutExpired):
                        child.wait(timeout=0.2)
                    child.send_signal(termination)
                child.wait(timeout=3)
                self.assertEqual(child.returncode, -termination)
                self.assertEqual(len(requests), 1)
            finally:
                if child is not None:
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)
                    if child.stdout is not None:
                        child.stdout.close()
                    if child.stderr is not None:
                        child.stderr.close()
                release.set()
                server.join(timeout=6)
            self.assertFalse(server.is_alive(), "fake broker survived fixture cleanup")
            self.assertEqual(errors, [])

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_completed_output_has_default_signal_policy(self):
        for stream in ["stdout", "stdout-progress"]:
            with self.subTest(stream=stream):
                self.check_blocked_output(stream, signal.SIGINT)

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_repeated_sigint_can_terminate_blocked_diagnostic_output(self):
        self.check_blocked_output("stderr", signal.SIGINT, repeat=True)

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_request_does_not_intercept_other_termination_signals(self):
        for termination in [signal.SIGTERM, signal.SIGHUP]:
            with self.subTest(signal=termination):
                self.check_blocked_output("stderr", termination)


if __name__ == "__main__":
    unittest.main()
