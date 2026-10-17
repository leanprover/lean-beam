#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Validate complete construction records through a non-shipped library fixture."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
suffix = ".exe" if os.name == "nt" else ""
fixture = ROOT / ".lake/build/bin" / ("beam-installation-construction-test" + suffix)


def check(prefix, environment):
    with tempfile.TemporaryDirectory(prefix=prefix) as temporary:
        directory = Path(temporary)
        linked = directory / "linked-inventory"
        linked.mkdir()
        target = directory / "empty-link-target"
        target.mkdir()
        if os.name == "nt":
            subprocess.run(["cmd", "/d", "/c", "mklink", "/J", linked / "extra", target],
                           check=True, capture_output=True, timeout=15)
        else:
            (linked / "extra").symlink_to(target, target_is_directory=True)
        subprocess.run([fixture, directory], env=environment, check=True, timeout=90)
        installation = directory / "one-target"
        assert (installation / "payload.bin").read_bytes() == bytes([0, 10, 13, 10, 26, 128, 255])
        manifest = json.loads((installation / "manifest.json").read_text(encoding="utf-8"))
        expected = {"LICENSE", "libexec/beam-cli", "libexec/lean-beam-mcp", "payload.bin",
                    "runtimes/0/daemon", "runtimes/0/plugin", "runtimes/1/daemon", "runtimes/1/plugin"}
        assert {artifact["destination"] for artifact in manifest["artifacts"]} == expected
        for artifact in manifest["artifacts"]:
            assert artifact["source"] == artifact["destination"], artifact
            actual = hashlib.sha256((installation / artifact["destination"]).read_bytes()).hexdigest()
            assert actual == artifact["hash"], artifact


if os.name == "nt":
    # Native Windows paths already contain backslashes. Use the real installed hash tool.
    check("beam construction-", os.environ.copy())
else:
    tools = [(name, shutil.which(name)) for name in ["sha256sum", "shasum"]]
    assert any(path for _, path in tools), "construction fixture needs a real checksum tool"
    for name, executable in tools:
        if executable is None:
            continue
        with tempfile.TemporaryDirectory(prefix="beam-checksum-tool-") as temporary:
            tool = Path(temporary) / name
            tool.symlink_to(executable)
            environment = dict(os.environ, PATH=temporary)
            for prefix in ["beam construction-", "beam construction-back\\slash-",
                           "beam construction-new\nline-"]:
                check(prefix, environment)
            print(f"construction raw-byte hashes and escaped filenames: {name} passed", flush=True)

    valid = "a" * 64
    for label, token, exit_code in [("empty", "", 0), ("short", "abc", 0), ("bad-hex", "g" * 64, 0),
                                    ("double-marker", "\\\\" + valid, 0), ("nonzero", valid, 7)]:
        with tempfile.TemporaryDirectory(prefix="beam-checksum-reject-") as temporary:
            directory = Path(temporary)
            tool = directory / "sha256sum"
            tool.write_text('#!/bin/sh\nif [ "${1-}" = --version ]; then exit 0; fi\n' +
                            "printf '%s\\n' " + shlex.quote(token + "  -") +
                            f"\nexit {exit_code}\n", encoding="utf-8")
            tool.chmod(0o755)
            result = subprocess.run([fixture, directory / "construction"],
                                    env=dict(os.environ, PATH=temporary),
                                    capture_output=True, text=True, encoding="utf-8", timeout=90)
            message = "SHA-256 command failed" if exit_code else "invalid SHA-256 digest"
            assert result.returncode != 0 and message in result.stderr, (label, result)
            assert not (directory / "construction/one-target/manifest.json").exists(), label
    print("construction malformed checksums and failed hash commands rejected", flush=True)
