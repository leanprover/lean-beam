#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise nightly SDK selection and native-test orchestration without compiling Lean."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
TOOLCHAIN = "leanprover/lean4-nightly:nightly-2026-10-13"
ELAN = '''#!/usr/bin/env python3
import os
from pathlib import Path
import sys
args = sys.argv[1:]
assert "ELAN_TOOLCHAIN" not in os.environ
assert "LEAN_SYSROOT" not in os.environ
if args == ["toolchain", "list"]:
    if not os.environ.get("BEAM_NIGHTLY_TEST_INSTALL_FAIL"):
        print("leanprover/lean4-nightly:nightly-2026-10-13")
elif args[:2] == ["toolchain", "install"]:
    print("fixture install failure", file=sys.stderr)
    sys.exit(7)
elif args == ["run", "leanprover/lean4-nightly:nightly-2026-10-13", "lean", "--print-prefix"]:
    print(Path(os.environ["BEAM_NIGHTLY_TEST_HOST_ELAN"]) / "toolchains/sdk")
else:
    raise SystemExit("unexpected elan invocation: " + repr(args))
'''
LEAN = '''#!/usr/bin/env python3
import os
import sys
if sys.argv[1:] == ["--version"]:
    print("Lean version 4.35.0" if os.environ.get("BEAM_NIGHTLY_TEST_WRONG_VERSION")
          else "Lean version 4.36.0-nightly-2026-10-13")
elif sys.argv[1:] == ["--githash"]:
    print("fixture-compiler-commit")
else:
    raise SystemExit("unexpected Lean invocation")
'''
NATIVE = '''import os
from pathlib import Path
import sys
repo = Path.cwd()
home = Path(os.environ["ELAN_HOME"])
host = Path(os.environ["BEAM_NIGHTLY_TEST_HOST_ELAN"])
assert len(sys.argv) == 2, "nightly runner should only pass the selected SDK"
assert Path(sys.argv[1]).resolve() == (host / "toolchains/sdk").resolve()
assert home != host and not (home / "settings.toml").exists()
assert (home / "toolchains" / "compiler-sentinel").read_text() == "installed compiler"
assert "ELAN_TOOLCHAIN" not in os.environ and "LAKE_CACHE_DIR" not in os.environ
assert (repo / ".git").is_dir()
assert not (repo / "deleted.lean").exists()
assert not (repo / "staged-deleted.lean").exists()
assert not (repo / "ignored-output").exists()
assert (repo / "changed.lean").read_text() == "modified source"
assert (repo / "added.lean").read_text() == "new source"
assert (repo / "lean-toolchain").read_text() == "leanprover/lean4:v4.35.0\\n"
assert (repo / "custom-lean-toolchains").read_text() == "unchanged-custom\\n"
with open(os.environ["BEAM_NIGHTLY_TEST_CALLS"], "a") as log:
    log.write("native\\n")
print("fixture native qualification", flush=True)
if os.environ.get("BEAM_NIGHTLY_TEST_NATIVE_FAIL"):
    sys.exit(23)
'''


class NightlyDriverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="beam-nightly-driver-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        (self.source / "tests/lib").mkdir(parents=True)
        for name in ("tests/test-beam-nightly.sh", "tests/lib/ci-steps.sh"):
            shutil.copy2(REPO / name, self.source / name)
        for name in ("changed.lean", "deleted.lean", "staged-deleted.lean"):
            (self.source / name).write_text("committed source")
        (self.source / "lean-toolchain").write_text("leanprover/lean4:v4.35.0\n")
        (self.source / "custom-lean-toolchains").write_text("unchanged-custom\n")
        (self.source / ".gitignore").write_text("ignored-output\n")
        (self.source / "tests/test-native-toolchain.py").write_text(NATIVE)
        self.env = dict(os.environ)
        self.env.pop("GITHUB_ACTIONS", None)
        self.env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        self.git("init", "-q")
        self.git("config", "user.name", "Nightly Fixture")
        self.git("config", "user.email", "nightly-fixture@example.invalid")
        self.git("add", ".")
        self.git("commit", "--no-gpg-sign", "-qm", "create fixture")
        self.head = self.git("rev-parse", "HEAD").stdout.strip()
        (self.source / "changed.lean").write_text("modified source")
        (self.source / "added.lean").write_text("new source")
        (self.source / "deleted.lean").unlink()
        (self.source / "staged-deleted.lean").unlink()
        self.git("add", "staged-deleted.lean")
        (self.source / "ignored-output").write_text("ignored cache")
        self.host_elan = self.root / "host-elan"
        sdk_bin = self.host_elan / "toolchains/sdk/bin"
        sdk_bin.mkdir(parents=True)
        (self.host_elan / "toolchains/compiler-sentinel").write_text("installed compiler")
        (self.host_elan / "settings.toml").write_text("caller directory overrides")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for path, contents in ((self.bin / "elan", ELAN), (sdk_bin / "lean", LEAN),
                               (sdk_bin / "lake", '#!/usr/bin/env python3\nprint("Lake nightly fixture")\n')):
            path.write_text(contents)
            path.chmod(0o755)
        self.temp_root = self.root / "tmp"
        self.temp_root.mkdir()
        self.calls = self.root / "calls"
        self.report = self.root / "report"
        self.env.update(PATH=f"{self.bin}:{self.env['PATH']}", ELAN_HOME=str(self.host_elan),
                        TMPDIR=str(self.temp_root), ELAN_TOOLCHAIN="wrong-toolchain",
                        LEAN_SYSROOT="wrong-sysroot", LAKE_CACHE_DIR="wrong-cache",
                        BEAM_NIGHTLY_TEST_HOST_ELAN=str(self.host_elan),
                        BEAM_NIGHTLY_TEST_CALLS=str(self.calls))

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.source, env=self.env,
                              capture_output=True, text=True, check=True)

    def run_driver(self, toolchain=TOOLCHAIN):
        proc = subprocess.run(["bash", "tests/test-beam-nightly.sh", toolchain, str(self.report)],
                              cwd=self.source, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(list(self.temp_root.iterdir()), [], proc.stdout + proc.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), self.head)
        self.assertEqual((self.host_elan / "settings.toml").read_text(), "caller directory overrides")
        self.assertEqual((self.source / "lean-toolchain").read_text(), "leanprover/lean4:v4.35.0\n")
        return proc

    def test_worktree_overlay_and_exact_native_sdk(self):
        linked = self.root / "linked"
        self.git("worktree", "add", "--detach", str(linked))
        for name in ("changed.lean", "added.lean"):
            shutil.copy2(self.source / name, linked / name)
        for name in ("deleted.lean", "staged-deleted.lean"):
            (linked / name).unlink()
        self.source = linked
        proc = self.run_driver()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual((self.report / "result.txt").read_text(), "passed\n")
        self.assertEqual(self.calls.read_text(), "native\n")
        metadata = json.loads((self.report / "metadata.json").read_text())
        self.assertTrue(metadata["source_dirty"])
        self.assertEqual(metadata["lean_githash"], "fixture-compiler-commit")
        self.assertEqual(Path(metadata["lean_prefix"]), self.host_elan / "toolchains/sdk")

    def test_native_failure_replaces_old_reports(self):
        self.report.mkdir()
        (self.report / "native.log").write_text("stale evidence")
        (self.report / "release.json").write_text("stale release")
        self.env["BEAM_NIGHTLY_TEST_NATIVE_FAIL"] = "1"
        proc = self.run_driver()
        self.assertEqual(proc.returncode, 23, proc.stdout + proc.stderr)
        self.assertIn("fixture native qualification", proc.stderr)
        self.assertNotIn("stale evidence", (self.report / "native.log").read_text())
        self.assertFalse((self.report / "release.json").exists())
        self.assertEqual((self.report / "result.txt").read_text(), "failed\n")

    def test_install_failure_leaves_no_old_identity(self):
        self.report.mkdir()
        (self.report / "metadata.json").write_text("stale identity")
        self.env["BEAM_NIGHTLY_TEST_INSTALL_FAIL"] = "1"
        proc = self.run_driver()
        self.assertEqual(proc.returncode, 7, proc.stdout + proc.stderr)
        self.assertIn("fixture install failure", proc.stderr)
        self.assertFalse((self.report / "metadata.json").exists())
        self.assertFalse(self.calls.exists())

    def test_wrong_sdk_version_stops_before_native_test(self):
        self.env["BEAM_NIGHTLY_TEST_WRONG_VERSION"] = "1"
        proc = self.run_driver()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("nightly toolchain name/version mismatch", proc.stderr)
        self.assertFalse(self.calls.exists())

    def test_missing_native_driver_is_a_failure(self):
        (self.source / "tests/test-native-toolchain.py").unlink()
        proc = self.run_driver()
        self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
        self.assertIn("test-native-toolchain.py", proc.stderr)
        self.assertEqual((self.report / "result.txt").read_text(), "failed\n")

    def test_mutable_and_invalid_dates_stop_before_install(self):
        for toolchain in ("nightly", "leanprover/lean4-nightly:nightly", "leanprover/lean4-nightly:nightly-2026-02-30"):
            with self.subTest(toolchain=toolchain):
                proc = self.run_driver(toolchain)
                self.assertNotEqual(proc.returncode, 0)
                self.assertFalse((self.report / "install.log").exists())
                self.assertEqual((self.report / "result.txt").read_text(), "failed\n")


if __name__ == "__main__":
    unittest.main()
