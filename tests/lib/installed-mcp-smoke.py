#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

import json
import os
import select
import subprocess
import sys
import time
from pathlib import Path

SHUTDOWN_TIMEOUT_SECONDS = int(os.environ.get("BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT", "30"))
server, project_root = sys.argv[1:]
workspace = {"root": str(Path(project_root).resolve())}
proc = subprocess.Popen(
    [server],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    encoding="utf-8",
    bufsize=1,
)

def send(message):
    proc.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    proc.stdin.flush()

def recv(expected_id):
    deadline = time.monotonic() + 25
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError(f"timed out waiting for MCP response id {expected_id}")
        if proc.poll() is not None:
            raise RuntimeError(f"lean-beam-mcp exited early with {proc.returncode}: {proc.stderr.read()}")
        ready, _, _ = select.select([proc.stdout], [], [], remaining)
        if not ready:
            continue
        # Read one line from the raw pipe. TextIO buffering can otherwise retain the
        # next response while select waits for bytes that have already been read.
        line = proc.stdout.buffer.raw.readline()
        if line == b"":
            raise RuntimeError(f"lean-beam-mcp closed stdout before response id {expected_id}")
        response = json.loads(line)
        if (response.get("jsonrpc") == "2.0" and "id" not in response
                and isinstance(response.get("method"), str)):
            continue
        if response.get("id") != expected_id:
            raise RuntimeError(f"expected response id {expected_id}, got {response}")
        return response

send({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
        "protocolVersion": "2025-11-25",
        "capabilities": {},
        "clientInfo": {"name": "lean-beam-install-test", "version": "0"},
    },
})
init = recv(1)
if init.get("result", {}).get("protocolVersion") != "2025-11-25":
    raise RuntimeError(f"unexpected initialize response: {init}")

send({"jsonrpc": "2.0", "method": "notifications/initialized"})
send({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean", "workspace": workspace}},
})
sync = recv(2)
result = sync.get("result")
if not isinstance(result, dict) or result.get("isError") is True:
    raise RuntimeError(f"expected lean_sync to succeed through installed MCP wrapper: {sync}")
structured = result.get("structuredContent")
if not isinstance(structured, dict) or not isinstance(structured.get("document_progress"), dict):
    raise RuntimeError(f"lean_sync result missing structured document_progress: {sync}")
progress = structured["document_progress"]
updates = progress.get("updates")
if not isinstance(updates, int) or isinstance(updates, bool) or updates < 0:
    raise RuntimeError(f"lean_sync result has invalid document_progress updates: {progress}")
done = progress.get("done")
if not isinstance(done, bool):
    raise RuntimeError(f"lean_sync result has invalid document_progress done: {progress}")
if "line" in progress:
    raise RuntimeError(f"lean_sync result should not expose document_progress line: {progress}")
if "totalLines" in progress:
    raise RuntimeError(f"lean_sync result should not expose document_progress totalLines: {progress}")
range_end = progress.get("range_end_line")
if range_end is not None and (
    not isinstance(range_end, int) or isinstance(range_end, bool) or range_end < 1
):
    raise RuntimeError(f"lean_sync result has invalid document_progress range_end_line: {progress}")
range_start = progress.get("range_start_line")
if range_start is not None and (
    not isinstance(range_start, int)
    or isinstance(range_start, bool)
    or range_start < 1
    or (range_end is not None and range_start > range_end)
):
    raise RuntimeError(f"lean_sync result has invalid document_progress range_start_line: {progress}")

proc.stdin.close()
try:
    code = proc.wait(timeout=SHUTDOWN_TIMEOUT_SECONDS)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
    stderr = proc.stderr.read()
    raise RuntimeError(
        f"lean-beam-mcp did not exit within {SHUTDOWN_TIMEOUT_SECONDS}s after EOF: {stderr}"
    )
stderr = proc.stderr.read()
if code != 0:
    raise RuntimeError(f"lean-beam-mcp exited with code {code}: {stderr}")
if stderr.strip():
    raise RuntimeError(f"lean-beam-mcp wrote stderr: {stderr}")
print(json.dumps({"ok": True, "progress": progress}, sort_keys=True))
