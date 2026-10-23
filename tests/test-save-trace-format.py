#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Check a broker-written trace with independent Lake readers from selected SDKs."""

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-prefix", action="append", type=Path)
    parser.add_argument("--keep", type=Path)
    args = parser.parse_args()
    prefixes = args.lean_prefix or [Path(subprocess.check_output(
        ["lean", "--print-prefix"], cwd=REPO, text=True, timeout=10).strip())]
    suffix = ".exe" if os.name == "nt" else ""
    fixture = REPO / ".lake/build/bin" / ("beam-daemon-fixture" + suffix)
    oracle = REPO / "tests/lean/BeamTest/Broker/SaveTraceOracle.lean"

    def check(root):
        subprocess.run([str(fixture), "save-trace-fixture", str(root)], cwd=REPO,
                       check=True, timeout=30)
        for prefix in prefixes:
            env = os.environ.copy()
            for key in ("LEAN_PATH", "LEAN_SRC_PATH", "LEAN_SYSROOT", "LAKE_HOME"):
                env.pop(key, None)
            compiler = prefix / "bin" / ("lean" + suffix)
            actual = Path(subprocess.check_output([str(compiler), "--print-prefix"],
                                                 text=True, env=env, timeout=10).strip())
            assert actual.resolve() == prefix.resolve(), (prefix, actual)
            subprocess.run([str(compiler), "--run", str(oracle), str(root)],
                           cwd=REPO, env=env, check=True, timeout=30)
            print(f"save trace format: {prefix}: passed", flush=True)

    if args.keep:
        args.keep.mkdir(parents=True, exist_ok=False)
        check(args.keep.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="beam-save-trace-format-") as root:
            check(Path(root).resolve())


if __name__ == "__main__":
    main()
