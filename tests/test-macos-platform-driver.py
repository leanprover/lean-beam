#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Check platform driver boundaries, cleanup, failure propagation, and stdio repetition limits."""

from collections import Counter
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
native_spec = importlib.util.spec_from_file_location("native_qualification", ROOT / "tests/test-native-toolchain.py")
native = importlib.util.module_from_spec(native_spec)
native_spec.loader.exec_module(native)
RECORDER = '''import json, os, sys
from pathlib import Path
kind = Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["BEAM_PROFILE_LOG"], "a") as log:
    log.write(json.dumps({"command": kind, "args": args,
                          "session_root": os.environ.get("BEAM_SESSION_ROOT")}) + "\\n")
if kind == "lake":
    for arg in args:
        if arg.startswith("beam-"):
            binary = Path(".lake/build/bin") / arg
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_text(Path(__file__).read_text())
            binary.chmod(0o755)
if os.environ.get("BEAM_PROFILE_FAIL") in [kind, *args]:
    sys.exit(73)
'''


class PlatformDriverTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beam-profile-driver-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "tests/lib").mkdir(parents=True)
        for relative in ["tests/test-macos-platform.sh", "tests/lib/ci-steps.sh"]:
            shutil.copy2(ROOT / relative, self.root / relative)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["lake", "python3"]:
            script = self.bin / name
            script.write_text(f"#!{sys.executable}\n" + RECORDER)
            script.chmod(0o755)
        (self.root / "tests/test-beam-prune.sh").write_text(
            '#!/usr/bin/env bash\nprintf \'{"command":"prune","args":[],"session_root":"%s"}\\n\' '
            '"$BEAM_SESSION_ROOT" >> "$BEAM_PROFILE_LOG"\n')
        self.log = self.root / "commands.jsonl"

    def run_driver(self, failure=None):
        self.log.write_text("")
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   BEAM_PROFILE_LOG=str(self.log), BEAM_PROFILE_FAIL=failure or "")
        result = subprocess.run(["bash", "tests/test-macos-platform.sh"], cwd=self.root,
                                env=env, capture_output=True, text=True, timeout=30)
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(records, result)
        self.assertFalse(Path(records[0]["session_root"]).parent.exists(), result)
        return result, records

    def test_platform_boundaries_and_owned_cleanup(self):
        result, records = self.run_driver()
        self.assertEqual(result.returncode, 0, result)
        build = records[0]
        self.assertEqual(build["command"], "lake")
        for target in ["beam-cli-daemon-test", "beam-installation-stage-fixture",
                       "beam-lake-helper-client-fixture"]:
            self.assertIn(target, build["args"])
        commands = [(r["command"], r["args"]) for r in records]
        self.assertIn(("python3", ["tests/test-installation-entrypoints.py"]), commands)
        self.assertIn(("python3", ["tests/lib/process_watchdog.py", "--timeout", "90", "--",
                                  ".lake/build/bin/beam-cli-daemon-test"]), commands)
        self.assertEqual(records[-1]["command"], "prune")

        # Compose the real native preflight with the actual shell driver's recorded calls.
        # Each source contract must have exactly one owner in the representative profile.
        sdk = self.root / "providing SDK"
        env = {"LEAN_SYSROOT": str(sdk)}
        with mock.patch.object(native, "run") as run:
            native.run_ordinary_source_checks(sdk, env)
        leaves = []
        for record in records[1:]:
            if record["command"] == "prune":
                leaves.append("test-beam-prune.sh")
            else:
                arguments = record["args"]
                leaves.append(Path(arguments[-1] if "--" in arguments else arguments[0]).name)
        for call in run.call_args_list:
            arguments = list(map(str, call.args[0]))
            self.assertIs(call.kwargs["env"], env)
            if arguments[1] == "-X":
                self.assertEqual(arguments[2], "utf8")
                leaves.append(Path(arguments[3]).name)
            else:
                self.assertEqual(arguments[1:5],
                                 [str(ROOT / "tests/lib/process_watchdog.py"), "--timeout", "30", "--"])
                leaves.append(Path(arguments[-1]).name.removesuffix(".exe"))
        self.assertEqual(Counter(leaves), Counter([
            "beam-cli-daemon-test", "test-installation-entrypoints.py", "test-beam-prune.sh",
            "beam-backend-process-test", "beam-transport-test", "beam-transaction-test",
            "beam-publication-test", "beam-prune-lock-test", "test-system-contracts.py",
            "test-client-doctor-native.py",
            "test-save-trace-format.py", "test-installation-manifest.py",
            "test-installation-construction.py", "test-installation-lookup.py",
        ]))
        self.assertEqual(len(records), 4, records)  # Build plus the three standalone checks.
        trace_call, = [call for call in run.call_args_list
                       if str(ROOT / "tests/test-save-trace-format.py") in list(map(str, call.args[0]))]
        self.assertEqual(trace_call.args[0][-2:], ["--lean-prefix", sdk])

    def test_failure_stops_and_preserves_status(self):
        for failure in [".lake/build/bin/beam-cli-daemon-test", "tests/test-installation-entrypoints.py"]:
            with self.subTest(failure=failure):
                result, records = self.run_driver(failure)
                self.assertEqual(result.returncode, 73, result)
                self.assertFalse(any(r["command"] == "prune" for r in records))


class NativeSourceChecksTest(unittest.TestCase):
    def test_failure_stops_and_preserves_exception(self):
        failure = RuntimeError("portable source check failed")
        with mock.patch.object(native, "run", side_effect=[None, None, failure]) as run:
            with self.assertRaises(RuntimeError) as raised:
                native.run_ordinary_source_checks(Path("SDK"), {})
        self.assertIs(raised.exception, failure)
        self.assertEqual(run.call_count, 3)

    @unittest.skipIf(os.name == "nt", "Windows also probes its native headers before source checks")
    def test_qualification_runs_source_checks_after_ordinary_build(self):
        sdk = ROOT / "fixture SDK"
        reached = RuntimeError("source checks reached")
        completed = subprocess.CompletedProcess([], 0, "fixture-commit\n", "")
        with (mock.patch.object(native, "run", return_value=completed) as run,
              mock.patch.object(native, "run_ordinary_source_checks", side_effect=reached) as checks):
            with self.assertRaises(RuntimeError) as raised:
                native.qualify(SimpleNamespace(skip_build=False), sdk, ROOT)
        self.assertIs(raised.exception, reached)
        checks.assert_called_once()
        ordinary_build = run.call_args_list[-1]
        self.assertEqual(ordinary_build.args[0][:6], [sdk / "bin/lake", "--reconfigure",
                                                    "-KbeamToolchain=false", "--no-cache", "build", "beam-cli"])
        self.assertEqual(checks.call_args.args[0], sdk)
        self.assertIs(checks.call_args.args[1], ordinary_build.kwargs["env"])
        self.assertEqual(checks.call_args.args[1]["LEAN_SYSROOT"], str(sdk))


class StdioRepetitionsTest(unittest.TestCase):
    def test_nonpositive_counts_are_rejected_before_starting_scenarios(self):
        for option in ["--iterations", "--restart-cycles"]:
            for value in ["0", "-1"]:
                with self.subTest(option=option, value=value):
                    result = subprocess.run(
                        [sys.executable, str(ROOT / "tests/test-mcp-stdio.py"), option, value],
                        capture_output=True, text=True, timeout=15)
                    self.assertEqual(result.returncode, 2, result)
                    self.assertIn("must both be positive", result.stderr)
                    self.assertEqual(result.stdout, "", result)


if __name__ == "__main__":
    unittest.main()
