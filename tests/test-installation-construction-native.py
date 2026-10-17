#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise real two-target standalone construction inside validate-defensive's fake homes."""

import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
validation = Path(os.environ["BEAM_VALIDATION_ROOT"]).resolve()
assert validation.parent == Path("/tmp") and validation.name.startswith("beam-validate-")
assert Path(os.environ["HOME"]).resolve().is_relative_to(validation)
host_elan = Path(os.environ["ELAN_HOME"]).resolve()
fixture_elan = validation / "construction-elan"
(fixture_elan / "toolchains").mkdir(parents=True)
targets = ["leanprover/lean4:v4.33.1", "leanprover/lean4:v4.36.0-rc1"]
for selector in targets:
    name = selector.replace("/", "--").replace(":", "---")
    source = host_elan / "toolchains" / name
    assert source.is_dir(), source
    (fixture_elan / "toolchains" / name).symlink_to(source, target_is_directory=True)
env = dict(os.environ, ELAN_HOME=str(fixture_elan), LAKE_CACHE_DIR="")


def install(*options, ok=True):
    result = subprocess.run(["bash", "scripts/install-beam.sh", "--dont-ask", *options],
                            cwd=ROOT, env=env, capture_output=True, text=True, timeout=900)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result


options = [option for target in targets for option in ["--toolchain", target]]
install(*options)
install_root = Path(env["HOME"]) / ".local/share/beam"
generation = (install_root / "current").resolve()
record_path = generation / "manifest.json"
record_bytes = record_path.read_bytes()
record = json.loads(record_bytes)
assert record["schemaVersion"] == 4
assert len(record["components"]["targets"]) == 2
assert record["components"]["frontends"]["compilerRevision"] != record["components"]["targets"][0]["compilerRevision"]
assert {entry["toolchain"] for entry in record["components"]["targets"]} == set(targets)
assert generation.name == record["payloadHash"]
for artifact in record["artifacts"]:
    path = generation / artifact["destination"]
    assert path.is_file() and not path.is_symlink(), path
    assert hashlib.sha256(path.read_bytes()).hexdigest() == artifact["hash"], path
for target in record["components"]["targets"]:
    for role in ["daemon", "plugin"]:
        path = Path(target[role])
        assert not path.is_absolute() and path.parts[0] == "runtimes", target
        assert (generation / path).is_file(), path
assert not (generation / "libexec/beam-daemon").exists()
assert not (generation / "libexec/beam-install-runtime").exists()
print("real two-target construction and installed artifact hashes passed", flush=True)

install(*options)
assert (install_root / "current").resolve() == generation
assert record_path.read_bytes() == record_bytes, "reuse rewrote the immutable generation"
assert len(list((install_root / "versions").iterdir())) == 1
print("unchanged reinstall reused the complete immutable generation", flush=True)

failed = install("--toolchain", targets[0], "--custom-toolchain", "construction-missing", ok=False)
assert failed.returncode != 0
assert (install_root / "current").resolve() == generation
assert record_path.read_bytes() == record_bytes
assert len(list((install_root / "versions").iterdir())) == 1
assert not list(install_root.glob(".staging-*")), "failed construction retained a publishable partial tree"
print("failed later-target construction preserved publication and removed owned staging", flush=True)

# Changed provenance publishes a different generation; it never edits the old record in place.
subprocess.run(["git", "-c", "user.name=Beam Construction Test", "-c",
                "user.email=construction@example.invalid", "-c", "commit.gpgsign=false",
                "commit", "--allow-empty", "-m", "test: change construction provenance"],
               cwd=ROOT, env=env, check=True, capture_output=True)
install(*options)
replacement = (install_root / "current").resolve()
assert replacement != generation
assert record_path.read_bytes() == record_bytes
assert len(list((install_root / "versions").iterdir())) == 2
print("changed provenance published another complete generation and retained the old one", flush=True)
