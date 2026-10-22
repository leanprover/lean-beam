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
    "Beam.Mcp.Projection", "Beam.Mcp.Protocol", "Beam.Mcp.Reporting", "Beam.Mcp.Server", "Beam.Mcp.StdioServer",
)
INSTALL_MODULES = (
    "Beam.Install", "Beam.Installation", "Beam.Cli.Installation", "Beam.Mcp.Application",
)
# Shipped executables and the plugin; none of them may contain the source-side installer.
SHIPPED_ROOTS = ("Beam.Cli", "Beam.Broker.ServerMain", "Beam.Mcp.ServerMain", "Beam.LSP")


def violations_for(roots, forbidden):
    failures = []
    for root in roots:
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
            if any(module == name or module.startswith(name + ".") for name in forbidden):
                failures.append(" -> ".join(chain))
                continue
            source = REPO / (module.replace(".", "/") + ".lean")
            if module.startswith("Beam.") and not source.is_file():
                failures.append("missing local module: " + " -> ".join(chain))
                continue
            if source.is_file():
                imports = re.findall(r"^(?:public[ \t]+)?import[ \t]+([^\n]+)",
                                     source.read_text(), re.MULTILINE)
                for line in imports:
                    pending.extend((name, chain + [name])
                                   for name in line.split("--", 1)[0].split())
    return failures


def violations():
    shared_installation = ("Beam.Installation.Lookup", "Beam.Installation.Manifest",
                           "Beam.Installation.StandaloneLayout",
                           "Beam.Installation.Bundled", "Beam.Mcp.Application", "Beam.Broker.ServerMain")
    return (violations_for(ROOTS, INSTALL_MODULES) + violations_for(shared_installation, ("Beam.Cli",)) +
            violations_for(("Beam.Mcp.Reporting",),
                           ("Beam.Broker.Server", "Beam.Mcp.Server", "Beam.Mcp.StdioServer", "Beam.Cli.DaemonManager")) +
            violations_for(SHIPPED_ROOTS, ("Beam.Install",)))


def main():
    failures = violations()
    if failures:
        print("Installation dependencies leaked into core Beam:\n" + "\n".join(failures),
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
