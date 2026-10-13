#!/usr/bin/env python3

import argparse
import collections
import concurrent.futures
import json
import os
import platform
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from mcp_test_util import (
    MCP_LEGACY_PROTOCOL_VERSION,
    MCP_MODERN_PROTOCOL_VERSION,
    MCP_PUBLIC_CACHE_TTL_MS,
    fail,
    notification_params,
    notifications_by_method,
    progress_messages,
    require,
    require_document_progress_range,
    save_warning_text,
    shared_lib_name,
)


CI_TIMEOUT_TRACKER = "https://github.com/leanprover/lean-beam/issues/110"
CI_TIMEOUT_TRACKER_NOTE = "\n".join(
    [
        f"Comment on {CI_TIMEOUT_TRACKER} if this scheduler-sensitive timeout hits an unrelated CI PR.",
        "Include:",
        "  - PR URL and branch",
        "  - failing GitHub Actions run URL and job URL",
        "  - job name, runner OS/arch, run attempt, and commit SHA",
        "  - failing test/scenario and this timeout headline",
        (
            "  - MCP stdio pending requests, completed requests, server requests, "
            "notifications, event timeline, stderr/server trace or watchdog lines, and process snapshot"
        ),
        "  - rerun URL and whether the rerun passed or reproduced",
    ]
)


def compact_json(value, limit=700):
    try:
        text = json.dumps(value, separators=(",", ":"), sort_keys=True)
    except TypeError:
        text = repr(value)
    if len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def short_value(value, limit=120):
    return compact_json(value, limit=limit)


def env_enabled(name):
    value = os.environ.get(name)
    if value is None:
        return False
    return value.lower() not in ("", "0", "false", "no", "off")


def copy_project_fixture(source, target):
    shutil.copytree(source, target, ignore=shutil.ignore_patterns(".beam"))


def runtime_context_lines():
    lines = [
        f"platform: {platform.platform()}",
        f"machine: {platform.machine()}",
        f"python: {platform.python_implementation()} {platform.python_version()}",
        f"os.cpu_count: {os.cpu_count()}",
    ]
    if hasattr(os, "sched_getaffinity"):
        try:
            lines.append(f"sched_getaffinity: {len(os.sched_getaffinity(0))}")
        except OSError as err:
            lines.append(f"sched_getaffinity: <failed: {err}>")
    if hasattr(os, "getloadavg"):
        try:
            load1, load5, load15 = os.getloadavg()
            lines.append(f"loadavg: {load1:.2f} {load5:.2f} {load15:.2f}")
        except OSError as err:
            lines.append(f"loadavg: <failed: {err}>")
    for name in (
        "GITHUB_ACTIONS",
        "RUNNER_OS",
        "RUNNER_ARCH",
        "RUNNER_NAME",
        "ImageOS",
        "LEAN_NUM_THREADS",
        "LEAN_OPTIONS",
        "BEAM_MCP_STDIO_TIMEOUT",
        "BEAM_MCP_SERVER_TRACE",
        "LEAN_BEAM_BROKER_WAIT_DIAGNOSTICS_WATCHDOG_MS",
        "LEAN_BEAM_MCP_TEST_STATUS_DELAY_MS",
    ):
        lines.append(f"{name}: {os.environ.get(name, '<unset>')}")
    return lines


def format_duration_stats(values):
    require(values, "cannot format empty duration stats")
    ordered = sorted(values)
    total = sum(ordered)
    return (
        f"runs={len(ordered)} "
        f"min={ordered[0]:.3f}s "
        f"median={ordered[len(ordered) // 2]:.3f}s "
        f"max={ordered[-1]:.3f}s "
        f"avg={total / len(ordered):.3f}s"
    )


def request_label(method, params):
    label = method
    if method == "tools/call" and isinstance(params, dict):
        tool_name = params.get("name")
        if isinstance(tool_name, str):
            label = f"{method} {tool_name}"
        arguments = params.get("arguments")
        details = []
        if isinstance(arguments, dict):
            for key in ("path", "root", "mode"):
                if key in arguments:
                    details.append(f"{key}={short_value(arguments[key], 80)}")
        meta = params.get("_meta")
        if isinstance(meta, dict) and "progressToken" in meta:
            details.append(f"progressToken={short_value(meta['progressToken'], 80)}")
        if details:
            label = f"{label} ({', '.join(details)})"
    return label


def notification_summary(notification):
    method = notification.get("method")
    params = notification.get("params")
    if method == "notifications/progress" and isinstance(params, dict):
        return (
            f"{method} token={short_value(params.get('progressToken'), 80)} "
            f"progress={short_value(params.get('progress'), 40)} "
            f"message={short_value(params.get('message'), 180)}"
        )
    if method == "notifications/message" and isinstance(params, dict):
        return (
            f"{method} level={short_value(params.get('level'), 40)} "
            f"logger={short_value(params.get('logger'), 80)} "
            f"data={compact_json(params.get('data'), 240)}"
        )
    return compact_json(notification, limit=300)


def request_id_key(request_id):
    if isinstance(request_id, str):
        return ("string", request_id)
    if isinstance(request_id, bool) or not isinstance(request_id, int):
        fail(f"MCP request id must be a string or integer, got {request_id!r}")
    return ("number", request_id)


def with_modern_metadata(params=None, *, log_level=None):
    params = dict(params or {})
    meta = dict(params.get("_meta") or {})
    meta.update(
        {
            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
            "io.modelcontextprotocol/clientInfo": {
                "name": "lean-beam-mcp-test",
                "version": "0",
            },
        }
    )
    if log_level is not None:
        meta["io.modelcontextprotocol/logLevel"] = log_level
    params["_meta"] = meta
    return params


class McpClient:
    def __init__(
        self,
        repo_root,
        project_root,
        timeout,
        *,
        label="mcp-client",
        server_trace=False,
        drain_stdout=True,
        extra_env=None,
        resolve_with_beam_cli=False,
    ):
        self.repo_root = repo_root
        self.project_root = project_root
        self.timeout = timeout
        self.label = label
        self.server_trace = server_trace or env_enabled("BEAM_MCP_SERVER_TRACE")
        self.runtime_context = runtime_context_lines()
        self.state_changed = threading.Condition(threading.RLock())
        self.stdin_lock = threading.Lock()
        self.next_id = 0
        self.server_requests = collections.deque(maxlen=20)
        self.pending_requests = {}
        self.responses = {}
        self.stdout_error = None
        self.stdout_eof = False
        self.completed_requests = collections.deque(maxlen=20)
        self.notifications = []
        self.event_log = collections.deque(maxlen=80)
        self.started_at = time.monotonic()
        self.last_notification_at = None
        self.stderr_lines = collections.deque(maxlen=80)
        exe = repo_root / ".lake" / "build" / "bin" / "lean-beam-mcp"
        require(exe.exists(), f"missing lean-beam-mcp executable at {exe}")
        cmd = [str(exe)]
        if resolve_with_beam_cli:
            beam_cli = repo_root / ".lake" / "build" / "bin" / "beam-cli"
            require(beam_cli.exists(), f"missing beam-cli executable at {beam_cli}")
            cmd.extend(["--beam-cli", str(beam_cli)])
        else:
            plugin = repo_root / ".lake" / "build" / "lib" / shared_lib_name()
            lean_cmd = shutil.which("lean") or "lean"
            require(plugin.exists(), f"missing Beam LSP plugin shared library at {plugin}")
            cmd.extend(
                [
                    "--lean-cmd",
                    lean_cmd,
                    "--lean-plugin",
                    str(plugin),
                ]
            )
        env = os.environ.copy()
        if extra_env is not None:
            env.update({str(key): str(value) for key, value in extra_env.items()})
        if self.server_trace:
            env["LEAN_BEAM_MCP_TRACE"] = "1"
            env["LEAN_BEAM_BROKER_TRACE"] = "1"
        self.proc = subprocess.Popen(
            cmd,
            cwd=str(repo_root),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            bufsize=1,
        )
        self.stdout_thread = None
        if drain_stdout:
            self.stdout_thread = threading.Thread(target=self._drain_stdout, daemon=True)
            self.stdout_thread.start()
        self.stderr_thread = threading.Thread(target=self._drain_stderr, daemon=True)
        self.stderr_thread.start()
        self._record_event(f"process started pid={self.proc.pid}")

    def _drain_stdout(self):
        try:
            for line in self.proc.stdout:
                try:
                    message = json.loads(line)
                except json.JSONDecodeError as err:
                    raise RuntimeError(f"stdout line is not valid JSON: {err}: {line!r}") from err
                require(message.get("jsonrpc") == "2.0", f"bad JSON-RPC message: {message}")
                if "method" in message and "id" in message:
                    self.handle_server_request(message)
                    continue
                with self.state_changed:
                    if "method" in message:
                        self.last_notification_at = time.monotonic()
                        self.notifications.append(message)
                        self._record_event_locked(
                            f"server notification: {notification_summary(message)}"
                        )
                    else:
                        response_id = message.get("id")
                        response_key = request_id_key(response_id)
                        require(
                            response_key in self.pending_requests,
                            f"received response for unknown request id {response_id}: {message}",
                        )
                        require(
                            response_key not in self.responses,
                            f"received duplicate response id {response_id}: {message}",
                        )
                        self.responses[response_key] = message
                        self.state_changed.notify_all()
            with self.state_changed:
                self.stdout_eof = True
                self.state_changed.notify_all()
        except Exception as err:
            with self.state_changed:
                self.stdout_error = str(err)
                self.state_changed.notify_all()

    def _drain_stderr(self):
        try:
            for line in self.proc.stderr:
                self.stderr_lines.append(line.rstrip("\n"))
        except Exception as err:
            self.stderr_lines.append(f"<stderr drain failed: {err}>")

    def _record_event(self, label):
        with self.state_changed:
            self._record_event_locked(label)

    def _record_event_locked(self, label):
        self.event_log.append({"at": time.monotonic(), "label": label})

    def close(self):
        if self.proc.poll() is None:
            try:
                self.close_input()
            except Exception:
                self.proc.kill()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        if self.stdout_thread is not None:
            self.stdout_thread.join(timeout=1)
        self.stderr_thread.join(timeout=1)
        stderr = "\n".join(self.stderr_lines)
        if not self.server_trace:
            require(stderr.strip() == "", f"lean-beam-mcp wrote unexpected stderr:\n{stderr}")

    def send_message(self, message):
        require(self.proc.poll() is None, "lean-beam-mcp exited before request")
        line = json.dumps(message, separators=(",", ":"))
        with self.stdin_lock:
            self.proc.stdin.write(line + "\n")
            self.proc.stdin.flush()

    def handle_server_request(self, request):
        method = request.get("method")
        request_id = request.get("id")
        with self.state_changed:
            self._record_event_locked(f"server request id {request_id}: {method}")
            self.server_requests.append(
                {
                    "id": request_id,
                    "method": method,
                    "params": request.get("params"),
                    "received": time.monotonic(),
                }
            )
        fail(f"lean-beam-mcp emitted forbidden server request {method!r}: {request}")

    def _request_label(self, request_id):
        pending = self.pending_requests.get(request_id_key(request_id))
        if pending is None:
            return "<unknown request>"
        return pending["label"]

    def _client_context(self):
        return "\n".join(
            [
                f"client label: {self.label}",
                f"project root: {self.project_root}",
                f"process pid: {self.proc.pid}",
                "runtime context:",
                *[f"  {line}" for line in self.runtime_context],
            ]
        )

    def _pending_requests_summary(self):
        now = time.monotonic()
        lines = []
        for _request_key, pending in sorted(self.pending_requests.items()):
            request_id = pending["id"]
            age = now - pending["started"]
            lines.append(
                f"  id {request_id}: {pending['label']} age={age:.3f}s "
                f"params={compact_json(pending.get('params'), 500)}"
            )
        return "\n".join(lines) if lines else "  <none>"

    def _completed_requests_summary(self):
        completed = "\n".join(
            f"  id {entry['id']}: {entry['label']} in {entry['elapsed']:.3f}s"
            for entry in self.completed_requests
        )
        return completed or "  <none>"

    def _server_requests_summary(self):
        now = time.monotonic()
        lines = []
        for entry in self.server_requests:
            age = now - entry["received"]
            lines.append(
                f"  id {entry['id']}: {entry['method']} age={age:.3f}s "
                f"params={compact_json(entry.get('params'), 300)}"
            )
        return "\n".join(lines) if lines else "  <none>"

    def _notifications_summary(self):
        rows = self.notifications[-12:]
        if not rows:
            return "  <none>"
        return "\n".join(f"  {notification_summary(notification)}" for notification in rows)

    def _event_timeline_summary(self):
        now = time.monotonic()
        if not self.event_log:
            return "  <none>"
        return "\n".join(
            f"  +{entry['at'] - self.started_at:.3f}s "
            f"({now - entry['at']:.3f}s ago): {entry['label']}"
            for entry in self.event_log
        )

    def _last_notification_summary(self):
        if self.last_notification_at is None:
            return "last notification: <none>"
        return f"last notification: {time.monotonic() - self.last_notification_at:.3f}s ago"

    def _process_snapshot(self):
        try:
            out = subprocess.run(
                ["ps", "-ef"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=5,
                check=False,
            )
        except Exception as err:
            return f"<ps failed: {err}>"
        needles = [
            "lean-beam-mcp",
            "beam-daemon",
            "beam-daemon-smo",
            "lean --server",
        ]
        lines = [
            line
            for line in out.stdout.splitlines()
            if any(needle in line for needle in needles)
        ]
        return "\n".join(lines[-40:]) if lines else "<no Beam/Lean processes found>"

    def _diagnostic_context(self):
        stderr_tail = "\n".join(self.stderr_lines)
        return (
            f"MCP client context:\n{self._client_context()}\n"
            f"pending MCP requests:\n{self._pending_requests_summary()}\n"
            f"recent completed MCP requests:\n{self._completed_requests_summary()}\n"
            f"recent server requests received from lean-beam-mcp:\n"
            f"{self._server_requests_summary()}\n"
            f"recent notifications:\n{self._notifications_summary()}\n"
            f"MCP event timeline ({self._last_notification_summary()}):\n"
            f"{self._event_timeline_summary()}\n"
            f"CI timeout tracker:\n{CI_TIMEOUT_TRACKER_NOTE}\n"
            f"lean-beam-mcp stderr tail:\n{stderr_tail or '  <empty>'}\n"
            f"process snapshot:\n{self._process_snapshot()}"
        )

    def _timeout_message(self, expected_id):
        label = self._request_label(expected_id)
        pending = self.pending_requests.get(request_id_key(expected_id))
        elapsed = time.monotonic() - pending["started"] if pending is not None else 0.0
        return (
            f"timed out waiting for MCP response id {expected_id} ({label}) "
            f"for client {self.label!r} after {elapsed:.3f}s\n"
            f"{self._diagnostic_context()}"
        )

    def read_response(self, expected_id, timeout=None):
        require(self.stdout_thread is not None, "MCP stdout reader is disabled")
        response_key = request_id_key(expected_id)
        deadline = time.monotonic() + (self.timeout if timeout is None else timeout)
        with self.state_changed:
            while response_key not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    fail(self._timeout_message(expected_id))
                if self.stdout_error is not None:
                    fail(f"failed reading lean-beam-mcp stdout: {self.stdout_error}")
                if self.stdout_eof:
                    fail(f"lean-beam-mcp closed stdout before response id {expected_id}")
                if self.proc.poll() is not None:
                    stderr = "\n".join(self.stderr_lines)
                    fail(f"lean-beam-mcp exited early with code {self.proc.returncode}\n{stderr}")
                self.state_changed.wait(timeout=min(remaining, 0.1))
            response = self.responses.pop(response_key)
            pending = self.pending_requests.pop(response_key, None)
            if pending is not None:
                elapsed = time.monotonic() - pending["started"]
                self.completed_requests.append(
                    {
                        "id": expected_id,
                        "label": pending["label"],
                        "elapsed": elapsed,
                    }
                )
                self._record_event_locked(
                    f"response id {expected_id}: {pending['label']} elapsed={elapsed:.3f}s"
                )
            return response

    def send_request(self, method, params=None, *, request_id=None, inject_workspace=True):
        if inject_workspace and method == "tools/call" and isinstance(params, dict):
            tool_name = params.get("name")
            if tool_name == "beam_feedback_report" or (
                isinstance(tool_name, str)
                and tool_name.startswith("lean_")
            ):
                params = dict(params)
                arguments = dict(params.get("arguments") or {})
                arguments.setdefault(
                    "workspace",
                    {"root": str(self.project_root.resolve())},
                )
                params["arguments"] = arguments
        with self.state_changed:
            if request_id is None:
                self.next_id += 1
                request_id = self.next_id
            request_key = request_id_key(request_id)
            require(
                request_key not in self.pending_requests and request_key not in self.responses,
                f"duplicate pending MCP request id {request_id!r}",
            )
            label = request_label(method, params)
            self.pending_requests[request_key] = {
                "id": request_id,
                "label": label,
                "method": method,
                "params": params,
                "started": time.monotonic(),
            }
            self._record_event_locked(f"request id {request_id}: {label}")
        message = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            message["params"] = params
        self.send_message(message)
        return request_id

    def request(self, method, params=None, *, request_id=None, inject_workspace=True):
        request_id = self.send_request(
            method,
            params,
            request_id=request_id,
            inject_workspace=inject_workspace,
        )
        return self.read_response(request_id)

    def modern_request(self, method, params=None, *, request_id=None, log_level=None):
        return self.request(
            method,
            with_modern_metadata(params, log_level=log_level),
            request_id=request_id,
        )

    def close_input(self):
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()

    def wait_for_exit_after_eof(self, timeout):
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            fail(
                f"timed out waiting {timeout:.1f}s for lean-beam-mcp to exit after EOF\n"
                f"{self._diagnostic_context()}"
            )

    def response_ready(self, request_id):
        with self.state_changed:
            return request_id_key(request_id) in self.responses

    def forget_request(self, request_id):
        request_key = request_id_key(request_id)
        with self.state_changed:
            require(
                request_key not in self.responses,
                f"request id {request_id!r} unexpectedly received a response",
            )
            self.pending_requests.pop(request_key, None)

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._record_event(f"client notification: {method}")
        self.send_message(message)

    def initialize(self):
        response = self.request(
            "initialize",
            {
                "protocolVersion": MCP_LEGACY_PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "lean-beam-mcp-test", "version": "0"},
            },
        )
        result = expect_result(response)
        require(
            result.get("protocolVersion") == MCP_LEGACY_PROTOCOL_VERSION,
            f"server negotiated unexpected protocol version: {result}",
        )
        tools = result.get("capabilities", {}).get("tools")
        require(isinstance(tools, dict), f"initialize did not advertise tools capability: {result}")
        logging = result.get("capabilities", {}).get("logging")
        require(isinstance(logging, dict), f"initialize did not advertise logging capability: {result}")
        self.notify("notifications/initialized")

    def call_tool(self, name, arguments=None):
        params = {"name": name}
        if arguments is not None:
            params["arguments"] = arguments
        response = self.request("tools/call", params)
        result = expect_result(response)
        require(result.get("isError") is not True, f"tool {name} returned MCP tool error: {result}")
        content = result.get("content")
        require(isinstance(content, list) and content, f"tool {name} missing content: {result}")
        require(content[0].get("type") == "text", f"tool {name} first content block is not text: {result}")
        structured = result.get("structuredContent")
        require(isinstance(structured, dict), f"tool {name} missing structuredContent: {result}")
        return structured

    def progress_notifications(self, token):
        with self.state_changed:
            notifications = list(self.notifications)
        rows = []
        for notification in notifications_by_method(notifications, "notifications/progress"):
            params = notification_params(notification, "notifications/progress", "progress notification")
            if params.get("progressToken") == token:
                rows.append(notification)
        return rows


def expect_result(response):
    if "error" in response:
        fail(f"unexpected JSON-RPC error response: {response}")
    result = response.get("result")
    require(result is not None, f"missing JSON-RPC result: {response}")
    return result


def expect_error_code(response, code):
    error = response.get("error")
    require(isinstance(error, dict), f"expected JSON-RPC error response, got {response}")
    require(error.get("code") == code, f"expected JSON-RPC error code {code}, got {response}")
    return error


def require_modern_result_envelope(result, label):
    require(result.get("resultType") == "complete", f"{label} missing resultType: {result}")
    server_info = result.get("_meta", {}).get("io.modelcontextprotocol/serverInfo")
    require(
        isinstance(server_info, dict) and server_info.get("name") == "lean-beam-mcp",
        f"{label} missing serverInfo: {result}",
    )


def write_save_warning_file(project_root, marker):
    (project_root / "SaveSmoke" / "B.lean").write_text(save_warning_text(marker), encoding="utf-8")


def diagnostic_log_notifications(client):
    rows = []
    for notification in notifications_by_method(client.notifications, "notifications/message"):
        params = notification_params(notification, "notifications/message", "diagnostic log notification")
        if params.get("logger") == "lean.diagnostic":
            rows.append(notification)
    return rows


def status_log_notifications(client, request_id=None):
    rows = []
    for notification in notifications_by_method(client.notifications, "notifications/message"):
        params = notification_params(notification, "notifications/message", "status log notification")
        if params.get("logger") != "beam.status":
            continue
        data = params.get("data")
        if request_id is not None and (
            not isinstance(data, dict) or data.get("requestId") != request_id
        ):
            continue
        rows.append(notification)
    return rows


def wait_for_status_log(client, request_id, timeout, label):
    deadline = time.monotonic() + timeout
    with client.state_changed:
        while True:
            notifications = status_log_notifications(client, request_id)
            if notifications:
                return notifications[0]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"{label}: timed out waiting for beam.status requestId={request_id!r}")
            client.state_changed.wait(timeout=min(remaining, 0.05))


def wait_for_progress_notification(client, token, timeout, label):
    deadline = time.monotonic() + timeout
    with client.state_changed:
        while True:
            notifications = client.progress_notifications(token)
            if notifications:
                return notifications[0]
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                fail(f"{label}: timed out waiting for progress token={token!r}")
            client.state_changed.wait(timeout=min(remaining, 0.05))


def expect_status_log(client, *, request_id, tool, state, timeout, label):
    notification = wait_for_status_log(client, request_id, timeout, label)
    params = notification_params(notification, "notifications/message", label)
    data = params.get("data", {})
    require(params.get("level") == "notice", f"{label} level: {notification}")
    require(data.get("tool") == tool, f"{label} tool: {notification}")
    require(data.get("state") == state, f"{label} state: {notification}")
    require(
        "progressToken" in data.get("progressHint", ""),
        f"{label} should make detailed progress discoverable: {notification}",
    )
    return notification


def expect_diagnostic_log(client, *, level, severity, path):
    for notification in diagnostic_log_notifications(client):
        params = notification_params(notification, "notifications/message", "diagnostic log notification")
        data = params.get("data", {})
        if (
            params.get("level") == level
            and isinstance(data, dict)
            and data.get("severity") == severity
            and data.get("path") == path
        ):
            require(isinstance(data.get("uri"), str), f"diagnostic log missing uri: {notification}")
            require(isinstance(data.get("snapshot"), str), f"diagnostic log missing snapshot: {notification}")
            require(isinstance(data.get("range"), dict), f"diagnostic log missing range: {notification}")
            require(isinstance(data.get("message"), str) and data["message"], f"diagnostic log missing message: {notification}")
            return notification
    fail(f"missing {level}/{severity} diagnostic log for {path}: {client.notifications}")


def expect_reply_diagnostic(sync, *, severity, path):
    diagnostics = sync.get("diagnostics", {}).get("items")
    require(isinstance(diagnostics, list) and diagnostics, f"sync reply missing diagnostics: {sync}")
    for diagnostic in diagnostics:
        if (
            isinstance(diagnostic, dict)
            and diagnostic.get("severity") == severity
            and diagnostic.get("path") == path
        ):
            require(isinstance(diagnostic.get("uri"), str), f"reply diagnostic missing uri: {diagnostic}")
            require(isinstance(diagnostic.get("snapshot"), str), f"reply diagnostic missing snapshot: {diagnostic}")
            require(isinstance(diagnostic.get("range"), dict), f"reply diagnostic missing range: {diagnostic}")
            require(isinstance(diagnostic.get("message"), str) and diagnostic["message"], f"reply diagnostic missing message: {diagnostic}")
            return diagnostic
    fail(f"missing {severity} reply diagnostic for {path}: {sync}")


def expect_error_message_contains(response, code, needle):
    error = expect_error_code(response, code)
    message = error.get("message")
    require(isinstance(message, str), f"error response missing message: {response}")
    require(needle in message, f"expected error message to contain {needle!r}, got {response}")
    return error


def expect_tool_error_code(response, code):
    result = expect_result(response)
    require(result.get("isError") is True, f"expected MCP tool error result, got {response}")
    structured = result.get("structuredContent")
    require(isinstance(structured, dict), f"tool error missing structuredContent: {response}")
    require(structured.get("code") == code, f"expected tool error code {code}, got {response}")
    return structured


def workspace_descriptor(root):
    return {"root": str(Path(root).resolve())}


def result_workspace_root(structured, label):
    workspace = structured.get("workspace")
    require(isinstance(workspace, dict), f"{label}: missing workspace descriptor: {structured}")
    root = workspace.get("root")
    require(isinstance(root, str), f"{label}: workspace descriptor has no root: {structured}")
    return Path(root)


def workspace_cache_key(root):
    return f"local:{Path(root).resolve()}"


def beam_cli_mcp_config(repo_root, root, timeout):
    beam_cli = repo_root / ".lake" / "build" / "bin" / "beam-cli"
    completed = subprocess.run(
        [str(beam_cli), "--root", str(root), "mcp-config"],
        cwd=str(repo_root),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        timeout=timeout,
        check=False,
    )
    require(
        completed.returncode == 0,
        f"beam-cli mcp-config failed for {root}:\n{completed.stdout}\n{completed.stderr}",
    )
    try:
        config = json.loads(completed.stdout)
    except json.JSONDecodeError as err:
        fail(f"beam-cli mcp-config returned invalid JSON for {root}: {err}: {completed.stdout!r}")
    require(isinstance(config, dict), f"beam-cli mcp-config returned no object for {root}: {config}")
    return config


def require_snapshot_mismatch_data(error, expected_snapshot, accepted_snapshot, label, *, expected_uri_suffix=None):
    data = error.get("data")
    require(isinstance(data, dict), f"{label}: tool error missing data: {error}")
    require(
        data.get("reason") == "snapshotMismatch",
        f"{label}: expected snapshotMismatch data, got {error}",
    )
    require(
        data.get("expectedSnapshot") == expected_snapshot,
        f"{label}: expected expectedSnapshot={expected_snapshot}, got {error}",
    )
    require(
        data.get("currentSnapshot") == accepted_snapshot,
        f"{label}: expected currentSnapshot={accepted_snapshot}, got {error}",
    )
    if expected_uri_suffix is not None:
        uri = data.get("uri")
        require(
            isinstance(uri, str) and uri.endswith(expected_uri_suffix),
            f"{label}: expected uri ending in {expected_uri_suffix!r}, got {error}",
        )


def require_success(label, structured):
    require(structured.get("success") is True, f"{label} should succeed: {structured}")


def require_failure(label, structured):
    require(structured.get("success") is False, f"{label} should fail semantically: {structured}")


def wait_for_file(path, timeout, label):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return
        time.sleep(0.02)
    fail(f"timed out waiting for {label} at {path}")


def require_message_contains(label, structured, needle):
    messages = structured.get("messages")
    require(isinstance(messages, list), f"{label}: missing messages array: {structured}")
    require(
        any(
            isinstance(message, dict)
            and isinstance(message.get("text"), str)
            and needle in message["text"]
            for message in messages
        ),
        f"{label}: expected message containing {needle!r}, got {structured}",
    )


def drop_workspace(client, root, *, expected_dropped=True):
    descriptor = workspace_descriptor(root)
    structured = client.call_tool(
        "lean_drop_workspace",
        {"workspace": descriptor},
    )
    require(
        structured.get("workspace") == descriptor,
        f"drop workspace returned wrong descriptor {descriptor!r}: {structured}",
    )
    require(
        structured.get("dropped") is expected_dropped,
        f"drop workspace returned wrong dropped={expected_dropped}: {structured}",
    )
    if expected_dropped:
        require(
            structured.get("invalidated_handles") is True,
            f"drop workspace should report handle invalidation: {structured}",
        )
    return structured


def require_progress_sequence(notifications, token, label):
    require(notifications, f"{label}: expected progress notifications for {token!r}")
    previous = None
    for notification in notifications:
        params = notification_params(notification, "notifications/progress", label)
        require(params.get("progressToken") == token, f"{label}: wrong progress token: {notification}")
        progress = params.get("progress")
        require(isinstance(progress, (int, float)), f"{label}: progress is not numeric: {notification}")
        if previous is not None:
            require(progress > previous, f"{label}: progress is not strictly increasing: {notifications}")
        previous = progress
        message = params.get("message")
        require(message is None or isinstance(message, str), f"{label}: progress message is not a string: {notification}")
    return [notification["params"]["progress"] for notification in notifications]


def require_progress_message_contains(notifications, label, *needles):
    messages = [message for message in progress_messages(notifications) if isinstance(message, str)]
    for needle in needles:
        require(
            any(needle in message for message in messages),
            f"{label}: expected a progress message containing {needle!r}, got {messages}",
        )


def require_document_progress_range_end(structured, label, range_end):
    require_document_progress_range(structured, label)
    progress = structured["document_progress"]
    require(
        progress.get("range_end_line") == range_end,
        f"{label}: expected document_progress range_end_line={range_end}, got {progress}",
    )


def expect_stale_handle(client, handle, label, *, root=None):
    arguments = {
        "path": "PositionEmptyLine.lean",
        "handle": handle,
        "text": "def mcpResetAfter : Nat := mcpResetBase + 1",
    }
    if root is not None:
        arguments["workspace"] = workspace_descriptor(root)
    response = client.request(
        "tools/call",
        {
            "name": "lean_run_with",
            "arguments": arguments,
        },
    )
    error = expect_tool_error_code(response, "contentModified")
    require(
        "stale backend session" in error.get("message", ""),
        f"{label}: handle should be stale after reset: {error}",
    )


def run_iteration(client, suffix):
    update = client.call_tool("lean_update", {"path": "PositionEmptyLine.lean"})
    require(
        result_workspace_root(update, "lean_update").resolve() == client.project_root.resolve(),
        f"update returned wrong workspace descriptor: {update}",
    )
    snapshot = update.get("snapshot")
    require(isinstance(snapshot, str), f"update did not return a document snapshot: {update}")
    changed = update.get("changed")
    require(isinstance(changed, bool), f"update did not return changed flag: {update}")

    command_update = client.call_tool("lean_update", {"path": "CommandA.lean"})
    command_snapshot = command_update.get("snapshot")
    require(isinstance(command_snapshot, str), f"CommandA update did not return a snapshot: {command_update}")
    command_path = client.project_root / "CommandA.lean"
    command_text = command_path.read_text(encoding="utf-8")
    command_path.write_text(f"{command_text}\n-- mcp stale-snapshot {suffix}\n", encoding="utf-8")
    command_changed = client.call_tool("lean_update", {"path": "CommandA.lean"})
    accepted_snapshot = command_changed.get("snapshot")
    require(isinstance(accepted_snapshot, str), f"CommandA changed update did not return a snapshot: {command_changed}")
    stale_response = client.request(
        "tools/call",
        {
            "name": "lean_run_at",
            "arguments": {
                "path": "CommandA.lean",
                "snapshot": command_snapshot,
                "line": 0,
                "character": 2,
                "text": "#check answerA",
            },
        },
    )
    stale_error = expect_tool_error_code(stale_response, "contentModified")
    require_snapshot_mismatch_data(
        stale_error,
        command_snapshot,
        accepted_snapshot,
        "stale MCP lean_run_at",
        expected_uri_suffix="/CommandA.lean",
    )

    probe = client.call_tool(
        "lean_run_at",
        {
            "path": "PositionEmptyLine.lean",
            "snapshot": snapshot,
            "line": 1,
            "character": 0,
            "text": f"def mcpProbe{suffix} : Nat :=\n  42",
        },
    )
    require_success("lean_run_at multiline probe", probe)
    require(probe.get("next_handle") is None, f"plain lean_run_at leaked a follow-up handle: {probe}")

    broken = client.call_tool(
        "lean_run_at",
        {
            "path": "PositionEmptyLine.lean",
            "snapshot": snapshot,
            "line": 1,
            "character": 0,
            "text": f"def mcpBroken{suffix} : Nat := \"bad\"",
        },
    )
    require_failure("semantic failure probe", broken)
    require(broken.get("next_handle") is None, f"semantic failure leaked a follow-up handle: {broken}")

    minted = client.call_tool(
        "lean_run_at_handle",
        {
            "path": "PositionEmptyLine.lean",
            "snapshot": snapshot,
            "line": 1,
            "character": 0,
            "text": f"def mcpBase{suffix} : Nat := 1",
        },
    )
    require_success("handle mint probe", minted)
    base_handle = minted.get("next_handle")
    require(isinstance(base_handle, dict), f"handle mint did not return next_handle: {minted}")

    continued = client.call_tool(
        "lean_run_with",
        {
            "path": "PositionEmptyLine.lean",
            "handle": base_handle,
            "text": f"def mcpNext{suffix} : Nat := mcpBase{suffix} + 1",
        },
    )
    require_success("handle continuation probe", continued)
    next_handle = continued.get("next_handle")
    require(isinstance(next_handle, dict), f"handle continuation did not return next_handle: {continued}")

    linear = client.call_tool(
        "lean_run_with_linear",
        {
            "path": "PositionEmptyLine.lean",
            "handle": next_handle,
            "text": f"def mcpLinear{suffix} : Nat := mcpNext{suffix} + 1",
        },
    )
    require_success("linear handle continuation probe", linear)
    linear_handle = linear.get("next_handle")
    require(isinstance(linear_handle, dict), f"linear continuation did not return next_handle: {linear}")

    client.call_tool("lean_release", {"path": "PositionEmptyLine.lean", "handle": linear_handle})
    client.call_tool("lean_release", {"path": "PositionEmptyLine.lean", "handle": base_handle})

    goal_update = client.call_tool("lean_update", {"path": "GoalSmoke.lean"})
    goal_snapshot = goal_update.get("snapshot")
    require(isinstance(goal_snapshot, str), f"GoalSmoke update did not return a snapshot: {goal_update}")

    ascription = client.call_tool(
        "lean_run_at_handle",
        {
            "path": "GoalSmoke.lean",
            "snapshot": goal_snapshot,
            "line": 1,
            "character": 2,
            "text": "have htest := (Nat.succ : Nat)",
        },
    )
    require_failure("term-ascription handle probe", ascription)
    require_message_contains("term-ascription handle probe", ascription, "Type mismatch")
    require(
        ascription.get("next_handle") is None,
        f"term-ascription failure leaked a follow-up handle: {ascription}",
    )

    goals_prev = client.call_tool(
        "lean_goals",
        {"path": "GoalSmoke.lean", "snapshot": goal_snapshot, "line": 1, "character": 2, "mode": "before"},
    )
    prev_goals = goals_prev.get("goals")
    require(isinstance(prev_goals, list) and prev_goals, f"goals before returned no goals: {goals_prev}")
    require(prev_goals[0].get("target") == "True", f"goals before returned unexpected goal: {goals_prev}")

    goals_after = client.call_tool(
        "lean_goals",
        {"path": "GoalSmoke.lean", "snapshot": goal_snapshot, "line": 1, "character": 2, "mode": "after"},
    )
    require(goals_after.get("goals") == [], f"goals after should return no goals: {goals_after}")

    client.call_tool("lean_close", {"path": "PositionEmptyLine.lean"})
    refreshed = client.call_tool("lean_refresh", {"path": "PositionEmptyLine.lean"})
    require(isinstance(refreshed.get("snapshot"), str), f"lean_refresh did not return a snapshot: {refreshed}")
    require("diagnostics" in refreshed, f"lean_refresh did not return diagnostic counts: {refreshed}")
    require("readiness" in refreshed, f"lean_refresh did not return readiness: {refreshed}")
    client.call_tool("lean_close", {"path": "PositionEmptyLine.lean"})
    client.call_tool("lean_close", {"path": "GoalSmoke.lean"})


def run_modern_protocol_smoke(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-modern-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, label="modern-protocol")
        try:
            discovery = expect_result(client.modern_request("server/discover"))
            require_modern_result_envelope(discovery, "server/discover")
            require(
                discovery.get("supportedVersions") == [MCP_MODERN_PROTOCOL_VERSION],
                f"unexpected supported protocol versions: {discovery}",
            )
            require(
                discovery.get("ttlMs") == MCP_PUBLIC_CACHE_TTL_MS,
                f"discovery missing ttlMs: {discovery}",
            )
            require(discovery.get("cacheScope") == "public", f"discovery missing cacheScope: {discovery}")
            capabilities = discovery.get("capabilities", {})
            require(
                isinstance(capabilities.get("logging"), dict),
                f"discovery did not advertise request-scoped logging: {discovery}",
            )
            require(
                capabilities.get("tools", {}).get("listChanged") is False,
                f"discovery did not advertise its static tool list: {discovery}",
            )
            listed = expect_result(client.modern_request("tools/list"))
            require_modern_result_envelope(listed, "modern tools/list")
            require(
                listed.get("ttlMs") == MCP_PUBLIC_CACHE_TTL_MS,
                f"modern tools/list missing ttlMs: {listed}",
            )
            require(listed.get("cacheScope") == "public", f"modern tools/list missing cacheScope: {listed}")
            require(isinstance(listed.get("tools"), list), f"modern tools/list missing tools: {listed}")
            modern_names = {tool.get("name") for tool in listed["tools"]}
            require(
                "beam_feedback_report" in modern_names,
                f"modern tools/list missing beam_feedback_report: {listed}",
            )
            require(
                "beam_feedback" not in modern_names,
                f"modern tools/list exposed obsolete beam_feedback: {listed}",
            )
            reuse_id = "modern-request-id-reuse"
            expect_result(client.modern_request("tools/list", request_id=reuse_id))
            expect_result(client.modern_request("tools/list", request_id=reuse_id))
            expect_error_message_contains(
                client.request("tools/list"),
                -32602,
                "protocolVersion",
            )
            expect_error_message_contains(
                client.request("initialize", initialize_params()),
                -32600,
                "modern protocol family",
            )

            version_result = expect_result(
                client.modern_request(
                    "tools/call",
                    {"name": "beam_version", "arguments": {}},
                )
            )
            require_modern_result_envelope(version_result, "modern tools/call")
            require(version_result.get("isError") is False, f"modern beam_version failed: {version_result}")

            expect_error_message_contains(
                client.modern_request(
                    "tools/call",
                    {
                        "name": "beam_version",
                        "arguments": {},
                        "requestState": {},
                    },
                ),
                -32602,
                "input_required",
            )
            expect_error_message_contains(
                client.modern_request(
                    "tools/call",
                    {
                        "name": "beam_version",
                        "arguments": {},
                        "inputResponses": [],
                    },
                ),
                -32602,
                "input_required",
            )

            expect_error_code(client.request("server/discover", {}), -32602)
            expect_error_code(
                client.request(
                    "tools/list",
                    {
                        "_meta": {
                            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
                        }
                    },
                ),
                -32602,
            )
            unsupported = expect_error_code(
                client.request(
                    "tools/list",
                    {
                        "_meta": {
                            "io.modelcontextprotocol/protocolVersion": "1900-01-01",
                            "io.modelcontextprotocol/clientCapabilities": {},
                        }
                    },
                ),
                -32022,
            )
            require(
                unsupported.get("data", {}).get("supported") == [MCP_MODERN_PROTOCOL_VERSION],
                f"unsupported-version error missing supported versions: {unsupported}",
            )
            expect_error_code(
                client.modern_request("tools/list", log_level="verbose"),
                -32602,
            )
            expect_error_code(
                client.request(
                    "tools/list",
                    {
                        "_meta": {
                            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
                            "io.modelcontextprotocol/clientCapabilities": {},
                            "io.modelcontextprotocol/clientInfo": {"name": "incomplete-client"},
                        }
                    },
                ),
                -32602,
            )
            expect_error_code(
                client.request(
                    "tools/list",
                    {
                        "_meta": {
                            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
                            "io.modelcontextprotocol/clientCapabilities": [],
                        }
                    },
                ),
                -32602,
            )

            semantic_error_response = client.modern_request(
                "tools/call",
                {"name": "lean_sync", "arguments": {}},
            )
            expect_tool_error_code(semantic_error_response, "invalidInput")
            require_modern_result_envelope(
                expect_result(semantic_error_response),
                "modern known-tool input error",
            )

            progress_token = "modern-sync-progress"
            progress_result = expect_result(
                client.modern_request(
                    "tools/call",
                    {
                        "name": "lean_sync",
                        "arguments": {"path": "PositionEmptyLine.lean"},
                        "_meta": {"progressToken": progress_token},
                    },
                )
            )
            require_modern_result_envelope(progress_result, "modern lean_sync")
            require(progress_result.get("isError") is not True, f"modern lean_sync failed: {progress_result}")
            progress_notifications = client.progress_notifications(progress_token)
            require_progress_sequence(progress_notifications, progress_token, "modern lean_sync progress")
            require_progress_message_contains(
                progress_notifications,
                "modern lean_sync progress",
                "lean_sync on PositionEmptyLine.lean: preparing the Lean workspace",
                "lean_sync: processing",
                "done=true",
            )
            expect_error_code(
                client.modern_request("logging/setLevel", {"level": "error"}),
                -32601,
            )
            expect_error_code(client.modern_request("ping"), -32601)
            require(not client.server_requests, f"modern server emitted JSON-RPC requests: {client.server_requests}")
            client.close_input()
            returncode = client.wait_for_exit_after_eof(timeout)
            require(returncode == 0, f"modern server exited with code {returncode} after EOF")
        finally:
            client.close()


def run_cycle(
    repo_root,
    fixture_root,
    cycle,
    iterations,
    timeout,
):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label=f"cycle-{cycle}",
        )
        try:
            pre_init = client.request("tools/list")
            expect_error_code(pre_init, -32600)
            client.initialize()
            expect_error_message_contains(
                client.modern_request("tools/list"),
                -32600,
                "legacy protocol family",
            )

            raw_tool = client.request(
                "tools/call",
                {"name": "$/lean/runAt", "arguments": {}},
            )
            expect_error_code(raw_tool, -32602)

            bad_known_tool_input = client.request(
                "tools/call",
                {
                    "name": "lean_run_at",
                    "arguments": {
                        "path": "PositionEmptyLine.lean",
                        "line": 1,
                        "character": 0,
                    },
                },
            )
            expect_tool_error_code(bad_known_tool_input, "invalidInput")

            tools = expect_result(client.request("tools/list")).get("tools")
            names = {tool.get("name") for tool in tools}
            require("beam_version" in names, f"tools/list missing beam_version: {tools}")
            require("beam_stats" in names, f"tools/list missing beam_stats: {tools}")
            require("beam_feedback_report" in names, f"tools/list missing beam_feedback_report: {tools}")
            require("beam_feedback" not in names, f"tools/list exposed obsolete beam_feedback: {tools}")
            require("lean_drop_workspace" in names, f"tools/list missing lean_drop_workspace: {tools}")
            require("lean_update" in names, f"tools/list missing lean_update: {tools}")
            require("lean_run_at" in names, f"tools/list missing lean_run_at: {tools}")
            require("lean_signature_help" in names, f"tools/list missing lean_signature_help: {tools}")
            require("lean_definition" in names, f"tools/list missing lean_definition: {tools}")
            require("lean_references" in names, f"tools/list missing lean_references: {tools}")
            require("lean_document_symbols" in names, f"tools/list missing lean_document_symbols: {tools}")
            require("lean_workspace_symbols" in names, f"tools/list missing lean_workspace_symbols: {tools}")
            require("lean_goals" in names, f"tools/list missing lean_goals: {tools}")
            require("lean_code_action_resolve" in names, f"tools/list missing lean_code_action_resolve: {tools}")
            require("lean_refresh" in names, f"tools/list missing lean_refresh: {tools}")
            require("lean_close_save" in names, f"tools/list missing lean_close_save: {tools}")
            require("$/lean/runAt" not in names, f"tools/list exposed raw LSP method: {tools}")
            require("lean_request_at" not in names, f"tools/list exposed raw request escape hatch: {tools}")

            version = client.call_tool("beam_version")
            require(version.get("name") == "lean-beam-mcp", f"beam_version returned wrong name: {version}")
            require(version.get("version") == "0.2.0-beta", f"beam_version returned wrong version: {version}")
            require(version.get("mcp_protocol") == MCP_MODERN_PROTOCOL_VERSION, f"beam_version returned wrong protocol: {version}")
            require(isinstance(version.get("server_binary"), str) and version["server_binary"], f"beam_version missing server_binary: {version}")
            require(version.get("runtime_active") is False, f"beam_version should not start runtime: {version}")

            stats_progress_token = "beam-stats-quiet-progress"
            stats_result = expect_result(
                client.request(
                    "tools/call",
                    {
                        "name": "beam_stats",
                        "arguments": {},
                        "_meta": {"progressToken": stats_progress_token},
                    },
                )
            )
            require(stats_result.get("isError") is not True, f"beam_stats failed: {stats_result}")
            require(
                not client.progress_notifications(stats_progress_token),
                "beam_stats emitted progress that added no liveness information",
            )

            for iteration in range(iterations):
                run_iteration(client, f"Cycle{cycle}Iter{iteration}")
        finally:
            client.close()


def run_diagnostic_logging(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-diagnostic-logs-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, label="diagnostic-logging")
        try:
            client.initialize()
            write_save_warning_file(project_root, "-- mcp stdio diagnostic log")
            sync = client.call_tool(
                "lean_sync",
                {
                    "path": "SaveSmoke/B.lean",
                    "diagnostic_scope": "all",
                    "diagnostics_in_result": True,
                },
            )
            require("saveReady" not in sync, f"warning-only sync should omit top-level saveReady: {sync}")
            require("warningCount" not in sync, f"warning-only sync should omit top-level warningCount: {sync}")
            readiness = sync.get("readiness", {})
            counts = sync.get("diagnostics", {}).get("counts", {})
            require(readiness.get("save_ready") is True, f"warning-only sync should be save-ready: {sync}")
            require(
                counts.get("warning", 0) >= 1,
                f"warning-only sync should report diagnostic warning counts: {sync}",
            )
            expect_reply_diagnostic(sync, severity="warning", path="SaveSmoke/B.lean")
            expect_diagnostic_log(client, level="warning", severity="warning", path="SaveSmoke/B.lean")

            expect_result(client.request("logging/setLevel", {"level": "error"}))
            client.notifications.clear()
            write_save_warning_file(project_root, "-- mcp stdio warning suppressed")
            sync = client.call_tool(
                "lean_sync", {"path": "SaveSmoke/B.lean", "diagnostic_scope": "all"}
            )
            require("saveReady" not in sync, f"suppressed warning sync should omit top-level saveReady: {sync}")
            readiness = sync.get("readiness", {})
            require(readiness.get("save_ready") is True, f"suppressed warning sync should be save-ready: {sync}")
            require("warningCount" not in sync, f"suppressed warning sync should omit top-level warningCount: {sync}")
            require(
                "items" not in sync.get("diagnostics", {}),
                f"sync reply should omit diagnostic items without diagnostics_in_result: {sync}",
            )
            require(
                diagnostic_log_notifications(client) == [],
                f"warning-only sync should not log diagnostics at error level: {client.notifications}",
            )

            client.notifications.clear()
            (project_root / "SaveSmoke" / "B.lean").write_text('def bVal : Nat := "broken"\n', encoding="utf-8")
            sync = client.call_tool(
                "lean_sync", {"path": "SaveSmoke/B.lean", "diagnostics_in_result": True}
            )
            require("saveReady" not in sync, f"broken sync should omit top-level saveReady: {sync}")
            require("errorCount" not in sync, f"broken sync should omit top-level errorCount: {sync}")
            require("warningCount" not in sync, f"broken sync should omit top-level warningCount: {sync}")
            current = sync.get("diagnostics", {}).get("counts", {})
            readiness = sync.get("readiness", {})
            require(current.get("error", 0) >= 1, f"broken sync should count errors: {sync}")
            require(readiness.get("save_ready") is False, f"broken sync should not be save-ready: {sync}")
            require(
                readiness.get("blocking_error_count", 0) >= 1,
                f"broken sync should report save-blocking errors: {sync}",
            )
            expect_reply_diagnostic(sync, severity="error", path="SaveSmoke/B.lean")
            require(
                all(
                    diagnostic.get("severity") == "error"
                    for diagnostic in sync.get("diagnostics", {}).get("items", [])
                ),
                f"default replayed diagnostics should be error-only: {sync}",
            )
            expect_diagnostic_log(client, level="error", severity="error", path="SaveSmoke/B.lean")
        finally:
            client.close()

        modern_client = McpClient(repo_root, project_root, timeout, label="modern-diagnostic-logging")
        try:
            write_save_warning_file(project_root, "-- modern request without log opt-in")
            modern_silent = expect_result(
                modern_client.modern_request(
                    "tools/call",
                    {
                        "name": "lean_sync",
                        "arguments": {"path": "SaveSmoke/B.lean", "diagnostic_scope": "all"},
                    },
                )
            )
            require(
                modern_silent.get("resultType") == "complete",
                f"modern lean_sync missing resultType: {modern_silent}",
            )
            require(
                diagnostic_log_notifications(modern_client) == [],
                f"modern request emitted logs without logLevel: {modern_client.notifications}",
            )

            modern_client.notifications.clear()
            write_save_warning_file(project_root, "-- modern request warning opt-in")
            modern_logged = expect_result(
                modern_client.modern_request(
                    "tools/call",
                    {
                        "name": "lean_sync",
                        "arguments": {"path": "SaveSmoke/B.lean", "diagnostic_scope": "all"},
                    },
                    log_level="warning",
                )
            )
            require(
                modern_logged.get("resultType") == "complete",
                f"modern logged lean_sync missing resultType: {modern_logged}",
            )
            expect_diagnostic_log(
                modern_client,
                level="warning",
                severity="warning",
                path="SaveSmoke/B.lean",
            )
        finally:
            modern_client.close()


FOCUSED_SYNC_SCENARIOS = {
    "progress-sync": {"progress": True},
    "no-progress-sync": {"progress": False},
}


def run_focused_sync_once(repo_root, fixture_root, timeout, label, scenario, server_trace=False):
    config = FOCUSED_SYNC_SCENARIOS[scenario]
    with tempfile.TemporaryDirectory(prefix=f"lean-beam-mcp-{scenario}-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label=label,
            server_trace=server_trace,
        )
        try:
            init_started = time.monotonic()
            client.initialize()
            init_elapsed = time.monotonic() - init_started

            token = f"{scenario}-token"
            call_params = {
                "name": "lean_sync",
                "arguments": {"path": "PositionEmptyLine.lean"},
            }
            if config["progress"]:
                call_params["_meta"] = {"progressToken": token}
            before_notifications = len(client.notifications)
            sync_started = time.monotonic()
            response = client.request("tools/call", call_params)
            sync_elapsed = time.monotonic() - sync_started
            result = expect_result(response)
            require(result.get("isError") is not True, f"{label}: lean_sync failed: {result}")
            if config["progress"]:
                notifications = client.progress_notifications(token)
                require_progress_sequence(notifications, token, f"{label} progress")
                require_progress_message_contains(
                    notifications,
                    f"{label} progress",
                    "lean_sync on PositionEmptyLine.lean: preparing the Lean workspace",
                    "lean_sync: processing",
                    "range",
                    "done=true",
                )
            else:
                notifications = notifications_by_method(
                    client.notifications[before_notifications:],
                    "notifications/progress",
                )
                require(
                    not notifications,
                    f"{label}: sync without progress token emitted progress notifications: {notifications}",
                )
            return {
                "init_elapsed": init_elapsed,
                "sync_elapsed": sync_elapsed,
                "notification_count": len(notifications),
            }
        finally:
            client.close()


def run_progress_notification_smoke(repo_root, fixture_root, timeout, server_trace=False, label_prefix="progress"):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-progress-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label=f"{label_prefix}-explicit-root",
            server_trace=server_trace,
        )
        try:
            client.initialize()

            invalid_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "PositionEmptyLine.lean"},
                    "_meta": {"progressToken": True},
                },
            )
            expect_error_code(invalid_token, -32602)
            decimal_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "PositionEmptyLine.lean"},
                    "_meta": {"progressToken": 1.5},
                },
            )
            decimal_result = expect_result(decimal_token)
            require(
                decimal_result.get("isError") is not True,
                f"lean_sync with decimal progress token failed: {decimal_result}",
            )
            decimal_notifications = client.progress_notifications(1.5)
            require_progress_sequence(
                decimal_notifications,
                1.5,
                "lean_sync decimal progress token",
            )

            before_no_token = len(client.notifications)
            no_token = client.request(
                "tools/call",
                {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
            )
            result = expect_result(no_token)
            require(result.get("isError") is not True, f"lean_sync without progress token failed: {result}")
            no_token_notifications = client.notifications[before_no_token:]
            require(
                not notifications_by_method(no_token_notifications, "notifications/progress"),
                f"lean_sync without progress token emitted progress notifications: {no_token_notifications}",
            )

            token = "sync-progress-token"
            before_token = len(client.notifications)
            with_token = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {"path": "CommandA.lean"},
                    "_meta": {"progressToken": token},
                },
            )
            result = expect_result(with_token)
            require(result.get("isError") is not True, f"lean_sync with progress token failed: {result}")
            structured = result.get("structuredContent")
            require(isinstance(structured, dict), f"lean_sync with progress token missing structuredContent: {result}")
            require(
                "client_request_id" not in structured,
                f"lean_sync leaked its internal broker request id: {structured}",
            )
            require_document_progress_range_end(structured, "lean_sync progress", 1)
            token_notifications = [
                notification
                for notification in notifications_by_method(
                    client.notifications[before_token:],
                    "notifications/progress",
                )
            ]
            require_progress_sequence(token_notifications, token, "lean_sync progress")
            require_progress_message_contains(
                token_notifications,
                "lean_sync progress",
                "lean_sync on CommandA.lean: preparing the Lean workspace",
                "lean_sync: processing",
                "rangeEndLine=1",
                "done=true",
            )
            require(
                sum("done=true" in (message or "") for message in progress_messages(token_notifications)) == 1,
                f"lean_sync progress should emit one terminal file-progress update: {token_notifications}",
            )

            progress_count_after_response = len(client.progress_notifications(token))
            ping = client.request("ping")
            expect_result(ping)
            require(
                len(client.progress_notifications(token)) == progress_count_after_response,
                f"progress notifications continued after final response: {client.progress_notifications(token)}",
            )
        finally:
            client.close()

    run_focused_sync_once(
        repo_root,
        fixture_root,
        timeout,
        f"{label_prefix}-descriptor",
        "progress-sync",
        server_trace,
    )


def run_focused_sync_repro(repo_root, fixture_root, timeout, runs, slow_threshold, scenario, server_trace):
    require(runs > 0, "--repro-runs must be positive")
    init_durations = []
    sync_durations = []
    started = time.monotonic()
    for index in range(runs):
        label = f"{scenario}-repro-{index + 1}-of-{runs}"
        result = run_focused_sync_once(repo_root, fixture_root, timeout, label, scenario, server_trace)
        init_durations.append(result["init_elapsed"])
        sync_durations.append(result["sync_elapsed"])
        sync_elapsed = result["sync_elapsed"]
        if slow_threshold is None or sync_elapsed >= slow_threshold:
            print(
                f"{label}: init={result['init_elapsed']:.3f}s "
                f"sync={sync_elapsed:.3f}s "
                f"progress_notifications={result['notification_count']}",
                file=sys.stderr,
            )
    elapsed = time.monotonic() - started
    print(
        f"{scenario} repro summary: "
        f"elapsed={elapsed:.3f}s "
        f"init[{format_duration_stats(init_durations)}] "
        f"sync[{format_duration_stats(sync_durations)}]",
        file=sys.stderr,
    )


PARALLEL_PROGRESS_SMOKE_SCENARIO = "progress-smoke-parallel"
CONCURRENT_DISPATCH_SCENARIO = "concurrent-dispatch"
MULTI_TOOLCHAIN_SCENARIO = "multi-toolchain-workspaces"


def run_concurrent_dispatch(repo_root, fixture_root, timeout, server_trace=False):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-concurrent-dispatch-") as tmp:
        tmp_root = Path(tmp)
        project_root = tmp_root / "project"
        other_project_root = tmp_root / "other-project"
        started_path = tmp_root / "gate-started"
        release_path = tmp_root / "gate-release"
        copy_project_fixture(fixture_root, project_root)
        copy_project_fixture(fixture_root, other_project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="concurrent-dispatch",
            server_trace=server_trace,
            extra_env={
                "BEAM_MCP_GATE_STARTED": started_path,
                "BEAM_MCP_GATE_RELEASE": release_path,
                "LEAN_BEAM_MCP_TEST_STATUS_DELAY_MS": "100",
            },
        )
        slow_id = "77"
        overlap_timeout = min(timeout, 10.0)
        try:
            client.initialize()
            update = client.call_tool("lean_update", {"path": "McpConcurrency.lean"})
            snapshot = update.get("snapshot")
            require(isinstance(snapshot, str), f"concurrency update missing snapshot: {update}")
            other_update = client.call_tool(
                "lean_update",
                {
                    "workspace": workspace_descriptor(other_project_root),
                    "path": "McpConcurrency.lean",
                },
            )
            other_snapshot = other_update.get("snapshot")
            require(
                isinstance(other_snapshot, str),
                f"cross-workspace concurrency update missing snapshot: {other_update}",
            )
            source_lines = (project_root / "McpConcurrency.lean").read_text(encoding="utf-8").splitlines()
            line = source_lines.index("  trivial")
            slow_params = {
                "name": "lean_run_at",
                "arguments": {
                    "path": "McpConcurrency.lean",
                    "snapshot": snapshot,
                    "line": line,
                    "character": 2,
                    "text": "mcp_concurrency_gate",
                },
            }
            fast_params = {
                "name": "lean_run_at",
                "arguments": {
                    "path": "McpConcurrency.lean",
                    "snapshot": snapshot,
                    "line": line,
                    "character": 2,
                    "text": "exact trivial",
                },
            }
            cross_workspace_fast_params = {
                "name": "lean_run_at",
                "arguments": {
                    "workspace": workspace_descriptor(other_project_root),
                    "path": "McpConcurrency.lean",
                    "snapshot": other_snapshot,
                    "line": line,
                    "character": 2,
                    "text": "exact trivial",
                },
            }
            client.send_request("tools/call", slow_params, request_id=slow_id)
            wait_for_file(started_path, timeout, "slow runAt gate sentinel")
            expect_status_log(
                client,
                request_id=slow_id,
                tool="lean_run_at",
                state="running",
                timeout=min(timeout, 5.0),
                label="slow no-token runAt status",
            )
            status_count = len(status_log_notifications(client, slow_id))
            cross_workspace_fast_id = client.send_request(
                "tools/call",
                cross_workspace_fast_params,
                request_id="cross-workspace-fast",
            )
            cross_workspace_fast_response = client.read_response(
                cross_workspace_fast_id,
                timeout=overlap_timeout,
            )
            cross_workspace_fast_result = expect_result(cross_workspace_fast_response)
            require(
                cross_workspace_fast_result.get("isError") is not True,
                f"cross-workspace fast runAt returned a tool error: {cross_workspace_fast_result}",
            )
            cross_workspace_fast_structured = cross_workspace_fast_result.get("structuredContent")
            require(
                isinstance(cross_workspace_fast_structured, dict),
                f"cross-workspace fast runAt missing structured content: {cross_workspace_fast_result}",
            )
            require_success("cross-workspace fast runAt", cross_workspace_fast_structured)
            require(
                not client.response_ready(slow_id),
                "workspace A gated runAt completed while workspace B overlap was checked",
            )
            fast_id = client.send_request("tools/call", fast_params, request_id=77)
            fast_response = client.read_response(fast_id, timeout=overlap_timeout)
            fast_result = expect_result(fast_response)
            require(fast_result.get("isError") is not True, f"fast runAt returned a tool error: {fast_result}")
            fast_structured = fast_result.get("structuredContent")
            require(isinstance(fast_structured, dict), f"fast runAt missing structured content: {fast_result}")
            require_success("fast concurrent runAt", fast_structured)
            require(
                not client.response_ready(slow_id),
                "slow gated runAt completed before its release sentinel",
            )
            release_path.write_text("release\n", encoding="utf-8")
            slow_response = client.read_response(slow_id)
            slow_result = expect_result(slow_response)
            require(slow_result.get("isError") is not True, f"slow runAt returned a tool error: {slow_result}")
            slow_structured = slow_result.get("structuredContent")
            require(isinstance(slow_structured, dict), f"slow runAt missing structured content: {slow_result}")
            require_success("slow concurrent runAt", slow_structured)
            expect_result(client.request("ping", request_id=slow_id))
            async_reuse_id = "async-tool-request-id-reuse"
            for reuse_iteration in range(64):
                version_result = expect_result(
                    client.request(
                        "tools/call",
                        {"name": "beam_version", "arguments": {}},
                        request_id=async_reuse_id,
                    )
                )
                require(
                    version_result.get("isError") is not True,
                    f"async request-ID reuse tool call {reuse_iteration} failed: {version_result}",
                )
                expect_result(client.request("ping", request_id=async_reuse_id))
            require(
                len(status_log_notifications(client, slow_id)) == status_count,
                f"slow no-token runAt emitted duplicate or post-response statuses: {client.notifications}",
            )

            started_path.unlink()
            release_path.unlink()
            expect_result(client.request("logging/setLevel", {"level": "warning"}))
            suppressed_status_count = len(status_log_notifications(client))
            cancel_id = "cancelled-run-at"
            client.send_request("tools/call", slow_params, request_id=cancel_id)
            wait_for_file(started_path, timeout, "cancelled runAt gate sentinel")
            time.sleep(0.5)
            require(
                len(status_log_notifications(client)) == suppressed_status_count,
                f"warning log level should suppress notice status: {client.notifications}",
            )
            client.send_message(
                {
                    "jsonrpc": "2.0",
                    "id": cancel_id,
                    "method": "tools/list",
                }
            )
            client.send_message(
                {
                    "jsonrpc": "2.0",
                    "id": cancel_id,
                    "method": "tools/list",
                    "unexpected": True,
                }
            )
            expect_result(client.request("ping", request_id="after-duplicate-active-id"))
            require(
                not client.response_ready(cancel_id),
                "duplicate active request ID produced a second ambiguous terminal response",
            )
            client.notify(
                "notifications/cancelled",
                {
                    "requestId": cancel_id,
                    "reason": "concurrency regression no longer needs the result",
                },
            )
            cancel_deadline = time.monotonic() + timeout
            cancelled_count = 0
            while time.monotonic() < cancel_deadline:
                stats = client.call_tool("beam_stats")
                lean_stats = (
                    stats.get("workspaces", {})
                    .get(workspace_cache_key(project_root), {})
                    .get("byBackend", {})
                    .get("lean", {})
                )
                cancelled_count = lean_stats.get("cancelledCount", 0)
                if isinstance(cancelled_count, int) and cancelled_count >= 1:
                    break
                time.sleep(0.02)
            require(
                isinstance(cancelled_count, int) and cancelled_count >= 1,
                f"broker did not record cancelled MCP runAt: {stats}",
            )
            require(
                not client.response_ready(cancel_id),
                "legacy cancelled request produced a terminal response",
            )
            client.forget_request(cancel_id)
            expect_result(client.request("ping", request_id="after-cancellation"))

            burst = []
            for index in range(6):
                token = f"concurrent-progress-{index}"
                params = {
                    "name": "lean_run_at",
                    "arguments": dict(fast_params["arguments"]),
                    "_meta": {"progressToken": token},
                }
                request_id = f"burst-{index}"
                client.send_request("tools/call", params, request_id=request_id)
                burst.append((request_id, token))
            for request_id, token in reversed(burst):
                response = client.read_response(request_id)
                result = expect_result(response)
                require(result.get("isError") is not True, f"burst runAt failed: {result}")
                structured = result.get("structuredContent")
                require(isinstance(structured, dict), f"burst runAt missing structured content: {result}")
                require_success(f"burst runAt {request_id}", structured)
                require_progress_sequence(
                    client.progress_notifications(token),
                    token,
                    f"burst progress {request_id}",
                )
            expect_result(client.request("ping", request_id="after-burst"))

            expect_result(client.request("logging/setLevel", {"level": "notice"}))
            started_path.unlink()
            release_path.unlink(missing_ok=True)
            drop_fence_id = "drop-fence-run-at"
            client.send_request("tools/call", slow_params, request_id=drop_fence_id)
            wait_for_file(started_path, timeout, "workspace-drop fence runAt gate sentinel")
            drop_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_drop_workspace",
                    "arguments": {"workspace": workspace_descriptor(project_root)},
                },
                request_id="drop-fence-control",
            )
            queued_drop_token = "drop-fence-tokened-progress"
            queued_drop_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_drop_workspace",
                    "arguments": {"workspace": workspace_descriptor(project_root)},
                    "_meta": {"progressToken": queued_drop_token},
                },
                request_id="drop-fence-tokened-control",
            )
            post_drop_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_update",
                    "arguments": {"path": "McpConcurrency.lean"},
                },
                request_id="post-drop-update",
            )
            expect_result(client.request("ping", request_id="after-drop-fence-admission"))
            require(
                not client.response_ready(drop_id),
                "workspace drop completed before previously admitted work drained",
            )
            require(
                not client.response_ready(queued_drop_id),
                "second workspace drop completed before the preceding control fence",
            )
            require(
                not client.response_ready(post_drop_id),
                "work admitted after workspace drop bypassed the global control fence",
            )
            expect_status_log(
                client,
                request_id=drop_id,
                tool="lean_drop_workspace",
                state="running",
                timeout=min(timeout, 5.0),
                label="delayed workspace drop status",
            )
            queued_progress = wait_for_progress_notification(
                client,
                queued_drop_token,
                min(timeout, 5.0),
                "queued workspace drop progress",
            )
            require_progress_message_contains(
                [queued_progress],
                "queued workspace drop progress",
                "lean_drop_workspace: preparing workspace eviction",
            )
            release_path.write_text("release\n", encoding="utf-8")
            slow_response = client.read_response(drop_fence_id)
            slow_result = expect_result(slow_response)
            require(
                slow_result.get("isError") is not True,
                f"work admitted before workspace drop failed: {slow_result}",
            )
            drop_response = expect_result(client.read_response(drop_id))
            require(drop_response.get("isError") is not True, f"workspace drop fence failed: {drop_response}")
            dropped = drop_response.get("structuredContent")
            require(
                isinstance(dropped, dict) and dropped.get("dropped") is True,
                f"workspace drop fence did not evict the runtime: {drop_response}",
            )
            queued_drop_response = expect_result(client.read_response(queued_drop_id))
            require(
                queued_drop_response.get("isError") is not True,
                f"second workspace drop fence failed: {queued_drop_response}",
            )
            queued_notifications = client.progress_notifications(queued_drop_token)
            require_progress_sequence(
                queued_notifications,
                queued_drop_token,
                "queued workspace drop progress",
            )
            require(
                len(queued_notifications) == 1,
                f"workspace drop emitted redundant terminal progress: {queued_notifications}",
            )
            post_drop_result = expect_result(client.read_response(post_drop_id))
            require(
                post_drop_result.get("isError") is not True,
                f"work admitted after workspace drop failed: {post_drop_result}",
            )
            post_drop_update = post_drop_result.get("structuredContent")
            require(
                isinstance(post_drop_update, dict),
                f"post-drop concurrency update missing structured content: {post_drop_result}",
            )
            snapshot = post_drop_update.get("snapshot")
            require(
                isinstance(snapshot, str),
                f"post-drop concurrency update missing snapshot: {post_drop_update}",
            )
            slow_params["arguments"]["snapshot"] = snapshot

            started_path.unlink()
            release_path.unlink()
            eof_request_id = "eof-inflight"
            client.send_request("tools/call", slow_params, request_id=eof_request_id)
            wait_for_file(started_path, timeout, "EOF runAt gate sentinel")
            eof_drop_token = "eof-workspace-drop-progress"
            eof_drop_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_drop_workspace",
                    "arguments": {"workspace": workspace_descriptor(project_root)},
                    "_meta": {"progressToken": eof_drop_token},
                },
                request_id="eof-workspace-drop",
            )
            wait_for_progress_notification(
                client,
                eof_drop_token,
                min(timeout, 5.0),
                "EOF workspace drop admission",
            )
            client.close_input()
            eof_drop_result = expect_result(client.read_response(eof_drop_id))
            require(
                eof_drop_result.get("isError") is not True,
                f"workspace drop admitted before EOF failed: {eof_drop_result}",
            )
            eof_dropped = eof_drop_result.get("structuredContent")
            require(
                isinstance(eof_dropped, dict) and eof_dropped.get("dropped") is True,
                f"workspace drop admitted before EOF did not evict the runtime: {eof_drop_result}",
            )
            require_progress_sequence(
                client.progress_notifications(eof_drop_token),
                eof_drop_token,
                "EOF workspace drop progress",
            )
            returncode = client.wait_for_exit_after_eof(timeout)
            require(returncode == 0, f"legacy server exited with code {returncode} after active EOF")
            require(
                not client.response_ready(eof_request_id),
                "request cancelled by EOF produced a terminal response",
            )
            client.forget_request(eof_request_id)
        finally:
            if not release_path.exists():
                release_path.write_text("release\n", encoding="utf-8")
            client.close()

        # Modern MCP uses the same coordinator and broker admission path, but keep an explicit
        # regression here so protocol-envelope changes cannot silently lose exact cancellation.
        started_path.unlink(missing_ok=True)
        release_path.unlink(missing_ok=True)
        modern_client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="modern-cancellation",
            server_trace=server_trace,
            extra_env={
                "BEAM_MCP_GATE_STARTED": started_path,
                "BEAM_MCP_GATE_RELEASE": release_path,
                "LEAN_BEAM_MCP_TEST_STATUS_DELAY_MS": "100",
            },
        )
        modern_cancel_id = "modern-cancelled-run-at"
        try:
            update_result = expect_result(
                modern_client.modern_request(
                    "tools/call",
                    {
                        "name": "lean_update",
                        "arguments": {"path": "McpConcurrency.lean"},
                    },
                )
            )
            require_modern_result_envelope(update_result, "modern cancellation update")
            update = update_result.get("structuredContent")
            require(isinstance(update, dict), f"modern cancellation update has no result: {update_result}")
            snapshot = update.get("snapshot")
            require(isinstance(snapshot, str), f"modern cancellation update missing snapshot: {update}")
            modern_slow_params = with_modern_metadata(
                {
                    "name": "lean_run_at",
                    "arguments": {
                        "path": "McpConcurrency.lean",
                        "snapshot": snapshot,
                        "line": line,
                        "character": 2,
                        "text": "mcp_concurrency_gate",
                    },
                }
            )

            def run_modern_status_case(request_id, log_level, expect_notice):
                label = f"modern {log_level} runAt"
                started_path.unlink(missing_ok=True)
                release_path.unlink(missing_ok=True)
                params = with_modern_metadata(
                    {
                        "name": "lean_run_at",
                        "arguments": dict(modern_slow_params["arguments"]),
                    },
                    log_level=log_level,
                )
                modern_client.send_request("tools/call", params, request_id=request_id)
                wait_for_file(started_path, timeout, f"{label} gate sentinel")
                if expect_notice:
                    expect_status_log(
                        modern_client,
                        request_id=request_id,
                        tool="lean_run_at",
                        state="running",
                        timeout=min(timeout, 5.0),
                        label=f"{label} status",
                    )
                else:
                    time.sleep(0.5)
                    require(
                        status_log_notifications(modern_client, request_id) == [],
                        f"{label} should suppress notice status: {modern_client.notifications}",
                    )
                status_count = len(status_log_notifications(modern_client, request_id))
                release_path.write_text("release\n", encoding="utf-8")
                result = expect_result(modern_client.read_response(request_id))
                require_modern_result_envelope(result, label)
                require(result.get("isError") is not True, f"{label} returned a tool error: {result}")
                require(
                    len(status_log_notifications(modern_client, request_id)) == status_count,
                    f"{label} emitted duplicate or post-response statuses: {modern_client.notifications}",
                )

            modern_client.send_request(
                "tools/call",
                modern_slow_params,
                request_id=modern_cancel_id,
            )
            wait_for_file(started_path, timeout, "modern cancelled runAt gate sentinel")
            time.sleep(0.5)
            require(
                status_log_notifications(modern_client, modern_cancel_id) == [],
                f"modern request without logLevel emitted status: {modern_client.notifications}",
            )
            modern_client.notify(
                "notifications/cancelled",
                {
                    "requestId": modern_cancel_id,
                    "reason": "modern cancellation regression no longer needs the result",
                },
            )
            cancel_deadline = time.monotonic() + timeout
            cancelled_count = 0
            while time.monotonic() < cancel_deadline:
                stats_result = expect_result(
                    modern_client.modern_request(
                        "tools/call",
                        {"name": "beam_stats", "arguments": {}},
                    )
                )
                require_modern_result_envelope(stats_result, "modern cancellation stats")
                stats = stats_result.get("structuredContent")
                require(isinstance(stats, dict), f"modern cancellation stats has no result: {stats_result}")
                lean_stats = (
                    stats.get("workspaces", {})
                    .get(workspace_cache_key(project_root), {})
                    .get("byBackend", {})
                    .get("lean", {})
                )
                cancelled_count = lean_stats.get("cancelledCount", 0)
                if isinstance(cancelled_count, int) and cancelled_count >= 1:
                    break
                time.sleep(0.02)
            require(
                isinstance(cancelled_count, int) and cancelled_count >= 1,
                f"broker did not record cancelled modern MCP runAt: {stats}",
            )
            require(
                not modern_client.response_ready(modern_cancel_id),
                "modern cancelled request produced a terminal response",
            )
            modern_client.forget_request(modern_cancel_id)
            listed = expect_result(modern_client.modern_request("tools/list"))
            require_modern_result_envelope(listed, "modern tools/list after cancellation")

            run_modern_status_case("modern-notice-run-at", "notice", expect_notice=True)
            run_modern_status_case("modern-warning-run-at", "warning", expect_notice=False)

            modern_client.close_input()
            returncode = modern_client.wait_for_exit_after_eof(timeout)
            require(returncode == 0, f"modern status server exited with code {returncode} after EOF")
        finally:
            if not release_path.exists():
                release_path.write_text("release\n", encoding="utf-8")
            modern_client.close()


def run_concurrent_first_use(repo_root, fixture_root, timeout, server_trace=False):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-concurrent-first-use-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="concurrent-first-use",
            server_trace=server_trace,
        )
        try:
            client.initialize()
            requests = [
                (
                    "first-use-position",
                    {
                        "name": "lean_update",
                        "arguments": {"path": "PositionEmptyLine.lean"},
                    },
                ),
                (
                    "first-use-command",
                    {
                        "name": "lean_update",
                        "arguments": {"path": "CommandA.lean"},
                    },
                ),
            ]
            for request_id, params in requests:
                client.send_request("tools/call", params, request_id=request_id)
            for request_id, _params in reversed(requests):
                response = client.read_response(request_id)
                result = expect_result(response)
                require(result.get("isError") is not True, f"concurrent first-use update failed: {result}")
                structured = result.get("structuredContent")
                require(isinstance(structured, dict), f"concurrent first-use update missing content: {result}")
                require(
                    isinstance(structured.get("snapshot"), str),
                    f"concurrent first-use update missing snapshot: {structured}",
                )
            stats = client.call_tool("beam_stats")
            lean_stats = (
                stats.get("workspaces", {})
                .get(workspace_cache_key(project_root), {})
                .get("byBackend", {})
                .get("lean", {})
            )
            require(
                lean_stats.get("sessionStarts") == 1,
                f"concurrent first use should start one Lean session: {stats}",
            )
        finally:
            client.close()


def run_concurrent_workspace_updates(client, roots, label):
    pending = []
    for index, root in enumerate(roots):
        request_id = f"{label}-{index}"
        client.send_request(
            "tools/call",
            {
                "name": "lean_update",
                "arguments": {
                    "path": "PositionEmptyLine.lean",
                    "workspace": workspace_descriptor(root),
                },
            },
            request_id=request_id,
        )
        pending.append((request_id, root))
    for request_id, root in reversed(pending):
        result = expect_result(client.read_response(request_id))
        require(result.get("isError") is not True, f"{label} update failed: {result}")
        structured = result.get("structuredContent")
        require(isinstance(structured, dict), f"{label} update has no result: {result}")
        require(
            result_workspace_root(structured, request_id).resolve() == root.resolve(),
            f"{label} request crossed workspace descriptors: {structured}",
        )
        require(
            isinstance(structured.get("snapshot"), str),
            f"{label} update returned no snapshot: {structured}",
        )


def require_active_lean_workspaces(client, roots, label):
    stats = client.call_tool("beam_stats").get("workspaces", {})
    require(
        set(stats) == {workspace_cache_key(root) for root in roots},
        f"{label} should retain exactly the requested workspace caches: {stats}",
    )
    for root in roots:
        workspace_stats = stats.get(workspace_cache_key(root), {})
        require(
            workspace_stats.get("sessions", {}).get("lean", {}).get("active") is True,
            f"{label} did not retain an active Lean session for {root}: {stats}",
        )
        require(
            workspace_stats.get("byBackend", {}).get("lean", {}).get("sessionStarts") == 1,
            f"{label} should start one Lean session for {root}: {stats}",
        )


def run_concurrent_multi_workspace_first_use(repo_root, fixture_root, timeout, server_trace=False):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-concurrent-workspaces-") as tmp:
        tmp_root = Path(tmp)
        roots = [tmp_root / "project-a", tmp_root / "project-b"]
        for root in roots:
            copy_project_fixture(fixture_root, root)
        client = McpClient(
            repo_root,
            roots[0],
            timeout,
            label="concurrent-multi-workspace-first-use",
            server_trace=server_trace,
        )
        try:
            client.initialize()
            run_concurrent_workspace_updates(client, roots, "cold-workspace")
            require_active_lean_workspaces(client, roots, "cold first use")
        finally:
            client.close()


def run_multi_toolchain_workspaces(repo_root, fixture_root, timeout, server_trace=False):
    current_toolchain = (repo_root / "lean-toolchain").read_text(encoding="utf-8").strip()
    fixture_toolchain = (fixture_root / "lean-toolchain").read_text(encoding="utf-8").strip()
    require(
        current_toolchain != fixture_toolchain,
        "multi-toolchain MCP coverage requires the repository and fixture toolchains to differ",
    )
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-multi-toolchain-") as tmp:
        tmp_root = Path(tmp)
        roots = [tmp_root / "fixture-toolchain", tmp_root / "current-toolchain"]
        for root in roots:
            copy_project_fixture(fixture_root, root)
            lakefile = root / "lakefile.toml"
            lakefile.write_text(
                lakefile.read_text(encoding="utf-8").replace(
                    "\n[[lean_lib]]",
                    '\nmoreGlobalServerArgs = ["-Dpp.universes=true"]\n\n[[lean_lib]]',
                ),
                encoding="utf-8",
            )
        (roots[1] / "lean-toolchain").write_text(current_toolchain + "\n", encoding="utf-8")
        expected_toolchains = [fixture_toolchain, current_toolchain]
        configs = [beam_cli_mcp_config(repo_root, root, timeout) for root in roots]
        for root, expected_toolchain, config in zip(roots, expected_toolchains, configs):
            require(
                config.get("toolchain") == expected_toolchain,
                f"beam-cli selected the wrong toolchain for {root}: {config}",
            )
            lean_cmd = config.get("lean_cmd")
            require(isinstance(lean_cmd, str) and lean_cmd, f"mcp-config omitted lean_cmd for {root}: {config}")
            lake_helper = config.get("lean_lake_helper")
            require(
                isinstance(lake_helper, str) and Path(lake_helper).is_file(),
                f"mcp-config omitted the target Lake helper for {root}: {config}",
            )
            helper_env = subprocess.run(
                [lake_helper, "lake-helper", "server-env"],
                input=json.dumps({"root": str(root), "leanCmd": lean_cmd}),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                timeout=timeout,
                check=False,
                cwd=str(root),
            )
            require(
                helper_env.returncode == 0,
                f"target Lake helper failed for {root}: {helper_env.stdout}{helper_env.stderr}",
            )
            helper_result = json.loads(helper_env.stdout).get("result", {})
            require(
                "-Dpp.universes=true" in helper_result.get("moreServerArgs", []),
                f"target Lake helper omitted moreGlobalServerArgs for {root}: {helper_result}",
            )
            version = subprocess.run(
                [lean_cmd, "--version"],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                timeout=timeout,
                check=False,
            )
            require(
                version.returncode == 0 and expected_toolchain.rsplit(":v", 1)[-1] in version.stdout,
                f"resolved Lean command did not match {expected_toolchain} for {root}: "
                f"{version.stdout}{version.stderr}",
            )
        require(
            configs[0].get("lean_cmd") != configs[1].get("lean_cmd"),
            f"different toolchains resolved to the same Lean command: {configs}",
        )
        require(
            configs[0].get("lean_plugin") != configs[1].get("lean_plugin"),
            f"different toolchains resolved to the same Beam plugin: {configs}",
        )
        require(
            configs[0].get("lean_lake_helper") != configs[1].get("lean_lake_helper"),
            f"different toolchains resolved to the same target Lake helper: {configs}",
        )

        client = McpClient(
            repo_root,
            roots[0],
            timeout,
            label="multi-toolchain-workspaces",
            server_trace=server_trace,
            resolve_with_beam_cli=True,
        )
        try:
            client.initialize()
            run_concurrent_workspace_updates(client, roots, "toolchain-first-use")
            for root in roots:
                saved = client.call_tool(
                    "lean_save",
                    {
                        "path": "SaveSmoke/B.lean",
                        "workspace": workspace_descriptor(root),
                    },
                )
                require(
                    saved.get("module") == "SaveSmoke.B",
                    f"cross-toolchain save returned the wrong module for {root}: {saved}",
                )
                require(
                    Path(saved.get("trace", "")).is_file(),
                    f"cross-toolchain save did not publish a Lake trace for {root}: {saved}",
                )
            require_active_lean_workspaces(client, roots, "multi-toolchain process")
        finally:
            client.close()


def run_parallel_progress_smoke_repro(
    repo_root,
    fixture_root,
    timeout,
    runs,
    workers,
    slow_threshold,
    server_trace,
):
    require(runs > 0, "--repro-runs must be positive")
    require(workers > 0, "--parallel-workers must be positive")
    stop_event = threading.Event()
    print_lock = threading.Lock()
    started = time.monotonic()

    def worker(worker_index):
        durations = []
        for run_index in range(runs):
            if stop_event.is_set():
                break
            label = f"parallel-w{worker_index + 1}-r{run_index + 1}-of-{runs}"
            run_started = time.monotonic()
            try:
                run_progress_notification_smoke(
                    repo_root,
                    fixture_root,
                    timeout,
                    server_trace=server_trace,
                    label_prefix=label,
                )
            except Exception as err:
                stop_event.set()
                elapsed = time.monotonic() - run_started
                raise RuntimeError(f"{label}: progress smoke failed after {elapsed:.3f}s\n{err}") from err
            elapsed = time.monotonic() - run_started
            durations.append(elapsed)
            if slow_threshold is not None and elapsed >= slow_threshold:
                with print_lock:
                    print(f"{label}: progress-smoke={elapsed:.3f}s", file=sys.stderr)
        with print_lock:
            if durations:
                print(
                    f"parallel worker {worker_index + 1} summary: "
                    f"{format_duration_stats(durations)}",
                    file=sys.stderr,
                )
            elif stop_event.is_set():
                print(f"parallel worker {worker_index + 1} stopped before starting", file=sys.stderr)
        return durations

    durations = []
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=workers)
    futures = [executor.submit(worker, worker_index) for worker_index in range(workers)]
    try:
        for future in concurrent.futures.as_completed(futures):
            durations.extend(future.result())
    except Exception:
        stop_event.set()
        for future in futures:
            future.cancel()
        raise
    finally:
        executor.shutdown(wait=True, cancel_futures=True)
    require(durations, "parallel progress smoke completed no runs")
    elapsed = time.monotonic() - started
    print(
        f"{PARALLEL_PROGRESS_SMOKE_SCENARIO} summary: "
        f"workers={workers} runs_per_worker={runs} "
        f"elapsed={elapsed:.3f}s {format_duration_stats(durations)}",
        file=sys.stderr,
    )


def run_stateless_workspace_matrix(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-stateless-workspaces-") as tmp:
        tmp_root = Path(tmp)
        root_a = tmp_root / "project-a"
        root_b = tmp_root / "project-b"
        alias_a = tmp_root / "project-a-alias"
        missing_root = tmp_root / "missing-project"
        file_root = tmp_root / "not-a-directory"
        empty_root = tmp_root / "not-a-project"
        copy_project_fixture(fixture_root, root_a)
        copy_project_fixture(fixture_root, root_b)
        alias_a.symlink_to(root_a, target_is_directory=True)
        file_root.write_text("not a workspace directory\n", encoding="utf-8")
        empty_root.mkdir()
        client = McpClient(repo_root, root_a, timeout, label="stateless-workspaces")
        try:
            client.initialize()

            missing = client.request(
                "tools/call",
                {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                inject_workspace=False,
            )
            missing_error = expect_tool_error_code(missing, "invalidInput")
            require(
                "workspace is required" in missing_error.get("message", ""),
                f"workspace-bound call should require its descriptor: {missing_error}",
            )

            relative = client.request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {
                        "path": "PositionEmptyLine.lean",
                        "workspace": {"root": "relative/project"},
                    },
                },
            )
            relative_error = expect_tool_error_code(relative, "invalidInput")
            require(
                "absolute path" in relative_error.get("message", ""),
                f"relative workspace root should fail explicitly: {relative_error}",
            )

            invalid_roots = [
                ("missing", missing_root, "does not resolve"),
                ("regular file", file_root, "not a directory"),
                ("non-project directory", empty_root, "not a Lean/Lake project"),
            ]
            for label, invalid_root, expected_message in invalid_roots:
                response = client.request(
                    "tools/call",
                    {
                        "name": "lean_sync",
                        "arguments": {
                            "path": "PositionEmptyLine.lean",
                            "workspace": workspace_descriptor(invalid_root),
                        },
                    },
                )
                error = expect_tool_error_code(response, "invalidInput")
                require(
                    expected_message in error.get("message", ""),
                    f"{label} workspace root should fail explicitly: {error}",
                )

            version_before_valid_root = client.call_tool("beam_version")
            require(
                version_before_valid_root.get("runtime_active") is False,
                f"rejected workspace roots should not create a broker runtime: {version_before_valid_root}",
            )
            stats_before_valid_root = client.call_tool("beam_stats").get("workspaces", {})
            require(
                stats_before_valid_root == {},
                f"rejected workspace roots should not create workspace caches: {stats_before_valid_root}",
            )

            first_a = client.call_tool("lean_sync", {"path": "PositionEmptyLine.lean"})
            require(
                result_workspace_root(first_a, "first workspace A sync").resolve() == root_a.resolve(),
                f"first request did not lazily select workspace A: {first_a}",
            )

            alias_descriptor = {"root": str(alias_a.absolute())}
            require(
                alias_descriptor != workspace_descriptor(root_a),
                f"canonical alias fixture did not preserve its symlink spelling: {alias_descriptor}",
            )
            alias_sync = client.call_tool(
                "lean_sync",
                {
                    "path": "PositionEmptyLine.lean",
                    "workspace": alias_descriptor,
                },
            )
            require(
                result_workspace_root(alias_sync, "canonical alias sync") == root_a.resolve(),
                f"canonical alias did not echo workspace A: {alias_sync}",
            )
            alias_stats = client.call_tool("beam_stats").get("workspaces", {})
            require(
                set(alias_stats) == {workspace_cache_key(root_a)},
                f"canonical aliases should share one cached workspace: {alias_stats}",
            )

            first_b = client.call_tool(
                "lean_sync",
                {
                    "path": "PositionEmptyLine.lean",
                    "workspace": workspace_descriptor(root_b),
                },
            )
            require(
                result_workspace_root(first_b, "first workspace B sync").resolve() == root_b.resolve(),
                f"independent request did not lazily select workspace B: {first_b}",
            )
            version_b = first_b.get("snapshot")
            require(isinstance(version_b, str), f"workspace B sync returned no snapshot: {first_b}")

            stats = client.call_tool("beam_stats").get("workspaces", {})
            require(
                set(stats) == {workspace_cache_key(root_a), workspace_cache_key(root_b)},
                f"two explicit descriptors should create exactly two caches: {stats}",
            )

            parallel = []
            for label, root in (("a", root_a), ("b", root_b)):
                request_id = f"parallel-workspace-{label}"
                client.send_request(
                    "tools/call",
                    {
                        "name": "lean_sync",
                        "arguments": {
                            "path": "PositionEmptyLine.lean",
                            "workspace": workspace_descriptor(root),
                        },
                    },
                    request_id=request_id,
                )
                parallel.append((request_id, root))
            for request_id, root in reversed(parallel):
                result = expect_result(client.read_response(request_id))
                require(result.get("isError") is not True, f"parallel workspace sync failed: {result}")
                structured = result.get("structuredContent")
                require(isinstance(structured, dict), f"parallel workspace sync has no result: {result}")
                require(
                    result_workspace_root(structured, request_id).resolve() == root.resolve(),
                    f"parallel requests crossed workspace descriptors: {structured}",
                )

            minted = client.call_tool(
                "lean_run_at_handle",
                {
                    "path": "PositionEmptyLine.lean",
                    "snapshot": version_b,
                    "line": 1,
                    "character": 0,
                    "text": "def statelessWorkspaceBase : Nat := 1",
                    "workspace": workspace_descriptor(root_b),
                },
            )
            require_success("workspace B handle mint", minted)
            handle_b = minted.get("next_handle")
            require(isinstance(handle_b, dict), f"workspace B handle mint returned no handle: {minted}")

            crossed = client.request(
                "tools/call",
                {
                    "name": "lean_run_with",
                    "arguments": {
                        "path": "PositionEmptyLine.lean",
                        "handle": handle_b,
                        "text": "def mustNotCrossWorkspaces : Nat := 0",
                        "workspace": workspace_descriptor(root_a),
                    },
                },
            )
            crossed_error = expect_tool_error_code(crossed, "invalidParams")
            require(
                "does not match handle workspace" in crossed_error.get("message", ""),
                f"cross-workspace handle failure should explain the mismatch: {crossed_error}",
            )

            feedback_progress_token = "beam-feedback-collection-progress"
            feedback_result = expect_result(
                client.request(
                    "tools/call",
                    {
                        "name": "beam_feedback_report",
                        "arguments": {
                            "workspace": workspace_descriptor(root_b),
                            "title": "workspace isolation regression",
                            "summary": "collect one explicit workspace only",
                            "reproduction": "call feedback with a workspace descriptor",
                            "expected": "only that workspace is collected",
                            "actual": "regression check",
                            "include_collected": True,
                            "redact": False,
                        },
                        "_meta": {"progressToken": feedback_progress_token},
                    },
                )
            )
            require(
                feedback_result.get("isError") is not True,
                f"workspace feedback failed: {feedback_result}",
            )
            feedback = feedback_result.get("structuredContent")
            require(
                isinstance(feedback, dict),
                f"workspace feedback omitted structured content: {feedback_result}",
            )
            feedback_notifications = client.progress_notifications(feedback_progress_token)
            require_progress_sequence(
                feedback_notifications,
                feedback_progress_token,
                "workspace feedback progress",
            )
            require_progress_message_contains(
                feedback_notifications,
                "workspace feedback progress",
                "collecting beam_feedback_report context",
            )
            require(
                len(feedback_notifications) == 1,
                f"beam_feedback_report emitted redundant phase or terminal progress: {feedback_notifications}",
            )
            collected = feedback.get("collected")
            require(isinstance(collected, dict), f"workspace feedback omitted context: {feedback}")
            feedback_stats = collected.get("stats")
            require(
                isinstance(feedback_stats, dict)
                and feedback_stats.get("id") == workspace_cache_key(root_b)
                and Path(feedback_stats.get("root")).resolve() == root_b.resolve(),
                f"workspace feedback stats were not scoped to B: {feedback_stats}",
            )
            require(
                str(root_a.resolve()) not in json.dumps(collected, sort_keys=True),
                f"workspace feedback leaked workspace A: {collected}",
            )

            invalid_drop_token = "invalid-workspace-drop-progress"
            invalid_drop = client.request(
                "tools/call",
                {
                    "name": "lean_drop_workspace",
                    "arguments": {"workspace": {"root": "relative-workspace"}},
                    "_meta": {"progressToken": invalid_drop_token},
                },
            )
            invalid_drop_error = expect_tool_error_code(invalid_drop, "invalidInput")
            require(
                "absolute path" in invalid_drop_error.get("message", ""),
                f"relative workspace drop should explain its invalid root: {invalid_drop_error}",
            )
            require(
                client.progress_notifications(invalid_drop_token) == [],
                "invalid workspace drop emitted progress before semantic input validation",
            )

            missing_drop = client.request(
                "tools/call",
                {"name": "lean_drop_workspace", "arguments": {}},
                inject_workspace=False,
            )
            missing_drop_error = expect_tool_error_code(missing_drop, "invalidInput")
            require(
                "workspace is required" in missing_drop_error.get("message", ""),
                f"cache eviction should require a descriptor: {missing_drop_error}",
            )

            drop_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_drop_workspace",
                    "arguments": {"workspace": workspace_descriptor(root_b)},
                    "_meta": {"progressToken": "cancelled-workspace-drop"},
                },
                request_id="drop-workspace-b",
            )
            client.notify(
                "notifications/cancelled",
                {
                    "requestId": drop_id,
                    "reason": "cache eviction must commit and report final state",
                },
            )
            recreate_id = client.send_request(
                "tools/call",
                {
                    "name": "lean_sync",
                    "arguments": {
                        "path": "PositionEmptyLine.lean",
                        "workspace": workspace_descriptor(root_b),
                    },
                },
                request_id="sync-after-drop",
            )
            drop_result = expect_result(client.read_response(drop_id))
            require(drop_result.get("isError") is not True, f"cancelled cache eviction failed: {drop_result}")
            dropped = drop_result.get("structuredContent")
            require(
                isinstance(dropped, dict)
                and dropped.get("workspace") == workspace_descriptor(root_b)
                and dropped.get("dropped") is True
                and dropped.get("invalidated_handles") is True,
                f"cancelled cache eviction did not report committed state: {drop_result}",
            )
            recreated_result = expect_result(client.read_response(recreate_id))
            require(recreated_result.get("isError") is not True, f"request after eviction failed: {recreated_result}")
            recreated = recreated_result.get("structuredContent")
            require(
                isinstance(recreated, dict)
                and result_workspace_root(recreated, "post-eviction sync").resolve() == root_b.resolve(),
                f"request after eviction did not lazily recreate workspace B: {recreated_result}",
            )
            require_progress_sequence(
                client.progress_notifications("cancelled-workspace-drop"),
                "cancelled-workspace-drop",
                "non-cancellable workspace drop progress",
            )
            expect_stale_handle(client, handle_b, "workspace B eviction", root=root_b)

            unavailable_root_b = tmp_root / "project-b-unavailable"
            root_b.rename(unavailable_root_b)
            try:
                drop_workspace(client, root_b)
                drop_workspace(client, root_b, expected_dropped=False)
            finally:
                unavailable_root_b.rename(root_b)
            remaining = client.call_tool("beam_stats").get("workspaces", {})
            require(
                set(remaining) == {workspace_cache_key(root_a)},
                f"eviction should affect only the selected workspace cache: {remaining}",
            )
            require(
                not client.server_requests,
                f"stateless MCP server must not issue server-to-client requests: {client.server_requests}",
            )
        finally:
            client.close()


def run_cross_process_handle_rejection(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-cross-process-handle-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        first = McpClient(repo_root, project_root, timeout, label="handle-origin-process")
        handle = None
        try:
            first.initialize()
            update = first.call_tool("lean_update", {"path": "PositionEmptyLine.lean"})
            snapshot = update.get("snapshot")
            require(isinstance(snapshot, str), f"cross-process handle update returned no snapshot: {update}")
            minted = first.call_tool(
                "lean_run_at_handle",
                {
                    "path": "PositionEmptyLine.lean",
                    "snapshot": snapshot,
                    "line": 1,
                    "character": 0,
                    "text": "def crossProcessHandleBase : Nat := 1",
                },
            )
            require_success("cross-process handle mint", minted)
            handle = minted.get("next_handle")
            require(isinstance(handle, dict), f"cross-process handle mint returned no handle: {minted}")
        finally:
            first.close()

        second = McpClient(repo_root, project_root, timeout, label="handle-restart-process")
        try:
            second.initialize()
            expect_stale_handle(second, handle, "fresh MCP process")
        finally:
            second.close()


def initialize_params(capabilities=None, protocol_version=MCP_LEGACY_PROTOCOL_VERSION):
    return {
        "protocolVersion": protocol_version,
        "capabilities": capabilities if capabilities is not None else {},
        "clientInfo": {"name": "lean-beam-mcp-lifecycle-test", "version": "0"},
    }


def check_response(response, expectation, label):
    kind = expectation["kind"]
    if kind == "result":
        result = expect_result(response)
        expected_protocol_version = expectation.get("protocol_version")
        if expected_protocol_version is not None:
            require(
                result.get("protocolVersion") == expected_protocol_version,
                f"{label}: expected protocol version {expected_protocol_version!r}, got {response}",
            )
    elif kind == "error":
        error = expect_error_code(response, expectation["code"])
        needle = expectation.get("message_contains")
        if needle is not None:
            message = error.get("message")
            require(isinstance(message, str) and needle in message, f"{label}: expected {needle!r} in {response}")
    else:
        fail(f"{label}: unknown expectation kind {kind}")


def run_lifecycle_matrix(repo_root, fixture_root, timeout):
    cases = [
        {
            "name": "discover_does_not_select_protocol_family",
            "actions": [
                {
                    "request": "server/discover",
                    "params": with_modern_metadata(),
                    "expect": {"kind": "result"},
                },
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {"notify": "notifications/initialized"},
                {"request": "tools/list", "expect": {"kind": "result"}},
            ],
        },
        {
            "name": "ping_before_initialize_is_rejected",
            "actions": [
                {
                    "request": "ping",
                    "expect": {"kind": "error", "code": -32600, "message_contains": "initialize"},
                },
            ],
        },
        {
            "name": "initialize_selects_supported_legacy_version",
            "actions": [
                {
                    "request": "initialize",
                    "params": initialize_params(protocol_version="2025-06-18"),
                    "expect": {"kind": "result", "protocol_version": MCP_LEGACY_PROTOCOL_VERSION},
                },
            ],
        },
        {
            "name": "malformed_initialize_does_not_change_state",
            "actions": [
                {
                    "request": "initialize",
                    "params": {
                        "protocolVersion": MCP_LEGACY_PROTOCOL_VERSION,
                        "capabilities": [],
                        "clientInfo": {"name": "invalid", "version": "0"},
                    },
                    "expect": {"kind": "error", "code": -32602},
                },
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
            ],
        },
        {
            "name": "tool_call_before_initialize",
            "actions": [
                {
                    "request": "tools/call",
                    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                    "expect": {"kind": "error", "code": -32600, "message_contains": "initialize"},
                },
            ],
        },
        {
            "name": "tool_call_before_initialized_notification",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "tools/call",
                    "params": {"name": "lean_sync", "arguments": {"path": "PositionEmptyLine.lean"}},
                    "expect": {"kind": "error", "code": -32600, "message_contains": "notifications/initialized"},
                },
            ],
        },
        {
            "name": "repeat_initialize",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "initialize",
                    "params": initialize_params(),
                    "expect": {"kind": "error", "code": -32600, "message_contains": "already completed"},
                },
            ],
        },
        {
            "name": "initialized_before_initialize_does_not_ready_server",
            "actions": [
                {"notify": "notifications/initialized"},
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {
                    "request": "tools/list",
                    "expect": {"kind": "error", "code": -32600, "message_contains": "notifications/initialized"},
                },
            ],
        },
        {
            "name": "malformed_initialized_does_not_ready_server",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {"notify": "notifications/initialized", "params": []},
                {
                    "request": "tools/list",
                    "expect": {"kind": "error", "code": -32600, "message_contains": "notifications/initialized"},
                },
            ],
        },
        {
            "name": "legacy_utility_params_are_closed",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {"notify": "notifications/initialized"},
                {
                    "request": "ping",
                    "params": [],
                    "expect": {"kind": "error", "code": -32602},
                },
                {
                    "request": "ping",
                    "params": {"unexpected": True},
                    "expect": {"kind": "error", "code": -32602},
                },
                {
                    "request": "tools/list",
                    "params": {"cursor": "not-issued-by-beam"},
                    "expect": {"kind": "error", "code": -32602},
                },
                {
                    "request": "tools/list",
                    "params": {"_meta": []},
                    "expect": {"kind": "error", "code": -32602},
                },
                {
                    "request": "ping",
                    "params": {"_meta": {}},
                    "expect": {"kind": "result"},
                },
            ],
        },
        {
            "name": "unknown_method_before_initialize",
            "actions": [
                {"request": "unknown/method", "expect": {"kind": "error", "code": -32600, "message_contains": "initialize"}},
            ],
        },
        {
            "name": "unknown_method_after_initialize",
            "actions": [
                {"request": "initialize", "params": initialize_params(), "expect": {"kind": "result"}},
                {"notify": "notifications/initialized"},
                {"request": "unknown/method", "expect": {"kind": "error", "code": -32601}},
            ],
        },
    ]
    for case in cases:
        with tempfile.TemporaryDirectory(prefix=f"lean-beam-mcp-{case['name']}-") as tmp:
            project_root = Path(tmp) / "project"
            copy_project_fixture(fixture_root, project_root)
            client = McpClient(repo_root, project_root, timeout, label=f"lifecycle-{case['name']}")
            try:
                for action in case["actions"]:
                    if "notify" in action:
                        client.notify(action["notify"], action.get("params"))
                        continue
                    response = client.request(action["request"], action.get("params"))
                    check_response(response, action["expect"], f"{case['name']} {action['request']}")
            finally:
                client.close()


def run_blank_line_regression(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-blank-line-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="blank-line-regression",
            drain_stdout=False,
        )
        try:
            with client.stdin_lock:
                client.proc.stdin.write("\n")
                client.proc.stdin.flush()
            ready, _, _ = select.select([client.proc.stdout], [], [], timeout)
            require(ready, "blank input did not produce a JSON-RPC parse error")
            parse_error = json.loads(client.proc.stdout.readline())
            expect_error_code(parse_error, -32700)
            require(parse_error.get("id") is None, f"blank-line error should have null id: {parse_error}")

            discover_request = {
                "jsonrpc": "2.0",
                "id": 1.5,
                "method": "server/discover",
                "params": {
                    "_meta": {
                        "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
                        "io.modelcontextprotocol/clientCapabilities": {},
                    }
                },
            }
            client.send_message(discover_request)
            ready, _, _ = select.select([client.proc.stdout], [], [], timeout)
            require(ready, "fractional request id did not produce a JSON-RPC error")
            invalid_id = json.loads(client.proc.stdout.readline())
            expect_error_code(invalid_id, -32600)
            require(invalid_id.get("id") is None, f"fractional-id error should have null id: {invalid_id}")

            discover_request["id"] = "after-blank-line"
            client.send_message(discover_request)
            ready, _, _ = select.select([client.proc.stdout], [], [], timeout)
            require(ready, "server stopped reading requests after a blank input line")
            discover = json.loads(client.proc.stdout.readline())
            require(discover.get("id") == "after-blank-line", f"wrong discover response: {discover}")
            require_modern_result_envelope(expect_result(discover), "discover after blank line")
        finally:
            client.close()


def run_legacy_eof_teardown(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-legacy-eof-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        client = McpClient(repo_root, project_root, timeout, label="legacy-eof-teardown")
        try:
            client.initialize()
            client.close_input()
            returncode = client.wait_for_exit_after_eof(timeout)
            require(returncode == 0, f"legacy server exited with code {returncode} after EOF")
        finally:
            client.close()


def require_clean_exit_after_closed_stdout(client, message, label):
    try:
        client.proc.stdout.close()
        client.send_message(message)
        client.close_input()
        try:
            client.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            client.proc.kill()
            fail(f"lean-beam-mcp did not exit after stdout was closed during {label}")
        client.stderr_thread.join(timeout=1)
        stderr = "\n".join(client.stderr_lines)
        require(
            client.proc.returncode == 0,
            f"lean-beam-mcp exited with {client.proc.returncode} during {label}\n{stderr}",
        )
        if client.server_trace:
            unexpected = [
                line for line in stderr.splitlines()
                if not line.startswith("lean-beam-mcp trace ")
            ]
            require(
                not unexpected,
                f"lean-beam-mcp wrote unexpected non-trace stderr during {label}:\n"
                + "\n".join(unexpected),
            )
        else:
            require(
                stderr.strip() == "",
                f"lean-beam-mcp wrote unexpected stderr during {label}:\n{stderr}",
            )
    finally:
        if client.proc.poll() is None:
            client.proc.kill()
            client.proc.wait(timeout=5)


def run_closed_stdout_regression(repo_root, fixture_root, timeout):
    with tempfile.TemporaryDirectory(prefix="lean-beam-mcp-closed-stdout-") as tmp:
        project_root = Path(tmp) / "project"
        copy_project_fixture(fixture_root, project_root)
        initialize_client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="closed-stdout-initialize",
            drain_stdout=False,
        )
        require_clean_exit_after_closed_stdout(
            initialize_client,
            {
                "jsonrpc": "2.0",
                "id": "closed-stdout-initialize",
                "method": "initialize",
                "params": initialize_params(),
            },
            "initialize response",
        )

        control_client = McpClient(
            repo_root,
            project_root,
            timeout,
            label="closed-stdout-control",
            drain_stdout=False,
        )
        try:
            control_client.send_message(
                {
                    "jsonrpc": "2.0",
                    "id": "closed-stdout-control-initialize",
                    "method": "initialize",
                    "params": initialize_params(),
                }
            )
            ready, _, _ = select.select([control_client.proc.stdout], [], [], timeout)
            require(ready, "closed-stdout control regression did not receive initialize response")
            initialized = json.loads(control_client.proc.stdout.readline())
            require(
                initialized.get("id") == "closed-stdout-control-initialize",
                f"closed-stdout control regression received wrong initialize response: {initialized}",
            )
            expect_result(initialized)
            control_client.send_message(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/initialized",
                }
            )
            require_clean_exit_after_closed_stdout(
                control_client,
                {
                    "jsonrpc": "2.0",
                    "id": "closed-stdout-control",
                    "method": "tools/call",
                    "params": {
                        "name": "lean_drop_workspace",
                        "arguments": {
                            "workspace": workspace_descriptor(project_root),
                        },
                        "_meta": {
                            "progressToken": "closed-stdout-control-progress",
                        },
                    },
                },
                "workspace-control response",
            )
        finally:
            if control_client.proc.poll() is None:
                control_client.proc.kill()
                control_client.proc.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description="Exercise lean-beam-mcp over stdio.")
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--restart-cycles", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--scenario",
        choices=[
            "full",
            CONCURRENT_DISPATCH_SCENARIO,
            MULTI_TOOLCHAIN_SCENARIO,
            PARALLEL_PROGRESS_SMOKE_SCENARIO,
        ]
        + sorted(FOCUSED_SYNC_SCENARIOS),
        default="full",
        help="run the full smoke suite or a focused repro scenario",
    )
    parser.add_argument(
        "--repro-runs",
        type=int,
        default=1,
        help="number of focused scenario repetitions",
    )
    parser.add_argument(
        "--parallel-workers",
        type=int,
        default=8,
        help="number of workers for the progress-smoke-parallel repro scenario",
    )
    parser.add_argument(
        "--slow-threshold",
        type=float,
        default=None,
        help="only print per-run focused scenario timings at or above this many seconds",
    )
    parser.add_argument(
        "--server-trace",
        action="store_true",
        help="enable opt-in lean-beam-mcp and broker stderr trace output",
    )
    args = parser.parse_args()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_root = repo_root / "tests" / "save_olean_project"
    require(fixture_root.exists(), f"missing MCP fixture root at {fixture_root}")
    if args.scenario in FOCUSED_SYNC_SCENARIOS:
        run_focused_sync_repro(
            repo_root,
            fixture_root,
            args.timeout,
            args.repro_runs,
            args.slow_threshold,
            args.scenario,
            args.server_trace,
        )
        return
    if args.scenario == PARALLEL_PROGRESS_SMOKE_SCENARIO:
        run_parallel_progress_smoke_repro(
            repo_root,
            fixture_root,
            args.timeout,
            args.repro_runs,
            args.parallel_workers,
            args.slow_threshold,
            args.server_trace,
        )
        return
    if args.scenario == MULTI_TOOLCHAIN_SCENARIO:
        run_multi_toolchain_workspaces(
            repo_root,
            fixture_root,
            args.timeout,
            server_trace=args.server_trace,
        )
        return
    if args.scenario == CONCURRENT_DISPATCH_SCENARIO:
        run_concurrent_dispatch(
            repo_root,
            fixture_root,
            args.timeout,
            server_trace=args.server_trace,
        )
        run_concurrent_first_use(
            repo_root,
            fixture_root,
            args.timeout,
            server_trace=args.server_trace,
        )
        run_concurrent_multi_workspace_first_use(
            repo_root,
            fixture_root,
            args.timeout,
            server_trace=args.server_trace,
        )
        run_stateless_workspace_matrix(repo_root, fixture_root, args.timeout)
        return
    run_modern_protocol_smoke(repo_root, fixture_root, args.timeout)
    for cycle in range(args.restart_cycles):
        run_cycle(repo_root, fixture_root, cycle, args.iterations, args.timeout)
    run_diagnostic_logging(repo_root, fixture_root, args.timeout)
    run_progress_notification_smoke(repo_root, fixture_root, args.timeout)
    run_concurrent_dispatch(repo_root, fixture_root, args.timeout, server_trace=args.server_trace)
    run_concurrent_first_use(repo_root, fixture_root, args.timeout, server_trace=args.server_trace)
    run_concurrent_multi_workspace_first_use(
        repo_root,
        fixture_root,
        args.timeout,
        server_trace=args.server_trace,
    )
    run_stateless_workspace_matrix(repo_root, fixture_root, args.timeout)
    run_cross_process_handle_rejection(repo_root, fixture_root, args.timeout)
    run_lifecycle_matrix(repo_root, fixture_root, args.timeout)
    run_blank_line_regression(repo_root, fixture_root, args.timeout)
    run_legacy_eof_teardown(repo_root, fixture_root, args.timeout)
    run_closed_stdout_regression(repo_root, fixture_root, args.timeout)


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        print(f"test-mcp-stdio.py: {err}", file=sys.stderr)
        sys.exit(1)
