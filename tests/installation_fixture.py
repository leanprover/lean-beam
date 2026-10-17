# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Stage already-built same-compiler files through the real construction finalizer."""

import os
from pathlib import Path
import shutil
import subprocess

REPO = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""


def stage(root, *, constructor_env=None):
    compiler_prefix = subprocess.run(["lake", "env", "lean", "--print-prefix"], cwd=REPO,
                                     check=True, capture_output=True, text=True).stdout.strip()
    compiler = Path(compiler_prefix) / "bin" / ("lean" + EXE)
    selector = (REPO / "lean-toolchain").read_text().strip()
    commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO, check=True,
                            capture_output=True, text=True).stdout.strip()
    result = subprocess.run([REPO / ".lake/build/bin" / ("beam-installation-stage-fixture" + EXE),
                             REPO, root, compiler, selector, commit], cwd=REPO,
                            capture_output=True, text=True, timeout=90, env=constructor_env)
    assert result.returncode == 0, (result.stdout, result.stderr)
    return compiler.parent.parent.resolve()


def prepare_project(root, compiler_prefix):
    """Build isolated project inputs with the fixture's explicitly selected compiler."""
    shutil.copytree(REPO / "tests/save_olean_project", root,
                    ignore=shutil.ignore_patterns(".beam", ".lake"))
    (root / "lean-toolchain").write_text(str(compiler_prefix) + "\n")
    result = subprocess.run([compiler_prefix / "bin" / ("lake" + EXE), "--no-cache", "build"],
                            cwd=root, text=True, capture_output=True, timeout=120,
                            env=dict(os.environ, LAKE_ARTIFACT_CACHE="false"))
    assert result.returncode == 0, (result.stdout, result.stderr)


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--project", type=Path)
    arguments = parser.parse_args()
    compiler = stage(arguments.root.resolve())
    if arguments.project is not None:
        prepare_project(arguments.project.resolve(), compiler)
