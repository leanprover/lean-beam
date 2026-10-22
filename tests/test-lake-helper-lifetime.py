#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Lake loading follows request cancellation; trace publication keeps its deadline."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time

from installation_fixture import EXE, REPO, stage
from lib.process_watchdog import process_is_running, run_with_watchdog

spec = importlib.util.spec_from_file_location("mcp_stdio_tests", REPO / "tests/test-mcp-stdio.py")
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


def wait_for(predicate, label, seconds=10):
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, label
        time.sleep(0.02)


def project(base, compiler, label, stall=True, abrupt=False):
    root = base / label
    root.mkdir()
    (root / "lean-toolchain").write_text(str(compiler) + "\n", encoding="utf-8")
    (root / "Main.lean").write_text("def answer : Nat := 42\n")
    # Both helper and descendant record their PID before the test cancels/kills the owner.
    descendant = root / "descendant.py"
    descendant.write_text("from pathlib import Path\nimport os,time\n" +
                          f"Path({str(root / 'descendant.pid')!r}).write_text(str(os.getpid()))\n" +
                          f"while not Path({str(root / 'release-descendant')!r}).exists(): time.sleep(0.02)\n",
                          encoding="utf-8")
    (root / "lakefile.lean").write_text(
        "import Lake\nopen Lake DSL\nrun_cmd do\n" +
        f"  IO.FS.writeFile {json.dumps(str(root / 'helper.pid'), ensure_ascii=False)} (toString (← IO.Process.getPID))\n" +
        "  discard <| IO.Process.spawn {\n" +
        f"    cmd := {json.dumps(sys.executable, ensure_ascii=False)}\n" +
        f"    args := #[{json.dumps(str(descendant), ensure_ascii=False)}]\n" +
        "    stdin := .null, stdout := .null, stderr := .null\n  }\n" +
        f"  while !(← (System.FilePath.mk {json.dumps(str(root / 'descendant.pid'), ensure_ascii=False)}).pathExists) do IO.sleep 10\n" +
        (f"  while !(← (System.FilePath.mk {json.dumps(str(root / 'release'), ensure_ascii=False)}).pathExists) do IO.sleep 10\n"
         if stall else "") +
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
        wait_for(lambda: not process_is_running(pid), f"owned helper/descendant {pid} still running", seconds=5)


def hold_helper(pids, label, assert_pending):
    started = time.monotonic()
    while time.monotonic() - started < 31:
        assert_pending()
        time.sleep(0.05)
    assert all(process_is_running(pid) for pid in pids), f"{label} stopped before release/cancellation"
    print(label, "held for", time.monotonic() - started, "seconds", flush=True)


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
        # No override for parent loss: exercise the production server-env wait policy.
        arguments = [str(fixture), str(helper), "server-env"]
        if scenario != "parent-loss":
            arguments.append(timeout)
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


def through_cli(base, compiler, cli):
    scenarios = ["cold-success", "owner-loss"]
    signals = {}
    if os.name == "posix":
        signals = {"interrupt": signal.SIGINT, "terminate": signal.SIGTERM, "hangup": signal.SIGHUP}
        scenarios.extend(signals)
    for scenario in scenarios:
        root = project(base, compiler, "cli-" + scenario)
        environment = child_environment(root)
        if scenario == "cold-success":
            environment["BEAM_PROGRESS"] = "1"
        command = [str(cli), "--root", str(root)]
        stdout_path, stderr_path = root / "owner.out", root / "owner.err"

        def invoke(*arguments):
            result = run_with_watchdog(command + list(arguments), timeout=15, env=environment)
            (root / (arguments[0] + ".out")).write_text(result.stdout, encoding="utf-8")
            (root / (arguments[0] + ".err")).write_text(result.stderr, encoding="utf-8")
            assert result.returncode == 0, (result.stdout, result.stderr)
            response = json.loads(result.stdout)
            assert response["ok"] is True, response
            return response

        with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
            owner = subprocess.Popen(command + ["serve"], stdout=stdout, stderr=stderr,
                                     env=environment)
            pids = []
            try:
                pids = entered(root, owner)
                if scenario == "cold-success":
                    assert "beam: loading Lake workspace configuration..." in stderr_path.read_text(), \
                        "serve must explain its configuration wait before readiness"
                    # Hold project evaluation past the old 30-second deadline. The descendant
                    # has a separate latch, so successful cleanup must terminate it too.

                    def still_loading():
                        assert owner.poll() is None, stderr_path.read_text(errors="replace")
                        assert stdout_path.stat().st_size == 0, "serve completed before release"

                    hold_helper(pids, "cold server environment", still_loading)
                    waits = [int(seconds) for seconds in re.findall(
                        r"still preparing Lean workspace \((\d+)s\)",
                        stderr_path.read_text(encoding="utf-8"))]
                    assert waits and waits[-1] >= 30, "held serve must report elapsed waiting time"
                    assert waits[0] >= 5, waits
                    assert all(later - earlier >= 5 for earlier, later in zip(waits, waits[1:])), waits
                    (root / "release").touch()

                    def ready():
                        assert owner.poll() is None, stderr_path.read_text(errors="replace")
                        return stdout_path.stat().st_size > 0

                    wait_for(ready, "cold serve did not become ready after release", seconds=20)
                    served = json.loads(stdout_path.read_text(encoding="utf-8"))
                    assert served["ok"] is True and served["result"]["state"] == "running", served
                    synced = invoke("sync", "Main.lean")
                    assert synced["fileProgress"]["done"] is True, synced
                    assert synced["result"]["readiness"]["saveReady"] is True, synced
                    assert synced["result"]["readiness"]["blockingErrorCount"] == 0, synced
                    stopping = invoke("stop")["result"]
                    assert stopping["state"] == "stopping" and stopping["changed"] is True, stopping
                    assert "warning" not in stopping, stopping
                    assert owner.wait(timeout=15) == 0, stderr_path.read_text(errors="replace")
                    assert "forcing daemon termination" not in stderr_path.read_text(errors="replace"), \
                        "normal stop must release the owner pipe and let the daemon exit gracefully"
                elif scenario in signals:
                    owner.send_signal(signals[scenario])
                    assert owner.wait(timeout=15) != 0, "interrupted cold serve reported success"
                    assert stdout_path.stat().st_size == 0, "interrupted cold serve became ready"
                    assert "forcing daemon termination" not in stderr_path.read_text(errors="replace"), \
                        "interruption must release the owner pipe and let the daemon exit gracefully"
                    assert invoke("status")["result"]["state"] == "absent", \
                        "handled termination must not require manual recovery"
                else:
                    owner.kill()
                    owner.wait(timeout=5)
                stopped(pids)
                print("owned helper CLI:", scenario, "passed", flush=True)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)
                stopped(pids)


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
                if modern and scenario == "save-cancel-drop":
                    # Save preparation reloads Lake too. Keep one real deadline regression,
                    # then prove that cancellation still tears down this long-running helper.
                    def still_preparing():
                        assert client.proc.poll() is None, client._diagnostic_context()
                        assert not client.response_ready(request), client._diagnostic_context()

                    hold_helper(pids, "cold save preparation", still_preparing)
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
    temporary = tempfile.mkdtemp(prefix="beam-helper-lifetime-")
    base = Path(temporary).resolve()
    try:
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
        if not args.native_prefix and os.name == "nt":
            # Standalone Windows installs declare native frontends; bin wrappers are shell scripts.
            frontends = record["components"]["frontends"]
            cli = installation / frontends["cli"]
            server = installation / frontends["mcp"]
        else:
            cli = installation / "bin" / ("lean-beam" + EXE)
            server = installation / "bin" / ("lean-beam-mcp" + EXE)
        direct(base, compiler, helper)
        # These use distinct projects and processes. Overlap the two required real-time holds
        # instead of adding another serial 31-second wait to the fast suite.
        with ThreadPoolExecutor(max_workers=2) as workers:
            checks = [workers.submit(through_cli, base, compiler, cli),
                      workers.submit(through_mcp, base, compiler, server)]
            for check in checks:
                check.result()
    except BaseException:
        print("Lake helper lifetime failure retained at:", temporary, file=sys.stderr)
        # Release fixture waits only after failure unwinding, so this cannot satisfy a cleanup
        # assertion. Keep PID evidence and re-raise the original failure.
        for descendant in base.glob("*/descendant.py"):
            for name in ["release", "release-descendant"]:
                try:
                    (descendant.parent / name).touch()
                except OSError as error:
                    print("Fixture latch release failed:", descendant.parent / name, error,
                          file=sys.stderr)
        raise
    else:
        shutil.rmtree(temporary)


if __name__ == "__main__":
    main()
