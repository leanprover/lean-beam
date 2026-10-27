#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""A bundled MCP workspace retains its generation and readmits before every Lean operation."""

import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile

TESTS = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(TESTS))
spec = importlib.util.spec_from_file_location("mcp_stdio_tests", TESTS / "test-mcp-stdio.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def connect(server, project, env, modern, label):
    client = module.McpClient(project, project, 30, label=label,
                              server_command=[str(server)], extra_env=env)
    if modern:
        response = client.modern_request("server/discover")
    else:
        response = client.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "runtime-generation-test", "version": "0"},
        })
        client.notify("notifications/initialized")
    assert "result" in response, response
    return client


def tool(client, modern, name, arguments):
    request = client.modern_request if modern else client.request
    return request("tools/call", {"name": name, "arguments": arguments})


def sync(client, modern, project):
    return tool(client, modern, "lean_sync", {
        "path": "Main.lean", "workspace": {"root": str(project)},
    })


def version(response):
    assert response.get("result", {}).get("isError") is False, response
    value = response["result"]["structuredContent"]["version"]
    assert isinstance(value, int), response
    return value


def project_at(root):
    root.mkdir()
    (root / "lakefile.toml").write_text('name = "runtime_generation"\n')
    (root / "Main.lean").write_text('def answer : Nat := 42\n')
    return root


def check(server, provenance, foreign_selector, *, env, matching_selectors=None):
    server, provenance = Path(server).resolve(), Path(provenance).resolve()
    original = provenance.read_bytes()
    with tempfile.TemporaryDirectory(prefix="beam-mcp-generation-") as directory:
        base = Path(directory).resolve()
        for modern in [False, True]:
            era = "modern" if modern else "legacy"
            for scenario in ["foreign selector", "unavailable selector", "generation"]:
                project = project_at(base / (era + "-" + scenario.replace(" ", "-")))
                healthy = project_at(base / (era + "-healthy-" + scenario.replace(" ", "-")))
                client = connect(server, project, env, modern, era + ": " + scenario)
                try:
                    first_version = version(sync(client, modern, project))
                    (project / "Main.lean").write_text('def answer : Nat := 43\n')
                    retained_version = version(sync(client, modern, project))
                    assert retained_version > first_version
                    healthy_version = version(sync(client, modern, healthy))
                    if scenario == "generation":
                        record = json.loads(original)
                        replacement = "f" * 64 if record["payloadHash"] != "f" * 64 else "a" * 64
                        provenance.write_text(json.dumps(dict(record, payloadHash=replacement)))
                    else:
                        selector = foreign_selector if scenario == "foreign selector" else "beam-not-installed"
                        (project / "lean-toolchain").write_text(selector + "\n")
                    rejected = sync(client, modern, project)
                    assert rejected.get("error", {}).get("code") == -32600, rejected
                    message = rejected["error"]["message"]
                    if scenario == "generation":
                        assert "generation changed" in message and "restart" in message, rejected
                    elif scenario == "foreign selector":
                        assert "has no runtime for" in message and "compiler was found" in message, rejected
                        assert "install Beam for this exact target" in message, rejected
                    else:
                        assert "unavailable locally" in message and "install or link" in message, rejected
                    if scenario == "generation":
                        identity = tool(client, modern, "beam_version", {})
                        assert identity.get("error", {}).get("code") == -32603, identity
                        assert "Beam installation generation changed" in identity["error"]["message"], identity
                        assert "restart" in identity["error"]["message"], identity
                        dropped = tool(client, modern, "lean_drop_workspace", {"workspace": {"root": str(project)}})
                        assert dropped["result"]["structuredContent"]["dropped"] is True, dropped
                        recreated = sync(client, modern, project)
                        assert recreated.get("error", {}).get("code") == -32600, recreated
                        assert "generation changed" in recreated["error"]["message"], recreated
                        provenance.write_bytes(original)
                        version(sync(client, modern, project))
                    else:
                        # Rejection of A does not replace it or interfere with initialized B.
                        assert version(sync(client, modern, healthy)) == healthy_version
                        (project / "lean-toolchain").unlink()
                        assert version(sync(client, modern, project)) == retained_version
                    provenance.write_text("{broken provenance")
                    request = client.modern_request if modern else client.request
                    assert "result" in request("tools/list")
                    dropped = tool(client, modern, "lean_drop_workspace", {"workspace": {"root": str(project)}})
                    assert dropped["result"]["structuredContent"]["dropped"] is True, dropped
                    client.close_input()
                    assert client.wait_for_exit_after_eof(30) == 0
                finally:
                    provenance.write_bytes(original)
                    (project / "lean-toolchain").unlink(missing_ok=True)
                    client.close()
            if matching_selectors:
                project = project_at(base / (era + "-aliases"))
                selector_file = project / "lean-toolchain"
                selector_file.write_text(matching_selectors[0] + "\n")
                client = connect(server, project, env, modern, era + ": selector aliases")
                try:
                    first = version(sync(client, modern, project))
                    (project / "Main.lean").write_text('def answer : Nat := 44\n')
                    retained = version(sync(client, modern, project))
                    assert retained > first
                    minted = tool(client, modern, "lean_run_at_handle", {
                        "path": "Main.lean", "version": retained, "line": 1, "character": 0,
                        "text": "def aliasWitness : Nat := 7", "workspace": {"root": str(project)},
                    })
                    assert minted.get("result", {}).get("isError") is False, minted
                    minted = minted["result"]["structuredContent"]
                    assert minted.get("success") is True, minted
                    handle = minted["next_handle"]
                    selector_file.write_text(matching_selectors[1] + "\n")
                    assert version(sync(client, modern, project)) == retained
                    continued = tool(client, modern, "lean_run_with", {
                        "path": "Main.lean", "handle": handle, "text": "#check aliasWitness",
                        "workspace": {"root": str(project)},
                    })
                    assert continued.get("result", {}).get("isError") is False, continued
                    assert continued["result"]["structuredContent"].get("success") is True, continued
                finally:
                    client.close()
    print("bundled MCP legacy/modern admission, isolation, aliases, generation, and cleanup passed")


if __name__ == "__main__":
    check(*sys.argv[1:], env=os.environ.copy())
