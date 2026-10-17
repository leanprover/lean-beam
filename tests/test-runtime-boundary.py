#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Reject installation dependencies in Beam's shared execution modules."""

from pathlib import Path
import re
import sys


REPO = Path(__file__).resolve().parents[1]
ROOTS = (
    "Beam.Version", "Beam.Runtime", "Beam.BuildInfo", "Beam.Broker.Config", "Beam.Cli.DaemonConfig", "Beam.Cli.DaemonManager",
    "Beam.Mcp.Projection", "Beam.Mcp.Protocol", "Beam.Mcp.Server", "Beam.Mcp.StdioServer",
)
INSTALL_MODULES = (
    "Beam.Installation", "Beam.InstallMain", "Beam.Cli.InstallConstruction",
    "Beam.Cli.Installation", "Beam.Cli.InstallCommands", "Beam.Cli.InstallLayout",
    "Beam.Cli.Toolchain", "Beam.Cli.RuntimeBundle", "Beam.Cli.RuntimeIdentity",
    "Beam.Mcp.Application", "Beam.Mcp.Runtime",
)


def violations():
    failures = []
    for root in ROOTS:
        root_source = REPO / (root.replace(".", "/") + ".lean")
        if not root_source.is_file():
            raise FileNotFoundError(f"missing core module: {root_source}")
        pending = [(root, [root])]
        visited = set()
        while pending:
            module, chain = pending.pop()
            if module in visited:
                continue
            visited.add(module)
            if any(module == name or module.startswith(name + ".") for name in INSTALL_MODULES):
                failures.append(" -> ".join(chain))
                continue
            source = REPO / (module.replace(".", "/") + ".lean")
            if source.is_file():
                imports = re.findall(r"^(?:public[ \t]+)?import[ \t]+([^\n]+)",
                                     source.read_text(), re.MULTILINE)
                for line in imports:
                    pending.extend((name, chain + [name])
                                   for name in line.split("--", 1)[0].split())
    return failures


def main():
    failures = violations()
    if failures:
        print("Installation dependencies leaked into core Beam:\n" + "\n".join(failures),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
