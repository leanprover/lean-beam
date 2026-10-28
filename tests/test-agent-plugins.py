#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Opt-in smoke test with installed Codex/Claude clients; no model requests or real Beam process."""

import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]


def run(client, args, cwd, env):
    with subprocess.Popen([client, *args], cwd=cwd, env=env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          start_new_session=True) as process:
        try:
            stdout, stderr = process.communicate(timeout=45)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)
            raise
        if process.returncode:
            raise RuntimeError(f"{client} {args}:\n{stdout}\n{stderr}")
        return stdout


def codex_session(client, project, env, stderr):
    process = subprocess.Popen([client, "app-server", "--stdio"], cwd=project, env=env,
                               text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=stderr, start_new_session=True)
    messages = queue.Queue()

    def read():
        try:
            for line in process.stdout:
                messages.put(json.loads(line))
        finally:
            messages.put(None)

    reader = threading.Thread(target=read, daemon=True)
    reader.start()

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()

    def request(request_id, method, params):
        send({"id": request_id, "method": method, "params": params})
        while True:
            message = messages.get(timeout=45)
            if message is None:
                raise RuntimeError(f"Codex exited during {method}")
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error']}")
                return message["result"]

    try:
        request(1, "initialize", {
            "clientInfo": {"name": "beam_plugin_smoke", "version": "1"},
            "capabilities": {"experimentalApi": True},
        })
        send({"method": "initialized"})
        thread = request(2, "thread/start", {"cwd": str(project), "ephemeral": True})
        status = request(3, "mcpServerStatus/list", {
            "threadId": thread["thread"]["id"], "serverName": "lean-beam",
        })
        servers = status["data"]
        assert len(servers) == 1, status
        assert servers[0]["pluginId"] == "lean-beam@lean-beam", status
        assert "beam_plugin_probe" in servers[0]["tools"], status
        skills = request(4, "skills/list", {"cwds": [str(project)]})
        beam = [s for group in skills["data"] for s in group["skills"]
                if s.get("pluginId") == "lean-beam@lean-beam"]
        assert len(beam) == 1 and beam[0]["enabled"], beam
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
        reader.join(timeout=5)
        process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clients", nargs="+", choices=["codex", "claude"],
                        default=["codex", "claude"])
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("this opt-in fixture uses POSIX executable scripts and process groups")
    clients = {name: shutil.which(name) for name in args.clients}
    if not all(clients.values()):
        parser.error(f"install the requested clients first: {clients}")
    with tempfile.TemporaryDirectory(prefix="beam-agent-plugin-") as tmp:
        base = Path(tmp)
        package = base / "relocated package"
        package.mkdir()
        # Copy only the published integration inputs, never local caches or credentials.
        for name in [".claude-plugin", ".codex-plugin", ".agents", "skills"]:
            shutil.copytree(ROOT / name, package / name)
        for name in [".mcp.json", "README.md", "LICENSE"]:
            shutil.copy2(ROOT / name, package / name)
        home = base / "home"
        home.mkdir()
        binary = base / "bin"
        binary.mkdir()
        log = base / "launches.jsonl"
        fake = binary / "lean-beam-mcp"
        fake.write_text(f"#!{sys.executable}\n" + f"log = {str(log)!r}\n" + '''import json, os, sys
with open(log, "a") as output:
    output.write(json.dumps({"cwd": os.getcwd()}) + "\\n")
for line in sys.stdin:
    message = json.loads(line)
    if "id" not in message:
        continue
    if message["method"] == "initialize":
        result = {"protocolVersion": message["params"]["protocolVersion"],
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "beam-plugin-probe", "version": "1"}}
    elif message["method"] == "tools/list":
        result = {"tools": [{"name": "beam_plugin_probe", "description": "Launch probe",
                             "inputSchema": {"type": "object"}}]}
    else:
        result = {}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
''')
        fake.chmod(0o755)
        env = {**os.environ, "HOME": str(home), "CODEX_HOME": str(home / ".codex"),
               "CLAUDE_CONFIG_DIR": str(home / ".claude"),
               "PATH": str(binary) + os.pathsep + os.environ["PATH"],
               "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"}
        for key in ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]:
            env.pop(key, None)
        for name in ["CODEX_HOME", "CLAUDE_CONFIG_DIR"]:
            Path(env[name]).mkdir()
        projects = [base / "project one", base / "project two"]
        for project in projects:
            project.mkdir()
        for name, client in clients.items():
            assert client is not None
            print(run(client, ["--version"], home, env).strip())
            if name == "codex":
                run(client, ["plugin", "marketplace", "add", str(package)], home, env)
                installed = json.loads(run(client, ["plugin", "add", "lean-beam@lean-beam",
                                                   "--json"], home, env))
                cached = Path(installed["installedPath"]) / "skills" / "lean-beam"
                for source in (ROOT / "skills" / "lean-beam").rglob("*"):
                    if source.is_file():
                        relative = source.relative_to(ROOT / "skills" / "lean-beam")
                        assert (cached / relative).read_bytes() == source.read_bytes(), relative
                with (base / "codex-stderr.log").open("w") as stderr:
                    for project in projects:
                        codex_session(client, project, env, stderr)
            else:
                for manifest in [package, package / ".claude-plugin" / "plugin.json"]:
                    run(client, ["plugin", "validate", str(manifest)], home, env)
                run(client, ["plugin", "marketplace", "add", str(package)], home, env)
                run(client, ["plugin", "install", "lean-beam@lean-beam"], home, env)
                details = run(client, ["plugin", "details", "lean-beam"], home, env)
                assert "Skills (1)" in details and "MCP servers (1)" in details, details
                for project in projects:
                    status = run(client, ["mcp", "list"], project, env)
                    assert "plugin:lean-beam:lean-beam" in status and "Connected" in status, status
        launches = [json.loads(line)["cwd"] for line in log.read_text().splitlines()]
        expected = [str(project.resolve()) for _ in clients for project in projects]
        assert sorted(launches) == sorted(expected), (launches, expected)
        print(f"Passed: one skill and MCP server per client; {len(launches)} project-directory launches.")


if __name__ == "__main__":
    main()
