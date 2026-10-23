#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Select skipped, representative PR, or exhaustive macOS coverage from verified changes."""

from enum import Enum
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT_DOCUMENTS = {"AGENTS.md", "CHANGELOG.md", "CONTRIBUTING.md", "README.md"}
ROOT_SOURCES = {"lean-toolchain", "validated-lean-toolchains", "compatible-lean-release-lines",
                "lake-manifest.json", "lakefile.toml"}


class Profile(Enum):
    SKIP = "skip"
    PLATFORM = "platform"
    FULL = "full"


def git(repo, *arguments):
    return subprocess.run(["git", *arguments], cwd=repo, check=True, capture_output=True,
                          timeout=15).stdout


def ordinary_path(path):
    parts = path.split("/")
    return (all(part not in {"", ".", ".."} for part in parts)
            and not any(ord(character) < 32 for character in path))


def documentation_path(path):
    return (path.endswith(".md")
            and (path in ROOT_DOCUMENTS or path.startswith(("docs/", "skills/lean-beam/"))))


def source_path(path):
    return (path.startswith(("Beam/", "BeamTest/", "native/", "scripts/"))
            or ("/" not in path and path.endswith(".lean")))


def exhaustive_path(path):
    return (path in ROOT_SOURCES or path == "lakefile.lean"
            or (path.startswith("scripts/") and path.endswith(".cmake"))
            or path.startswith((".github/", "tests/", "scripts/ci-", "scripts/check-",
                                "scripts/lint-", "scripts/validate-", "scripts/codex-",
                                "scripts/extended-ci.py", "scripts/pr-message.sh")))


def classify_macos(repo, event_name, event, merge):
    if event_name != "pull_request":
        return Profile.FULL, "main, manual, and other events retain exhaustive coverage"
    try:
        pr = event["pull_request"]
        base, head = pr["base"]["sha"], pr["head"]["sha"]
        if not all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                   for sha in (base, head, merge)):
            return Profile.FULL, "unverified PR revisions"
        if git(repo, "rev-parse", "HEAD").decode().strip() != merge:
            return Profile.FULL, "checkout differs from the PR merge"
        if git(repo, "show", "-s", "--format=%P", "HEAD").decode().split() != [base, head]:
            return Profile.FULL, "PR merge parents could not be verified"
        # Compare the actual tested merge tree with its base. Disable rename detection so
        # both sides of a rename must qualify, including source renamed to Markdown.
        raw = git(repo, "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                  "--raw", "-z", base, merge, "--")
        if not raw or not raw.endswith(b"\0"):
            return Profile.FULL, "no complete nonempty change list"
        records = raw[:-1].split(b"\0")
        if len(records) % 2:
            return Profile.FULL, "unrecognized change list"
        documents_only = True
        for index in range(0, len(records), 2):
            header = records[index].split()
            if (len(header) != 5 or header[0] not in {b":000000", b":100644", b":100755"}
                    or header[1] not in {b"000000", b"100644", b"100755"}
                    or header[4] not in {b"A", b"D", b"M"}):
                return Profile.FULL, "unrecognized file kinds or change status"
            before, after = header[0][1:], header[1]
            if before != b"000000" and after != b"000000" and before != after:
                return Profile.FULL, "file mode changes require exhaustive coverage"
            path = records[index + 1].decode("utf-8")
            if not ordinary_path(path):
                return Profile.FULL, "unrecognized path spelling"
            if exhaustive_path(path):
                return Profile.FULL, "CI and test driver changes retain exhaustive coverage"
            if documentation_path(path):
                if b"100755" in {before, after}:
                    return Profile.FULL, "executable documentation requires exhaustive coverage"
            elif source_path(path):
                documents_only = False
            else:
                return Profile.FULL, "unknown paths retain exhaustive coverage"
        if documents_only:
            return Profile.SKIP, "verified regular Markdown documentation changes only"
        return Profile.PLATFORM, "verified source PR uses representative macOS platform coverage"
    except (KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError):
        return Profile.FULL, "PR metadata or Git comparison could not be verified"


def main():
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        # PR creation events can precede GitHub computing merge_commit_sha. The runner's
        # GITHUB_SHA names the tested merge; verify its parents against the event instead.
        profile, reason = classify_macos(Path(__file__).resolve().parent.parent,
                                        os.environ.get("GITHUB_EVENT_NAME"), event,
                                        os.environ.get("GITHUB_SHA"))
    except (KeyError, OSError, ValueError):
        profile, reason = Profile.FULL, "event metadata could not be read"
    print(f"profile={profile.value}")
    print(f"macOS coverage ({profile.value}): {reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
