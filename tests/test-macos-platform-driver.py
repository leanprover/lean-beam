#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Check the representative driver selects its native boundaries and propagates failures."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
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
        for target in ["beam-system-contract-test", "beam-backend-process-test", "beam-transport-test",
                       "beam-prune-lock-test", "beam-cli-daemon-test", "beam-installation-stage-fixture",
                       "beam-lake-helper-client-fixture"]:
            self.assertIn(target, build["args"])
        commands = [(r["command"], r["args"]) for r in records]
        for script in ["tests/test-system-contracts.py", "tests/test-installation-manifest.py",
                       "tests/test-installation-construction.py", "tests/test-installation-lookup.py",
                       "tests/test-installation-entrypoints.py"]:
            self.assertIn(("python3", [script]), commands)
        self.assertIn(("python3", ["tests/lib/process_watchdog.py", "--timeout", "30", "--",
                                  ".lake/build/bin/beam-prune-lock-test"]), commands)
        self.assertEqual(records[-1]["command"], "prune")

    def test_failure_stops_and_preserves_status(self):
        result, records = self.run_driver("tests/test-installation-lookup.py")
        self.assertEqual(result.returncode, 73, result)
        self.assertFalse(any(r["command"] == "prune" for r in records))
        self.assertFalse(any("tests/test-installation-entrypoints.py" in r["args"] for r in records))


if __name__ == "__main__":
    unittest.main()
