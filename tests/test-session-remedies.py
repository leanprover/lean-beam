#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Execute generated session invocations directly, including on native Windows."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

from installation_fixture import EXE, REPO, stage


def invoke(command, *, cwd):
    assert set(command) == {"executable", "arguments"}, command
    result = subprocess.run([command["executable"], *command["arguments"]], cwd=cwd,
                            capture_output=True, text=True, encoding="utf-8", timeout=30)
    assert result.returncode == 0, (result.args, result.returncode, result.stdout, result.stderr)
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native-prefix", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="beam remedy invocation-") as temporary:
        scratch = Path(temporary).resolve()
        supplied = args.native_prefix or os.environ.get("BEAM_TEST_INSTALLATION")
        if supplied:
            installation = Path(supplied).resolve()
        else:
            installation = scratch / "installation's Ω"
            stage(installation)
        project = scratch / "workspace's Ω"
        project.mkdir()
        (project / "lakefile.toml").write_text('name = "remedy_fixture"\n', encoding="utf-8")
        control = scratch / "session's Ω"
        generation = "generation 'Ω'\t\n\x1b\\tail\\"
        fixture = REPO / ".lake/build/bin" / ("beam-cli-daemon-test" + EXE)
        commands = invoke({
            "executable": str(fixture),
            "arguments": ["--session-commands", str(installation), str(project), str(control), generation],
        }, cwd=scratch)
        selectors = ["--root", str(project), "--session-dir", str(control)]
        for operation, tail in [("status", ["status"]), ("stop", ["stop"]),
                                ("recover", ["recover", "--generation", generation])]:
            command = commands[operation]
            assert command == {
                "executable": str(installation / "bin" / ("lean-beam" + EXE)),
                "arguments": [*selectors, *tail],
            }, command
            # Observe the generated vector through a real native receiver, without executing
            # recovery or treating its presence as proof that producers have stopped.
            received = invoke({
                "executable": str(fixture),
                "arguments": ["--record-invocation", *command["arguments"], ""],
            }, cwd=scratch)
            assert received == [*command["arguments"], ""], received
        # Read-only status is safe for this fixture-owned absent session. Execute the actual
        # owning installation, rather than another lean-beam selected from PATH.
        status = invoke(commands["status"], cwd=scratch)
        assert status["ok"] and status["result"]["state"] == "absent", status
        assert Path(status["result"]["workspace"]["root"]).samefile(project), status
        assert status["result"]["session_dir"] == str(control), status
        assert not control.exists(), "status created a session directory"
    print("session remedies: native argv, selectors, owning installation, and control text passed")


if __name__ == "__main__":
    main()
