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
               PATH=str(foreign / "bin") + os.pathsep + os.environ["PATH"])
    cli_g = g / record["components"]["frontends"]["cli"]
    cli_h = h / record["components"]["frontends"]["cli"]
    mcp = g / record["components"]["frontends"]["mcp"]
    daemon = g / target["daemon"]
    # Reject a target outside the installation before creating any session state. Existing
    # private state belongs to its owner and must remain untouched when admission fails.
    admission_env = dict(env, HOME=str(directory / "admission-home"),
                         ELAN_HOME=str(directory / "admission-elan"))
    admission_env.pop("BEAM_SESSION_ROOT", None)
    for explicit in [False, True]:
        for existing in [False, True]:
            rejected_project = directory / f"rejected-project-{explicit}-{existing}"
            rejected_project.mkdir()
            (rejected_project / "lean-toolchain").write_text(str(foreign) + "\n")
            (rejected_project / "lakefile.toml").write_text('name = "rejected_target"\n')
            control = (directory / f"rejected-session-{existing}" if explicit
                       else rejected_project / ".beam")
            if existing:
                control.mkdir(mode=0o700)
                (control / "retained-owner-state").write_bytes(b"must not change\n")
                control_mode = control.stat().st_mode
            arguments = ["--root", str(rejected_project)]
            if explicit:
                arguments += ["--session-dir", str(control)]
            refused = run(cli_g, *arguments, "serve", env=admission_env,
                          cwd=rejected_project, ok=False)
            assert "has no runtime for" in refused.stderr, refused.stderr
            if existing:
                assert [path.name for path in control.iterdir()] == ["retained-owner-state"]
                assert (control / "retained-owner-state").read_bytes() == b"must not change\n"
                assert control.stat().st_mode == control_mode
            else:
                assert not control.exists(), f"rejected target created session state: {control}"
            if explicit:
                assert not (rejected_project / ".beam").exists()
    # A Lean source checkout can select its stage1 SDK directly, without a lakefile.
    # Distinguish an existing compiler without a Beam runtime from a missing compiler.
    source_root = directory / "lean4 source"
    source_compiler = source_root / "build/release/stage1/bin" / ("lean" + EXE)
    source_compiler.parent.mkdir(parents=True)
    source_compiler.write_bytes((foreign / "bin" / ("lean" + EXE)).read_bytes())
    source_compiler.chmod(0o755)
    selector = source_root / "lean-toolchain"
    selector.write_text("build/release/stage1\n")
    selector_bytes = selector.read_bytes()
    for arguments, cwd in [((), source_root), (("--root", str(source_root)), directory)]:
        diagnosis = run(cli_g, *arguments, "doctor", env=admission_env, cwd=cwd, ok=False)
        assert diagnosis.returncode == 1
        error = json.loads(diagnosis.stdout)["error"]
        assert error["code"] == "setupError", error
        assert str(source_compiler.resolve()) in error["message"], error
        assert "has no runtime for" in error["message"], error
        assert "compiler was found" in error["message"], error
        assert "docs/CUSTOM_TOOLCHAINS.md" in error["message"], error
        assert f"project root: {source_root}" in error["data"]["diagnostics"], error
        assert "daemon status: absent" in error["data"]["diagnostics"], error
        assert "compiler was found" in diagnosis.stderr, diagnosis.stderr
        assert not (source_root / ".beam").exists(), "doctor created session state"
        assert selector.read_bytes() == selector_bytes, "doctor changed project selection"
    source_compiler.unlink()
    diagnosis = run(cli_g, "doctor", env=admission_env, cwd=source_root, ok=False)
    assert "unavailable locally" in diagnosis.stderr, diagnosis.stderr
    assert "has no runtime for" not in diagnosis.stderr, diagnosis.stderr
    assert not (source_root / ".beam").exists()
    assert not marker.exists(), "doctor invoked a compiler or provider while inspecting the target"
    assert not Path(admission_env["HOME"]).exists()
    assert not Path(admission_env["ELAN_HOME"]).exists()
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

    # An independent installation remains foreign when relocated beneath G's root.
    nested_h = g / "independent-H"
    h.rename(nested_h)
    h = nested_h
    cli_h = h / record["components"]["frontends"]["cli"]

    original_components = [(root / relative, (root / relative).read_bytes())
                           for root in [g, h] for relative in [target["plugin"], "manifest.json"]]
    for missing_record in [False, True]:
        for path, contents in original_components:
            path.write_bytes(contents)
        (project / "lean-toolchain").write_text(str(compiler) + "\n")
        owner_log = directory / f"owner-missing-record-{missing_record}.log"
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
                (g / "manifest.json").write_text("broken foreign provenance\n", encoding="utf-8")
                run(cli_g, "--root", str(project), "doctor", env=env, cwd=project, ok=False)
                # Control is installation-owned too, even when the independent copy has identical bytes.
                registries = list(directory.rglob("beam-daemon.json"))
                assert len(registries) == 1, registries
                registry = registries[0]
                descriptor_bytes = registry.read_bytes()
                descriptor = json.loads(descriptor_bytes)
                for arguments in [("stop",), ("recover", "--generation", descriptor["daemonId"])]:
                    foreign_control = run(cli_g, "--root", str(project), *arguments,
                                          env=env, cwd=project, ok=False)
                    error = json.loads(foreign_control.stdout)["error"]
                    assert error["code"] == "sessionInstallationMismatch", error
                    assert error["data"]["installation_root"] == str(h.resolve()), error
                    assert error["data"]["current_installation_root"] == str(g.resolve()), error
                    assert error["data"]["generation"] == descriptor["daemonId"], error
                    assert foreign_control.stderr.splitlines()[-1] == error["data"]["remedy_command"]
                    assert owner.poll() is None, owner_log.read_text()
                    assert registry.read_bytes() == descriptor_bytes
                run(cli_h, "--root", str(project), "recover", "--force", env=env, cwd=project, ok=False)
                # The owning installation can clean up without its plugin, selector, or manifest.
                (h / target["plugin"]).unlink()
                if missing_record:
                    (h / "manifest.json").unlink()
                else:
                    (h / "manifest.json").write_text("broken provenance\n", encoding="utf-8")
                run(cli_h, "--root", str(project), "stop", env=env, cwd=project)
                assert owner.wait(timeout=30) == 0, owner_log.read_text()
            finally:
                if owner.poll() is None:
                    run(cli_h, "--root", str(project), "stop", env=env, cwd=project)
                    owner.wait(timeout=30)
    assert not marker.exists(), "a foreign component was invoked before rejection"
    print("shipped component restrictions, independently validated daemon identity, cross-installation rejection, and recovery passed")
