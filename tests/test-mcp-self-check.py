#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Supervise self-check fixtures outside Lean, including its runtime shutdown."""

from __future__ import annotations

import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


BINARY = Path(".lake/build/bin/beam-mcp-protocol-test").resolve()


@unittest.skipUnless(os.name == "posix", "fixture cleanup uses an owned POSIX process group")
class SelfCheckLifecycle(unittest.TestCase):
    def run_fixture(self, mode: str, timeout_ms: int = 300) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory(prefix="beam-self-check-") as directory:
            root = Path(directory)
            child_pid = root / "child.pid"
            holder_pid = root / "holder.pid"
            env = dict(os.environ, LEAN_BEAM_MCP_SELF_CHECK_TIMEOUT_MS=str(timeout_ms),
                       BEAM_SELF_CHECK_CHILD_PID=str(child_pid),
                       BEAM_SELF_CHECK_HOLDER_PID=str(holder_pid))
            # Files also keep a broken fixture's inherited output from hanging communicate().
            with (root / "stdout").open("w+b") as out, (root / "stderr").open("w+b") as err:
                proc = subprocess.Popen([str(BINARY), "--self-check-parent", mode],
                                        env=env, stdout=out, stderr=err, start_new_session=True)
                try:
                    start = time.monotonic()
                    try:
                        proc.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        self.fail(f"{mode}: whole CLI (including runtime shutdown) exceeded 4 s")
                    if timeout_ms == 300:
                        self.assertLess(time.monotonic() - start, 2,
                                        f"{mode}: CLI exceeded phase and cleanup bounds")
                    if child_pid.exists():
                        with self.assertRaises(ProcessLookupError,
                                               msg=f"{mode}: direct child was not reaped"):
                            os.kill(int(child_pid.read_text()), 0)
                    if holder_pid.exists():
                        # Prove that completion did not depend on inherited pipe EOF.
                        os.kill(int(holder_pid.read_text()), 0)
                    out.seek(0)
                    err.seek(0)
                    return proc.returncode, out.read().decode(), err.read().decode()
                finally:
                    # Only this fixture's session; descendants intentionally outlive the CLI.
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait(timeout=2)

    def test_success_with_diagnostics_and_inherited_pipes(self):
        for mode in ("logged-success", "stderr-flood", "inherited-stderr", "inherited-both",
                     "shutdown-stdout-flood"):
            with self.subTest(mode=mode):
                code, out, err = self.run_fixture(mode, 2000)
                self.assertEqual(code, 0, err)
                self.assertIn("Lean Beam MCP self-check passed", out)
                self.assertEqual(err, "")

    def test_failure_retains_bounded_diagnostics(self):
        code, _, err = self.run_fixture("stderr-failure", 2000)
        self.assertNotEqual(code, 0)
        self.assertIn("RETAINED-STDERR-TAIL", err)
        self.assertNotIn("DISCARDED-STDERR-PREFIX", err)
        self.assertLess(len(err.encode()), 20000)

    def test_absolute_deadlines_and_cleanup(self):
        for mode, phase in (("discovery-notifications", "server/discover response"),
                            ("sync-notifications", "lean_sync response"),
                            ("notification-flood", "server/discover response"),
                            ("partial-line", "server/discover response"),
                            ("inherited-stdout", "server/discover response"),
                            ("shutdown-stall", "EOF teardown")):
            with self.subTest(mode=mode):
                code, _, err = self.run_fixture(mode)
                self.assertNotEqual(code, 0)
                self.assertIn(f"timed out after 300 ms waiting for lean-beam-mcp self-check {phase}", err)
                self.assertNotIn("cleanup failed", err)

    def test_nonzero_exit_is_independent_of_stderr_eof(self):
        for mode in ("shutdown-failure", "failure-inherited-stderr"):
            with self.subTest(mode=mode):
                code, _, err = self.run_fixture(mode)
                self.assertNotEqual(code, 0)
                self.assertIn("child exited with code", err)
                self.assertIn("self-check shutdown failure fixture", err)
                self.assertNotIn("cleanup failed", err)

    def test_pipe_backpressure_does_not_block_the_controller(self):
        for mode in ("pipe-backpressure", "closed-pipe"):
            with self.subTest(mode=mode):
                code, _, err = self.run_fixture(mode)
                self.assertEqual(code, 0, err)

    def test_malformed_bytes_and_frame_limit(self):
        for mode, message in (("invalid-utf8", "invalid UTF-8"),
                              ("oversize-frame", "response exceeds 1 MiB")):
            with self.subTest(mode=mode):
                code, _, err = self.run_fixture(mode, 2000)
                self.assertNotEqual(code, 0)
                self.assertIn(message, err)
                self.assertNotIn("PANIC", err)


if __name__ == "__main__":
    unittest.main()
