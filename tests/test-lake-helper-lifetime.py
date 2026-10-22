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
import socket
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
                          "os.write(1, 'child stdout α'.encode('utf-8'))\n" +
                          "os.write(2, 'child stderr β'.encode('utf-8'))\n" +
                          f"Path({str(root / 'descendant.pid')!r}).write_text(str(os.getpid()))\n" +
                          f"while not Path({str(root / 'release-descendant')!r}).exists():\n" +
                          f"    if Path({str(root / 'pulse-output')!r}).exists(): os.write(2, b'configuration output\\n')\n" +
                          "    time.sleep(0.5)\n",
                          encoding="utf-8")
    (root / "lakefile.lean").write_text(
        "import Lake\nopen Lake DSL\nrun_cmd do\n" +
        '  (← IO.getStdout).putStr "helper stdout α"\n' +
        '  (← IO.getStdout).flush\n' +
        '  (← IO.getStderr).putStr "helper stderr β"\n' +
        '  (← IO.getStderr).flush\n' +
        '  Lean.logWarning "helper configuration warning"\n' +
        f"  IO.FS.writeFile {json.dumps(str(root / 'helper.pid'), ensure_ascii=False)} (toString (← IO.Process.getPID))\n" +
        "  discard <| IO.Process.spawn {\n" +
        f"    cmd := {json.dumps(sys.executable, ensure_ascii=False)}\n" +
        f"    args := #[{json.dumps(str(descendant), ensure_ascii=False)}]\n" +
        "    stdin := .null, stdout := .inherit, stderr := .inherit\n  }\n" +
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


def cleanup_receipts(base, fixture):
    if os.name != "posix" or os.geteuid() == 0:
        print("cleanup receipt permission fault: requires unprivileged POSIX permissions", flush=True)
        return
    responses = [
        {"ok": True, "result": {"traceWritten": True, "tracePath": "fixture.trace"}},
        {"ok": False, "error": {"code": "contentModified", "message": "fixture changed",
                                 "data": {"reason": "fixture", "snapshot": 42}}},
    ]
    for index, response in enumerate(responses):
        root = base / f"cleanup-receipt-{index}"
        root.mkdir()
        marker, receipt = root / "operation-finished", root / "job-receipt.json"
        request = {"response": response, "marker": str(marker), "receipt": str(receipt)}
        with (root / "owner.out").open("w") as stdout, (root / "owner.err").open("w") as stderr:
            owner = subprocess.Popen([str(fixture), str(fixture), "write-save-trace", "5000"],
                                     stdin=subprocess.PIPE, stdout=stdout, stderr=stderr, text=True,
                                     env=child_environment(root))
            try:
                owner.stdin.write(json.dumps(request))
                owner.stdin.close()
                owner.wait(timeout=10)
                assert owner.returncode == 0, (root / "owner.err").read_text()
                assert marker.read_text() == "operation finished\n", "operation did not finish"
                failure = json.loads((root / "owner.out").read_text())
                assert failure["ok"] is False, failure
                assert failure["error"]["code"] == "internalError", failure
                assert failure["error"]["data"]["operationResponse"] == response, failure
                stopped([json.loads(receipt.read_text())["pid"]])
                print("owned helper cleanup retains typed response:", index, "passed", flush=True)
            finally:
                if owner.poll() is None:
                    owner.kill()
                    owner.wait(timeout=5)
                if receipt.is_file():
                    protected = Path(json.loads(receipt.read_text())["directory"])
                    assert protected.name == "cleanup-denied" and protected.parent.name == "job"
                    assert protected.parent.parent.parent == root / "temporary", protected
                    # Restore only this fixture's obstacle so outer owned-directory cleanup works.
                    if protected.exists():
                        protected.chmod(0o700)


def direct(base, compiler, helper):
    fixture = REPO / ".lake/build/bin" / ("beam-lake-helper-client-fixture" + EXE)
    subprocess.run([str(fixture), "--process-job-exited-groups"], check=True, timeout=30)
    cleanup_receipts(base, fixture)
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
                        output = stderr_path.read_text(encoding="utf-8")
                        assert "helper stdout α" in output, output
                        assert "helper stderr β" in output, output
                        assert "helper configuration warning" in output, output
                        assert "helper stdout" not in stdout_path.read_text(encoding="utf-8"), response
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


def local_git_dependency(base):
    """Standalone log-filter coverage; native qualification deliberately forbids Git."""
    dependency = base / "dependency-source"
    dependency.mkdir()
    (dependency / "lakefile.toml").write_text('name = "fixture_dep"\n', encoding="utf-8")
    for arguments in [["init", "--quiet"], ["add", "lakefile.toml"],
                      ["-c", "user.name=Beam Fixture", "-c", "user.email=fixture@example.invalid",
                       "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"]]:
        subprocess.run(["git", *arguments], cwd=dependency, check=True,
                       capture_output=True, text=True, timeout=10)
    return dependency


def through_cli(base, compiler, cli, dependency=None):
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
            (root / "pulse-output").touch()
            if dependency is not None:
                with (root / "lakefile.lean").open("a", encoding="utf-8") as config:
                    config.write(f'\nrequire fixture_dep from git {json.dumps(str(dependency))} @ "HEAD"\n')
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

                def raw_output_visible():
                    assert owner.poll() is None, stderr_path.read_text(errors="replace")
                    assert stdout_path.stat().st_size == 0, "serve completed before release"
                    output = stderr_path.read_text(encoding="utf-8", errors="replace")
                    # The descendant inherits the helper's real pipes. run_cmd's own Lean
                    # streams are captured upstream until command completion. Both raw
                    # scalars must arrive without a newline, including non-TTY cases.
                    return "α" in output and "β" in output

                wait_for(raw_output_visible, "cold serve hid flushed Lake output until completion")
                if scenario == "cold-success":
                    assert "beam: loading Lake workspace configuration..." in stderr_path.read_text(), \
                        "serve must explain its configuration wait before readiness"
                    # Hold project evaluation past the old 30-second deadline. The descendant
                    # has a separate latch, so successful cleanup must terminate it too.
                    active_until = time.monotonic() + 8
                    initial_waits = re.findall(r"still preparing Lean workspace \((\d+)s\)",
                                              stderr_path.read_text(encoding="utf-8"))

                    def still_loading():
                        assert owner.poll() is None, stderr_path.read_text(errors="replace")
                        assert stdout_path.stat().st_size == 0, "serve completed before release"
                        if time.monotonic() < active_until:
                            waits = re.findall(r"still preparing Lean workspace \((\d+)s\)",
                                               stderr_path.read_text(encoding="utf-8"))
                            assert waits == initial_waits, "waiting reminders duplicated active Lake output"
                        else:
                            (root / "pulse-output").unlink(missing_ok=True)

                    hold_helper(pids, "cold server environment", still_loading)
                    waits = [int(seconds) for seconds in re.findall(
                        r"still preparing Lean workspace \((\d+)s\)",
                        stderr_path.read_text(encoding="utf-8"))]
                    assert waits and waits[-1] >= 25, "quiet held serve must resume waiting reminders"
                    assert waits[0] >= 5, waits
                    assert all(later - earlier >= 5 for earlier, later in zip(waits, waits[1:])), waits
                    (root / "release").touch()

                    def ready():
                        assert owner.poll() is None, stderr_path.read_text(errors="replace")
                        return stdout_path.stat().st_size > 0

                    wait_for(ready, "cold serve did not become ready after release", seconds=20)
                    served = json.loads(stdout_path.read_text(encoding="utf-8"))
                    assert served["ok"] is True and served["result"]["state"] == "running", served
                    output = stderr_path.read_text(encoding="utf-8")
                    if dependency is not None:
                        assert (root / ".lake/packages/fixture_dep/.git").exists(), "local dependency was not cloned"
                        assert "info:" in output and "helper configuration warning" in output, output
                        assert not any(line.startswith("trace:") for line in output.splitlines()), output
                    registry = Path(served["result"]["sessionDir"]) / "beam-daemon.json"
                    port = json.loads(registry.read_text(encoding="utf-8"))["port"]
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as connection:
                        with connection.makefile("rb") as incoming:
                            def receive():
                                header = incoming.readline()
                                assert header, "wrapper daemon closed before returning its framed error"
                                return json.loads(incoming.read(int(header)))
                            assert receive()["schemaVersion"] == 1
                            connection.sendall(b"16777217\n")
                            error = receive()["payload"]["error"]
                            assert error["code"] == "internalError", error
                            assert "exceeds 16777216 bytes" in error["message"], error
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
                    assert owner.wait(timeout=15) == 130, stderr_path.read_text(errors="replace")
                    response = json.loads(stdout_path.read_text(encoding="utf-8"))
                    assert response["ok"] is False, "interrupted cold serve became ready"
                    assert response["error"]["code"] == "requestCancelled", response
                    assert "uncaught exception:" not in stderr_path.read_text(errors="replace")
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
                    params = mcp.with_modern_metadata(params, log_level="info")
                request = client.send_request("tools/call", params)
                pids = entered(root)

                def raw_output_visible():
                    assert client.proc.poll() is None, client._diagnostic_context()
                    assert not client.response_ready(request), client._diagnostic_context()
                    with client.state_changed:
                        notifications = list(client.notifications)
                    streams = {"stdout": "", "stderr": ""}
                    for notification in notifications:
                        params = notification.get("params", {})
                        if params.get("logger") != "lake.output":
                            continue
                        data = params.get("data", {})
                        if data.get("requestId") == request:
                            assert data.get("tool") == ("lean_save" if scenario == "save-cancel-drop" else "lean_sync")
                            assert isinstance(data.get("omittedBefore"), bool), data
                            streams[data["source"]] += data["text"]
                    return "α" in streams["stdout"] and "β" in streams["stderr"]

                wait_for(raw_output_visible, "MCP hid live helper output until completion")
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
        # Keep native qualification's forbidden Git shim active. Its projects have no external
        # dependency; the standalone fast suite owns the real-clone/log-threshold assertion.
        dependency = None if args.native_prefix else local_git_dependency(base)
        with ThreadPoolExecutor(max_workers=2) as workers:
            checks = [workers.submit(through_cli, base, compiler, cli, dependency),
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
