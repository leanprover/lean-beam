#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

from pathlib import Path
import signal
import subprocess
import sys
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
        self.check_mode("throw")

    @unittest.skipIf(sys.platform == "win32", "requires POSIX signal delivery")
    def test_delivery_and_later_watcher_are_isolated(self):
        for name in ["INT", "TERM", "HUP"]:
            with self.subTest(signal=name):
                self.check_mode("signal-" + name, getattr(signal, "SIG" + name))


if __name__ == "__main__":
    unittest.main()
