#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Check toolchain registry handling and installer policy without building Lean."""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
PINNED = "leanprover/lean4:v99.2.0-rc1"
STABLE = "leanprover/lean4:v99.1.2"
PINNED_LINE = "leanprover/lean4:v99.2"
STABLE_LINE = "leanprover/lean4:v99.1"


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


class InstallerRegistryTests(unittest.TestCase):
    def run_installer(self, *, registries=None, missing=None, partial_failure=None,
                      args=("--all-validated",), pinned=PINNED):
        with tempfile.TemporaryDirectory(prefix="beam-installer-registry-") as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            for name in ["install-beam.sh", "install-lib.sh", "install-locations.sh",
                         "install-mcp.sh", "shared-lib.sh"]:
                shutil.copyfile(ROOT / "scripts" / name, root / "scripts" / name)
            (root / "lean-toolchain").write_text(pinned + "\n")
            entries = {
                "validated-lean-toolchains": PINNED + "\n" + STABLE + "\n",
                "compatible-lean-release-lines": PINNED_LINE + "\n" + STABLE_LINE + "\n",
            }
            entries.update(registries or {})
            for name, contents in entries.items():
                if name != missing:
                    (root / name).write_bytes(contents.encode("utf-8"))

            stub_bin = root / "bin"
            stub_bin.mkdir()
            marker = root / "setup-called"
            # No write approval is given. Guard setup/build commands against accidental execution.
            for command in ["elan", "lake", "mkdir", "mktemp"]:
                stub = stub_bin / command
                stub.write_text(
                    '#!/usr/bin/env bash\n'
                    'printf "%s\\n" "$0" >> "$BEAM_REGISTRY_SETUP_MARKER"\nexit 77\n'
                )
                stub.chmod(0o755)
            env = os.environ.copy()
            env.update({
                "PATH": str(stub_bin) + os.pathsep + env["PATH"],
                "HOME": str(root / "home"),
                "BEAM_BIN_HOME": str(root / "commands"),
                "BEAM_INSTALL_ROOT": str(root / "install"),
                "BEAM_REGISTRY_SETUP_MARKER": str(marker),
            })
            if partial_failure:
                env["BEAM_REGISTRY_FAIL_PATH"] = str(root / partial_failure)
                env["BEAM_REGISTRY_REAL_AWK"] = shutil.which("awk")
                env["BEAM_REGISTRY_PARTIAL_ENTRY"] = (
                    PINNED if partial_failure == "validated-lean-toolchains" else PINNED_LINE
                )
                stub = stub_bin / "awk"
                stub.write_text(
                    '#!/usr/bin/env bash\n'
                    'if [ "${!#}" = "$BEAM_REGISTRY_FAIL_PATH" ]; then\n'
                    '  printf "%s\\n" "$BEAM_REGISTRY_PARTIAL_ENTRY"\n'
                    '  echo "injected registry read failure" >&2\n  exit 23\nfi\n'
                    'exec "$BEAM_REGISTRY_REAL_AWK" "$@"\n'
                )
                stub.chmod(0o755)
            result = subprocess.run(
                ["bash", str(root / "scripts/install-beam.sh"), *args],
                cwd=root, env=env, input=b"", capture_output=True, timeout=10, check=False,
            )
            self.assertEqual(result.stdout, b"")
            self.assertFalse(marker.exists(), result.stderr)
            for name in ["home", "commands", "install", ".lake"]:
                self.assertFalse((root / name).exists(), result.stderr)
            return result

    def test_missing_registries_stop_install_planning(self):
        for name, label in [("validated-lean-toolchains", "validated Lean toolchain"),
                            ("compatible-lean-release-lines", "compatible Lean release-line")]:
            with self.subTest(registry=name):
                result = self.run_installer(missing=name)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f"failed to read {label} registry".encode(), result.stderr)
                self.assertIn(
                    f"restore {name} from the same Beam revision or fix its read permissions".encode(),
                    result.stderr,
                )
                self.assertNotIn(b"Install Plan", result.stderr)

    def test_partial_reads_stop_install_planning(self):
        for name, label in [("validated-lean-toolchains", "validated Lean toolchain"),
                            ("compatible-lean-release-lines", "compatible Lean release-line")]:
            with self.subTest(registry=name):
                result = self.run_installer(partial_failure=name)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"injected registry read failure", result.stderr)
                self.assertIn(f"failed to read {label} registry".encode(), result.stderr)
                self.assertIn(
                    f"restore {name} from the same Beam revision or fix its read permissions".encode(),
                    result.stderr,
                )
                self.assertNotIn(b"Install Plan", result.stderr)

    def test_formatted_registries_reach_confirmation_without_writing(self):
        for newline in ["\n", "\r\n"]:
            with self.subTest(newline=repr(newline)):
                result = self.run_installer(registries={
                    "validated-lean-toolchains": newline.join(
                        ["  # exact releases", "", f" \t{PINNED}\t ", f"  {STABLE}  "]),
                    "compatible-lean-release-lines": newline.join(
                        ["\t# release lines", f"  {PINNED_LINE}  ", f" \t{STABLE_LINE}\t "]),
                })
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(b"Install Plan", result.stderr)
                self.assertLess(result.stderr.index(PINNED.encode()), result.stderr.index(STABLE.encode()))
                self.assertIn(b"refusing to install without confirmation", result.stderr)
                self.assertNotIn(b"failed to read", result.stderr)

    def test_invalid_and_duplicate_entries_still_fail_policy_checks(self):
        for name, contents, expected in [
            ("validated-lean-toolchains", "invalid toolchain\n", "invalid validated Lean toolchain"),
            ("validated-lean-toolchains", "leanprover/lean4:v4.33.0-rc01\n",
             "invalid validated Lean toolchain: leanprover/lean4:v4.33.0-rc01"),
            ("validated-lean-toolchains", f"{PINNED}\n{PINNED}\n", "duplicate validated Lean toolchain"),
            ("compatible-lean-release-lines", "invalid line\n", "invalid compatible Lean release line"),
            ("compatible-lean-release-lines", f"{PINNED_LINE}\n{PINNED_LINE}\n",
             "duplicate compatible Lean release line"),
        ]:
            with self.subTest(registry=name, expected=expected):
                result = self.run_installer(registries={name: contents})
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(expected.encode(), result.stderr)
                self.assertNotIn(b"failed to read", result.stderr)
                self.assertNotIn(b"Install Plan", result.stderr)

    def test_retired_toolchains_are_rejected_by_checked_in_policy(self):
        registries = {
            name: (ROOT / name).read_text()
            for name in ["validated-lean-toolchains", "compatible-lean-release-lines"]
        }
        pinned = (ROOT / "lean-toolchain").read_text().strip()
        retired_toolchains = [
            "leanprover/lean4:v4.26.0",
            "leanprover/lean4:v4.28.0", "leanprover/lean4:v4.28.1", "leanprover/lean4:v4.28.0-rc1",
            "leanprover/lean4:v4.29.0", "leanprover/lean4:v4.29.1", "leanprover/lean4:v4.29.0-rc1",
            "leanprover/lean4:v4.30.0", "leanprover/lean4:v4.30.1", "leanprover/lean4:v4.30.0-rc2",
            "leanprover/lean4:v4.31.0", "leanprover/lean4:v4.31.1", "leanprover/lean4:v4.31.0-rc1",
            "leanprover/lean4:v4.32.0", "leanprover/lean4:v4.32.1", "leanprover/lean4:v4.32.2",
            "leanprover/lean4:v4.32.0-rc1",
        ]
        for toolchain in retired_toolchains:
            with self.subTest(toolchain=toolchain):
                result = self.run_installer(
                    registries=registries, pinned=pinned, args=("--toolchain", toolchain),
                )
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(
                    f"unsupported Lean toolchain requested for install: {toolchain}".encode(),
                    result.stderr,
                )
                self.assertNotIn(b"Install Plan", result.stderr)

    def test_release_line_variant_reaches_confirmation_without_writing(self):
        toolchain = STABLE_LINE + ".0-rc1"
        result = self.run_installer(args=("--toolchain", toolchain))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Install Plan", result.stderr)
        self.assertIn(f"{toolchain} (release-line compatible)".encode(), result.stderr)
        self.assertIn(b"refusing to install without confirmation", result.stderr)
        self.assertNotIn(b"unsupported Lean toolchain", result.stderr)

    def test_default_install_requires_confirmation_without_writing(self):
        result = self.run_installer(args=())
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Install Plan", result.stderr)
        self.assertIn(PINNED.encode(), result.stderr)
        self.assertNotIn(STABLE.encode(), result.stderr)
        self.assertIn(b"refusing to install without confirmation", result.stderr)


if __name__ == "__main__":
    unittest.main()
