#!/usr/bin/env python3
"""Project doctor keeps session evidence visible when Lean setup cannot be inspected."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
CLI = REPO_ROOT / ".lake/build/bin/beam-cli"


class PartialSetupDoctorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beam-doctor-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        elan = fake_bin / "elan"
        elan.write_text(
            '#!/bin/sh\n'
            'printf "%s\\n" "$*" >> "$BEAM_TEST_ELAN_LOG"\n'
            'if [ -n "${BEAM_TEST_DOCTOR_STDOUT:-}" ]; then\n'
            '  if ! grep -Fq "daemon status: absent" "$BEAM_TEST_DOCTOR_STDOUT" || '
            '! grep -Fq "daemon incidents: none" "$BEAM_TEST_DOCTOR_STDOUT"; then\n'
            '    echo "fixture: session report missing before toolchain probe" >&2\n'
            '    exit 2\n'
            '  fi\n'
            'fi\n'
            'echo "fixture: toolchain is not installed" >&2\n'
            'exit 1\n'
        )
        elan.chmod(0o755)
        self.elan_log = self.root / "elan.log"
        self.env = dict(os.environ)
        self.env.update(
            BEAM_HOME=str(REPO_ROOT),
            HOME=str(self.root / "home"),
            PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
            BEAM_TEST_ELAN_LOG=str(self.elan_log),
        )
        self.env.pop("BEAM_SESSION_ROOT", None)

    def doctor(self, *selectors, stdout=subprocess.PIPE):
        return subprocess.run(
            [str(CLI), "--root", str(self.project), *selectors, "doctor"],
            env=self.env,
            text=True,
            stdout=stdout,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )

    def test_missing_toolchain_flushes_session_report_before_probe(self):
        (self.project / "lakefile.toml").write_text('name = "doctor_fixture"\n')
        toolchain = (REPO_ROOT / "lean-toolchain").read_text()
        (self.project / "lean-toolchain").write_text(toolchain)
        output_path = self.root / "doctor.stdout"
        self.env["BEAM_TEST_DOCTOR_STDOUT"] = str(output_path)
        with output_path.open("w") as output:
            result = self.doctor(stdout=output)
        report = output_path.read_text()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture: toolchain is not installed", result.stderr)
        self.assertIn("daemon status: absent", report)
        self.assertIn("daemon incidents: none", report)
        self.assertEqual(
            self.elan_log.read_text().splitlines(),
            [f"run {toolchain.strip()} lean --version"],
        )
        self.assertFalse((self.project / ".beam").exists())
        self.assertEqual((self.project / "lean-toolchain").read_text(), toolchain)

    def test_missing_project_markers_preserves_recovery_report(self):
        control = self.project / ".beam"
        control.mkdir(mode=0o700)
        descriptor = control / "beam-daemon.json"
        contents = json.dumps({"schemaVersion": 999})
        descriptor.write_text(contents)
        descriptor.chmod(0o600)
        result = self.doctor()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing lean-toolchain", result.stderr)
        self.assertIn("daemon status: recovery required", result.stdout)
        self.assertIn("unsupported session descriptor schemaVersion 999", result.stdout)
        self.assertIn("daemon incidents: none", result.stdout)
        self.assertEqual(descriptor.read_text(), contents)
        self.assertEqual(sorted(path.name for path in control.iterdir()), ["beam-daemon.json"])
        self.assertFalse(self.elan_log.exists())

    def test_missing_markers_reports_selected_incident_without_writes(self):
        control = self.root / "selected-session"
        control.mkdir(mode=0o700)
        descriptor = control / "beam-daemon.json"
        contents = json.dumps({"schemaVersion": 999})
        descriptor.write_text(contents)
        descriptor.chmod(0o600)
        incidents = control / "daemon-failures"
        incidents.mkdir(mode=0o700)
        incident = incidents / "20261016-fixture.json"
        incident.write_text('{}\n')
        before = {
            path.relative_to(control): path.read_bytes()
            for path in control.rglob("*") if path.is_file()
        }
        before_paths = {path.relative_to(control) for path in control.rglob("*")}
        result = self.doctor("--session-dir", str(control))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing lean-toolchain", result.stderr)
        self.assertIn(f"registry: {descriptor}", result.stdout)
        self.assertIn("daemon status: recovery required", result.stdout)
        self.assertIn(f"daemon incident: {incident}", result.stdout)
        after = {
            path.relative_to(control): path.read_bytes()
            for path in control.rglob("*") if path.is_file()
        }
        self.assertEqual(before, after)
        self.assertEqual(before_paths, {path.relative_to(control) for path in control.rglob("*")})
        self.assertFalse((self.project / ".beam").exists())
        self.assertFalse(self.elan_log.exists())


if __name__ == "__main__":
    unittest.main()
