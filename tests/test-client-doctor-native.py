#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Portable static client checks against the already-built native CLI; no client is launched."""

import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent.parent
EXE = ".exe" if os.name == "nt" else ""
CLI = REPO / ".lake/build/bin" / ("beam-cli" + EXE)


@contextmanager
def inspection_cli():
    # Darwin may resolve a cache hard link by its cache pathname. Keep an independent
    # executable beside the staged libraries, without editing the build or cache entry.
    descriptor, name = tempfile.mkstemp(prefix="beam-client-doctor-", suffix=EXE, dir=CLI.parent)
    os.close(descriptor)
    command = Path(name)
    try:
        shutil.copyfile(CLI, command)
        assert not command.is_symlink() and command.stat().st_nlink == 1, command
        assert not command.samefile(CLI) and command.read_bytes() == CLI.read_bytes(), command
        command.chmod(0o700)
        yield command
    finally:
        command.unlink()


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
    with (tempfile.TemporaryDirectory(prefix="beam client doctor Ω ") as temporary,
          inspection_cli() as cli):
        root = Path(temporary).resolve()
        home, workspace = root / "home", root / "workspace"
        home.mkdir()
        workspace.mkdir()
        (workspace / ".git").mkdir()
        env = dict(os.environ, HOME=str(home), USERPROFILE=str(home))
        for key in ["CODEX_HOME", "CLAUDE_HOME", "CLAUDE_CONFIG_DIR", "BEAM_CLAUDE_MCP_CONFIG",
                    "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR",
                    "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "VIBE_HOME",
                    "BEAM_AGY_HOME", "BEAM_SESSION_ROOT"]:
            env.pop(key, None)

        def inspect(*args, expected=0, environment=None, report=True):
            before = snapshot(root)
            result = subprocess.run([cli, "doctor", "clients", *args, "--json"], cwd=workspace,
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
        def agy_config(**settings):
            return json.dumps({"mcpServers": {"lean-beam": {
                "command": str(launcher), **settings}}}).encode("utf-8")

        agy = home / ".gemini/config/mcp_config.json"
        project_agy = workspace / ".agents/mcp_config.json"
        for config in (agy, project_agy):
            config.parent.mkdir(parents=True)
            for contents in (b"\xef\xbb\xbf", b"\xef\xbb\xbf \n\t\r", b"\xef\xbb\xbf{}",
                             b" \n\t\r"):
                config.write_bytes(contents)
                client = inspect("agy")["clients"][0]
                assert client["discovered"] and client["mcp"] == "notConfigured", client
            config.write_bytes(b"\xef\xbb\xbf" + agy_config())
            client = inspect("agy", expected=expected)["clients"][0]
            assert client["discovered"] and client["mcp"] == ("unverified" if expected else "checked"), client
            assert any(Path(s["path"]) == config and s["state"] == "ok" for s in client["sources"]), client
            assert any(f["code"] == "launch.file" for f in client["findings"]), client
            config.unlink()

        for name in (".agent", "_agents"):
            alternate = workspace / name / "mcp_config.json"
            alternate.parent.mkdir()
            alternate.write_bytes(agy_config())
            client = inspect("agy", expected=expected)["clients"][0]
            assert any(Path(source["path"]) == alternate and source["state"] == "ok"
                       for source in client["sources"]), client
            alternate.unlink()

        jsonc = agy_config()[:-1] + b",}"
        agy.write_bytes(b"\xef\xbb\xbf{/* header */ // comment\n" + jsonc[1:])
        client = inspect("agy", expected=expected)["clients"][0]
        assert any(f["code"] == "launch.file" for f in client["findings"]), client
        for raw in (b'{"key":NaN}', b'{"key":Infinity}'):
            agy.write_bytes(raw)
            client = inspect("agy", expected=1)["clients"][0]
            assert any(f["code"] == "config.syntax" for f in client["findings"]), client

        for settings in ({"httpUrl": None}, {"type": "sse"}, {"transport": "http"},
                         {"cwd": {}}, {"env": []}, {"enabledTools": {}}, {"disabledTools": [1]}):
            agy.write_bytes(agy_config(**settings))
            client = inspect("agy", expected=1)["clients"][0]
            assert client["mcp"] == "error", client
            assert any(f["code"] == "mcp.invalidEntry" for f in client["findings"]), client

        project_agy.write_bytes(agy_config())
        agy.write_bytes(agy_config(disabled=True))
        client = inspect("agy", expected=2)["clients"][0]
        assert client["mcp"] == "unverified", client
        assert any(f["code"] == "config.layers" and f["status"] == "unknown" for f in client["findings"]), client
        assert {Path(f["source"]) for f in client["findings"] if f["code"] == "mcp.definition"} == {
            agy, project_agy}, client
        project_agy.unlink()
        client = inspect("agy", expected=1)["clients"][0]
        assert any(f["code"] == "mcp.disabled" for f in client["findings"]), client

        for key in ("enabledTools", "disabledTools"):
            agy.write_bytes(agy_config(**{key: ["lean_run_at"]}))
            client = inspect("agy", expected=2)["clients"][0]
            assert client["mcp"] == "unverified", client
            assert any(f["code"] == "launch.overrides" and f["status"] == "unknown"
                       and f["key"] == f"mcpServers.lean-beam.{key}" for f in client["findings"]), client
        agy.unlink()

        plugin = workspace / "_agent/plugins/example"
        plugin_skill = plugin / "skills/lean-beam/SKILL.md"
        plugin_skill.parent.mkdir(parents=True)
        plugin_skill.write_text("Plugin Lean skill", encoding="utf-8")
        plugin_config = plugin / "mcp_config.json"
        plugin_config.write_bytes(b"// plugin config\n" + agy_config())
        client = inspect("agy", expected=2)["clients"][0]
        assert (client["mcp"], client["skill"]) == ("unverified", "unverified"), client
        assert "skill.notConfigured" not in {f["code"] for f in client["findings"]}, client
        shutil.rmtree(plugin)

        if os.name != "nt":
            agy.write_bytes(agy_config())
            alias = root / "alias-home"
            alias.symlink_to(home, target_is_directory=True)
            physical = inspect("agy", expected=expected)["clients"][0]
            aliased = inspect("agy", expected=expected, environment=dict(env, HOME=str(alias)))["clients"][0]
            assert physical["sources"] == aliased["sources"], (physical, aliased)
            agy.unlink()

        nonrepo_parent = home / "nonrepo"
        nonrepo_workspace = nonrepo_parent / "workspace"
        nonrepo_workspace.mkdir(parents=True)
        ancestor_agy = nonrepo_parent / ".agents/mcp_config.json"
        ancestor_skill = nonrepo_parent / ".agents/skills/lean-beam/SKILL.md"
        ancestor_skill.parent.mkdir(parents=True)
        ancestor_skill.write_text("Parent skill\n", encoding="utf-8")
        ancestor_agy.write_bytes(agy_config())
        custom_home = root / "custom agy home"
        nonrepo_env = dict(env, BEAM_AGY_HOME=str(custom_home))
        result = subprocess.run(
            [str(cli), "--root", str(nonrepo_workspace), "doctor", "clients", "agy", "--json"],
            cwd=nonrepo_workspace, env=nonrepo_env, capture_output=True, text=True, check=False,
        )
        assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
        client = json.loads(result.stdout)["clients"][0]
        assert not client["discovered"], client
        assert (client["mcp"], client["skill"]) == ("notConfigured", "notConfigured"), client
        assert {Path(s["path"]) for s in client["sources"]}.isdisjoint({ancestor_agy, ancestor_skill}), client
        remediation = next(f["remediation"] for f in client["findings"] if f["code"] == "mcp.notConfigured")
        assert str(custom_home / ".gemini/config/mcp_config.json") in remediation, client
        assert "agy mcp add" not in remediation, client
        if os.name == "nt":
            no_home = {key: value for key, value in env.items() if key != "HOME"}
            result = inspect("codex", expected=2, environment=no_home)
            assert any(Path(source["path"]) == codex for source in result["clients"][0]["sources"]), result
        assert launcher.read_bytes() == b"static inspection only; this is not a runnable MCP server"
    print("Native client doctor: aliases, optional integration, typed failures and read-only files passed")


if __name__ == "__main__":
    main()
