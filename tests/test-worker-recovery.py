#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Typed worker errors and a real worker exit recover only the affected document."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

from mcp_test_util import shared_lib_name

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from process_watchdog import run_with_watchdog

REPO = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""


def main():
    prefix = subprocess.run(["lake", "env", "lean", "--print-prefix"], cwd=REPO,
                            capture_output=True, text=True, check=True, timeout=15).stdout.strip()
    compiler = Path(prefix) / "bin" / ("lean" + EXE)
    fixture = REPO / ".lake/build/bin" / ("beam-daemon-fixture" + EXE)
    plugin = REPO / ".lake/build/lib" / shared_lib_name()
    with tempfile.TemporaryDirectory(prefix="beam-worker-recovery-") as temporary:
        result = run_with_watchdog(
            [fixture, "--lean-cmd", compiler, "--lean-plugin", plugin,
             "worker-recovery-test", Path(temporary).resolve()], timeout=180, cwd=REPO)
        assert result.returncode == 0, (result.stdout, result.stderr)
        print(result.stdout, end="")


if __name__ == "__main__":
    main()
