#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Build and qualify a small target through the POSIX nonstandard-layout adapter."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / ".lake/build/bin/beam-installation-construction-test"


def run(arguments, *, cwd, env, timeout=120):
    return subprocess.run(arguments, cwd=cwd, env=env, text=True,
                          capture_output=True, timeout=timeout)


def prepare_sdk(root, original):
    """Keep Lake modules only in a distinct directory; retain the real compiler and Lake."""
    sdk = root / "SDK with spaces"
    modules = root / "stage1 modules"
    sdk.mkdir()
    modules.mkdir()
    for entry in original.iterdir():
        if entry.name not in {"bin", "lib"}:
            (sdk / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (sdk / "lib").mkdir()
    for entry in (original / "lib").iterdir():
        if entry.name != "lean":
            (sdk / "lib" / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (sdk / "lib/lean").mkdir()
    for entry in (original / "lib/lean").iterdir():
        (modules / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
        if entry.name != "Lake" and not entry.name.startswith("Lake."):
            (sdk / "lib/lean" / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (sdk / "bin").mkdir()
    for entry in (original / "bin").iterdir():
        if entry.name not in {"lean", "lake"}:
            (sdk / "bin" / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    # Copy Lake so it observes this SDK's layout instead of its original executable directory.
    shutil.copy2(original / "bin/lake", sdk / "bin/lake")
    (sdk / "bin/lean").write_text(
        '#!/bin/sh\n'
        'if [ -n "${BEAM_TEST_LEAN_LOG-}" ]; then\n'
        '  printf \'%s\\n\' "$@" >> "$BEAM_TEST_LEAN_LOG"\nfi\n'
        'case "${1-}" in\n'
        f"  --print-prefix) printf '%s\\n' {shlex.quote(str(sdk))} ;;\n"
        f"  --print-libdir) printf '%s\\n' {shlex.quote(str(modules))} ;;\n"
        f"  *) export LEAN_SYSROOT={shlex.quote(str(sdk))}; "
        f'exec {shlex.quote(str(original / "bin/lean"))} "$@" ;;\n'
        "esac\n", encoding="utf-8")
    (sdk / "bin/lean").chmod(0o755)
    return sdk, modules


LAKEFILE = '''import Lake
open Lake DSL
package beam
lean_lib Beam.LSP
lean_exe "beam-daemon" where
  root := `Beam.FixtureDaemon

script beamSharedRuntimeFiles do
  let lean ← getLeanInstall
  let lake ← getLakeInstall
  unless (← IO.getEnv "LEAN") == some lean.lean.toString do
    throw <| IO.userError "construction changed its selected compiler"
  unless (← IO.getEnv "LAKE_HOME") == some lake.home.toString do
    throw <| IO.userError "construction did not use its private Lake home"
  for key in ["LEAN_SYSROOT", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_CC", "LEAN_AR", "LEAN_ABORT_ON_PANIC"] do
    if (← IO.getEnv key).isSome then throw <| IO.userError s!"inherited {key}"
  let library := lake.libDir / "Lake.olean"
  unless ← library.pathExists do throw <| IO.userError "missing adapted Lake module"
  -- Stage real SDK bytes, as the normal Beam build does, before recording the inventory.
  let shared := (LakeInstall.ofLean lean).sharedDynlib
  let libraries := shared.deps.push shared
  let destination := System.FilePath.mk ".lake/build/lib/lean"
  IO.FS.createDirAll destination
  for lib in libraries do
    IO.FS.writeBinFile (destination / lib.path.fileName.get!) (← IO.FS.readBinFile lib.path)
  IO.println (Lean.toJson (libraries.map fun lib => "lib/lean/" ++ lib.path.fileName.get!)).compress
  return 0
'''


def main():
    assert os.name != "nt", "nonstandard standalone SDK layouts are supported only on POSIX"
    environment = os.environ.copy()
    for key in ["LEAN", "LEAN_SYSROOT", "LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH",
                "LEAN_CC", "LEAN_AR", "LEAN_ABORT_ON_PANIC"]:
        environment.pop(key, None)
    original = Path(subprocess.check_output(["lean", "--print-prefix"], cwd=ROOT,
                                           env=environment, text=True).strip()).resolve()
    with tempfile.TemporaryDirectory(prefix="beam-nonstandard-sdk-") as temporary:
        directory = Path(temporary).resolve()
        sdk, modules = prepare_sdk(directory, original)
        assert modules.resolve() != (sdk / "lib/lean").resolve()
        assert not (sdk / "lib/lean/Lake.olean").exists()
        source = directory / "target source"
        (source / "Beam").mkdir(parents=True)
        (source / "lakefile.lean").write_text(LAKEFILE, encoding="utf-8")
        (source / "Beam/FixtureDaemon.lean").write_text(
            'def main : IO Unit := IO.println "nonstandard fixture"\n', encoding="utf-8")
        marker = directory / "plugin-observed.json"
        (source / "Beam/LSP.lean").write_text('''import Lean
initialize
  if let some marker ← IO.getEnv "BEAM_TEST_PLUGIN_OBSERVED" then
    IO.FS.writeFile marker Lean.githash
''', encoding="utf-8")
        # This SDK cannot accidentally pass through the standard-layout construction path.
        direct = run([sdk / "bin/lake", "script", "run", "beamSharedRuntimeFiles"],
                     cwd=source, env=environment, timeout=30)
        assert direct.returncode != 0, "fixture did not require nonstandard layout adaptation"
        cache, staging = directory / "cache", directory / "staged target"
        invocation_log = directory / "lean-invocations"
        polluted = dict(environment, BEAM_TEST_PLUGIN_OBSERVED=str(marker),
                        BEAM_TEST_LEAN_LOG=str(invocation_log),
                        **{key: "unrelated-build-override" for key in [
                            "LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_CC", "LEAN_AR",
                            "LEAN_ABORT_ON_PANIC"]})
        command = [FIXTURE, "nonstandard-target", sdk, source, cache, staging]
        built = run(command, cwd=ROOT, env=polluted)
        assert built.returncode == 0, built.stdout + built.stderr
        fingerprint = json.loads(built.stdout)
        assert Path(fingerprint["leanPrefix"]) == sdk
        assert Path(fingerprint["leanLibDir"]) == modules
        record_path, = cache.rglob("metadata.json")
        record_bytes = record_path.read_bytes()
        record = json.loads(record_bytes)
        assert record["toolchainFingerprint"] == fingerprint
        home = record_path.parent / "lake-home"
        assert (home / ".lake/build/bin/lake").read_bytes() == (sdk / "bin/lake").read_bytes()
        assert (home / ".lake/build/lib/lean/Lake.olean").is_symlink()
        assert (home / ".lake/build/lib/lean/Lake.olean").resolve() == (modules / "Lake.olean").resolve()
        assert marker.read_text() == fingerprint["compilerRevision"]
        arguments = invocation_log.read_text().splitlines()
        assert any(arg.startswith("--plugin=") for arg in arguments), arguments
        assert any(arg.endswith("/qualification/Probe.lean") for arg in arguments), arguments
        for artifact in record["artifacts"]:
            staged = staging / Path(artifact["source"]).name
            assert hashlib.sha256(staged.read_bytes()).hexdigest() == artifact["hash"], staged
        marker.unlink()
        reused = run(command, cwd=ROOT, env=polluted, timeout=30)
        assert reused.returncode == 0, reused.stdout + reused.stderr
        assert record_path.read_bytes() == record_bytes, "reuse rewrote the qualified record"
        assert not marker.exists(), "verified cache reuse rebuilt or requalified the target"
    print("nonstandard SDK branch, real target build/plugin qualification, cache reuse and verified staging passed")


if __name__ == "__main__":
    main()
