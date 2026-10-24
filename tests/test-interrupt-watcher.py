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


def save_receipt(source_hash="saved-source"):
    return {
        "path": "Main.lean",
        "module": "Main",
        "version": 1,
        "sourceHash": source_hash,
        "olean": "Main.olean",
        "ilean": "Main.ilean",
        "c": "Main.c",
        "trace": "Main.trace",
        "oleanServer": "Main.server.olean",
        "oleanPrivate": "Main.private.olean",
        "ir": "Main.ir",
        "irSig": "Main.ir.sig",
        "bc": "Main.bc",
        "sync": {
            "path": "Main.lean",
            "version": 1,
            "diagnostics": {
                "counts": {"error": 0, "warning": 0, "information": 0,
                           "hint": 0, "unknown": 0, "total": 0},
                "items": [],
            },
            "readiness": {
                "saveReady": True,
                "reason": "ok",
                "blockingErrorCount": 0,
                "blockingDiagnostics": [],
                "blockingMessages": [],
            },
        },
    }


def projected_save_receipt(source_hash="saved-source"):
    return {
        "path": "Main.lean",
        "module": "Main",
        "version": 1,
        "source_hash": source_hash,
        "olean": "Main.olean",
        "ilean": "Main.ilean",
        "c": "Main.c",
        "trace": "Main.trace",
        "olean_server": "Main.server.olean",
        "olean_private": "Main.private.olean",
        "ir": "Main.ir",
        "ir_sig": "Main.ir.sig",
        "bc": "Main.bc",
        "sync": {
            "path": "Main.lean",
            "version": 1,
            "diagnostics": {
                "counts": {"error": 0, "warning": 0, "information": 0,
                           "hint": 0, "unknown": 0, "total": 0},
                "items": [],
            },
            "readiness": {
                "save_ready": True,
                "reason": "ok",
                "blocking_error_count": 0,
                "blocking_diagnostics": [],
                "blocking_messages": [],
            },
        },
    }


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
        self.assertEqual(result.returncode, 130, result.stderr)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "requestCancelled")
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
                    self.assertEqual(json.loads(stdout)["error"]["code"], "requestCancelled")
                    self.assertEqual(child.returncode, 130, stderr)
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
                                "message": "x" * 1024,
                                "completionBlocking": False,
                            }}
                        else:
                            value = {"kind": "response", "payload": {
                                "ok": True,
                                "result": save_receipt("x" * (1024 * 1024)),
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
            stderr_read = stderr_write = None
            try:
                if stream == "stderr":
                    # Fill an owned pipe before spawning. A small valid diagnostic must
                    # then block, regardless of the platform's default pipe capacity.
                    stderr_read, stderr_write = os.pipe()
                    os.set_blocking(stderr_write, False)
                    try:
                        while True:
                            os.write(stderr_write, b"x" * 4096)
                    except BlockingIOError:
                        pass
                    try:
                        while True:
                            os.write(stderr_write, b"x")
                    except BlockingIOError:
                        pass
                    os.set_blocking(stderr_write, True)
                child = subprocess.Popen(
                    [str(self.binary.resolve()), "--blocked-output", stream,
                     str(listener.getsockname()[1])],
                    cwd=REPO_ROOT, stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=stderr_write if stream == "stderr" else subprocess.DEVNULL,
                    env=dict(os.environ, BEAM_PROGRESS="0"), start_new_session=True,
                )
                if stderr_write is not None:
                    os.close(stderr_write)
                    stderr_write = None
                # Do not drain the output being tested. For stderr, the separate fixture
                # marker establishes entry into the write to the already-full pipe.
                self.assertTrue(select.select([child.stdout], [], [], 5)[0], errors)
                if stream == "stderr":
                    self.assertEqual(child.stdout.readline(), b"diagnostic write reached\n", errors)
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
                for descriptor in [stderr_read, stderr_write]:
                    if descriptor is not None:
                        os.close(descriptor)
                release.set()
                server.join(timeout=6)
            self.assertFalse(server.is_alive(), "fake broker survived fixture cleanup")
            self.assertEqual(errors, [])
            self.assertEqual(requests[0]["op"], "save_olean")
            self.assertEqual(requests[0]["path"], "Main.lean")

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


class OutputFailureTest(unittest.TestCase):
    """Exercise actual CLI writers without a Lean workspace or an installed runtime."""

    binary = InterruptWatcherTest.binary
    receipt = save_receipt()

    def public_response(self, response):
        if response["ok"]:
            result = projected_save_receipt(self.receipt["sourceHash"])
            if "fileProgress" in response:
                result["document_progress"] = response["fileProgress"]
            result["workspace"] = {"root": "/tmp"}
            public = {"ok": True, "result": result}
        else:
            # Error data is opaque at this boundary; in particular, retain the raw broker receipt.
            public = dict(response)
        public["client_request_id"] = "writer-test"
        return public

    def exchange(self, stream, response, event_kind="diagnostic"):
        errors = []

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
                        request = json.loads(incoming.read(int(incoming.readline())))
                    self.assertEqual(request["clientRequestId"], "writer-test")
                    self.assertEqual(request["op"], "save_olean")
                    self.assertEqual(request["path"], "Main.lean")
                    if stream.startswith("stderr-"):
                        payloads = {
                            "diagnostic": {"path": "Main.lean", "uri": "file:///Main.lean",
                                "range": {"start": {"line": 0, "character": 0},
                                          "end": {"line": 0, "character": 1}},
                                "message": "fixture diagnostic", "completionBlocking": False},
                            "workspaceOutput": {"source": "stderr", "text": "Lake configuration ünïcödé\n",
                                                "omittedBefore": False},
                            "fileProgress": {"updates": 1, "done": False},
                        }
                        send_frame(connection, {"kind": event_kind, "clientRequestId": "writer-test",
                                                "payload": payloads[event_kind]})
                        # The writer acknowledges its failure on stdout before the server
                        # returns a response or disconnects. No timing assumption is needed.
                        self.assertTrue(failed.wait(5), "stderr writer never failed")
                    if response is not None:
                        send_frame(connection, {"kind": "response", "clientRequestId": "writer-test",
                                                "payload": response})
            except Exception as error:
                errors.append(error)

        failed = threading.Event()
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(5)
            server = threading.Thread(target=serve, args=(listener,))
            server.start()
            with subprocess.Popen(
                [str(self.binary.resolve()), "--blocked-output", stream,
                 str(listener.getsockname()[1])], cwd=REPO_ROOT,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                env=dict(os.environ, BEAM_PROGRESS="1" if event_kind == "fileProgress" else "0",
                         BEAM_REQUEST_ID="writer-test"),
            ) as child:
                reader = None
                try:
                    if stream.startswith("stderr-"):
                        # A bounded reader thread also works with Windows anonymous pipes.
                        marker = []
                        reader = threading.Thread(target=lambda: marker.append(child.stdout.readline()))
                        reader.start()
                        reader.join(timeout=5)
                        self.assertFalse(reader.is_alive(), "stderr writer did not acknowledge failure")
                        self.assertEqual(marker, [b"fixture stderr failed\n"])
                        failed.set()
                    stdout, stderr = child.communicate(timeout=10)
                    result = subprocess.CompletedProcess(child.args, child.returncode,
                                                         stdout.decode(), stderr.decode())
                finally:
                    failed.set()
                    if child.poll() is None:
                        child.kill()
                    child.wait(timeout=5)
                    if reader is not None:
                        reader.join(timeout=5)
                    server.join(timeout=6)
            self.assertFalse(server.is_alive(), "fake broker survived cleanup")
            self.assertEqual(errors, [])
        self.assertNotIn("uncaught exception:", result.stderr)
        return result

    def test_optional_stderr_failure_preserves_completed_receipt(self):
        response = {"ok": True, "result": self.receipt}
        for event_kind in ["diagnostic", "workspaceOutput", "fileProgress"]:
            with self.subTest(event_kind=event_kind):
                result = self.exchange("stderr-fails", response, event_kind)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), self.public_response(response))

    def test_optional_stderr_flush_failure_preserves_completed_receipt(self):
        response = {"ok": True, "result": self.receipt}
        result = self.exchange("stderr-flush-fails", response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.public_response(response))
        self.assertIn("fixture diagnostic", result.stderr)

    def test_success_progress_is_nested_in_projected_result(self):
        progress = {"updates": 4, "done": True}
        response = {"ok": True, "result": self.receipt, "fileProgress": progress}
        result = self.exchange("stderr-fails", response)
        self.assertEqual(result.returncode, 0, result.stderr)
        public = json.loads(result.stdout)
        self.assertEqual(public, self.public_response(response))
        self.assertEqual(public["client_request_id"], "writer-test")
        self.assertEqual(public["result"]["document_progress"], progress)
        self.assertNotIn("fileProgress", public)

    def test_recovered_stderr_explains_display_failure_without_changing_result(self):
        response = {"ok": True, "result": self.receipt}
        result = self.exchange("stderr-fails-once", response)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.public_response(response))
        self.assertIn("beam[writer-test]: some workspace output could not be displayed", result.stderr)
        self.assertIn("request outcome is unchanged", result.stderr)

    def test_optional_stderr_failure_preserves_committed_error_receipt(self):
        response = {"ok": False, "error": {"code": "contentModified",
                    "message": "checkpoint saved, document changed",
                    "data": {"saved": self.receipt, "closed": False}}}
        result = self.exchange("stderr-fails", response)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(json.loads(result.stdout), self.public_response(response))
        self.assertEqual(json.loads(result.stdout)["error"]["data"]["saved"], self.receipt)

    def test_optional_stderr_failure_preserves_unconfirmed_delivery(self):
        result = self.exchange("stderr-fails", None)
        self.assertEqual(result.returncode, 1, result.stderr)
        response = json.loads(result.stdout)
        self.assertEqual(response["client_request_id"], "writer-test")
        self.assertEqual(response["error"]["code"], "brokerUnavailable")
        self.assertIs(response["error"]["data"]["operationMayHaveCompleted"], True)
        self.assertIn("operation may have completed", response["error"]["message"])

    def test_projection_failure_preserves_observed_save_receipt(self):
        response = {"ok": True, "result": {"module": "Main", "sourceHash": "saved-source"},
                    "fileProgress": {"updates": 2, "done": True}}
        result = self.exchange("stdout", response)
        self.assertEqual(result.returncode, 1, result.stderr)
        failure = json.loads(result.stdout)["error"]
        self.assertEqual(failure["code"], "invalidResult")
        self.assertEqual(failure["data"]["observed_response"], response)
        self.assertEqual(failure["document_progress"], {"updates": 2, "done": True})

    def test_final_stdout_write_is_never_replaced(self):
        for response in [{"ok": True, "result": self.receipt},
                         {"ok": False, "error": {"code": "contentModified",
                          "message": "checkpoint saved", "data": {"saved": self.receipt}}}]:
            for stream in ["stdout-fails", "stdout-flush-fails"]:
                with self.subTest(response=response, stream=stream):
                    result = self.exchange(stream, response)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("fixture response write attempts: 1", result.stderr)
                    self.assertIn("could not write the final JSON response", result.stderr)
                    self.assertNotIn("operation may have completed", result.stderr)
                    if stream == "stdout-flush-fails":
                        self.assertEqual(json.loads(result.stdout), self.public_response(response))
                    else:
                        self.assertEqual(len(result.stdout), 12, result.stdout)

    def test_owner_cleanup_failure_after_final_output_never_replaces_reply(self):
        for stream in ["stdout-fails", "stdout-flush-fails"]:
            with self.subTest(stream=stream):
                result = subprocess.run(
                    [str(self.binary.resolve()), "--cli-error", "owner-output", stream],
                    cwd=REPO_ROOT, capture_output=True, text=True, timeout=15,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("fixture owner cleanup failed", result.stderr)
                self.assertIn("fixture response write attempts: 1", result.stderr)
                self.assertNotIn("uncaught exception:", result.stderr)
                if stream == "stdout-flush-fails":
                    self.assertEqual(json.loads(result.stdout), {"ok": True, "result": {"state": "running"}})
                else:
                    self.assertEqual(len(result.stdout), 12, result.stdout)


if __name__ == "__main__":
    unittest.main()
