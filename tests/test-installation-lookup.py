#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Local target lookup never executes candidate compilers, providers, or construction tools."""

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
                       BEAM_HOME=str(directory / "foreign"),
                       BEAM_BUNDLE_DIR=str(directory / "forbidden-build"),
                       BEAM_INSTALL_BUNDLE_DIR=str(directory / "foreign-cache"))
    elan = shutil.which("elan")
    assert elan, "local link fixtures require elan"
    for alias, target in [("fixture-alias", "sdk-0"), ("fixture-second", "sdk-1"),
                          ("foreign-alias", "foreign"),
                          ("leanprover--lean4---v4.33.1", "sdk-0")]:
        # Elan uses directory junctions on Windows; no developer-mode symlink privilege.
        subprocess.run([elan, "toolchain", "link", alias, directory / target],
                       env=environment, check=True, capture_output=True, timeout=15)
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
    subprocess.run([ROOT / ".lake/build/bin" / ("beam-installation-lookup-test" + suffix), directory],
                   env=environment, check=True, timeout=90)
    assert not calls.exists(), "lookup invoked a candidate compiler before rejecting it"
    assert not (directory / "forbidden-build").exists(), "lookup attempted runtime construction"
    assert not (directory / "foreign-cache").exists(), "lookup searched or created a foreign provider cache"
