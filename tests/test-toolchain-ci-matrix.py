#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ToolchainCiMatrixTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="beam-toolchain-matrix-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        repo = Path(__file__).resolve().parent.parent
        for relative in (
            "scripts/check-toolchain-ci-matrix.sh",
            ".github/workflows/ci.yml",
            "validated-lean-toolchains",
            "compatible-lean-release-lines",
            "lean-toolchain",
        ):
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repo / relative, target)
        self.points = [
            line for line in (self.root / "validated-lean-toolchains").read_text().splitlines()
            if line and not line.startswith("#")
        ]
        self.pinned = (self.root / "lean-toolchain").read_text().strip()
        self.stable_points = [point for point in self.points if "-rc" not in point]

    def replace(self, relative, old, new):
        path = self.root / relative
        text = path.read_text()
        self.assertIn(old, text)
        path.write_text(text.replace(old, new))

    def replace_point(self, old, new):
        for relative in ("validated-lean-toolchains", ".github/workflows/ci.yml"):
            self.replace(relative, old, new)

    def run_guard(self, expected_error=None):
        result = subprocess.run(
            ["bash", "scripts/check-toolchain-ci-matrix.sh"],
            cwd=self.root, capture_output=True, text=True, check=False,
        )
        if expected_error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected_error, result.stderr)

    def test_current_matrix(self):
        self.run_guard()

    def test_unpinned_rc_is_rejected_even_when_matrix_matches(self):
        point = next(point for point in self.stable_points if point != self.pinned)
        self.replace_point(point, point + "-rc1")
        self.run_guard("only the pinned default may be a release candidate")

    def test_pinned_rc_is_accepted(self):
        candidate = self.pinned.split("-rc", 1)[0] + "-rc7"
        self.replace_point(self.pinned, candidate)
        (self.root / "lean-toolchain").write_text(candidate + "\n")
        self.run_guard()

    def test_noncanonical_pinned_rc_is_rejected(self):
        candidate = self.pinned.split("-rc", 1)[0] + "-rc01"
        self.replace_point(self.pinned, candidate)
        (self.root / "lean-toolchain").write_text(candidate + "\n")
        self.run_guard("expected a canonical Lean toolchain")

    def test_two_stable_points_in_one_line_are_rejected(self):
        point = self.stable_points[0]
        line, patch = point.rsplit(".", 1)
        extra = f"{line}.{int(patch) + 1}"
        self.replace("validated-lean-toolchains", point, f"{point}\n{extra}")
        self.replace(".github/workflows/ci.yml", f"- {point}", f"- {point}\n          - {extra}")
        self.run_guard("expected exactly one validated point")

    def test_missing_release_line_coverage_is_rejected(self):
        point = self.points[-1]
        self.replace("validated-lean-toolchains", point + "\n", "")
        self.replace(".github/workflows/ci.yml", "          - " + point + "\n", "")
        self.run_guard("expected exactly one validated point")

    def test_stable_and_rc_in_one_line_are_rejected(self):
        point = self.pinned
        stable = point.split("-rc", 1)[0]
        extra = stable if point != stable else stable + "-rc8"
        self.replace("validated-lean-toolchains", point, f"{point}\n{extra}")
        self.replace(".github/workflows/ci.yml", f"- {point}", f"- {point}\n          - {extra}")
        self.run_guard("expected exactly one validated point")

    def test_toolchain_outside_supported_lines_is_rejected(self):
        self.replace_point(self.points[-1], "leanprover/lean4:v999.0.0")
        self.run_guard("validated toolchain is outside compatible-lean-release-lines")

    def test_matrix_drift_is_rejected(self):
        self.replace(".github/workflows/ci.yml", self.points[-1], self.points[-1] + "-rc1")
        self.run_guard("validated Lean toolchains missing from beam-toolchain-compat matrix")

    def test_unvalidated_default_is_rejected(self):
        (self.root / "lean-toolchain").write_text("leanprover/lean4:v999.0.0\n")
        self.run_guard("pinned toolchain is not validated")


if __name__ == "__main__":
    unittest.main()
