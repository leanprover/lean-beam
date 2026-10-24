#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Require successful selected CI jobs before reporting the merge gate as passed."""

import json
import os
import sys


def failed_jobs(results, optional_mac):
    if not isinstance(results, dict) or not results:
        raise ValueError("required CI results are missing")
    failures = {}
    for name, job in results.items():
        if not isinstance(job, dict):
            raise ValueError(f"invalid result for CI job {name}")
        allowed = {"success"}
        if name == "macos-platform" and optional_mac:
            allowed.add("skipped")
        if job.get("result") not in allowed:
            failures[name] = job.get("result")
    return failures


def main():
    try:
        results = json.loads(os.environ["JOB_RESULTS"])
        optional_mac = (os.environ.get("FULL_MACOS") == "true"
                        or os.environ.get("MACOS_PROFILE") == "skip")
        failures = failed_jobs(results, optional_mac)
    except (KeyError, TypeError, ValueError) as error:
        print(f"Cannot establish CI success: {error}", file=sys.stderr)
        return 1
    if failures:
        print(f"Required CI did not pass: {failures}", file=sys.stderr)
        return 1
    print("All selected CI coverage passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
