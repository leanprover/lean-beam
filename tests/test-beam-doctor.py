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

    def doctor(self, *selectors, stdout=subprocess.PIPE, json_output=False, pretty=False, args=()):
        return subprocess.run(
            [str(self.cli), *(["--pretty"] if pretty else []), "--root", str(self.project),
             *selectors, "doctor", *args, *(["--json"] if json_output else [])],
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
            result = self.doctor(stdout=output, json_output=True)
        report = "\n".join(json.loads(output_path.read_text())["error"]["data"]["diagnostics"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unavailable locally", json.loads(output_path.read_text())["error"]["message"])
        self.assertEqual(result.stderr, "")
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
        result = self.doctor(json_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not resolve Lean project", json.loads(result.stdout)["error"]["message"])
        self.assertEqual(result.stderr, "")
        report = "\n".join(json.loads(result.stdout)["error"]["data"]["diagnostics"])
        self.assertIn("daemon status: recovery required", report)
        self.assertIn("unsupported session descriptor schemaVersion 999", report)
        self.assertIn("daemon incidents: none", report)
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
        result = self.doctor("--session-dir", str(control), json_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not resolve Lean project", json.loads(result.stdout)["error"]["message"])
        self.assertEqual(result.stderr, "")
        report = "\n".join(json.loads(result.stdout)["error"]["data"]["diagnostics"])
        self.assertIn(f"registry: {descriptor}", report)
        report = "\n".join(json.loads(result.stdout)["error"]["data"]["diagnostics"])
        self.assertIn("daemon status: recovery required", report)
        self.assertIn(f"daemon incident: {incident}", report)
        after = {
            path.relative_to(control): path.read_bytes()
            for path in control.rglob("*") if path.is_file()
        }
        self.assertEqual(before, after)
        self.assertEqual(before_paths, {path.relative_to(control) for path in control.rglob("*")})
        self.assertFalse((self.project / ".beam").exists())
        self.assertFalse(self.elan_log.exists())

    def test_default_failure_is_one_text_report(self):
        (self.project / "lean-toolchain").write_text("missing-doctor-compiler\n")
        result = self.doctor()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr.count("unavailable locally"), 1)
        self.assertIn("daemon status: absent", result.stderr)
        self.assertIn("daemon incidents: none", result.stderr)
        self.assertNotIn('"ok"', result.stderr)
        self.assertFalse((self.project / ".beam").exists())
        self.assertFalse(self.elan_log.exists())

    def test_success_text_and_json_have_the_same_diagnostics(self):
        record = json.loads((self.cli.parent.parent / "manifest.json").read_text())
        compiler = Path(record["components"]["targets"][0]["lean"]).parent.parent
        (self.project / "lean-toolchain").write_text(str(compiler) + "\n")
        text = self.doctor()
        self.assertEqual(text.returncode, 0, text.stderr)
        self.assertEqual(text.stderr, "")
        self.assertIn("target membership: present", text.stdout)
        for pretty in [False, True]:
            result = self.doctor(json_output=True, pretty=pretty)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            value = json.loads(result.stdout)
            self.assertTrue(value["ok"])
            self.assertEqual(value["result"]["diagnostics"], text.stdout.splitlines())
            self.assertEqual(result.stdout.count("\n") > 1, pretty)
        self.assertEqual(self.doctor(pretty=True).stdout, text.stdout)
        self.assertFalse((self.project / ".beam").exists())
        self.assertFalse(self.elan_log.exists())

    def test_argument_errors_respect_the_selected_format(self):
        for pretty in [False, True]:
            result = self.doctor(args=("--unknown",), pretty=pretty)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertIn("doctor [--json]", result.stderr)
            result = self.doctor(args=("--unknown",), json_output=True, pretty=pretty)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalidParams")
            self.assertEqual(result.stdout.count("\n") > 1, pretty)
        for json_output in [False, True]:
            args = [str(self.cli), "--root", str(self.project / "missing"), "doctor"]
            if json_output: args.append("--json")
            result = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, 2)
            if json_output:
                self.assertEqual(result.stderr, "")
                self.assertEqual(json.loads(result.stdout)["error"]["code"], "invalidParams")
            else:
                self.assertEqual(result.stdout, "")
                self.assertIn("beam:", result.stderr)

    def test_failed_output_never_appends_json(self):
        fixture = REPO_ROOT / ".lake/build/bin/beam-cli-daemon-test"
        for mode in ["text", "json"]:
            for stream in ["stdout-fails", "stdout-flush-fails"]:
                with self.subTest(mode=mode, stream=stream):
                    result = subprocess.run([str(fixture), "--doctor-report-output", mode, stream],
                                            cwd=self.project, env=self.env, text=True,
                                            capture_output=True, timeout=15)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("fixture response write attempts: 1", result.stderr)
                    self.assertNotIn('"ok":false', result.stdout)
                    self.assertNotIn('"ok": false', result.stdout)
                    if mode == "json" and stream == "stdout-flush-fails":
                        self.assertTrue(json.loads(result.stdout)["ok"])


if __name__ == "__main__":
    unittest.main()
