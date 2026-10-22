#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Keep the always-loaded skill body small; detail belongs in its on-demand references."""

from pathlib import Path
import sys


REPO = Path(__file__).resolve().parents[1]
SKILL = REPO / "skills" / "lean-beam" / "SKILL.md"
# Agents load the whole body whenever the skill triggers. Raising this needs a reason; prefer
# moving detail to skills/lean-beam/references/ instead.
SKILL_BUDGET_BYTES = 10_000


def main() -> int:
    size = len(SKILL.read_bytes())
    if size > SKILL_BUDGET_BYTES:
        print(
            f"{SKILL.relative_to(REPO)} is {size} bytes, over its {SKILL_BUDGET_BYTES}-byte budget; "
            "move detail into skills/lean-beam/references/",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
