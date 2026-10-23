#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Retain macOS CI unless a verified PR merge changes only regular Markdown documentation."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT_DOCUMENTS = {"AGENTS.md", "CHANGELOG.md", "CONTRIBUTING.md", "README.md"}


def git(repo, *arguments):
    return subprocess.run(["git", *arguments], cwd=repo, check=True, capture_output=True,
                          timeout=15).stdout


def documentation_path(path):
    parts = path.split("/")
    return (all(part not in {"", ".", ".."} for part in parts)
            and not any(ord(character) < 32 for character in path)
            and path.endswith(".md")
            and (path in ROOT_DOCUMENTS or path.startswith(("docs/", "skills/lean-beam/"))))


def requires_macos(repo, event_name, event):
    if event_name != "pull_request":
        return True, "main, manual, and other events retain coverage"
    try:
        pr = event["pull_request"]
        base, head, merge = pr["base"]["sha"], pr["head"]["sha"], pr["merge_commit_sha"]
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                   for sha in (base, head, merge)):
            return True, "unverified PR revisions"
        if git(repo, "rev-parse", "HEAD").decode().strip() != merge:
            return True, "checkout differs from the PR merge"
        if git(repo, "show", "-s", "--format=%P", "HEAD").decode().split() != [base, head]:
            return True, "PR merge parents could not be verified"
        # Compare the actual tested merge tree with its base. Disable rename detection so
        # both sides of a rename must qualify, including source renamed to Markdown.
        raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                  "--raw", "-z", base, merge, "--")
        if not raw or not raw.endswith(b"\0"):
            return True, "no complete nonempty change list"
        records = raw[:-1].split(b"\0")
        if len(records) % 2:
            return True, "unrecognized change list"
        for index in range(0, len(records), 2):
            header = records[index].split()
            if (len(header) != 5 or header[0] not in {b":000000", b":100644"}
                    or header[1] not in {b"000000", b"100644"}
                    or header[4] not in {b"A", b"D", b"M"}
                    or not documentation_path(records[index + 1].decode("utf-8"))):
                return True, "changes include source, configuration, unknown paths, or file kinds"
        return False, "verified regular Markdown documentation changes only"
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        return True, "PR metadata or Git comparison could not be verified"


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        required, reason = requires_macos(Path(__file__).resolve().parent.parent,
                                          os.environ.get("GITHUB_EVENT_NAME"), event)
    except (KeyError, OSError, ValueError):
        required, reason = True, "event metadata could not be read"
    print(f"macos={str(required).lower()}")
    print(f"macOS coverage: {reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
