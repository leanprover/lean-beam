#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Local target lookup never executes candidate compilers, providers, or construction tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
suffix = ".exe" if os.name == "nt" else ""
with tempfile.TemporaryDirectory(prefix="beam installation lookup-") as temporary:
    directory = Path(temporary).resolve()
    tools = directory / "elan/toolchains"
    tools.mkdir(parents=True)
    calls = directory / "foreign-invocations"
    for name in ["sdk-0", "sdk-1", "foreign"]:
        command = directory / name / "bin" / ("lean" + suffix)
        command.parent.mkdir(parents=True)
        command.write_text(f'#!/bin/sh\nprintf invoked >> "{calls}"\nexit 99\n')
        command.chmod(0o755)
    environment = dict(os.environ, ELAN_HOME=str(directory / "elan"),
                       BEAM_HOME=str(directory / "foreign"))
    elan = shutil.which("elan")
    assert elan, "local link fixtures require elan"

    def link(alias, target):
        # Elan uses directory junctions on Windows; no developer-mode symlink privilege.
        subprocess.run([elan, "toolchain", "link", alias, directory / target],
                       env=environment, check=True, capture_output=True, timeout=15)

    def run_lookup(*arguments):
        subprocess.run([ROOT / ".lake/build/bin" / ("beam-installation-lookup-test" + suffix),
                        directory, *arguments], env=environment, check=True, timeout=90)

    for alias, target in [("fixture-alias", "sdk-0"), ("fixture-second", "sdk-1"),
                          ("foreign-alias", "foreign"),
                          ("leanprover--lean4---v4.34.1", "sdk-0")]:
        link(alias, target)
    for name in ["ordinary-local", "stable", "beta", "nightly", "lean-toolchain"]:
        ordinary = tools / name
        ordinary.mkdir()
        # A matching compiler behind an inner link must not turn this ordinary leaf into
        # a custom Elan link or admit a floating selector.
        if os.name == "nt":
            subprocess.run(["cmd", "/d", "/c", "mklink", "/J", ordinary / "bin",
                            directory / "sdk-0/bin"], check=True, capture_output=True, timeout=15)
        else:
            (ordinary / "bin").symlink_to(directory / "sdk-0/bin", target_is_directory=True)
    (directory / "project").mkdir()
    selectors = directory / "selectors"
    for name in ["absent", "valid-link", "dangling-link", "unreadable"]:
        (selectors / name).mkdir(parents=True)
    selector_target = selectors / "selector-content"
    selector_target.write_text("fixture-alias\n", encoding="utf-8")
    (selectors / "valid-link/lean-toolchain").symlink_to(selector_target)
    (selectors / "dangling-link/lean-toolchain").symlink_to(selectors / "missing-content")
    if os.name != "nt":
        (selectors / "fifo").mkdir()
        (selectors / "fifo-link").mkdir()
        os.mkfifo(selectors / "fifo/lean-toolchain", 0o600)
        (selectors / "fifo-link/lean-toolchain").symlink_to(selectors / "fifo/lean-toolchain")
    unreadable = selectors / "unreadable/lean-toolchain"
    unreadable.write_text("fixture-alias\n", encoding="utf-8")
    locked_handle = None
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        locked_handle = kernel.CreateFileW(str(unreadable), 0x80000000, 0, None, 3, 0x80, None)
        assert locked_handle != wintypes.HANDLE(-1).value, ctypes.get_last_error()
    else:
        assert os.geteuid() != 0, "selector permission regression must run without root privileges"
        unreadable.parent.chmod(0)
    try:
        run_lookup()
        # The exact installed release remains present throughout every alias transition.
        run_lookup("shadowed-alias", "absent")
        link("v4.34.1", "foreign")
        run_lookup("shadowed-alias", "healthy")
        compiler = directory / "foreign/bin" / ("lean" + suffix)
        contents = compiler.read_bytes()
        compiler.unlink()
        run_lookup("shadowed-alias", "missing-compiler")
        compiler.mkdir()
        run_lookup("shadowed-alias", "nonfile-compiler")
        compiler.rmdir()
        compiler.parent.rmdir()
        compiler.parent.write_text("compiler parent must be a directory\n")
        try:
            run_lookup("shadowed-alias", "observation-error")
        finally:
            compiler.parent.unlink()
            compiler.parent.mkdir()
            compiler.write_bytes(contents)
            compiler.chmod(0o755)
        (directory / "foreign").rename(directory / "foreign-moved")
        run_lookup("shadowed-alias", "dangling")
        alias = tools / "v4.34.1"
        if os.name == "nt":
            alias.rmdir()
        else:
            alias.unlink()
        run_lookup("shadowed-alias", "removed")
    finally:
        if os.name == "nt":
            kernel.CloseHandle(locked_handle)
        else:
            unreadable.parent.chmod(0o700)
    assert not calls.exists(), "lookup invoked a candidate compiler before rejecting it"

    # Execute only a fake source installer: verify the emitted POSIX quoting and complete target set.
    recipe = subprocess.run(
        [ROOT / ".lake/build/bin" / ("beam-installation-lookup-test" + suffix), directory, "remedy"],
        env=environment, check=True, capture_output=True, text=True, timeout=30)
    remedy = json.loads(recipe.stdout)
    checkout = directory / "Beam checkout's"
    (checkout / "scripts").mkdir(parents=True)
    installer = checkout / "scripts/install-beam.sh"
    installer.write_text("#!/bin/sh\nexec python3 -c 'import json,os,sys; "
                         "print(json.dumps([os.environ[\"BEAM_INSTALL_ROOT\"], *sys.argv[1:]]))' \"$@\"\n")
    installer.chmod(0o755)
    executed = subprocess.run(["bash", "-c", remedy["command"]], cwd=checkout,
                              env=environment, capture_output=True, text=True, check=True, timeout=15)
    assert json.loads(executed.stdout) == [
        remedy["install_root"], "--toolchain", "leanprover/lean4:v4.35.0",
        "--custom-toolchain", "retained'alias", "--custom-toolchain", "requested'alias"]
    assert not calls.exists(), "rendering a remedy invoked a candidate compiler"
