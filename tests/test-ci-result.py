#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Guard the required CI result against missing, skipped, or cancelled coverage."""

import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/ci-result.py"
spec = importlib.util.spec_from_file_location("ci_result", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class RequiredCiTest(unittest.TestCase):
    def test_success(self):
        self.assertEqual(gate.failed_jobs({"beam-fast": {"result": "success"}}, False), {})

    def test_required_jobs_cannot_be_skipped_or_cancelled(self):
        for result in ["failure", "cancelled", "skipped", "timed_out", None]:
            with self.subTest(result=result):
                jobs = {"beam-fast": {"result": result}}
                self.assertEqual(gate.failed_jobs(jobs, True), {"beam-fast": result})

    def test_mac_skip_is_explicit(self):
        jobs = {"macos-platform": {"result": "skipped"}}
        self.assertEqual(gate.failed_jobs(jobs, True), {})
        self.assertEqual(gate.failed_jobs(jobs, False), {"macos-platform": "skipped"})

    def test_missing_or_malformed_results_fail(self):
        for results in [{}, [], None, {"beam-fast": None}]:
            with self.subTest(results=results), self.assertRaises(ValueError):
                gate.failed_jobs(results, False)

    def test_entrypoint_mac_policy(self):
        for profile, full, expected in [("skip", "", 0), ("full", "true", 0),
                                        ("platform", "", 1), ("", "", 1)]:
            with self.subTest(profile=profile, full=full):
                result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(
                    os.environ, JOB_RESULTS=json.dumps({"macos-platform": {"result": "skipped"}}),
                    MACOS_PROFILE=profile, FULL_MACOS=full), capture_output=True, text=True)
                self.assertEqual(result.returncode, expected, result)
        result = subprocess.run([sys.executable, str(SCRIPT)], env=dict(
            os.environ, JOB_RESULTS="not JSON"), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, result)

    def test_workflow_gate_waits_for_every_ci_job(self):
        # A future matrix/job must not silently fall outside the required aggregate.
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        job_ids = set(re.findall(r"^  ([A-Za-z_][A-Za-z0-9_-]*):$",
                                 workflow.split("jobs:\n", 1)[1], re.MULTILINE))
        aggregate = workflow.split("  ci-result:\n", 1)[1]
        dependency_block = aggregate.split("    needs:\n", 1)[1].split("    runs-on:", 1)[0]
        dependencies = set(re.findall(r"^      - ([A-Za-z_][A-Za-z0-9_-]*)$",
                                      dependency_block, re.MULTILINE))
        self.assertEqual(dependencies, job_ids - {"ci-result"})
        self.assertIn("if: ${{ always() }}", aggregate)
        self.assertIn("run: python3 scripts/ci-result.py", aggregate)
        self.assertIn("uses: actions/checkout@", aggregate)
        self.assertIn("  merge_group:\n    types: [checks_requested]", workflow)


if __name__ == "__main__":
    unittest.main()
