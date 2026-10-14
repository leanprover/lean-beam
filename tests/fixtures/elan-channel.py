#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

"""Controlled channel metadata; concrete toolchain commands use the real Elan."""

import json
import os
from pathlib import Path
import sys


args = sys.argv[1:]
real_elan = os.environ["BEAM_TEST_REAL_ELAN"]
selector = "leanprover/lean4:stable"
with Path(os.environ["BEAM_TEST_ELAN_LOG"]).open("a", encoding="utf-8") as log:
    log.write(json.dumps({"args": args, "selector": os.environ.get("ELAN_TOOLCHAIN")}) + "\n")

if args and args[0] == "dump-state":
    offline = args == ["dump-state", "--no-net"]
    if not offline and (args != ["dump-state"] or os.environ.get("ELAN_TOOLCHAIN") != selector):
        sys.exit("channel resolution did not pin the captured selector")
    mode = os.environ["BEAM_TEST_CHANNEL_MODE"]
    current = os.environ["BEAM_TEST_CURRENT_TOOLCHAIN"]
    cached = os.environ["BEAM_TEST_CACHED_TOOLCHAIN"]
    marker = Path(os.environ["BEAM_TEST_CHANNEL_MOVED"])
    if offline or mode in {"fallback", "unavailable"}:
        live = {"Err": "network unavailable"}
    else:
        # A second resolution would observe a different release.
        live = {"Ok": cached if marker.exists() else current}
        marker.write_text("moved", encoding="utf-8")
    if mode == "unavailable":
        cached = None
    elif mode == "unsupported" and not offline:
        live = {"Ok": "leanprover/lean4:v9.99.0"}
    print(json.dumps({"toolchains": {
        "active_override": {"unresolved": {"Remote": {
            "origin": "leanprover/lean4", "release": "stable", "from_channel": "stable",
        }}},
        "resolved_active": {"live": live, "cached": cached},
    }}))
    sys.exit(0)

if args[:1] == ["run"] and args[1].split(":")[-1] == "stable":
    sys.exit("runtime construction re-resolved the moving channel")
os.execv(real_elan, [real_elan, *args])
