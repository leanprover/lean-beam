#!/usr/bin/env python3
"""Exercise the published CLI against real installer output and native CLI stubs.

Called after --all-skills and --all-mcp in test-beam-install.sh. The fixtures
stand in for Codex/Claude's registration commands; Beam's installer is real.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

cli, root = Path(sys.argv[1]), Path(sys.argv[2])
workspace = root / "doctor-workspace"
workspace.mkdir(exist_ok=True)
(workspace / ".git").mkdir(exist_ok=True)


def snapshot():
    result = {}
    for path in root.rglob("*"):
        metadata = path.lstat()
        content = None
        if stat.S_ISLNK(metadata.st_mode):
            content = os.readlink(path)
        elif stat.S_ISREG(metadata.st_mode):
            content = hashlib.sha256(path.read_bytes()).hexdigest()
        result[str(path)] = metadata.st_mode, metadata.st_mtime_ns, content
    return result


before = snapshot()
result = subprocess.run([str(cli), "doctor", "clients", "--json"], cwd=workspace,
                        text=True, capture_output=True, timeout=15)
assert result.returncode == 0, (result.stdout, result.stderr)
report = json.loads(result.stdout)
clients = {client["client"]: client for client in report["clients"]}
assert set(clients) == {"codex", "claude", "pi", "opencode", "vibe"}, report
for name, client in clients.items():
    findings = {finding["code"] for finding in client["findings"]}
    assert "skill.readable" in findings, (name, client)
    assert client["skill"] == "checked", (name, client)
    assert not any(f["status"] in ["error", "unknown"] for f in client["findings"]), client
    if name in ["codex", "claude", "vibe"]:
        assert {"launch.file", "runtime.metadata"} <= findings, (name, client)
    elif name == "pi":
        assert "mcp.notApplicable" in findings, client
    else:
        assert "mcp.notConfigured" in findings, client
opencode_home = Path(os.environ.get("OPENCODE_CONFIG_DIR") or (
    str(Path(os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")) / "opencode")))
assert any(source["path"] == str(opencode_home / "skills/lean-beam/SKILL.md")
           and source["state"] == "ok" for source in clients["opencode"]["sources"]), clients["opencode"]
text = subprocess.run([str(cli), "doctor", "clients"], cwd=workspace,
                      text=True, capture_output=True, timeout=15, check=True).stdout
assert "0 errors, 0 unverified checks, 0 recommendations, 1 setup reminder." in text, text
assert snapshot() == before, "installed doctor modified files or created state"
print("Installed doctor: five skills and three installer registrations checked; files unchanged.")
