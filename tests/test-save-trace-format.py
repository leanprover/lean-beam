#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Check private trace I/O failures and compatibility with target Lake readers."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]


def check_write_failure(fixture, root):
    if os.name != "posix":
        print("trace flush failure: skipped (requires POSIX file-size limit)", flush=True)
        return
    import resource
    import signal

    def limit_file_size():
        signal.signal(signal.SIGXFSZ, signal.SIG_IGN)
        resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))

    spec_path = root / "spec.json"
    original = spec_path.read_bytes()
    prior = (root / "Saved.trace").read_bytes()
    candidate_dir = root / "failed-trace"
    candidate_dir.mkdir(mode=0o700)
    spec = json.loads(original)
    spec["tracePath"] = str(candidate_dir / "Saved.trace.candidate")
    try:
        spec_path.write_text(json.dumps(spec), encoding="utf-8")
        result = subprocess.run([str(fixture), "write-prepared-trace", str(root)], cwd=REPO,
                                preexec_fn=limit_file_size, capture_output=True, text=True,
                                timeout=30)
        assert result.returncode > 0, result
        candidate = Path(spec["tracePath"])
        assert candidate.is_file() and candidate.stat().st_size == 0, result
        assert (root / "Saved.trace").read_bytes() == prior
    finally:
        spec_path.write_bytes(original)
    print("trace write/flush failure is reported before publication: passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lean-prefix", action="append", type=Path)
    parser.add_argument("--keep", type=Path)
    args = parser.parse_args()
    prefixes = args.lean_prefix or [Path(subprocess.check_output(
        ["lean", "--print-prefix"], cwd=REPO, text=True, timeout=10).strip())]
    suffix = ".exe" if os.name == "nt" else ""
    fixture = REPO / ".lake/build/bin" / ("beam-lake-helper-client-fixture" + suffix)
    oracle = REPO / "tests/lean/BeamTest/Broker/SaveTraceOracle.lean"

    def check(root):
        subprocess.run([str(fixture), "save-trace-fixture", str(root)], cwd=REPO,
                       check=True, timeout=30)
        check_write_failure(fixture, root)
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
