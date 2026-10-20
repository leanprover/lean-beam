#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""MCP discovery must not resolve an unused runtime at application startup."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from installation_fixture import EXE, stage
from mcp_test_util import MCP_MODERN_PROTOCOL_VERSION


def check_discovery(executable, directory):
    request = {
        "jsonrpc": "2.0", "id": 1, "method": "server/discover",
        "params": {"_meta": {
            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
            "io.modelcontextprotocol/clientInfo": {"name": "beam-application-test", "version": "0"},
        }},
    }
    missing = directory / "missing"
    env = dict(os.environ, BEAM_HOME=str(missing))
    result = subprocess.run(
        [executable], input=json.dumps(request) + "\n", capture_output=True, text=True,
        encoding="utf-8", env=env, cwd=directory, timeout=15,
    )
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    response, = [message for message in responses if message.get("id") == 1]
    assert MCP_MODERN_PROTOCOL_VERSION in response["result"]["supportedVersions"], response
    for flag in ["--lean-cmd", "--lean-plugin", "--beam-cli"]:
        result = subprocess.run([executable, flag, str(missing / "component")],
                                capture_output=True, text=True, encoding="utf-8",
                                env=env, cwd=directory, timeout=15)
        assert result.returncode != 0 and "unexpected" in result.stderr, result
    assert not missing.exists(), "discovery created runtime state"


def main():
    with tempfile.TemporaryDirectory(prefix="beam-mcp-application-") as temporary:
        directory = Path(temporary).resolve()
        source = directory / "source"
        stage(source)
        frontend = Path("libexec") / ("lean-beam-mcp" + EXE)
        source_executable = source / frontend
        assert source_executable.stat().st_nlink == 1
        contents = source_executable.read_bytes()
        cache = directory / "cache/artifacts/mcp"
        for state in ["fresh", "restored"]:
            if state == "restored":
                # Reproduce Lake's cache-first inode without touching the real build/cache.
                cache.parent.mkdir(parents=True)
                shutil.copy2(source_executable, cache)
                source_executable.unlink()
                os.link(cache, source_executable)
                assert source_executable.stat().st_nlink == 2
            application = directory / state
            # Like construction, give the frontend and its private libraries independent files.
            # Darwin can otherwise resolve @loader_path against an executable's cache alias.
            shutil.copytree(source, application, ignore=shutil.ignore_patterns("runtimes"))
            executable = application / frontend
            assert not executable.samefile(source_executable) and executable.stat().st_nlink == 1
            # Discovery must work even when this application's installation cannot be admitted.
            (application / "manifest.json").unlink()
            check_discovery(executable, directory)
            assert not (application / "manifest.json").exists(), "discovery created an installation record"
            assert not (application / "runtimes").exists(), "discovery created target runtimes"
            assert source_executable.read_bytes() == contents, "application mutated its input"
            if state == "restored":
                assert cache.read_bytes() == contents, "application mutated the cached input"
            print(f"MCP discovery without runtime admission passed: {state} input", flush=True)


if __name__ == "__main__":
    main()
