#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Timing must preserve failures, caller cleanup, and compact successful logs."""

import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

STEPS = Path(__file__).resolve().parent / "lib/ci-steps.sh"


class StepTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beam-ci-steps-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.env = dict(os.environ, TMPDIR=str(self.root), BEAM_TEST_SUITE="timing-test")
        self.env.pop("GITHUB_ACTIONS", None)

    def run_shell(self, source):
        return subprocess.run(["bash", "-eu", "-c", f". {shlex.quote(str(STEPS))}\n{source}"],
                              env=self.env, text=True, capture_output=True, timeout=10)

    def command(self, code):
        program = f"import sys; print('child stdout'); print('child stderr', file=sys.stderr); sys.exit({code})"
        return f"{shlex.quote(sys.executable)} -c {shlex.quote(program)}"

    def test_quiet_success_keeps_timing_and_removes_capture(self):
        result = self.run_shell(f"run_quiet_step 'leaf with spaces' {self.command(0)}")
        self.assertEqual(result.returncode, 0, result)
        self.assertIn("[timing-test] leaf with spaces\n", result.stdout)
        self.assertRegex(result.stdout, r"leaf with spaces finished in \d+s")
        self.assertNotIn("child stdout", result.stdout)
        self.assertEqual(result.stderr, "")
        self.assertEqual(list(self.root.iterdir()), [])

    def test_failure_preserves_status_output_and_caller_exit_trap(self):
        self.env["GITHUB_ACTIONS"] = "true"
        result = self.run_shell(f"""
trap 'printf "caller cleanup\\n"' EXIT
run_quiet_step 'failing leaf' {self.command(73)}
printf 'must not run\\n'
""")
        self.assertEqual(result.returncode, 73, result)
        self.assertIn("child stdout", result.stderr)
        self.assertIn("child stderr", result.stderr)
        self.assertIn("exit status 73", result.stderr)
        self.assertIn("::group::failing leaf\n", result.stdout)
        self.assertIn("::endgroup::\n", result.stdout)
        self.assertIn("caller cleanup\n", result.stdout)
        self.assertNotIn("must not run", result.stdout)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_conditional_caller_keeps_status_and_errexit(self):
        for helper in ["run_step", "run_quiet_step"]:
            with self.subTest(helper=helper):
                result = self.run_shell(f"""
if {helper} leaf {self.command(73)}; then exit 99; else rc=$?; fi
printf 'observed status %s\\n' "$rc"
false
printf 'must not run\\n'
""")
                self.assertEqual(result.returncode, 1, result)
                self.assertIn("observed status 73\n", result.stdout)
                self.assertNotIn("must not run", result.stdout)

    def test_capture_cleanup_failure_does_not_replace_command_failure(self):
        binary = self.root / "bin"
        binary.mkdir()
        remove = binary / "rm"
        remove.write_text("#!/usr/bin/env bash\nexit 19\n")
        remove.chmod(0o755)
        self.env["PATH"] = str(binary) + os.pathsep + self.env["PATH"]
        for command_status, expected in [(73, 73), (0, 19)]:
            with self.subTest(command_status=command_status):
                result = self.run_shell(f"run_quiet_step leaf {self.command(command_status)}")
                self.assertEqual(result.returncode, expected, result)

    def test_capture_creation_failure_does_not_run_command(self):
        self.env["GITHUB_ACTIONS"] = "true"
        result = self.run_shell(f"""
mktemp() {{ printf 'fixture capture creation failed\\n' >&2; return 23; }}
trap 'printf "caller cleanup\\n"' EXIT
run_quiet_step leaf {self.command(0)}
printf 'must not run\\n'
""")
        self.assertEqual(result.returncode, 23, result)
        self.assertIn("fixture capture creation failed", result.stderr)
        self.assertNotIn("child stdout", result.stdout + result.stderr)
        self.assertNotIn("child stderr", result.stdout + result.stderr)
        self.assertIn("::endgroup::\n", result.stdout)
        self.assertIn("caller cleanup\n", result.stdout)
        self.assertNotIn("must not run", result.stdout)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_disabled_errexit_stays_disabled(self):
        for helper in ["run_step", "run_quiet_step"]:
            for status in [0, 73]:
                with self.subTest(helper=helper, status=status):
                    result = self.run_shell(f"""
set +e
{helper} leaf {self.command(status)}
rc=$?
printf 'observed status %s\\n' "$rc"
case "$-" in *e*) exit 99 ;; esac
false
printf 'caller continues\\n'
""")
                    self.assertEqual(result.returncode, 0, result)
                    self.assertIn(f"observed status {status}\n", result.stdout)
                    self.assertIn("caller continues\n", result.stdout)
                    self.assertEqual(list(self.root.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
