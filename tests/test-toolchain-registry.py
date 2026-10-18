#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Check that shell tests consume formatted toolchain registries without changing entries."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
PINNED = "leanprover/lean4:v99.2.0-rc1"
STABLE = "leanprover/lean4:v99.1.2"


class ToolchainRegistryTests(unittest.TestCase):
    def read_registry(self, contents):
        with tempfile.TemporaryDirectory(prefix="beam-toolchain-registry-") as tmp:
            registry = Path(tmp) / "supported toolchains"
            if contents is not None:
                registry.write_bytes(contents.encode("utf-8"))
            return subprocess.run(
                ["bash", "-c", 'set -euo pipefail; . "$1"; beam_test_read_registry_entries "$2"',
                 "registry-test", str(ROOT / "tests/lib/toolchain-registry.sh"), str(registry)],
                cwd=tmp, capture_output=True, check=False,
            )

    def run_consumer(self, script, contents=None, partial_read_failure=False):
        with tempfile.TemporaryDirectory(prefix="beam-toolchain-consumer-") as tmp:
            root = Path(tmp)
            shutil.copytree(ROOT / "tests/lib", root / "tests/lib")
            shutil.copyfile(ROOT / "tests" / script, root / "tests" / script)
            (root / "scripts").mkdir()
            shutil.copyfile(ROOT / "scripts/shared-lib.sh", root / "scripts/shared-lib.sh")
            if contents is not None:
                (root / "validated-lean-toolchains").write_bytes(contents.encode("utf-8"))
            stub_bin = root / "bin"
            stub_bin.mkdir()
            setup_marker = root / "setup-called"
            # Stop at setup even for valid inputs; these tests must never build Lean or install Beam.
            for command in ["mktemp", "lake"]:
                stub = stub_bin / command
                stub.write_text(
                    '#!/usr/bin/env bash\n'
                    'printf "%s\\n" "$0" >> "$BEAM_REGISTRY_SETUP_MARKER"\nexit 77\n'
                )
                stub.chmod(0o755)
            if partial_read_failure:
                stub = stub_bin / "awk"
                stub.write_text(
                    '#!/usr/bin/env bash\n'
                    f'printf "%s\\n" "{PINNED}"\n'
                    'echo "injected registry read failure" >&2\nexit 23\n'
                )
                stub.chmod(0o755)
            env = os.environ.copy()
            env["PATH"] = str(stub_bin) + os.pathsep + env["PATH"]
            env["BEAM_REGISTRY_SETUP_MARKER"] = str(setup_marker)
            result = subprocess.run(
                ["bash", str(root / "tests" / script), STABLE], cwd=root, env=env,
                capture_output=True, timeout=10, check=False,
            )
            return result, setup_marker.exists()

    def assert_entries(self, contents, expected):
        result = self.read_registry(contents)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout, "".join(entry + "\n" for entry in expected).encode("utf-8"))

    def test_padded_entries_remain_exact_toolchain_names(self):
        for newline in ["\n", "\r\n"]:
            with self.subTest(newline=repr(newline)):
                self.assert_entries(
                    newline.join(["  # selected releases", "", f" \t{PINNED} \t",
                                  "\t# stable line", f"  {STABLE}  ", " \t", ""]),
                    [PINNED, STABLE],
                )

    def test_last_entry_does_not_need_a_newline(self):
        self.assert_entries(f"{PINNED}\n  {STABLE}  ", [PINNED, STABLE])

    def test_crlf_entries_do_not_keep_carriage_returns(self):
        self.assert_entries(f"{PINNED}\r\n{STABLE}\r\n", [PINNED, STABLE])

    def test_empty_or_comment_only_registry_has_no_entries(self):
        for contents in ["", " \t\r\n\t# no releases\r\n"]:
            with self.subTest(contents=contents):
                self.assert_entries(contents, [])

    def test_order_duplicates_and_invalid_entries_reach_policy_validation(self):
        entries = [STABLE, PINNED, STABLE, "invalid toolchain", PINNED + " # inline comment"]
        self.assert_entries("\n".join(entries) + "\n", entries)

    def test_missing_registry_fails_without_entries(self):
        result = self.read_registry(None)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"supported toolchains", result.stderr)

    def test_missing_registry_stops_consumers_before_setup(self):
        for script in ["test-beam-install.sh", "test-beam-toolchain-compat.sh"]:
            with self.subTest(script=script):
                result, setup_called = self.run_consumer(script)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"failed to read validated Lean toolchain registry", result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertFalse(setup_called)

    def test_partial_reader_failure_stops_consumers_before_setup(self):
        for script in ["test-beam-install.sh", "test-beam-toolchain-compat.sh"]:
            with self.subTest(script=script):
                result, setup_called = self.run_consumer(
                    script, PINNED + "\n", partial_read_failure=True,
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"injected registry read failure", result.stderr)
                self.assertEqual(result.stdout, b"")
                self.assertFalse(setup_called)

    def test_unlisted_toolchain_does_not_count_as_a_read_failure(self):
        for script in ["test-beam-install.sh", "test-beam-toolchain-compat.sh"]:
            with self.subTest(script=script):
                result, setup_called = self.run_consumer(script, PINNED + "\n")
                self.assertEqual(result.returncode, 77, result.stderr)
                self.assertEqual(result.stderr, b"")
                self.assertTrue(setup_called)


if __name__ == "__main__":
    unittest.main()
