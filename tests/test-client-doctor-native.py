#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Portable static client checks against the already-built native CLI; no client is launched."""

import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""
CLI = REPO / ".lake/build/bin" / ("beam-cli" + EXE)


def snapshot(root):
    result = {}
    for path in root.rglob("*"):
        metadata = path.lstat()
        result[str(path.relative_to(root))] = (
            metadata.st_mode, metadata.st_mtime_ns,
            hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(metadata.st_mode) else None,
        )
    return result


def main():
    with tempfile.TemporaryDirectory(prefix="beam client doctor Ω ") as temporary:
        root = Path(temporary).resolve()
        home, workspace = root / "home", root / "workspace"
        home.mkdir()
        workspace.mkdir()
        (workspace / ".git").mkdir()
        env = dict(os.environ, HOME=str(home), USERPROFILE=str(home))
        for key in ["CODEX_HOME", "CLAUDE_HOME", "CLAUDE_CONFIG_DIR", "BEAM_CLAUDE_MCP_CONFIG",
                    "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR",
                    "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "VIBE_HOME", "BEAM_SESSION_ROOT"]:
            env.pop(key, None)

        def inspect(*args, expected=0, environment=None, report=True):
            before = snapshot(root)
            result = subprocess.run([CLI, "doctor", "clients", *args, "--json"], cwd=workspace,
                                    env=env if environment is None else environment,
                                    capture_output=True, text=True, encoding="utf-8", timeout=15)
            assert result.returncode == expected, (result.returncode, result.stdout, result.stderr)
            value = json.loads(result.stdout)
            assert snapshot(root) == before, "client inspection wrote files or created Beam state"
            if report:
                assert value["kind"] == "clientInspection", value
                assert not result.stderr, result.stderr
            else:
                assert not value["ok"] and value["error"]["code"] == "invalidParams", value
                assert "kind" not in value, value
            return value

        pi = inspect("pi")
        assert pi["clients"][0]["mcp"] == "notApplicable", pi
        launcher = root / ("lean-beam-mcp" + EXE)
        launcher.write_bytes(b"static inspection only; this is not a runnable MCP server")
        launcher.chmod(0o700)
        codex = home / ".codex/config.toml"
        codex.parent.mkdir()
        codex.write_text("[mcp_servers.alias]\ncommand = " + json.dumps(str(launcher)) +
                         "\nsupports_parallel_tool_calls = true\n", encoding="utf-8")
        expected = 2 if os.name == "nt" else 0
        result = inspect("codex", expected=expected)
        findings = {finding["code"] for finding in result["clients"][0]["findings"]}
        assert "launch.file" in findings, result
        assert ("launch.permissions" in findings) == (os.name == "nt"), result
        assert "mcp.notConfigured" not in findings, result
        inspect("codex", "--config", str(root / "absent.toml"), expected=1)
        inspect("unknown-client", expected=2, report=False)
        opencode = home / ".config/opencode/opencode.json"
        opencode.parent.mkdir(parents=True)
        local = {"type": "local", "command": [str(launcher)]}
        source = json.dumps({"mcp": {"lean-beam": {**local, "timeout": "TIMEOUT"}}})
        for spelling in ["5000", "5000.0", "50000e-1"]:
            opencode.write_text(source.replace('"TIMEOUT"', spelling), encoding="utf-8")
            value = inspect("opencode", expected=expected)
            codes = {f["code"] for f in value["clients"][0]["findings"]}
            assert "launch.file" in codes and "mcp.invalidEntry" not in codes, value
        opencode.write_text(json.dumps({"mcp": {"lean-beam": {**local, "enabled": False}}}), encoding="utf-8")
        (workspace / "opencode.json").write_text(json.dumps({"mcp": {"lean-beam": {
            **local, "disabled": False, "timeout": 5000}}}), encoding="utf-8")
        value = inspect("opencode", expected=2)
        assert value["clients"][0]["mcp"] == "unverified", value
        assert any(f["code"] == "config.sourceUnsupported" for f in value["clients"][0]["findings"]), value
        vibe = home / ".vibe/config.toml"
        vibe.parent.mkdir()
        vibe.write_text("[[mcp_servers]]\nname = 'lean-beam'\ntransport = 'stdio'\ndisabled = true\n"
                        "command = " + json.dumps(str(launcher)) + "\n", encoding="utf-8")
        result = inspect("vibe", expected=1)
        assert any(f["code"] == "mcp.disabled" for f in result["clients"][0]["findings"]), result
        if os.name == "nt":
            no_home = {key: value for key, value in env.items() if key != "HOME"}
            result = inspect("codex", expected=2, environment=no_home)
            assert any(Path(source["path"]) == codex for source in result["clients"][0]["sources"]), result
        assert launcher.read_bytes() == b"static inspection only; this is not a runnable MCP server"
    print("Native client doctor: aliases, optional integration, typed failures and read-only files passed")


if __name__ == "__main__":
    main()
