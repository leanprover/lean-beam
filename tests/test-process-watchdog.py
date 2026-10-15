#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise the watchdog through real child processes, including inherited output."""

import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


HELPER = Path(__file__).parent / "lib" / "process_watchdog.py"
spec = importlib.util.spec_from_file_location("process_watchdog", HELPER)
watchdog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watchdog)


class ProcessWatchdog(unittest.TestCase):
    def run_python(self, code, timeout=5):
        return watchdog.run_with_watchdog([sys.executable, "-c", code], timeout=timeout)

    def test_success_keeps_stdout_and_diagnostic_stderr(self):
        result = self.run_python("import sys; print('ok'); print('diagnostic', file=sys.stderr)")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "ok\n")
        self.assertEqual(result.stderr, "diagnostic\n")

    def test_nonzero_exit_is_preserved(self):
        result = self.run_python("import sys; print('failure', file=sys.stderr); sys.exit(7)")
        self.assertEqual(result.returncode, 7)
        self.assertIn("failure", result.stderr)

    def test_output_capture_is_bounded(self):
        result = self.run_python("print('x' * (2 * 1024 * 1024)); print('retained tail')")
        self.assertLess(len(result.stdout), 1024 * 1024 + 100)
        self.assertTrue(result.stdout.endswith("retained tail\n"))

    def test_success_does_not_wait_for_inherited_output_eof(self):
        with tempfile.TemporaryDirectory(prefix="beam-watchdog-inherited-") as directory:
            pid_file = Path(directory) / "holder.pid"
            code = f"""
import subprocess, sys
from pathlib import Path
holder = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
Path({str(pid_file)!r}).write_text(str(holder.pid))
print('completed with inherited output')
"""
            try:
                result = self.run_python(code, timeout=2)
                self.assertEqual(result.returncode, 0)
                self.assertIn("completed with inherited output", result.stdout)
            finally:
                if pid_file.exists():
                    # This PID comes only from the owned fixture above.
                    pid = int(pid_file.read_text())
                    if os.name == "posix":
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    else:
                        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                       timeout=5, check=False)

    def test_timeout_covers_inherited_pipes_and_partial_output(self):
        code = """
import subprocess, sys, time
subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
print('partial response', end='', flush=True)
print('diagnostic before stall', file=sys.stderr, flush=True)
time.sleep(60)
"""
        # Supervise the watchdog itself; files keep its descendants out of communicate().
        with tempfile.TemporaryDirectory(prefix="beam-watchdog-test-") as directory:
            root = Path(directory)
            script = root / "child.py"
            script.write_text(code)
            with (root / "out").open("w+b") as out, (root / "err").open("w+b") as err:
                result = subprocess.run([sys.executable, str(HELPER), "--timeout", "2", "--",
                                         sys.executable, str(script)],
                                        stdout=out, stderr=err, timeout=15)
                out.seek(0)
                err.seek(0)
                self.assertEqual(result.returncode, 124)
                self.assertIn(b"partial response", out.read())
                stderr = err.read()
                self.assertIn(b"diagnostic before stall", stderr)
                self.assertIn(b"external watchdog expired after 2 seconds", stderr)
                self.assertNotIn(b"watchdog cleanup failed", stderr)

    def test_invalid_timeout_does_not_launch(self):
        for timeout in (0, -1, float("inf"), float("nan")):
            with self.subTest(timeout=timeout), self.assertRaises(ValueError):
                self.run_python("raise AssertionError('must not run')", timeout)


if __name__ == "__main__":
    unittest.main()
