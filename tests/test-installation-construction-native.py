#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise real two-target standalone construction against a private home, install root, and elan home.

Requires the exact targets below in the host elan home. Never writes outside its own temporary root
except the checkout's `.lake` build output, as any installer run does. Keep two cache-disabled
constructions for the independent rebuild check before using a fixture-owned cache in later cases."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
validation = Path(tempfile.mkdtemp(prefix="beam-construction-native-")).resolve()
host_elan = Path(os.environ.get("ELAN_HOME") or Path.home() / ".elan").resolve()
fixture_elan = validation / "construction-elan"
(fixture_elan / "toolchains").mkdir(parents=True)
targets = ["leanprover/lean4:v4.33.1", "leanprover/lean4:v4.36.0-rc1"]
for selector in targets:
    name = selector.replace("/", "--").replace(":", "---")
    source = host_elan / "toolchains" / name
    assert source.is_dir(), source
    (fixture_elan / "toolchains" / name).symlink_to(source, target_is_directory=True)
home = validation / "home"
home.mkdir()
env = dict(os.environ, ELAN_HOME=str(fixture_elan), LAKE_CACHE_DIR="", HOME=str(home),
           BEAM_INSTALL_ROOT=str(home / ".local/share/beam"), BEAM_BIN_HOME=str(home / ".local/bin"),
           CODEX_HOME=str(home / ".codex"), CLAUDE_HOME=str(home / ".claude"))


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
reinstalled = (install_root / "current").resolve()
if reinstalled != generation:
    # Name the artifacts whose bytes differ, so a non-reproducible build is diagnosable.
    before = {artifact["destination"]: artifact["hash"] for artifact in record["artifacts"]}
    after = {artifact["destination"]: artifact["hash"]
             for artifact in json.loads((reinstalled / "manifest.json").read_text())["artifacts"]}
    differing = sorted(path for path in before.keys() | after.keys() if before.get(path) != after.get(path))
    raise AssertionError(f"unchanged reinstall published another generation; differing artifacts: {differing}")
assert record_path.read_bytes() == record_bytes, "reuse rewrote the immutable generation"
assert len(list((install_root / "versions").iterdir())) == 1
print("unchanged reinstall reused the complete immutable generation", flush=True)

assert not (generation / ".construction").exists(), "temporary target builds reached the publication"
assert not (install_root / "state").exists(), "construction persisted state outside the generation"
assert not list(install_root.glob(".staging-*")), "construction retained a staging tree"
print("construction left no build directories or persistent cache", flush=True)

# Both constructions above are cache-disabled. Later cases share only this owned fixture cache,
# leaving the independent rebuild comparison and the host SDK caches untouched.
fixture_cache = validation / "lake-cache"
fixture_cache.mkdir()
assert not list(fixture_cache.iterdir())
env["LAKE_CACHE_DIR"] = str(fixture_cache)

# An upgraded root may still hold an earlier construction cache; the installer neither reads,
# removes, nor extends it.
legacy = install_root / "state/install-bundles/linux-x86_64/legacy-entry"
legacy.mkdir(parents=True)
(legacy / "sentinel").write_text("earlier construction cache")
legacy_before = sorted(str(path.relative_to(install_root)) for path in (install_root / "state").rglob("*"))
install(*options)
assert any(path.is_file() for path in fixture_cache.rglob("*")), "fixture cache was not populated"
assert (install_root / "current").resolve() == generation
assert (legacy / "sentinel").read_text() == "earlier construction cache"
assert sorted(str(path.relative_to(install_root)) for path in (install_root / "state").rglob("*")) == legacy_before
print("reinstall left an earlier construction cache untouched and wrote nothing new", flush=True)

failed = install("--toolchain", targets[0], "--custom-toolchain", "construction-missing", ok=False)
assert failed.returncode != 0
assert (install_root / "current").resolve() == generation
assert record_path.read_bytes() == record_bytes
assert len(list((install_root / "versions").iterdir())) == 1
assert not list(install_root.glob(".staging-*")), "failed construction retained a publishable partial tree"
print("failed later-target construction preserved publication and removed owned staging", flush=True)


def qualification_failing_sdk(original, sdk):
    """Link a real SDK whose lean builds normally but refuses every plugin load."""
    sdk.mkdir()
    for entry in original.iterdir():
        if entry.name != "bin":
            (sdk / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (sdk / "bin").mkdir()
    for entry in (original / "bin").iterdir():
        if entry.name not in {"lean", "lake"}:
            (sdk / "bin" / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    # Copy Lake so it resolves this SDK rather than its original executable directory.
    shutil.copy2(original / "bin/lake", sdk / "bin/lake")
    (sdk / "bin/lean").write_text(
        "#!/bin/sh\n"
        'for arg in "$@"; do case "$arg" in --plugin=*) '
        'echo "fixture SDK refuses plugin loads" >&2; exit 1 ;; esac; done\n'
        'case "${1-}" in\n'
        f"  --print-prefix) printf '%s\\n' {shlex.quote(str(sdk))} ;;\n"
        f"  --print-libdir) printf '%s\\n' {shlex.quote(str(sdk / 'lib/lean'))} ;;\n"
        f'  *) exec {shlex.quote(str(original / "bin/lean"))} "$@" ;;\n'
        "esac\n", encoding="utf-8")
    (sdk / "bin/lean").chmod(0o755)


# A later target that builds and stages but whose staged plugin fails qualification must not publish.
failing_name = "qualification-fails"
failing_sdk = validation / "qualification-fails-sdk"
qualification_failing_sdk((host_elan / "toolchains" / targets[1].replace("/", "--").replace(":", "---")).resolve(),
                          failing_sdk)
subprocess.run(["elan", "toolchain", "link", failing_name, failing_sdk], env=env, check=True,
               capture_output=True)
failed = install("--toolchain", targets[0], "--custom-toolchain", failing_name, ok=False)
assert failed.returncode != 0, failed.stdout + failed.stderr
assert f"failed to qualify the Beam runtime for target {failing_name}" in failed.stderr, failed.stderr
assert "fixture SDK refuses plugin loads" in failed.stderr, failed.stderr
assert (install_root / "current").resolve() == generation
assert record_path.read_bytes() == record_bytes
assert len(list((install_root / "versions").iterdir())) == 1
assert not list(install_root.glob(".staging-*")), "failed qualification retained a staging tree"
print("staged-plugin qualification failure on a later target preserved publication", flush=True)

# Warm construction and failed qualification must not mutate the immutable installed generation,
# including through cache-linked build outputs.
for artifact in record["artifacts"]:
    path = generation / artifact["destination"]
    assert not path.is_symlink() and path.stat().st_nlink == 1, path
    assert hashlib.sha256(path.read_bytes()).hexdigest() == artifact["hash"], path

shutil.rmtree(validation)
