#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Reject deferred saves without replacing any prior module artifact or Lake trace."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
WRAPPER = REPO / "scripts/lean-beam"


def run(root, *args, check=True):
    return subprocess.run(args, cwd=root, text=True, capture_output=True, check=check,
                          env={**os.environ, "LAKE_ARTIFACT_CACHE": "false"}, timeout=120)


def beam(root, *args, check=True):
    return run(root, str(WRAPPER), "--root", str(root), *args, check=check)


def artifact_family(root):
    paths = list((root / ".lake/build/lib/lean/SaveSmoke").glob("ModuleB.*"))
    paths += list((root / ".lake/build/ir/SaveSmoke").glob("ModuleB.*"))
    return {p: p.read_bytes() for p in paths if p.is_file()}


def check_deferred_save(root, scoped):
    # Prepare a complete prior artifact family with ordinary compilation first.
    run(root, "lake", "--no-cache", "build", "SaveSmoke/ModuleB.lean")
    before = artifact_family(root)
    assert any(p.suffix == ".trace" for p in before), before
    if scoped:
        text = "module\n\nset_option compiler.postponeCompile true in\n"
    else:
        # Lake options test the configured server option as well as pending declarations.
        config = root / "lakefile.toml"
        config.write_text(config.read_text().replace(
            '[[lean_lib]]', '[leanOptions]\ncompiler.postponeCompile = true\n\n[[lean_lib]]'))
        text = "module\n\n"
    (root / "SaveSmoke/ModuleB.lean").write_text(
        text + "@[noinline] public def moduleBVal : Nat := 2\n")
    # All source/config edits precede the owner and the document's first open.
    with (root / "owner.out").open("w") as stdout, (root / "owner.err").open("w") as stderr:
        owner = subprocess.Popen([str(WRAPPER), "--root", str(root), "serve"],
                                 stdout=stdout, stderr=stderr,
                                 env={**os.environ, "LAKE_ARTIFACT_CACHE": "false"})
        try:
            deadline = time.monotonic() + 60
            while "serving Beam session" not in (root / "owner.err").read_text():
                if owner.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError((root / "owner.err").read_text())
                time.sleep(0.1)
            sync = json.loads(beam(root, "sync", "SaveSmoke/ModuleB.lean").stdout)["result"]
            assert sync["readiness"]["saveReady"] is False, sync
            assert sync["readiness"]["reason"] == "deferredCompilation", sync
            assert any("lake build" in m["message"] for m in sync["readiness"]["blockingMessages"]), sync
            assert sync["diagnostics"]["counts"]["error"] == 0, sync
            for command in ["save", "close-save"]:
                rejected = beam(root, command, "SaveSmoke/ModuleB.lean", check=False)
                assert rejected.returncode != 0, rejected.stdout
                failure = json.loads(rejected.stdout)["error"]
                assert failure["code"] == "saveUnsupportedSetup", failure
                assert failure["data"]["sync"]["readiness"]["saveReady"] is False, failure
                assert "compiler.postponeCompile" in failure["message"], failure
                assert artifact_family(root) == before, command
            print(f"deferred compilation ({'scoped' if scoped else 'Lake option'}): rejected, prior family preserved")
        finally:
            beam(root, "stop", check=False)
            try:
                owner.wait(timeout=10)
            except subprocess.TimeoutExpired:
                owner.terminate()
                owner.wait(timeout=10)


def main():
    # The save fixture pins the oldest supported release; postponed compilation is required there.
    with tempfile.TemporaryDirectory(prefix="beam-save-olean-deferred-", dir=os.getenv("TMPDIR", "/tmp")) as tmp:
        for scoped in [False, True]:
            root = Path(tmp) / ("scoped" if scoped else "global")
            shutil.copytree(REPO / "tests/save_olean_project", root, ignore=shutil.ignore_patterns(".lake", ".beam"))
            check_deferred_save(root, scoped)


if __name__ == "__main__":
    main()
