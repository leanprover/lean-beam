#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Keep the always-loaded skill body and each on-demand reference file concise."""

from pathlib import Path
import sys


REPO = Path(__file__).resolve().parents[1]
SKILL_DIR = REPO / "skills" / "lean-beam"
SKILL = SKILL_DIR / "SKILL.md"
REFERENCES_DIR = SKILL_DIR / "references"
# Agents load the whole body whenever the skill triggers. Raising this needs a reason; prefer
# moving detail to focused files under skills/lean-beam/references/ instead.
SKILL_BUDGET_BYTES = 5_000
# Keep individual on-demand references bounded so opening one topic does not bloat session context.
REFERENCE_BUDGET_BYTES = 16_000


def main() -> int:
    failed = False
    size = len(SKILL.read_bytes())
    if size > SKILL_BUDGET_BYTES:
        print(
            f"{SKILL.relative_to(REPO)} is {size} bytes, over its {SKILL_BUDGET_BYTES}-byte budget; "
            "move detail into skills/lean-beam/references/",
            file=sys.stderr,
        )
        failed = True
    for ref in sorted(REFERENCES_DIR.glob("*.md")):
        ref_size = len(ref.read_bytes())
        if ref_size > REFERENCE_BUDGET_BYTES:
            print(
                f"{ref.relative_to(REPO)} is {ref_size} bytes, over its {REFERENCE_BUDGET_BYTES}-byte budget; "
                "split or tighten the reference",
                file=sys.stderr,
            )
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
