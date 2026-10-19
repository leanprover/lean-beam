#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Unsupported save setups must be rejected before fetching Lake dependencies."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

from installation_fixture import EXE, REPO, stage


def check_preflight(base, compiler, helper, scope):
    root = base / scope
    root.mkdir()
    (root / "lean-toolchain").write_text(str(compiler) + "\n", encoding="utf-8")
    source = root / "Main.lean"
    source.write_text("def answer : Nat := 42\n", encoding="utf-8")
    args = '  moreLeanArgs := #["-Dweak.batchOnlySetup=true"]\n'
    # The marker is written when Lake fetches the dependency, including in no-build mode.
    # The supported control below proves that this is reachable from prepare-save.
    (root / "lakefile.lean").write_text(
        "import Lake\nopen Lake DSL\n\npackage save_preflight where\n" +
        (args if scope == "package" else "") +
        '\ntarget preparationProbe pkg : Unit := do\n'
        '  IO.FS.writeFile (pkg.dir / "dependency-entered") "entered"\n'
        '  return Job.pure ()\n\n'
        'lean_lib Main where\n  extraDepTargets := #[`preparationProbe]\n' +
        (args if scope == "library" else "") +
        ('  leanOptions := #[⟨`weak.batchOnlySetup, true⟩]\n' if scope == "structured" else ""),
        encoding="utf-8")
    # Rejection must not invalidate an existing trace or overwrite any prior output.
    artifacts = [root / ".lake/build" / path for path in [
        "lib/lean/Main.olean", "lib/lean/Main.ilean", "lib/lean/Main.trace", "ir/Main.c"]]
    for path in artifacts:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"prior checkpoint\n")
    before = {path: path.read_bytes() for path in artifacts}
    mtime = source.stat().st_mtime_ns
    request = {"root": str(root), "path": str(source),
               # Deliberately stale: unsupported setup must win before source trace validation.
               "sourceHash": "0000000000000000",
               "sourceMTimeSec": mtime // 1_000_000_000,
               "sourceMTimeNsec": mtime % 1_000_000_000}
    client = REPO / ".lake/build/bin" / ("beam-lake-helper-client-fixture" + EXE)
    result = subprocess.run([str(client), str(helper), "prepare-save", "30000"],
                            input=json.dumps(request), capture_output=True, text=True,
                            timeout=40, check=True,
                            env=dict(os.environ, LAKE_ARTIFACT_CACHE="false"))
    response = json.loads(result.stdout)
    entered = (root / "dependency-entered").exists()
    if scope == "structured":
        assert entered, ("supported setup never reached dependency preparation", response)
        assert response["error"]["code"] == "contentModified", response
    else:
        assert not entered, ("unsupported setup entered dependency preparation", response)
        failure = response["error"]
        assert failure["code"] == "saveUnsupportedSetup", response
        assert failure["data"]["path"] == "Main.lean", failure
        assert failure["data"]["reason"] == "Lake module uses batch-only moreLeanArgs", failure
        assert "Move shared -D settings from moreLeanArgs to leanOptions" in failure["message"], failure
        assert "run lake build" in failure["message"], failure
    assert {path: path.read_bytes() for path in artifacts} == before
    print(f"save preflight ({scope}): passed", flush=True)


def main():
    with tempfile.TemporaryDirectory(prefix="beam-save-preflight-") as temporary:
        base = Path(temporary).resolve()
        if "BEAM_TEST_INSTALLATION" in os.environ:
            installation = Path(os.environ["BEAM_TEST_INSTALLATION"])
        else:
            installation = base / "installation"
            stage(installation)
        record = json.loads((installation / "manifest.json").read_text())
        target = next(t for t in record["components"]["targets"] if
                      t["toolchain"] == (REPO / "lean-toolchain").read_text().strip())
        compiler = Path(target["lean"]).parent.parent
        helper = installation / target["daemon"]
        for scope in ["structured", "package", "library"]:
            check_preflight(base, compiler, helper, scope)


if __name__ == "__main__":
    main()
