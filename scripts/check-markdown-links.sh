#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

python3 - <<'PY'
from pathlib import Path
import html
import re
import subprocess
import sys
from urllib.parse import unquote

repo = Path.cwd()
skill_payload = repo / "skills" / "lean-beam"
md_files = subprocess.check_output(
    ["git", "ls-files", "*.md"],
    cwd=repo,
    text=True,
).splitlines()

link_re = re.compile(r"(?<!!)\[[^\]\n]+\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
scheme_re = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")
failures: list[str] = []
anchor_cache: dict[Path, set[str]] = {}


def heading_slug(heading: str) -> str:
    heading = html.unescape(re.sub(r"<[^>]*>", "", heading)).replace("`", "").lower()
    heading = "".join(
        character
        for character in heading
        if character.isalnum() or character.isspace() or character in "-_"
    )
    return re.sub(r"\s", "-", heading.strip())


def markdown_anchors(path: Path) -> set[str]:
    cached = anchor_cache.get(path)
    if cached is not None:
        return cached

    anchors: set[str] = set()
    slug_counts: dict[str, int] = {}
    fence: tuple[str, int] | None = None
    for line in path.read_text(encoding="utf-8").splitlines():
        fence_match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence_match:
            marker = fence_match.group(1)
            if fence is None:
                fence = (marker[0], len(marker))
            elif marker[0] == fence[0] and len(marker) >= fence[1]:
                fence = None
            continue
        if fence is not None:
            continue

        heading_match = re.match(r"^\s{0,3}#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not heading_match:
            continue
        slug = heading_slug(heading_match.group(1))
        if not slug:
            continue
        count = slug_counts.get(slug, 0)
        anchors.add(slug if count == 0 else f"{slug}-{count}")
        slug_counts[slug] = count + 1

    anchor_cache[path] = anchors
    return anchors

for rel in md_files:
    path = repo / rel
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8")
    for match in link_re.finditer(text):
        raw_target = match.group(1).strip()
        if not raw_target:
            continue
        if raw_target.startswith("<") and raw_target.endswith(">"):
            raw_target = raw_target[1:-1]
        if raw_target.startswith("//") or scheme_re.match(raw_target):
            continue

        target_text, separator, raw_anchor = raw_target.partition("#")
        target = unquote(target_text.split("?", 1)[0])

        if not target:
            dest = path
        elif target.startswith("/"):
            dest = repo / target.lstrip("/")
        else:
            dest = path.parent / target
        dest = dest.resolve(strict=False)

        if path.is_relative_to(skill_payload) and (
            target.startswith("/") or not dest.is_relative_to(skill_payload)
        ):
            failures.append(f"{rel}: link leaves installed skill payload: {raw_target}")
            continue

        try:
            dest.relative_to(repo)
        except ValueError:
            failures.append(f"{rel}: link leaves repository: {raw_target}")
            continue

        if not dest.exists():
            failures.append(f"{rel}: missing link target: {raw_target}")
            continue

        if separator and raw_anchor and dest.suffix.lower() == ".md":
            anchor = unquote(raw_anchor)
            if anchor not in markdown_anchors(dest):
                failures.append(f"{rel}: missing markdown anchor: {raw_target}")

if failures:
    for failure in failures:
        print(failure, file=sys.stderr)
    sys.exit(1)
PY
