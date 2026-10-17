#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Owned Lake helpers stop on deadline, cancellation, owner loss, and MCP teardown."""

import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from installation_fixture import EXE, REPO, stage

spec = importlib.util.spec_from_file_location("mcp_stdio_tests", REPO / "tests/test-mcp-stdio.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


def wait_for(predicate, label, seconds=10):
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, label
        time.sleep(0.02)


def running(pid):
    if os.name == "nt":
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        kernel.OpenProcess.restype = ctypes.c_void_p
        kernel.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        kernel.WaitForSingleObject.restype = ctypes.c_uint32
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
        if not handle:
            assert ctypes.get_last_error() == 87, ctypes.get_last_error()  # no such process
            return False
        try:
            status = kernel.WaitForSingleObject(handle, 0)
            assert status in [0, 258], (status, ctypes.get_last_error())
            return status == 258  # WAIT_TIMEOUT
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    # A terminated grandchild can await its new parent's reap; it cannot execute more work.
    state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                           text=True, capture_output=True, check=False).stdout.strip()
    return bool(state) and not state.startswith("Z")


def project(base, compiler, label, stall=True, abrupt=False):
    root = base / label
    root.mkdir()
    (root / "lean-toolchain").write_text(str(compiler) + "\n", encoding="utf-8")
    (root / "Main.lean").write_text("def answer : Nat := 42\n")
    # Both helper and descendant record their PID before the test cancels/kills the owner.
    descendant = root / "descendant.py"
    descendant.write_text("from pathlib import Path\nimport os,time\n" +
                          f"Path({str(root / 'descendant.pid')!r}).write_text(str(os.getpid()))\n" +
                          "time.sleep(30)\n", encoding="utf-8")
    (root / "lakefile.lean").write_text(
        "import Lake\nopen Lake DSL\nrun_cmd do\n" +
        f"  IO.FS.writeFile {json.dumps(str(root / 'helper.pid'), ensure_ascii=False)} (toString (← IO.Process.getPID))\n" +
        "  discard <| IO.Process.spawn {\n" +
        f"    cmd := {json.dumps(sys.executable, ensure_ascii=False)}\n" +
        f"    args := #[{json.dumps(str(descendant), ensure_ascii=False)}]\n" +
        "    stdin := .null, stdout := .null, stderr := .null\n  }\n" +
        f"  while !(← (System.FilePath.mk {json.dumps(str(root / 'descendant.pid'), ensure_ascii=False)}).pathExists) do IO.sleep 10\n" +
        ("  IO.sleep 30000\n" if stall else "") +
        ("  (IO.Process.forceExit 23 : IO Unit)\n" if abrupt else "") +
        "package helper_lifetime_fixture\nlean_lib Main\n", encoding="utf-8")
    return root


def entered(root, owner=None):
    def ready():
        if all((root / name).is_file() for name in ["helper.pid", "descendant.pid"]):
            return True
        if owner is not None and owner.poll() is not None:
            raise AssertionError("helper fixture returned before project code: " +
                                 (root / "owner.out").read_text(encoding="utf-8") +
                                 (root / "owner.err").read_text(encoding="utf-8", errors="replace"))
        return False
    wait_for(ready, f"Lake helper did not enter {root}")
    return [int((root / name).read_text()) for name in ["helper.pid", "descendant.pid"]]


def stopped(pids):
    for pid in pids:
        wait_for(lambda: not running(pid), f"owned helper/descendant {pid} still running", seconds=5)


def child_environment(root):
    # A killed owner cannot run its temp-directory finally block. Keep those files within this
    # test's owned root so the outer TemporaryDirectory can remove them after all children stop.
    temporary = root / "temporary"
    temporary.mkdir()
    return dict(os.environ, TMPDIR=str(temporary), TMP=str(temporary), TEMP=str(temporary))


def direct(base, compiler, helper):
    fixture = REPO / ".lake/build/bin" / ("beam-lake-helper-client-fixture" + EXE)
    subprocess.run([str(fixture), "--process-job-exited-groups"], check=True, timeout=30)
    for scenario in [f"early-deadline-{i}" for i in range(8)] + [
            "success", "abrupt", "deadline", "cancel", "parent-loss"]:
        early = scenario.startswith("early-deadline-")
        root = project(base, compiler, "direct-" + scenario,
                       stall=scenario not in ["success", "abrupt"], abrupt=scenario == "abrupt")
        cancelled = root / "cancel"
        timeout = "0" if early else "15000" if scenario == "deadline" else "30000"
        arguments = [str(fixture), str(helper), "server-env", timeout]
        if scenario == "cancel":
            arguments.append(str(cancelled))
        stdout_path, stderr_path = root / "owner.out", root / "owner.err"
        before_exec = None
        if early and sys.platform.startswith("linux"):
            # Delay the new child's setsid relative to its owner's immediate cleanup.
            affinity = {min(os.sched_getaffinity(0))}
            before_exec = lambda: os.sched_setaffinity(0, affinity)
        # File capture avoids waiting on an unread, platform-sized stdout pipe buffer.
        with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
            owner = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=stdout,
                                     stderr=stderr, text=True, env=child_environment(root),
                                     preexec_fn=before_exec)
            owner.stdin.write(json.dumps({"root": str(root)}))
            owner.stdin.close()
            try:
                pids = [] if early else entered(root, owner)
                if scenario == "cancel":
                    cancelled.touch()
                elif scenario == "parent-loss":
                    owner.kill()
                owner.wait(timeout=5 if early else 20)
                if scenario != "parent-loss":
                    assert owner.returncode == 0, stderr_path.read_text()
                    response = json.loads(stdout_path.read_text(encoding="utf-8"))
                    if scenario == "success":
                        assert "result" in response, response
                    elif scenario == "cancel":
                        assert response["error"]["code"] == "requestCancelled", response
                    elif scenario == "abrupt":
                        assert response["error"]["code"] == "workerExited", response
                    else:
                        assert "timed out" in response["error"]["message"], response
                stopped(pids)
                if early:
                    assert not (root / "helper.pid").exists(), "expired request reached project code"
                print("owned helper:", scenario, "passed", flush=True)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)


def through_mcp(base, compiler, server):
    for modern in [False, True]:
        for scenario in ["eof", "cancel-drop", "save-cancel-drop"]:
            cancel = scenario != "eof"
            label = ("modern" if modern else "legacy") + "-" + scenario
            root = project(base, compiler, label)
            stalling_config = (root / "lakefile.lean").read_text(encoding="utf-8")
            if scenario == "save-cancel-drop":
                (root / "lakefile.lean").write_text(
                    "import Lake\nopen Lake DSL\npackage helper_lifetime_fixture\nlean_lib Main\n", encoding="utf-8")
            client = mcp.McpClient(REPO, root, 10, label=label, server_command=[str(server)],
                                   shutdown_timeout=5, extra_env=child_environment(root))
            try:
                if modern:
                    client.modern_request("server/discover")
                else:
                    client.initialize()
                invoke = client.modern_request if modern else client.request
                arguments = {"workspace": {"root": str(root)}, "path": "Main.lean"}
                if scenario == "save-cancel-drop":
                    synced = invoke("tools/call", {"name": "lean_sync", "arguments": arguments})
                    assert synced["result"].get("isError") is False, synced
                    # Lake configuration is not open in the broker. Change it before save's
                    # fresh helper load; the existing document/Lean backend stays retained.
                    (root / "lakefile.lean").write_text(stalling_config, encoding="utf-8")
                params = {"name": "lean_save" if scenario == "save-cancel-drop" else "lean_sync", "arguments": {
                    "workspace": {"root": str(root)}, "path": "Main.lean"}}
                if modern:
                    params = mcp.with_modern_metadata(params)
                request = client.send_request("tools/call", params)
                pids = entered(root)
                if cancel:
                    client.notify("notifications/cancelled", {"requestId": request})
                    dropped = invoke("tools/call", {"name": "lean_drop_workspace", "arguments": {
                        "workspace": {"root": str(root)}}})
                    assert dropped["result"]["structuredContent"]["dropped"] is True, dropped
                    # Suppressed cancelled requests never become a later broker operation.
                    assert not client.response_ready(request), client._diagnostic_context()
                client.close_input()
                assert client.wait_for_exit_after_eof(5) == 0
                stopped(pids)
                print("owned helper MCP:", label, "passed", flush=True)
            finally:
                client.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-prefix", type=Path,
                        help="exercise an already installed native SDK instead of standalone staging")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="beam-helper-lifetime-") as temporary:
        base = Path(temporary).resolve()
        if args.native_prefix:
            installation = args.native_prefix.resolve()
            compiler = installation
            helper = installation / "bin" / ("beam-daemon" + EXE)
        else:
            if "BEAM_TEST_INSTALLATION" in os.environ:
                installation = Path(os.environ["BEAM_TEST_INSTALLATION"])
                record = json.loads((installation / "manifest.json").read_text())
                target = next(t for t in record["components"]["targets"] if
                              t["toolchain"] == (REPO / "lean-toolchain").read_text().strip())
                compiler = Path(target["lean"]).parent.parent
            else:
                installation = base / "installation"
                compiler = stage(installation)
                record = json.loads((installation / "manifest.json").read_text())
                target, = record["components"]["targets"]
            helper = installation / target["daemon"]
        direct(base, compiler, helper)
        through_mcp(base, compiler, installation / "bin" / ("lean-beam-mcp" + EXE))


if __name__ == "__main__":
    main()
