#!/usr/bin/env python3

import argparse
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from mcp_test_util import (
    MCP_LEGACY_PROTOCOL_VERSION,
    MCP_MODERN_PROTOCOL_VERSION,
    fail,
    require,
    require_document_progress_range,
    save_warning_text,
    shared_lib_name,
)


def load_bridge_module(repo_root):
    bridge_path = repo_root / "tests" / "mcp_http_bridge.py"
    spec = importlib.util.spec_from_file_location("mcp_http_bridge", bridge_path)
    require(spec is not None and spec.loader is not None, f"failed to load bridge module spec for {bridge_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_bridge_bind_skips_reverse_lookup(repo_root):
    bridge = load_bridge_module(repo_root)
    original_getfqdn = socket.getfqdn

    def fail_getfqdn(host):
        fail(f"bridge bind unexpectedly called socket.getfqdn({host!r})")

    socket.getfqdn = fail_getfqdn
    try:
        server = bridge.BridgeHttpServer(
            ("127.0.0.1", 0),
            bridge.McpBridgeHandler,
            endpoint="/mcp",
            allowed_origins=set(),
            mcp=object(),
        )
        try:
            host, port = server.server_address[:2]
            require(host == "127.0.0.1", f"unexpected bridge bind host: {server.server_address}")
            require(port > 0, f"expected ephemeral bridge port, got {server.server_address}")
            require(server.server_name == host, f"unexpected bridge server name: {server.server_name!r}")
            require(server.server_port == port, f"unexpected bridge server port: {server.server_port!r}")
        finally:
            server.server_close()
    finally:
        socket.getfqdn = original_getfqdn


def wait_for_ready(ready_file, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if ready_file.exists():
            data = json.loads(ready_file.read_text(encoding="utf-8"))
            return data["url"]
        time.sleep(0.05)
    fail(f"timed out waiting for bridge ready file {ready_file}")


def http_json(
    url,
    payload,
    *,
    protocol_version=MCP_LEGACY_PROTOCOL_VERSION,
    origin=None,
    content_type="application/json",
    extra_headers=None,
    timeout=30,
):
    headers = {
        "Accept": "application/json, text/event-stream",
    }
    if content_type is not None:
        headers["Content-Type"] = content_type
    if protocol_version is not None:
        headers["MCP-Protocol-Version"] = protocol_version
    if origin is not None:
        headers["Origin"] = origin
    if extra_headers is not None:
        headers.update(extra_headers)
    request = urllib.request.Request(
        url,
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
            if response.status == 202:
                return response.status, None
            require(response.headers.get_content_type() == "application/json", "expected application/json response")
            return response.status, json.loads(body.decode("utf-8"))
    except urllib.error.HTTPError as err:
        body = err.read()
        parsed = json.loads(body.decode("utf-8")) if body else None
        return err.code, parsed


def http_get_status(url, timeout=30):
    request = urllib.request.Request(
        url,
        headers={"Accept": "text/event-stream"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status
    except urllib.error.HTTPError as err:
        return err.code


def expect_result(response):
    status, body = response
    require(status == 200, f"expected HTTP 200, got {status}: {body}")
    require(isinstance(body, dict), f"expected JSON response body, got {body}")
    require("error" not in body, f"unexpected JSON-RPC error: {body}")
    result = body.get("result")
    require(isinstance(result, dict), f"expected JSON-RPC result object, got {body}")
    return result


def expect_rpc_error(response, code):
    expect_http_rpc_error(response, 200, code)


def expect_http_rpc_error(response, expected_status, code):
    status, body = response
    require(status == expected_status, f"expected HTTP {expected_status}, got {status}: {body}")
    error = body.get("error") if isinstance(body, dict) else None
    require(isinstance(error, dict), f"expected JSON-RPC error body, got {body}")
    require(error.get("code") == code, f"expected JSON-RPC error code {code}, got {body}")


def expect_tool_error(response, code):
    result = expect_result(response)
    require(result.get("isError") is True, f"expected MCP tool error result, got {result}")
    structured = result.get("structuredContent")
    require(isinstance(structured, dict), f"tool error missing structuredContent: {result}")
    require(structured.get("code") == code, f"expected tool error code {code}, got {structured}")


def text_tail(text, limit=80):
    lines = text.splitlines()
    return "\n".join(lines[-limit:]) if lines else "<empty>"


def stop_bridge_process(bridge):
    if bridge.poll() is None:
        bridge.terminate()
        try:
            bridge.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait(timeout=5)


def stream_text(stream):
    if stream is None:
        return ""
    try:
        return stream.read()
    except Exception as err:
        return f"<failed to read stream: {err}>"


def file_text(path):
    try:
        if path.exists():
            return path.read_text(encoding="utf-8")
    except Exception as err:
        return f"<failed to read {path}: {err}>"
    return ""


def bridge_failure_context(bridge, child_stderr_file):
    stop_bridge_process(bridge)
    return "\n".join([
        f"bridge return code: {bridge.returncode}",
        "bridge stdout tail:",
        text_tail(stream_text(bridge.stdout)),
        "bridge stderr tail:",
        text_tail(stream_text(bridge.stderr)),
        "lean-beam-mcp stderr tail:",
        text_tail(file_text(child_stderr_file)),
    ])


def start_bridge(
    repo_root,
    exe,
    lean_cmd,
    plugin,
    ready_file,
    child_stderr_file,
    timeout,
    *,
    protocol_era="legacy",
    env=None,
):
    command = [
        sys.executable,
        str(repo_root / "tests" / "mcp_http_bridge.py"),
        "--server",
        str(exe),
        "--lean-cmd",
        lean_cmd,
        "--lean-plugin",
        str(plugin),
        "--protocol-era",
        protocol_era,
        "--ready-file",
        str(ready_file),
        "--server-stderr-file",
        str(child_stderr_file),
        "--timeout",
        str(timeout),
    ]
    return subprocess.Popen(
        command,
        cwd=str(repo_root),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description="Smoke-test the local MCP stdio-to-HTTP bridge.")
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[1]
    assert_bridge_bind_skips_reverse_lookup(repo_root)

    exe = repo_root / ".lake" / "build" / "bin" / "lean-beam-mcp"
    plugin = repo_root / ".lake" / "build" / "lib" / shared_lib_name()
    lean_cmd = shutil.which("lean") or "lean"
    require(exe.exists(), f"missing lean-beam-mcp executable at {exe}")
    require(plugin.exists(), f"missing Beam LSP plugin shared library at {plugin}")

    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-http-") as tmp:
        tmp_path = Path(tmp)
        project_root = tmp_path / "project"
        shutil.copytree(
            repo_root / "tests" / "save_olean_project",
            project_root,
            ignore=shutil.ignore_patterns(".beam"),
        )
        ready_file = tmp_path / "ready.json"
        child_stderr_file = tmp_path / "lean-beam-mcp.stderr"
        workspace = {"root": str(project_root.resolve())}
        bridge_env = os.environ.copy()
        bridge_env["LEAN_BEAM_MCP_TRACE"] = "1"
        bridge_env["LEAN_BEAM_BROKER_TRACE"] = "1"
        bridge = start_bridge(
            repo_root,
            exe,
            lean_cmd,
            plugin,
            ready_file,
            child_stderr_file,
            args.timeout,
            env=bridge_env,
        )
        try:
            url = wait_for_ready(ready_file, args.timeout)
            require(http_get_status(url, args.timeout) == 405, "bridge GET should return 405 without SSE support")

            forbidden_status, forbidden_body = http_json(
                url,
                {"jsonrpc": "2.0", "id": 99, "method": "ping"},
                origin="https://example.invalid",
                timeout=args.timeout,
            )
            require(forbidden_status == 403, f"invalid Origin should return HTTP 403, got {forbidden_status}: {forbidden_body}")

            bad_content_type_status, _ = http_json(
                url,
                {"jsonrpc": "2.0", "id": 97, "method": "ping"},
                content_type="text/plain",
                timeout=args.timeout,
            )
            require(bad_content_type_status == 415, f"unsupported Content-Type should return HTTP 415, got {bad_content_type_status}")

            bad_version_status, _ = http_json(
                url,
                {"jsonrpc": "2.0", "id": 98, "method": "ping"},
                protocol_version="2025-06-18",
                timeout=args.timeout,
            )
            require(bad_version_status == 400, f"unsupported MCP-Protocol-Version should return HTTP 400, got {bad_version_status}")

            init = expect_result(http_json(
                url,
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": MCP_LEGACY_PROTOCOL_VERSION,
                        "capabilities": {},
                        "clientInfo": {"name": "lean-beam-http-bridge-test", "version": "0"},
                    },
                },
                protocol_version=None,
                timeout=args.timeout,
            ))
            require(
                init.get("protocolVersion") == MCP_LEGACY_PROTOCOL_VERSION,
                f"unexpected initialized version: {init}",
            )

            initialized_status, initialized_body = http_json(
                url,
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                timeout=args.timeout,
            )
            require(initialized_status == 202 and initialized_body is None, "initialized notification should return HTTP 202")

            tools = expect_result(http_json(
                url,
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                timeout=args.timeout,
            )).get("tools")
            names = {tool.get("name") for tool in tools}
            require("beam_version" in names, f"tools/list missing beam_version: {tools}")
            require("lean_sync" in names, f"tools/list missing lean_sync: {tools}")
            require("beam_feedback_report" in names, f"tools/list missing beam_feedback_report: {tools}")
            require("beam_feedback" not in names, f"tools/list exposed obsolete beam_feedback: {tools}")
            require("lean_run_at" in names, f"tools/list missing lean_run_at: {tools}")
            require("$/lean/runAt" not in names, f"tools/list exposed raw LSP method: {tools}")

            expect_rpc_error(
                http_json(
                    url,
                    {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "$/lean/runAt", "arguments": {}}},
                    timeout=args.timeout,
                ),
                -32602,
            )

            expect_tool_error(
                http_json(
                    url,
                    {
                        "jsonrpc": "2.0",
                        "id": 4,
                        "method": "tools/call",
                        "params": {
                            "name": "lean_run_at",
                            "arguments": {
                                "path": "PositionEmptyLine.lean",
                                "line": 1,
                                "character": 0,
                                "workspace": workspace,
                            },
                        },
                    },
                    timeout=args.timeout,
                ),
                "invalidInput",
            )

            sync = expect_result(http_json(
                url,
                {
                    "jsonrpc": "2.0",
                    "id": 5,
                    "method": "tools/call",
                    "params": {
                        "name": "lean_sync",
                        "arguments": {"path": "PositionEmptyLine.lean", "workspace": workspace},
                    },
                },
                timeout=args.timeout,
            ))
            require(sync.get("isError") is not True, f"lean_sync returned tool error: {sync}")
            structured = sync.get("structuredContent")
            require(isinstance(structured, dict), f"sync missing structuredContent: {sync}")
            snapshot = structured.get("snapshot")
            require(isinstance(snapshot, str), f"sync missing snapshot: {sync}")
            require_document_progress_range(structured, "lean_sync")

            probe = expect_result(http_json(
                url,
                {
                    "jsonrpc": "2.0",
                    "id": 6,
                    "method": "tools/call",
                    "params": {
                        "name": "lean_run_at",
                        "arguments": {
                            "path": "PositionEmptyLine.lean",
                            "snapshot": snapshot,
                            "line": 1,
                            "character": 0,
                            "text": "def mcpHttpProbe : Nat := 1",
                            "workspace": workspace,
                        },
                    },
                },
                timeout=args.timeout,
            ))
            require(probe.get("isError") is not True, f"lean_run_at returned tool error: {probe}")

            (project_root / "SaveSmoke" / "B.lean").write_text(
                save_warning_text("-- mcp http diagnostic log"),
                encoding="utf-8",
            )
            warning_sync = expect_result(http_json(
                url,
                {
                    "jsonrpc": "2.0",
                    "id": 7,
                    "method": "tools/call",
                    "params": {
                        "name": "lean_sync",
                        "arguments": {
                            "path": "SaveSmoke/B.lean",
                            "diagnostic_scope": "all",
                            "workspace": workspace,
                        },
                    },
                },
                timeout=args.timeout,
            ))
            warning_structured = warning_sync.get("structuredContent")
            warning_readiness = warning_structured.get("readiness", {}) if isinstance(warning_structured, dict) else {}
            require(
                isinstance(warning_structured, dict)
                and "saveReady" not in warning_structured
                and warning_readiness.get("save_ready") is True,
                f"warning-only sync should return the response after diagnostic notifications: {warning_sync}",
            )

        except Exception as err:
            if "bridge return code:" in str(err):
                raise
            raise RuntimeError(f"{err}\n{bridge_failure_context(bridge, child_stderr_file)}") from err
        finally:
            stop_bridge_process(bridge)

        modern_ready_file = tmp_path / "modern-ready.json"
        modern_child_stderr_file = tmp_path / "modern-lean-beam-mcp.stderr"
        modern_bridge = start_bridge(
            repo_root,
            exe,
            lean_cmd,
            plugin,
            modern_ready_file,
            modern_child_stderr_file,
            args.timeout,
            protocol_era="modern",
        )
        try:
            modern_url = wait_for_ready(modern_ready_file, args.timeout)
            modern_meta = {
                "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
                "io.modelcontextprotocol/clientCapabilities": {},
                "io.modelcontextprotocol/clientInfo": {
                    "name": "lean-beam-modern-http-bridge-test",
                    "version": "0",
                },
            }

            discovery = expect_result(http_json(
                modern_url,
                {
                    "jsonrpc": "2.0",
                    "id": "modern-discover",
                    "method": "server/discover",
                    "params": {"_meta": modern_meta},
                },
                protocol_version=MCP_MODERN_PROTOCOL_VERSION,
                extra_headers={"Mcp-Method": "server/discover"},
                timeout=args.timeout,
            ))
            require(discovery.get("resultType") == "complete", f"modern discovery envelope is invalid: {discovery}")

            expect_http_rpc_error(
                http_json(
                    modern_url,
                    {
                        "jsonrpc": "2.0",
                        "id": "missing-method-header",
                        "method": "tools/list",
                        "params": {"_meta": modern_meta},
                    },
                    protocol_version=MCP_MODERN_PROTOCOL_VERSION,
                    timeout=args.timeout,
                ),
                400,
                -32020,
            )
            expect_http_rpc_error(
                http_json(
                    modern_url,
                    {
                        "jsonrpc": "2.0",
                        "id": "missing-modern-meta",
                        "method": "tools/list",
                        "params": {},
                    },
                    protocol_version=MCP_MODERN_PROTOCOL_VERSION,
                    extra_headers={"Mcp-Method": "tools/list"},
                    timeout=args.timeout,
                ),
                400,
                -32602,
            )
            expect_http_rpc_error(
                http_json(
                    modern_url,
                    {
                        "jsonrpc": "2.0",
                        "id": "removed-modern-initialize",
                        "method": "initialize",
                        "params": {"_meta": modern_meta},
                    },
                    protocol_version=MCP_MODERN_PROTOCOL_VERSION,
                    extra_headers={"Mcp-Method": "initialize"},
                    timeout=args.timeout,
                ),
                404,
                -32601,
            )

            version = expect_result(http_json(
                modern_url,
                {
                    "jsonrpc": "2.0",
                    "id": "encoded-tool-name",
                    "method": "tools/call",
                    "params": {
                        "name": "beam_version",
                        "arguments": {},
                        "_meta": modern_meta,
                    },
                },
                protocol_version=MCP_MODERN_PROTOCOL_VERSION,
                extra_headers={
                    "Mcp-Method": "tools/call",
                    "Mcp-Name": "=?base64?YmVhbV92ZXJzaW9u?=",
                },
                timeout=args.timeout,
            ))
            require(version.get("isError") is not True, f"Base64 Mcp-Name request failed: {version}")
        except Exception as err:
            raise RuntimeError(
                f"{err}\n{bridge_failure_context(modern_bridge, modern_child_stderr_file)}"
            ) from err
        finally:
            stop_bridge_process(modern_bridge)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"test-mcp-http-bridge.py: {err}", file=sys.stderr)
        sys.exit(1)
