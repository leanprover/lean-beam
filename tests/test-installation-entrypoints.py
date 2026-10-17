#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Shipped entry points cannot select foreign components or attach across installations."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from installation_fixture import EXE, stage


def run(command, *arguments, env, cwd, ok=True, input=None):
    result = subprocess.run([command, *arguments], env=env, cwd=cwd, input=input,
                            text=True, capture_output=True, timeout=30)
    if ok:
        assert result.returncode == 0, (arguments, result.stdout, result.stderr)
    else:
        assert result.returncode != 0, (arguments, result.stdout, result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix="beam-entrypoints-") as temporary:
    directory = Path(temporary).resolve()
    g = directory / "G with spaces"
    h = directory / "H"
    marker = directory / "foreign-invocations"
    construction_shim = directory / "construction-shim"
    construction_shim.mkdir()
    fake_elan = construction_shim / "elan"
    fake_elan.write_text(f'#!/bin/sh\nprintf invoked >> "{marker}"\nexit 99\n')
    fake_elan.chmod(0o755)
    # The fixture captures its compiler first; constructing with it must not reselect via elan.
    compiler = stage(g, constructor_env=dict(os.environ,
        PATH=str(construction_shim) + os.pathsep + os.environ["PATH"]))
    assert not marker.exists(), "construction reselected the captured frontend SDK"
    shutil.copytree(g, h)
    record = json.loads((g / "manifest.json").read_text())
    assert json.loads((h / "manifest.json").read_text()) == record
    target, = record["components"]["targets"]
    project = directory / "project"
    project.mkdir()
    (project / "lean-toolchain").write_text(str(compiler) + "\n")
    (project / "lakefile.toml").write_text('name = "entrypoint_smoke"\n[[lean_lib]]\nname = "Smoke"\n')
    (project / "Smoke.lean").write_text("def smoke : Nat := 42\n")
    foreign = directory / "foreign"
    (foreign / "bin").mkdir(parents=True)
    for name in ["lean", "lake", "elan", "beam-cli", "beam-daemon", "lean-beam-mcp"]:
        path = foreign / "bin" / (name + EXE)
        path.write_text(f'#!/bin/sh\nprintf invoked >> "{marker}"\nexit 99\n')
        path.chmod(0o755)
    env = dict(os.environ, BEAM_HOME=str(foreign),
               BEAM_SESSION_ROOT=str(directory / "sessions"),
               BEAM_BUNDLE_DIR=str(directory / "forbidden-runtime-cache"),
               BEAM_INSTALL_BUNDLE_DIR=str(directory / "forbidden-install-cache"),
               PATH=str(foreign / "bin") + os.pathsep + os.environ["PATH"])
    cli_g = g / record["components"]["frontends"]["cli"]
    cli_h = h / record["components"]["frontends"]["cli"]
    mcp = g / record["components"]["frontends"]["mcp"]
    daemon = g / target["daemon"]
    # Frontends and each separately compiled target carry independent shared-library closure.
    # Removing the selected core must fail even while the original SDK remains available.
    core = "libleanshared" + (".dll" if os.name == "nt" else ".dylib" if sys.platform == "darwin" else ".so")
    for executable, arguments, library in [
        (cli_g, ["--version"], g / ("libexec" if os.name == "nt" else "lib/lean") / core),
        (mcp, ["--version"], g / ("libexec" if os.name == "nt" else "lib/lean") / core),
        (daemon, ["build-info"], daemon.parent / core if os.name == "nt" else daemon.parent.parent / "lib/lean" / core),
    ]:
        assert library.is_file(), f"missing constructed runtime library: {library}"
        run(executable, *arguments, env=env, cwd=project)
        parked = library.with_name(library.name + ".parked")
        library.rename(parked)
        try:
            run(executable, *arguments, env=env, cwd=project, ok=False)
        finally:
            parked.rename(library)
    doctor = run(cli_g, "--root", str(project), "doctor", env=env, cwd=project)
    assert target["lean"] in doctor.stdout and str(g / target["plugin"]) in doctor.stdout
    for flag in ["--beam-cli", "--lean-cmd", "--lean-plugin"]:
        run(mcp, flag, str(cli_h), env=env, cwd=project, ok=False)
    run(daemon, "--root", str(project), "--workspace-id", "fixture", "--lean-cmd",
        str(foreign / "bin/lean"), env=env, cwd=project, ok=False)
    forged = run(daemon, "--root", str(project), "--workspace-id", "fixture", "--daemon-id",
                 "forged", "--config-hash", "foreign", env=env, cwd=project, ok=False)
    assert "does not belong" in forged.stderr
    helper_client = Path(__file__).resolve().parent.parent / ".lake/build/bin" / ("beam-lake-helper-client-fixture" + EXE)
    helper = run(helper_client, str(daemon), "server-env", env=env, cwd=project,
                 input=json.dumps({"root": str(project), "leanCmd": str(foreign / "bin/lean")}))
    assert "error" in json.loads(helper.stdout), helper.stdout

    owner_log = directory / "owner.log"
    with owner_log.open("w") as log:
        owner = subprocess.Popen([cli_h, "--root", project, "serve"], cwd=project, env=env,
                                 stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 30
            while "serving Beam session" not in owner_log.read_text():
                assert owner.poll() is None, owner_log.read_text()
                assert time.monotonic() < deadline, owner_log.read_text()
                time.sleep(0.05)
            update = run(cli_h, "--root", str(project), "update", "Smoke.lean", env=env, cwd=project)
            assert "version" in update.stdout
            denied = run(cli_g, "--root", str(project), "update", "Smoke.lean", env=env,
                         cwd=project, ok=False)
            assert "config" in denied.stderr.lower(), denied.stderr
            (project / "lean-toolchain").write_text(str(foreign) + "\n")
            run(cli_g, "--root", str(project), "doctor", env=env, cwd=project, ok=False)
            (g / target["plugin"]).unlink()
            run(cli_g, "--root", str(project), "doctor", env=env, cwd=project, ok=False)
            # Cleanup uses recorded ownership even with foreign selection and broken current G.
            run(cli_g, "--root", str(project), "stop", env=env, cwd=project)
            assert owner.wait(timeout=30) == 0, owner_log.read_text()
        finally:
            if owner.poll() is None:
                run(cli_h, "--root", str(project), "stop", env=env, cwd=project)
                owner.wait(timeout=30)
    assert not marker.exists(), "a foreign component was invoked before rejection"
    assert not (directory / "forbidden-runtime-cache").exists()
    assert not (directory / "forbidden-install-cache").exists()
    print("shipped component restrictions, independently validated daemon identity, cross-installation rejection, and recovery passed")
