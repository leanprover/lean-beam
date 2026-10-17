#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Check that shell tests consume formatted toolchain registries without changing entries."""

from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
