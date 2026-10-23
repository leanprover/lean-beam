#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Private preparation preserves canonical checkpoints and exact finalization identity."""

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
REPLY_CASES = ["remote-invalid-params", "remote-owner-loss", "remote-cancelled",
               "malformed-completion", "handler-failure", "cancelled-handler-failure", "cancelled-remote-owner-loss",
               "remote-worker-crashed", "cancelled-remote-worker-crashed"]
REPLY_CASES += ["ordinary-" + case for case in REPLY_CASES]
WRITE_CASES = [prefix + case for prefix in ("", "ordinary-")
               for case in ("uncertain-save", "uncertain-save-flush")]
WORKER_CANCEL_CASES = [prefix + "cancel-prepared-" + operation
                       for prefix in ("", "module-") for operation in ("save", "close")]
OWNER_CASES = ["workspace-replace", "backend-restart", "distinct-runtime",
               "delayed-admission", "uncertain-close", "rejected-close"] + REPLY_CASES + WRITE_CASES + WORKER_CANCEL_CASES
CLOSING_CASES = ["exclusive", "preflight-exclusive", "cancel-before-dispatch", "cancel-close",
                 "cancel-failed-close", "failed-close"]
CASES = ["exact", "save-update", "save-reopen", "save-reopen-identical", "drop", "before-dispatch"]
CASES += CLOSING_CASES
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


def artifact_paths(saved):
    fields = ("olean", "ilean", "c", "trace", "oleanServer", "oleanPrivate", "ir", "irSig", "bc")
    assert all(field in saved for field in fields[:4]), saved
    return [Path(saved[field]) for field in fields if saved.get(field)]


def checkpoint(saved):
    return {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in artifact_paths(saved)}


def assert_checkpoint_unchanged(prior):
    assert {path: (path.read_bytes(), path.stat().st_mtime_ns) for path in prior} == prior


def private_paths(spec):
    assert all(isinstance(spec.get(field), str)
               for field in ("oleanPath", "ileanPath", "cPath", "tracePath")), spec
    return [Path(value) for field, value in spec.items()
            if field.endswith("Path") and isinstance(value, str)]


def assert_private_cleaned(spec):
    for path in private_paths(spec):
        assert path.parent.name.startswith(".beam-publication-"), path
        assert not path.exists(), path
        assert not path.parent.exists(), path.parent
        assert not Path(str(path.parent) + ".claim").exists(), path.parent


def assert_canonical_present(saved):
    for path in artifact_paths(saved):
        assert path.is_file(), path
        assert not path.parent.name.startswith(".beam-publication-"), path


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


def closing_case(base, case, lean, plugin, daemon):
    operation = "prepare-save" if case in ("preflight-exclusive", "cancel-before-dispatch") else "write-save-trace"
    with broker(base, lean, plugin, daemon, operation) as (port, source):
        initial = ok(request(port, "sync_file", path="Main.lean"))
        seed = ok(request(port, "run_at", path="Main.lean", version=initial["version"],
                          line=2, character=2, text="skip", storeHandle=True))
        prior = checkpoint(ok(request(port, "save_olean", path="Main.lean")))
        (base / "enabled").touch()
        spec = None
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(request, port, "close", path="Main.lean", saveArtifacts=True,
                                      clientRequestId="closing-save")
            try:
                wait_until(lambda: (base / "entered").exists(), 35, "reserved close-save helper")
                if operation == "write-save-trace":
                    job = Path(json.loads((base / "entered").read_text())["job"])
                    spec = json.loads((job / "request.json").read_text())
                    assert all(path not in prior for path in private_paths(spec)), spec
                conflicts = [
                    ("update_file", {}), ("sync_file", {}), ("refresh_file", {}),
                    ("close", {}), ("close", {"saveArtifacts": True}), ("save_olean", {}),
                    ("hover", {"version": initial["version"], "line": 0, "character": 4}),
                    ("run_with", {"handle": seed["handle"], "text": "skip"}),
                    ("release", {"handle": seed["handle"]}),
                ]
                for op, fields in conflicts:
                    response = request(port, op, path="Main.lean", wait_seconds=3, **fields)
                    assert not response["ok"], (case, op, response)
                    assert response["error"]["code"] == "contentModified", response
                    assert response["error"]["data"]["reason"] == "documentClosing", response
                assert tracked(port)["version"] == initial["version"]
                # The reservation is per canonical document, not per workspace or save mutex.
                (source.parent / "Other.lean").write_text("def other : Nat := 42\n")
                ok(request(port, "sync_file", path="Other.lean", wait_seconds=10))
                if case in ("cancel-close", "cancel-failed-close", "cancel-before-dispatch"):
                    # The helper gate holds private preparation before canonical commit.
                    assert_checkpoint_unchanged(prior)
                    assert ok(request(port, "cancel", cancelRequestId="closing-save"))["cancelled"]
                    if case != "cancel-before-dispatch":
                        try:
                            pending.result(timeout=.1)
                        except concurrent.futures.TimeoutError:
                            pass
                        else:
                            raise AssertionError("cancelled trace helper completed before explicit release")
                    if case == "cancel-failed-close":
                        (base / "fail").touch()
                    (base / "release").touch()
                elif case == "failed-close":
                    (base / "fail").touch()
                else:
                    (base / "release").touch()
                response = pending.result(timeout=35)
            finally:
                (base / "release").touch()
        (base / "response.json").write_text(json.dumps(response, indent=2) + "\n")
        if case in ("cancel-close", "cancel-failed-close", "cancel-before-dispatch", "failed-close"):
            assert not response["ok"], response
            assert "saved" not in (response["error"].get("data") or {}), response
            assert_checkpoint_unchanged(prior)
            if case in ("cancel-close", "cancel-failed-close", "cancel-before-dispatch"):
                assert response["error"]["code"] == "requestCancelled", response
            if spec and case == "cancel-close":
                assert_private_cleaned(spec)
            if spec and case == "cancel-failed-close":
                for path in private_paths(spec):
                    assert path.parent.is_dir(), path
                    assert Path(str(path.parent) + ".claim").is_file(), path
            assert tracked(port)["checkpointed"] is True, response
            # Precommit failure releases admission and retains the live document/handle.
            ok(request(port, "run_with", path="Main.lean", handle=seed["handle"], text="trivial"))
            (base / "enabled").unlink()
            ok(request(port, "close", path="Main.lean", saveArtifacts=True))
        else:
            result = ok(response)
            assert result["closed"] is True, response
            assert_canonical_present(result["saved"])
            if spec:
                assert_private_cleaned(spec)
        assert tracked(port) is None
        # A fresh caller is free to reopen after closure.
        assert ok(request(port, "sync_file", path="Main.lean"))["version"] == 1
    print(f"save finalization ({case}): passed", flush=True)


def check_case(base, case, lean, plugin, daemon):
    base.mkdir()
    if case in CLOSING_CASES:
        closing_case(base, case, lean, plugin, daemon)
        return
    if case in OWNER_CASES:
        project = base / "project"
        project.mkdir()
        worker_cancel = case in WORKER_CANCEL_CASES
        plugin_args = ("moreGlobalServerArgs = " + json.dumps([f"--plugin={plugin}"]) + "\n"
                       if worker_cancel else "")
        (project / "lakefile.toml").write_text('name = "Main"\n' + plugin_args + '[[lean_lib]]\nname = "Main"\n')
        (project / "lean-toolchain").write_text((REPO / "lean-toolchain").read_text())
        (project / "Main.lean").write_text(("module\npublic " if case.startswith("module-") else "") + SOURCE)
        selected_plugin = plugin.with_name(plugin.name.replace("Beam_LSP", "BeamPrivateSaveGate")) if worker_cancel else plugin
        subprocess.run([str(daemon), "--lean-cmd", str(lean), "--lean-plugin", str(selected_plugin),
                        "save-owner-test", case, str(project)], cwd=REPO, check=True, timeout=60,
                       env=dict(os.environ, BEAM_TEST_SAVE_GATE_DIR=str(base),
                                BEAM_TEST_SAVE_GATE_OP=(
                                    "prepare-save" if case in WRITE_CASES or case in REPLY_CASES
                                    else "write-save-trace"),
                                BEAM_PRIVATE_EFFECT_GATE=str(base) if worker_cancel else "",
                                BEAM_PRIVATE_EFFECT_PHASE="after-serialization" if worker_cancel else ""))
        return
    before_dispatch = case == "before-dispatch"
    with broker(base, lean, plugin, daemon, "prepare-save" if before_dispatch else "write-save-trace") as (port, source):
        initial = ok(request(port, "sync_file", path="Main.lean"))
        prior_artifacts = checkpoint(ok(request(port, "save_olean", path="Main.lean")))
        (base / "enabled").touch()
        close_after = case in ("exact", "drop")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            pending = executor.submit(request, port, "close" if close_after else "save_olean",
                                      path="Main.lean", **({"saveArtifacts": True} if close_after else {}))
            try:
                wait_until(lambda: (base / "entered").exists(), 35, "save preparation helper")
                job = Path(json.loads((base / "entered").read_text())["job"])
                spec = json.loads((job / "request.json").read_text())
                if not before_dispatch:
                    assert all(path.is_file() for path in private_paths(spec)
                               if path != Path(spec["tracePath"])), spec
                    assert not Path(spec["tracePath"]).exists(), spec
                    assert all(path not in prior_artifacts for path in private_paths(spec)), spec
                assert_checkpoint_unchanged(prior_artifacts)
                version = initial["version"]
                handle = None
                if case == "drop":
                    ok(request(port, "drop_workspace"))
                elif case != "exact":
                    if "reopen" in case or before_dispatch:
                        ok(request(port, "close", path="Main.lean"))
                    if "identical" not in case and not before_dispatch:
                        source.write_text(SOURCE.replace("11", "22"))
                    update = ok(request(port, "update_file", path="Main.lean"))
                    version = update["version"]
                    assert version == (1 if "reopen" in case or before_dispatch else 2), update
                    # A fresh replacement context must survive refused old finalization.
                    seed = ok(request(port, "run_at", path="Main.lean", version=version,
                                      line=2, character=2, text="skip", storeHandle=True))
                    handle = seed["handle"]
                    assert tracked(port)["checkpointed"] is False
                (base / "release").touch()
                response = pending.result(timeout=35)
            finally:
                (base / "release").touch()
        (base / "response.json").write_text(json.dumps(response, indent=2) + "\n")
        print(f"save finalization ({case}): {json.dumps(response)}", flush=True)
        if case == "exact":
            result = ok(response)
            assert result["closed"] is True
            assert_canonical_present(result["saved"])
            assert_private_cleaned(spec)
            assert tracked(port) is None
        elif case == "drop":
            assert not response["ok"] and response["error"]["code"] == "workerExited", response
            assert "saved" not in (response["error"].get("data") or {}), response
            assert "closed" not in (response["error"].get("data") or {}), response
            assert response["fileProgress"]["done"] is True
            assert_checkpoint_unchanged(prior_artifacts)
        else:
            assert not response["ok"] and response["error"]["code"] == "contentModified", response
            assert response["error"]["data"]["reason"] == "documentChanged", response
            assert "saved" not in (response["error"].get("data") or {}), response
            assert_checkpoint_unchanged(prior_artifacts)
            if before_dispatch:
                assert not (base / "trace-entered").exists(), "stale basis reached trace preparation"
            current = tracked(port)
            assert current and current["version"] == version and not current["checkpointed"], current
            continued = ok(request(port, "run_with", path="Main.lean", handle=handle, text="trivial"))
            assert continued["success"], continued
            assert source.read_text() == (SOURCE if "identical" in case or before_dispatch
                                          else SOURCE.replace("11", "22"))
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
