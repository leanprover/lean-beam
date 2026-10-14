#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Check the standalone selector against the minimum supported Elan binary on Linux."""

import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request


repo = Path(__file__).resolve().parent.parent
toolchain = (repo / "lean-toolchain").read_text().strip()
lean = Path(subprocess.check_output(
    ["elan", "run", toolchain, "elan", "which", "lean"], text=True,
).strip()).resolve()
prefix = lean.parent.parent
url = "https://github.com/leanprover/elan/releases/download/v4.0.0/elan-x86_64-unknown-linux-gnu.tar.gz"
with urllib.request.urlopen(url, timeout=30) as response:
    archive = response.read()

with tempfile.TemporaryDirectory(prefix="beam-elan-compat-") as scratch:
    root = Path(scratch)
    bin_dir = root / "bin"
    bin_dir.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as tar:
        member = next(m for m in tar.getmembers() if Path(m.name).name == "elan-init" and m.isfile())
        elan = bin_dir / "elan"
        elan.write_bytes(tar.extractfile(member).read())
        elan.chmod(0o755)
    home = root / "elan-home"
    (home / "toolchains").mkdir(parents=True)
    (home / "toolchains" / prefix.name).symlink_to(prefix, target_is_directory=True)
    (home / "toolchains" / "lean4-compat-local").symlink_to(prefix, target_is_directory=True)
    project = root / "project"
    project.mkdir()
    (project / "lean-toolchain").write_text(toolchain + "\n")
    (project / "lakefile.toml").write_text('name = "elan_compat_probe"\n')
    env = {**os.environ, "ELAN_HOME": str(home), "HOME": str(root / "home"),
           "CODEX_HOME": str(root / "codex"), "CLAUDE_HOME": str(root / "claude"),
           "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"]}
    env.pop("ELAN_TOOLCHAIN", None)
    version = subprocess.check_output([str(elan), "--version"], env=env, text=True)
    if not version.startswith("elan 4.0.0 "):
        raise RuntimeError("unexpected minimum Elan binary: " + version)
    for selector in [None, toolchain, "lean4-compat-local"]:
        case_env = env.copy()
        if selector is not None:
            case_env["ELAN_TOOLCHAIN"] = selector
        result = subprocess.run(
            [str(repo / ".lake/build/bin/beam-cli"), "--root", str(project), "doctor"],
            env=case_env, text=True, capture_output=True, timeout=30, check=True,
        )
        selected = selector or toolchain
        for line in [f"project toolchain: {selected}", f"project toolchain selector: {selected}"]:
            if line not in result.stdout.splitlines():
                raise RuntimeError("minimum Elan selection disagreed with Beam: " + result.stdout)
        if selector != "lean4-compat-local" and f"lean binary: {lean}" not in result.stdout.splitlines():
            raise RuntimeError("minimum Elan selected a different compiler: " + result.stdout)
        print(f"Elan 4.0 selection passed: {selected}")
