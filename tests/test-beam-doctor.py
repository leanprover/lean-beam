#!/usr/bin/env python3
"""Project doctor keeps session evidence visible when Lean setup cannot be inspected."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from installation_fixture import stage


REPO_ROOT = Path(__file__).resolve().parents[1]


class PartialSetupDoctorTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beam-doctor-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        installation = Path(os.environ["BEAM_TEST_INSTALLATION"]) if "BEAM_TEST_INSTALLATION" in os.environ else self.root / "installation"
        if "BEAM_TEST_INSTALLATION" not in os.environ:
            stage(installation)
        self.cli = installation / "libexec/beam-cli"
        self.project = self.root / "project"
        self.project.mkdir()
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        elan = fake_bin / "elan"
        elan.write_text(
            '#!/bin/sh\n'
            'printf "%s\\n" "$*" >> "$BEAM_TEST_ELAN_LOG"\n'
            'echo "fixture: toolchain is not installed" >&2\n'
            'exit 1\n'
        )
        elan.chmod(0o755)
        self.elan_log = self.root / "elan.log"
        self.env = dict(os.environ)
        self.env.update(
            BEAM_HOME=str(REPO_ROOT),
            HOME=str(self.root / "home"),
            ELAN_HOME=str(self.root / "elan"),
            PATH=str(fake_bin) + os.pathsep + os.environ["PATH"],
            BEAM_TEST_ELAN_LOG=str(self.elan_log),
        )
        self.env.pop("BEAM_SESSION_ROOT", None)

    def doctor(self, *selectors, stdout=subprocess.PIPE):
        return subprocess.run(
            [str(self.cli), "--root", str(self.project), *selectors, "doctor"],
            env=self.env,
            text=True,
            stdout=stdout,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )

    def test_unavailable_target_preserves_session_report_without_probe(self):
        (self.project / "lakefile.toml").write_text('name = "doctor_fixture"\n')
        toolchain = (REPO_ROOT / "lean-toolchain").read_text()
        (self.project / "lean-toolchain").write_text(toolchain)
        output_path = self.root / "doctor.stdout"
        with output_path.open("w") as output:
            result = self.doctor(stdout=output)
        report = output_path.read_text()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unavailable locally", result.stderr)
        self.assertIn("daemon status: absent", report)
        self.assertIn("daemon incidents: none", report)
        self.assertFalse(self.elan_log.exists(), "doctor must never invoke elan")
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
        self.assertIn("could not resolve Lean project", result.stderr)
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
        self.assertIn("could not resolve Lean project", result.stderr)
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
