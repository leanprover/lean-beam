#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""MCP discovery must not resolve an unused runtime at application startup."""

import json
import os
from pathlib import Path
import subprocess
import tempfile

from mcp_test_util import MCP_MODERN_PROTOCOL_VERSION


REPO = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""


def main():
    request = {
        "jsonrpc": "2.0", "id": 1, "method": "server/discover",
        "params": {"_meta": {
            "io.modelcontextprotocol/protocolVersion": MCP_MODERN_PROTOCOL_VERSION,
            "io.modelcontextprotocol/clientCapabilities": {},
            "io.modelcontextprotocol/clientInfo": {"name": "beam-application-test", "version": "0"},
        }},
    }
    with tempfile.TemporaryDirectory(prefix="beam-mcp-application-") as directory:
        missing = Path(directory) / "missing"
        env = dict(os.environ, BEAM_HOME=str(missing))
        for args in [[], ["--lean-cmd", "lean", "--lean-plugin", str(missing / "plugin")],
                     ["--beam-cli", str(missing / f"beam-cli{EXE}")]]:
            result = subprocess.run(
                [str(REPO / f".lake/build/bin/lean-beam-mcp{EXE}"), *args],
                input=json.dumps(request) + "\n", capture_output=True, text=True,
                encoding="utf-8", env=env, cwd=directory, timeout=15,
            )
            assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
            responses = [json.loads(line) for line in result.stdout.splitlines()]
            response, = [message for message in responses if message.get("id") == 1]
            assert MCP_MODERN_PROTOCOL_VERSION in response["result"]["supportedVersions"], response
        assert not missing.exists(), "discovery created runtime state"


if __name__ == "__main__":
    main()
