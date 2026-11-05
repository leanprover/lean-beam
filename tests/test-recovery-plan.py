#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise broker-authored stale dependency recovery through installed CLI and MCP."""

import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tests"))

def load_test_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

basis = load_test_module("save_import_basis", REPO / "tests/test-save-import-basis.py")
mcp_test = load_test_module("mcp_stdio", REPO / "tests/test-mcp-stdio.py")
Case = basis.Case

GOOD_FILES = {
    "W.lean": "import W.B\n",
    "W/A.lean": "def a : Nat := 1\n",
    "W/B.lean": "import W.A\ndef b : Nat := a\n",
}


def assert_recovery_error(error, *, dependency="W/A.lean", target="W/B.lean"):
    assert error["code"] == "syncBarrierIncomplete", error
    data = error["data"]
    assert data["save_deps"] == [dependency], data
    assert data["recovery_plan"] == [
        f'lean-beam save "{dependency}"',
        f'lean-beam refresh "{target}"',
    ], data
    assert all("lake build" not in step for step in data["recovery_plan"]), data
    message = error["message"]
    assert "stop if a step fails" in message, message
    assert "save readiness" in message, message
    assert "fileProgress=" not in message, message
    assert "confirm cleanup" in message, message
    return data


def execute_beam_plan(steps, call):
    """Interpret only the two supported public Beam commands; never pass a shell string."""
    results = []
    for step in steps:
        words = shlex.split(step)
        assert len(words) == 3 and words[0] == "lean-beam", step
        operation, path = words[1:]
        assert operation in {"save", "refresh"}, step
        response = call(operation, path)
        results.append(response)
        if not response.get("ok", True):
            return results
    return results


def update_dependency(case, call, source):
    case.write({"W/A.lean": source})
    update = call("update", "W/A.lean")
    result = update.get("result", update)
    assert update.get("ok", True) and result.get("version") is not None, update
    return result


def cli_call(case, operation, path):
    return case.beam(operation, path)


def mcp_client(case, installation, label):
    client = mcp_test.McpClient(
        REPO,
        case.root,
        timeout=90,
        label=label,
        server_command=[installation / "bin/lean-beam-mcp"],
    )
    return client


def mcp_call(client, case, operation, path):
    raw = client.modern_request("tools/call", {
        "name": "lean_" + operation,
        "arguments": {"workspace": mcp_test.workspace_descriptor(case.root), "path": path},
    })["result"]
    structured = raw.get("structuredContent")
    assert isinstance(structured, dict), raw
    assert json.loads(raw["content"][0]["text"]) == structured, raw
    if raw.get("isError"):
        return {"ok": False, "error": structured}
    return {"ok": True, "result": structured}


def prime(case):
    case.project(GOOD_FILES)


@contextmanager
def cli_owner(case):
    log = case.root.parent / "owner.stderr"
    with log.open("w", encoding="utf-8") as stderr:
        process = subprocess.Popen(
            [case.wrapper, "--root", case.root, "serve"], cwd=case.root,
            env=case.env, stdout=subprocess.DEVNULL, stderr=stderr,
        )
        try:
            deadline = time.monotonic() + 60
            while "serving Beam session" not in log.read_text(encoding="utf-8"):
                assert process.poll() is None, log.read_text(encoding="utf-8")
                assert time.monotonic() < deadline, log.read_text(encoding="utf-8")
                time.sleep(0.05)
            yield process
        finally:
            if process.poll() is None:
                stopped = case.beam("stop")
                assert stopped["ok"], stopped
            try:
                status = process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.kill()
                status = process.wait(timeout=10)
            assert status == 0, (status, log.read_text(encoding="utf-8"))


def establish_changed_dependency(case, call, source):
    assert call("sync", "W/A.lean")["ok"]
    assert call("sync", "W/B.lean")["ok"]
    update_dependency(case, call, source)
    assert call("sync", "W/A.lean")["ok"]
    response = call("sync", "W/B.lean")
    assert not response["ok"], response
    return response["error"]


@contextmanager
def session(case, installation, surface):
    if surface == "cli":
        with cli_owner(case):
            yield lambda operation, path: cli_call(case, operation, path)
    else:
        client = mcp_client(case, installation, "recovery-plan")
        try:
            yield lambda operation, path: mcp_call(client, case, operation, path)
            dropped = client.modern_request("tools/call", {
                "name": "lean_drop_workspace",
                "arguments": {"workspace": {"root": str(case.root)}},
            })["result"]
            assert not dropped.get("isError"), dropped
            data = dropped["structuredContent"]
            assert json.loads(dropped["content"][0]["text"]) == data, dropped
            assert data["dropped"] and data["invalidated_handles"], data
        finally:
            client.close()
        assert client.proc.returncode == 0, "MCP cleanup must finish normally before Lake runs"


def check_recovery(case, installation, surface, scenario):
    if scenario == "unsupported_save":
        case.write({
            "lean-toolchain": case.toolchain + "\n",
            "lakefile.lean": "import Lake\nopen Lake DSL\npackage w\nlean_lib W where\n"
                             '  moreLeanArgs := #["-Dpp.universes=true"]\n',
            **GOOD_FILES,
        })
        case.lake_run("build", "W.B")
    else:
        prime(case)
    source = 'def a : Nat := "bad"\n' if scenario == "upstream_error" else "def a : Nat := 2\n"
    with session(case, installation, surface) as call:
        error = establish_changed_dependency(case, call, source)
        data = assert_recovery_error(error)
        completed = execute_beam_plan(data["recovery_plan"], call)
        if scenario == "regular":
            assert len(completed) == 2 and all(x["ok"] for x in completed), completed
            assert completed[-1]["result"]["readiness"]["save_ready"] is True, completed[-1]
        else:
            # The failed save is terminal for this plan: refresh must not be invoked.
            assert len(completed) == 1 and not completed[0]["ok"], completed
            refusal = completed[0]["error"]
            if scenario == "upstream_error":
                assert refusal["code"] == "invalidParams", refusal
                assert refusal["data"]["sync"]["readiness"]["save_ready"] is False, refusal
            else:
                assert refusal["code"] == "saveUnsupportedSetup", refusal
                assert refusal["data"]["reason"] == "Lake module uses batch-only moreLeanArgs", refusal
                # Building while this session is live would leave its sync history stale (#256).
                assert "drop the MCP workspace and confirm cleanup" in refusal["message"], refusal
                assert "rebuild only after cleanup completes" in refusal["message"], refusal
                assert "sync" in refusal["data"], refusal
    if scenario == "unsupported_save":
        # Session cleanup above has completed successfully; only now build externally.
        case.lake_run("build", "W.A")
        with session(case, installation, surface) as call:
            refreshed = call("sync", "W/B.lean")
            assert refreshed["ok"] and refreshed["result"]["readiness"]["save_ready"], refreshed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installation", type=Path, default=os.environ.get("BEAM_TEST_INSTALLATION"))
    parser.add_argument("--toolchain", default=(REPO / "lean-toolchain").read_text().strip())
    args = parser.parse_args()
    if args.installation is None:
        parser.error("--installation or BEAM_TEST_INSTALLATION is required")
    installation = args.installation.resolve(strict=True)
    manifest = json.loads((installation / "manifest.json").read_text(encoding="utf-8"))
    target, = [item for item in manifest["components"]["targets"] if item["toolchain"] == args.toolchain]
    base = Path(tempfile.mkdtemp(prefix="beam-recovery-plan-"))
    try:
        scenarios = ["regular", "upstream_error", "unsupported_save"]
        for surface in ("cli", "mcp"):
            for scenario in scenarios:
                name = f"{surface}-{scenario}"
                print(f"recovery plan: {name}", flush=True)
                check_recovery(Case(base, name, installation, target), installation, surface, scenario)
    finally:
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
