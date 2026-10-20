#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""A completed checkpoint may finalize only the document acceptance it saved."""

import argparse
import concurrent.futures
from contextlib import contextmanager
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from mcp_test_util import shared_lib_name

REPO = Path(__file__).resolve().parent.parent
WORKSPACE = "save-finalization-test"
OWNER_CASES = ["workspace-replace", "backend-restart", "distinct-runtime"]
CASES = ["exact", "update", "reopen", "reopen-identical", "refresh-identical", "unchanged",
         "save-update", "save-reopen", "save-reopen-identical", "absent", "drop", "before-dispatch"]
CASES += OWNER_CASES
SOURCE = "def bVal : Nat := 11\nexample : True := by\n  trivial\n"


def wait_until(predicate, timeout, label):
    deadline = time.monotonic() + timeout
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out waiting for {label}")
        time.sleep(0.01)


def receive(sock, size):
    result = bytearray()
    while len(result) < size:
        chunk = sock.recv(size - len(result))
        assert chunk, "broker closed the response stream"
        result.extend(chunk)
    return result


def request(port, op, *, wait_seconds=45, **fields):
    payload = {"op": op, **fields}
    if op != "shutdown":
        payload["workspaceId"] = WORKSPACE
    raw = json.dumps(payload).encode()
    with socket.create_connection(("127.0.0.1", port), timeout=wait_seconds) as sock:
        sock.sendall(str(len(raw)).encode() + b"\n" + raw)
        while True:
            header = bytearray()
            while (byte := receive(sock, 1)) != b"\n":
                header.extend(byte)
            envelope = json.loads(receive(sock, int(header)))
            if envelope["kind"] == "response":
                return envelope["payload"]


def ok(response):
    assert response["ok"], response
    return response["result"]


def tracked(port):
    view = ok(request(port, "open_docs"))
    return next((f for f in view.get("session", {}).get("files", [])
                 if f["path"] == "Main.lean"), None)


@contextmanager
def broker(base, lean, plugin, daemon, gate_operation):
    project = base / "project"
    project.mkdir()
    (project / "lakefile.toml").write_text('name = "Main"\n[[lean_lib]]\nname = "Main"\n')
    (project / "lean-toolchain").write_text((REPO / "lean-toolchain").read_text())
    source = project / "Main.lean"
    source.write_text(SOURCE)
    with socket.socket() as unused:
        unused.bind(("127.0.0.1", 0))
        port = unused.getsockname()[1]
    with (base / "daemon.log").open("w") as log:
        proc = subprocess.Popen([str(daemon), "--root", str(project), "--port", str(port),
                                 "--workspace-id", WORKSPACE, "--lean-cmd", str(lean),
                                 "--lean-plugin", str(plugin)],
                                cwd=REPO, stdout=log, stderr=log,
                                env=dict(os.environ, BEAM_TEST_SAVE_GATE_DIR=str(base),
                                         BEAM_TEST_SAVE_GATE_OP=gate_operation))
        try:
            def ready():
                assert proc.poll() is None, (base / "daemon.log").read_text()
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        return True
                except OSError:
                    return False
            wait_until(ready, 15, "broker listener")
            yield port, source
        finally:
            (base / "release").touch()
            # Keep daemon/backend in the external watchdog's group. Helper jobs have their
            # own broker-owned groups and terminate on owner-pipe loss; the gate is bounded.
            if proc.poll() is None:
                try:
                    request(port, "shutdown", wait_seconds=3)
                except (OSError, AssertionError, ValueError):
                    pass
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)


def check_case(base, case, lean, plugin, daemon):
    base.mkdir()
    if case in OWNER_CASES:
        project = base / "project"
        project.mkdir()
        (project / "lakefile.toml").write_text('name = "Main"\n[[lean_lib]]\nname = "Main"\n')
        (project / "lean-toolchain").write_text((REPO / "lean-toolchain").read_text())
        (project / "Main.lean").write_text(SOURCE)
        subprocess.run([str(daemon), "--lean-cmd", str(lean), "--lean-plugin", str(plugin),
                        "save-owner-test", case, str(project)], cwd=REPO, check=True, timeout=60,
                       env=dict(os.environ, BEAM_TEST_SAVE_GATE_DIR=str(base),
                                BEAM_TEST_SAVE_GATE_OP="write-save-trace"))
        return
    before_dispatch = case == "before-dispatch"
    with broker(base, lean, plugin, daemon, "prepare-save" if before_dispatch else "write-save-trace") as (port, source):
        initial = ok(request(port, "sync_file", path="Main.lean"))
        prior_artifacts = None
        if before_dispatch:
            saved = ok(request(port, "save_olean", path="Main.lean"))
            prior_artifacts = {Path(saved[field]): (Path(saved[field]).read_bytes(), Path(saved[field]).stat().st_mtime_ns)
                               for field in ["olean", "ilean", "c", "trace"]}
        (base / "enabled").touch()
        close_after = not case.startswith("save-")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(request, port, "close" if close_after else "save_olean",
                                      path="Main.lean", **({"saveArtifacts": True} if close_after else {}))
            try:
                wait_until(lambda: (base / "entered").exists(), 35, "post-artifact trace helper")
                job = Path(json.loads((base / "entered").read_text())["job"])
                spec = json.loads((job / "request.json").read_text())
                if not before_dispatch:
                    assert all(Path(spec[field]).is_file() for field in ["oleanPath", "ileanPath", "cPath"]), spec
                    assert not Path(spec["tracePath"]).exists(), spec
                version = initial["version"]
                handle = None
                if case == "drop":
                    ok(request(port, "drop_workspace"))
                elif case == "absent":
                    ok(request(port, "close", path="Main.lean"))
                elif case not in ("exact", "unchanged"):
                    if "reopen" in case or before_dispatch:
                        ok(request(port, "close", path="Main.lean"))
                    if "identical" not in case and not before_dispatch:
                        source.write_text(SOURCE.replace("11", "22"))
                    update = ok(request(port, "refresh_file" if case == "refresh-identical" else "update_file",
                                        path="Main.lean"))
                    version = update["version"]
                    assert version == (1 if "reopen" in case or case == "refresh-identical" or before_dispatch else 2), update
                    # A fresh replacement context must survive refused old finalization.
                    seed = ok(request(port, "run_at", path="Main.lean", version=version,
                                      line=2, character=2, text="skip", storeHandle=True))
                    handle = seed["handle"]
                    assert tracked(port)["checkpointed"] is False
                elif case == "unchanged":
                    unchanged = ok(request(port, "sync_file", path="Main.lean"))
                    assert unchanged["version"] == initial["version"]
                (base / "release").touch()
                response = pending.result(timeout=35)
            finally:
                (base / "release").touch()
        (base / "response.json").write_text(json.dumps(response, indent=2) + "\n")
        print(f"save finalization ({case}): {json.dumps(response)}", flush=True)
        if before_dispatch:
            assert not response["ok"] and response["error"]["code"] == "contentModified", response
            assert response["error"]["data"]["reason"] == "documentChanged", response
            assert "saved" not in response["error"]["data"], "pre-dispatch refusal claimed a committed checkpoint"
            assert {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in prior_artifacts} == prior_artifacts
            assert not (base / "trace-entered").exists(), "stale basis reached trace publication"
            assert tracked(port)["checkpointed"] is False
            assert ok(request(port, "run_with", path="Main.lean", handle=handle, text="trivial"))["success"]
        elif case in ("exact", "unchanged"):
            assert ok(response)["closed"] is True
            assert tracked(port) is None
        elif case == "drop":
            assert not response["ok"] and response["error"]["code"] == "workerExited", response
            assert response["error"]["data"]["saved"]["version"] == initial["version"], response
            assert response["fileProgress"]["done"] is True
            assert "closed" not in response["error"]["data"]
        elif case == "absent":
            assert not response["ok"] and response["error"]["code"] == "contentModified", response
            data = response["error"]["data"]
            assert data["closed"] is False and "currentVersion" not in data, data
            assert data["saved"]["version"] == initial["version"]
            assert tracked(port) is None
        else:
            if close_after:
                assert not response["ok"] and response["error"]["code"] == "contentModified", response
                data = response["error"]["data"]
                assert data["reason"] == "savedDocumentChanged" and data["closed"] is False, data
                assert data["saved"]["version"] == initial["version"] and data["currentVersion"] == version, data
                assert response["fileProgress"]["done"] is True
            else:
                assert ok(response)["version"] == initial["version"]
            current = tracked(port)
            assert current and current["version"] == version and not current["checkpointed"], current
            continued = ok(request(port, "run_with", path="Main.lean", handle=handle, text="trivial"))
            assert continued["success"], continued
            assert source.read_text() == (SOURCE if "identical" in case else SOURCE.replace("11", "22"))
        if not before_dispatch:
            assert Path(spec["tracePath"]).is_file(), response
    print(f"save finalization ({case}): passed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--keep", type=Path)
    args = parser.parse_args()
    prefix = Path(subprocess.check_output(["lean", "--print-prefix"], cwd=REPO, text=True).strip())
    exe = ".exe" if os.name == "nt" else ""
    lean = prefix / "bin" / ("lean" + exe)
    plugin = REPO / ".lake/build/lib" / shared_lib_name()
    daemon = REPO / ".lake/build/bin" / ("beam-daemon-fixture" + exe)
    def run(base):
        for case in [args.case] if args.case else CASES:
            check_case(base / case, case, lean, plugin, daemon)
    if args.keep:
        args.keep.mkdir(parents=True, exist_ok=False)
        run(args.keep.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="beam-save-finalization-") as temporary:
            run(Path(temporary).resolve())


if __name__ == "__main__":
    main()
