#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

import importlib.util
import json
import os
import sys
from pathlib import Path


def main():
    server, project_root = sys.argv[1:]
    project_root = Path(project_root).resolve()
    tests = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(tests))
    spec = importlib.util.spec_from_file_location("beam_mcp_stdio_tests", tests / "test-mcp-stdio.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    timeout = float(os.environ.get("BEAM_MCP_SMOKE_TIMEOUT", "25"))
    shutdown_timeout = float(os.environ.get("BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT", "30"))
    client = module.McpClient(
        project_root, project_root, timeout, label="installed-mcp-smoke",
        server_command=[server], shutdown_timeout=min(shutdown_timeout, 5),
    )
    try:
        init = client.request("initialize", {
            "protocolVersion": "2025-11-25", "capabilities": {},
            "clientInfo": {"name": "lean-beam-install-test", "version": "0"},
        }, request_id=1)
        if init.get("result", {}).get("protocolVersion") != "2025-11-25":
            raise RuntimeError(f"unexpected initialize response: {init}")
        client.notify("notifications/initialized")
        sync = client.request("tools/call", {
            "name": "lean_sync",
            "arguments": {"path": "PositionEmptyLine.lean", "workspace": {"root": str(project_root)}},
        }, request_id=2)
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
        client.close_input()
        code = client.wait_for_exit_after_eof(shutdown_timeout)
        if code != 0:
            raise RuntimeError(f"lean-beam-mcp exited with code {code}")
    finally:
        client.close()
    stderr = "\n".join(client.stderr_lines)
    if stderr.strip():
        raise RuntimeError(f"lean-beam-mcp wrote stderr: {stderr}")
    print(json.dumps({"ok": True, "progress": progress}, sort_keys=True))


if __name__ == "__main__":
    main()
