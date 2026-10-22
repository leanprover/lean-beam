#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""CLI process-boundary regressions, using the same installed runtime as the fast suite."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from installation_fixture import stage

REPO = Path(__file__).resolve().parents[1]


class CliErrorsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="beam-cli-errors-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        installation = Path(os.environ.get("BEAM_TEST_INSTALLATION", cls.root / "installation"))
        if "BEAM_TEST_INSTALLATION" not in os.environ:
            stage(installation)
        cls.cli = installation / "libexec" / ("beam-cli.exe" if os.name == "nt" else "beam-cli")
        cls.fixture = REPO / ".lake/build/bin" / ("beam-cli-daemon-test.exe" if os.name == "nt" else "beam-cli-daemon-test")
        cls.env = dict(os.environ, BEAM_PROGRESS="0")
        cls.env.pop("BEAM_SESSION_ROOT", None)
        cls.env.pop("BEAM_REQUEST_ID", None)

    def invoke(self, *args, executable=None):
        return subprocess.run([str(executable or self.cli), *map(str, args)], cwd=self.root,
                              env=self.env, text=True, capture_output=True, timeout=15)

    def failure(self, result, code, exit_code):
        self.assertEqual(result.returncode, exit_code, result.stderr)
        response = json.loads(result.stdout)  # Reject duplicate JSON and partial human stdout.
        self.assertIs(response["ok"], False)
        self.assertEqual(response["error"]["code"], code, response)
        self.assertNotIn("uncaught exception:", result.stderr)
        self.assertEqual(sum(line.startswith(("beam:", "beam[")) for line in result.stderr.splitlines()), 1)
        return response["error"]

    def test_help_and_version_succeed(self):
        for args in [("--help",), ("help",), ("--version",), ("version",)]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout)

    def test_usage_is_short_and_names_command(self):
        for args, detail in [((), "a command is required"), (("synk",), "synk"),
                             (("sync",), "sync"), (("hover", "Main.lean"), "hover"),
                             (("--root",), "--root"), (("--session-dir",), "--session-dir"),
                             (("recover", "--wrong"), "--wrong"),
                             (("feedback-report", "--input"), "--input"),
                             (("feedback-report", "--unknown"), "--unknown")]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                error = self.failure(result, "invalidParams", 2)
                self.assertIn(detail, error["message"])
                self.assertLess(len(result.stderr), 600)

    def test_bad_numbers_and_enums_precede_project_selection(self):
        for args, detail in [
            (("hover", "Main.lean", "1", "-1", "0"), "-1"),
            (("run-at", "Main.lean", "one", "0", "0", "#check 1"), "one"),
            (("todo", "Main.lean", "1", "0", "0", "1", "0", "--kind", "alien"), "alien"),
            (("goals", "unknown", "Main.lean", "1", "0", "0"), "unknown"),
        ]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertIn(detail, self.failure(result, "invalidParams", 2)["message"])
                self.assertIn("usage:", result.stderr)

    def test_root_file_and_text_file_have_input_context(self):
        root_file = self.root / "root-file"
        root_file.write_text("not a workspace")
        result = self.invoke("--root", root_file, "status")
        error = self.failure(result, "invalidParams", 2)
        self.assertIn("workspace root is not a directory", error["message"])
        self.assertIn(str(root_file), error["message"])
        missing = self.root / "missing-text"
        result = self.invoke("run-at", "Main.lean", "1", "0", "0", "--text-file", missing)
        error = self.failure(result, "invalidParams", 2)
        self.assertIn("--text-file", error["message"])
        self.assertIn(str(missing), error["message"])

    def test_invalid_handle_has_one_usage_response(self):
        result = self.invoke("run-with", "Main.lean", "{invalid", "simp")
        self.assertIn("handle", self.failure(result, "invalidParams", 2)["message"])

    def test_no_live_owner_has_distinct_exit_and_exact_remedy(self):
        result = self.invoke("--root", self.root, "stats")
        error = self.failure(result, "noLiveSession", 3)
        self.assertIn(f"lean-beam --root '{self.root}' --session-dir '{self.root / '.beam'}' serve", error["message"])
        self.assertFalse((self.root / ".beam").exists())

    def test_absent_status_and_stop_still_succeed(self):
        for command in ("status", "stop"):
            result = self.invoke("--root", self.root, command)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIs(json.loads(result.stdout)["ok"], True)
            self.assertFalse((self.root / ".beam").exists())

    @unittest.skipIf(os.name == "nt", "POSIX mode observation")
    def test_unsafe_directory_is_rejected_without_repair(self):
        session = self.root / "unsafe"
        session.mkdir(mode=0o755)
        session.chmod(0o755)
        result = self.invoke("--root", self.root, "--session-dir", session, "status")
        error = self.failure(result, "setupError", 1)
        self.assertIn("expected 0700", error["message"])
        self.assertEqual(session.stat().st_mode & 0o777, 0o755)
        self.assertEqual(list(session.iterdir()), [])

    def test_unexpected_io_fault_stays_internal(self):
        result = self.invoke("--cli-error", "internal", executable=self.fixture)
        self.assertEqual(self.failure(result, "internalError", 1)["message"], "fixture unexpected fault")

    def test_broker_failure_code_and_data_survive(self):
        result = self.invoke("--cli-error", "broker", executable=self.fixture)
        self.assertEqual(self.failure(result, "fileChanged", 1)["data"], {"version": 7})
        response = json.loads(result.stdout)
        self.assertEqual(response["clientRequestId"], "fixture-request")
        self.assertEqual(response["fileProgress"], {"updates": 9, "done": False})

    def test_semantic_failure_is_a_completed_response(self):
        result = self.invoke("--cli-error", "semantic", executable=self.fixture)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": True, "result": {"success": False}})


if __name__ == "__main__":
    unittest.main()
