#!/usr/bin/env python3

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise an installed MCP executable through the shared external stdio client."""

import argparse
import importlib.util
import json
import os
import sys
import tempfile
from pathlib import Path


tests = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(tests))
spec = importlib.util.spec_from_file_location("beam_mcp_stdio_tests", tests / "test-mcp-stdio.py")
stdio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stdio)


def smoke(server, project_root, source, unsupported_sources, *, modern, server_trace):
    timeout = float(os.environ.get("BEAM_MCP_SMOKE_TIMEOUT", "60"))
    shutdown_timeout = float(os.environ.get("BEAM_MCP_SMOKE_SHUTDOWN_TIMEOUT", "30"))
    client = stdio.McpClient(
        project_root, project_root, timeout, label="installed-mcp-smoke",
        server_command=[server], shutdown_timeout=min(shutdown_timeout, 5),
        server_trace=server_trace,
    )
    try:
        try:
            request = client.modern_request if modern else client.request
            if modern:
                discovery = stdio.expect_result(request("server/discover"))
                stdio.require_modern_result_envelope(discovery, "server/discover")
                stdio.require(
                    discovery.get("supportedVersions") == [stdio.MCP_MODERN_PROTOCOL_VERSION],
                    f"unexpected discovery response: {discovery}",
                )
            else:
                client.initialize()
            sync = stdio.expect_result(request("tools/call", {
                "name": "lean_sync",
                "arguments": {"path": source, "workspace": {"root": str(project_root)}},
            }))
            if modern:
                stdio.require_modern_result_envelope(sync, "lean_sync")
            stdio.require(sync.get("isError") is False, f"expected lean_sync success: {sync}")
            structured = sync.get("structuredContent")
            stdio.require(isinstance(structured, dict), f"lean_sync missing structuredContent: {sync}")
            stdio.require_document_progress_range(structured, "installed lean_sync")

            # Check the normal tool error path, rather than a separate CLI path preflight.
            missing = "__beam_mcp_smoke_missing__.lean"
            stdio.require(not (project_root / missing).exists(), f"smoke fixture exists: {missing}")
            failure = stdio.expect_result(request("tools/call", {
                "name": "lean_sync",
                "arguments": {"path": missing, "workspace": {"root": str(project_root)}},
            }))
            if modern:
                stdio.require_modern_result_envelope(failure, "missing-file lean_sync")
            stdio.require(failure.get("isError") is True, f"missing file was accepted: {failure}")
            error = failure.get("structuredContent")
            stdio.require(isinstance(error, dict), f"missing-file error missing structuredContent: {failure}")
            stdio.require(error.get("code") == "invalidParams", f"unexpected missing-file error code: {failure}")
            stdio.require(missing in error.get("message", ""), f"missing-file error omitted path: {failure}")
            for path in unsupported_sources:
                failure = stdio.expect_result(request("tools/call", {
                    "name": "lean_sync",
                    "arguments": {"path": path, "workspace": {"root": str(project_root)}},
                }))
                if modern:
                    stdio.require_modern_result_envelope(failure, "unsupported-source lean_sync")
                stdio.require(failure.get("isError") is True,
                              f"unsupported source was accepted: {failure}")
                error = failure.get("structuredContent")
                stdio.require(isinstance(error, dict) and error.get("code") == "invalidParams",
                              f"unexpected unsupported-source error code: {failure}")
            client.close_input()
            code = client.wait_for_exit_after_eof(shutdown_timeout)
        finally:
            client.close()
    except Exception:
        # close() has joined the stderr reader; traced failures still need its diagnostic tail.
        if client.server_trace and client.stderr_lines:
            print("\n".join(client.stderr_lines)[-65536:], file=sys.stderr)
        raise
    stderr = "\n".join(client.stderr_lines)
    stdio.require(code == 0, f"lean-beam-mcp exited with code {code}\n{stderr}")
    return structured["document_progress"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server")
    parser.add_argument("project_root", type=Path)
    parser.add_argument("source", nargs="?", default="PositionEmptyLine.lean")
    parser.add_argument("--server-trace", action="store_true")
    args = parser.parse_args()
    root = args.project_root.resolve()
    with tempfile.TemporaryDirectory(prefix="beam-input-smoke-", dir=root) as scratch:
        inputs = Path(scratch)
        (inputs / "notes.txt").write_text("ordinary notes\n")
        (inputs / "Directory.lean").mkdir()
        unsupported = [str(path.relative_to(root)) for path in
                       [inputs / "notes.txt", inputs / "Directory.lean"]]
        progress = {
            family: smoke(args.server, root, args.source, unsupported,
                          modern=modern, server_trace=args.server_trace)
            for family, modern in [("modern", True), ("legacy", False)]
        }
    print(json.dumps({"ok": True, "progress": progress}, sort_keys=True))


if __name__ == "__main__":
    main()
