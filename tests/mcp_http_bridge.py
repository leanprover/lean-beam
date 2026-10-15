#!/usr/bin/env python3

import argparse
import base64
import binascii
import json
import select
import socketserver
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlparse

from mcp_test_util import MCP_LEGACY_PROTOCOL_VERSION, MCP_MODERN_PROTOCOL_VERSION


MCP_PROTOCOL_VERSION_META = "io.modelcontextprotocol/protocolVersion"
MCP_NAME_SOURCE = {
    "tools/call": "name",
    "resources/read": "uri",
    "prompts/get": "name",
}


class BridgeError(Exception):
    pass


class StdioMcpServer:
    def __init__(self, command, cwd, timeout, *, mirror_stderr=False, stderr_file=None):
        self.timeout = timeout
        self.mirror_stderr = mirror_stderr
        self.stderr_file = stderr_file
        self.lock = threading.Lock()
        self.stderr = []
        self.proc = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()

    def _drain_stderr(self):
        trace = None
        try:
            if self.stderr_file is not None:
                trace = open(self.stderr_file, "a", encoding="utf-8")
            for line in self.proc.stderr:
                self.stderr.append(line)
                if trace is not None:
                    trace.write(line)
                    trace.flush()
                if self.mirror_stderr:
                    print(line, file=sys.stderr, end="")
        finally:
            if trace is not None:
                trace.close()

    def stderr_tail(self, limit=80):
        return "".join(self.stderr[-limit:])

    def close(self):
        if self.proc.poll() is None:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait(timeout=5)

    def send_notification(self, message):
        with self.lock:
            self._write_message(message)

    def send_request(self, message):
        with self.lock:
            self._write_message(message)
            return self._read_response()

    def _write_message(self, message):
        if self.proc.poll() is not None:
            raise BridgeError(f"lean-beam-mcp exited with code {self.proc.returncode}")
        line = json.dumps(message, separators=(",", ":"))
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def _read_response(self):
        deadline = time.monotonic() + self.timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BridgeError(
                    "timed out waiting for lean-beam-mcp response\n"
                    f"lean-beam-mcp stderr tail:\n{self.stderr_tail() or '<empty>'}"
                )
            if self.proc.poll() is not None:
                stderr = self.stderr_tail()
                raise BridgeError(f"lean-beam-mcp exited with code {self.proc.returncode}\n{stderr}")
            ready, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if line == "":
                raise BridgeError("lean-beam-mcp closed stdout")
            try:
                message = json.loads(line)
            except json.JSONDecodeError as err:
                raise BridgeError(f"lean-beam-mcp wrote invalid JSON: {err}: {line!r}") from err
            if "method" in message and "id" not in message:
                continue
            return message


class BridgeHttpServer(HTTPServer):
    allow_reuse_address = True

    def __init__(
        self,
        server_address,
        handler_cls,
        *,
        endpoint,
        allowed_origins,
        mcp,
        protocol_era="legacy",
    ):
        super().__init__(server_address, handler_cls)
        self.endpoint = endpoint
        self.allowed_origins = allowed_origins
        self.mcp = mcp
        self.protocol_era = protocol_era

    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


class McpBridgeHandler(BaseHTTPRequestHandler):
    server_version = "lean-beam-mcp-http-bridge/0"

    def log_message(self, fmt, *args):
        if self.server.verbose:
            super().log_message(fmt, *args)

    def do_GET(self):
        if not self._check_path():
            return
        self._send_empty(HTTPStatus.METHOD_NOT_ALLOWED)

    def do_DELETE(self):
        if not self._check_path():
            return
        self._send_empty(HTTPStatus.METHOD_NOT_ALLOWED)

    def do_POST(self):
        if not self._check_path():
            return
        if not self._check_origin():
            return
        if not self._check_content_type():
            return
        if not self._check_accept():
            return
        try:
            body = self._read_json_body()
        except BridgeError as err:
            self._send_json_error(HTTPStatus.BAD_REQUEST, None, -32700, str(err))
            return

        if not isinstance(body, dict):
            self._send_json_error(HTTPStatus.BAD_REQUEST, None, -32600, "HTTP body must be one JSON-RPC object")
            return

        is_request = "id" in body
        if is_request and not self._check_request_headers(body):
            return
        try:
            if is_request:
                response = self.server.mcp.send_request(body)
                self._send_json(self._response_status(response), response)
            else:
                self.server.mcp.send_notification(body)
                self._send_empty(HTTPStatus.ACCEPTED)
        except BridgeError as err:
            self._send_json_error(HTTPStatus.INTERNAL_SERVER_ERROR, body.get("id"), -32603, str(err))

    def _check_path(self):
        if urlparse(self.path).path != self.server.endpoint:
            self._send_empty(HTTPStatus.NOT_FOUND)
            return False
        return True

    def _check_origin(self):
        origin = self.headers.get("Origin")
        if origin is not None and origin not in self.server.allowed_origins:
            self._send_json_error(HTTPStatus.FORBIDDEN, None, -32600, "invalid Origin header")
            return False
        return True

    def _check_accept(self):
        accept = self.headers.get("Accept", "")
        accepted = [part.split(";", 1)[0].strip() for part in accept.split(",")]
        if "application/json" not in accepted or "text/event-stream" not in accepted:
            self._send_empty(HTTPStatus.NOT_ACCEPTABLE)
            return False
        return True

    def _check_content_type(self):
        content_type = self.headers.get("Content-Type", "")
        media_type = content_type.split(";", 1)[0].strip().lower()
        if media_type != "application/json":
            self._send_empty(HTTPStatus.UNSUPPORTED_MEDIA_TYPE)
            return False
        return True

    def _check_request_headers(self, body):
        if self.server.protocol_era == "modern":
            return self._check_modern_request_headers(body)
        return self._check_legacy_protocol_version_header()

    def _check_legacy_protocol_version_header(self):
        version = self._header_value("MCP-Protocol-Version")
        if version is not None and version != MCP_LEGACY_PROTOCOL_VERSION:
            self._send_empty(HTTPStatus.BAD_REQUEST)
            return False
        return True

    def _check_modern_request_headers(self, body):
        request_id = body.get("id")
        header_version = self._header_value("MCP-Protocol-Version")
        params = body.get("params")
        meta = params.get("_meta") if isinstance(params, dict) else None
        body_version = meta.get(MCP_PROTOCOL_VERSION_META) if isinstance(meta, dict) else None
        if not isinstance(header_version, str) or header_version == "":
            return self._reject_header_mismatch(request_id, "missing MCP-Protocol-Version header")
        if not isinstance(body_version, str) or body_version == "":
            self._send_json_error(
                HTTPStatus.BAD_REQUEST,
                request_id,
                -32602,
                "request body is missing required protocol-version metadata",
            )
            return False
        if header_version != body_version:
            return self._reject_header_mismatch(
                request_id,
                "MCP-Protocol-Version header does not match request body metadata",
            )
        if header_version != MCP_MODERN_PROTOCOL_VERSION:
            self._send_json_error(
                HTTPStatus.BAD_REQUEST,
                request_id,
                -32022,
                f"unsupported MCP protocol version '{header_version}'",
                data={
                    "supported": [MCP_MODERN_PROTOCOL_VERSION],
                    "requested": header_version,
                },
            )
            return False

        method = body.get("method")
        header_method = self._header_value("Mcp-Method")
        if not isinstance(method, str) or header_method != method:
            return self._reject_header_mismatch(
                request_id,
                "Mcp-Method header is missing or does not match the request body",
            )

        source_field = MCP_NAME_SOURCE.get(method)
        if source_field is None:
            return True
        body_name = params.get(source_field) if isinstance(params, dict) else None
        header_name = self._header_value("Mcp-Name")
        try:
            decoded_name = self._decode_header_value(header_name)
        except BridgeError as err:
            return self._reject_header_mismatch(request_id, str(err))
        if not isinstance(body_name, str) or decoded_name != body_name:
            return self._reject_header_mismatch(
                request_id,
                "Mcp-Name header is missing or does not match the request body",
            )
        return True

    def _header_value(self, name):
        value = self.headers.get(name)
        return value.strip(" \t") if isinstance(value, str) else None

    @staticmethod
    def _decode_header_value(value):
        if not isinstance(value, str):
            raise BridgeError("missing required header value")
        if value.startswith("=?base64?") and value.endswith("?="):
            encoded = value[len("=?base64?"):-len("?=")]
            try:
                return base64.b64decode(encoded, validate=True).decode("utf-8")
            except (binascii.Error, UnicodeDecodeError) as err:
                raise BridgeError("malformed Base64 header value") from err
        if any(character != "\t" and not (" " <= character <= "~") for character in value):
            raise BridgeError("header value contains invalid characters")
        return value

    def _reject_header_mismatch(self, request_id, message):
        self._send_json_error(
            HTTPStatus.BAD_REQUEST,
            request_id,
            -32020,
            f"header mismatch: {message}",
        )
        return False

    def _response_status(self, response):
        if self.server.protocol_era != "modern" or not isinstance(response, dict):
            return HTTPStatus.OK
        error = response.get("error")
        if not isinstance(error, dict):
            return HTTPStatus.OK
        if error.get("code") == -32601:
            return HTTPStatus.NOT_FOUND
        if error.get("code") == -32603:
            return HTTPStatus.INTERNAL_SERVER_ERROR
        return HTTPStatus.BAD_REQUEST

    def _read_json_body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as err:
            raise BridgeError("invalid Content-Length") from err
        raw = self.rfile.read(length)
        try:
            return json.loads(raw.decode("utf-8"))
        except UnicodeDecodeError as err:
            raise BridgeError("request body is not UTF-8") from err
        except json.JSONDecodeError as err:
            raise BridgeError(f"request body is not valid JSON: {err}") from err

    def _send_empty(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_json(self, status, payload):
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _send_json_error(self, status, id_value, code, message, *, data=None):
        error = {"code": code, "message": message}
        if data is not None:
            error["data"] = data
        self._send_json(status, {
            "jsonrpc": "2.0",
            "id": id_value,
            "error": error,
        })


def parse_args():
    parser = argparse.ArgumentParser(description="Bridge lean-beam-mcp stdio to a local MCP Streamable HTTP endpoint.")
    parser.add_argument("--server", required=True, help="Path to lean-beam-mcp executable.")
    parser.add_argument("--lean-cmd", default="lean")
    parser.add_argument("--lean-plugin", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--endpoint", default="/mcp")
    parser.add_argument("--protocol-era", choices=("legacy", "modern"), default="legacy")
    parser.add_argument("--ready-file")
    parser.add_argument("--server-trace", action="store_true")
    parser.add_argument("--server-stderr-file")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    repo_root = Path.cwd()
    command = [
        str(Path(args.server)),
        "--lean-cmd",
        args.lean_cmd,
        "--lean-plugin",
        args.lean_plugin,
    ]
    mcp = StdioMcpServer(
        command,
        repo_root,
        args.timeout,
        mirror_stderr=args.server_trace,
        stderr_file=args.server_stderr_file,
    )
    try:
        server = BridgeHttpServer(
            (args.host, args.port),
            McpBridgeHandler,
            endpoint=args.endpoint,
            allowed_origins=set(),
            mcp=mcp,
            protocol_era=args.protocol_era,
        )
        server.verbose = args.verbose
        host, port = server.server_address
        server.allowed_origins = {
            f"http://{host}:{port}",
            f"http://127.0.0.1:{port}",
            f"http://localhost:{port}",
        }
        url = f"http://{host}:{port}{args.endpoint}"
        if args.ready_file:
            ready_path = Path(args.ready_file)
            # Publish complete JSON before the conformance runner can observe readiness.
            pending_path = ready_path.with_name(ready_path.name + ".tmp")
            pending_path.write_text(json.dumps({"url": url}) + "\n", encoding="utf-8")
            pending_path.replace(ready_path)
        else:
            print(url, flush=True)
        server.serve_forever()
    finally:
        mcp.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception as err:
        print(f"mcp_http_bridge.py: {err}", file=sys.stderr)
        sys.exit(1)
