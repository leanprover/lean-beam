#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh

if [ "$#" -gt 2 ]; then
  echo "usage: bash tests/test-beam-nightly.sh [leanprover/lean4-nightly:nightly-YYYY-MM-DD] [report-dir]" >&2
  exit 2
fi
BEAM_TEST_SUITE=beam-nightly
report_dir="${2:-build/nightly-validation}"
mkdir -p "$report_dir"
report_dir="$(cd "$report_dir" && pwd)"
# These files belong to this lane. A failed rerun must not retain older evidence.
for report_file in result.txt toolchain.txt metadata.json release.json source-files \
    install.log clone.log native.log; do
  rm -f -- "$report_dir/$report_file"
done
printf 'running\n' > "$report_dir/result.txt"
test_root=""
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'failed\n' > "$report_dir/result.txt"
  fi
  if [ -n "$test_root" ]; then
    case "$test_root" in
      "${TMPDIR:-/tmp}"/beam-nightly-*) rm -rf -- "$test_root" ;;
      *) echo "refusing to clean unexpected nightly test root: $test_root" >&2 ;;
    esac
  fi
  return "$rc"
}
trap cleanup EXIT

# Resolve once. Never keep a mutable `nightly` alias in the test checkout or its report.
toolchain="$(python3 - "${1:-}" "$report_dir" <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys
import urllib.request

toolchain = sys.argv[1]
report = pathlib.Path(sys.argv[2])
if not toolchain:
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "lean-beam-nightly-validation"}
    if os.environ.get("GH_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GH_TOKEN"]
    request = urllib.request.Request(
        "https://api.github.com/repos/leanprover/lean4-nightly/releases?per_page=5", headers=headers
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        releases = json.load(response)
    releases = [r for r in releases if not r["draft"] and
                re.fullmatch(r"nightly-\d{4}-\d{2}-\d{2}", r["tag_name"])]
    if not releases:
        raise SystemExit("no published dated Lean nightly release found")
    release = max(releases, key=lambda r: r["published_at"])
    (report / "release.json").write_text(json.dumps(release, indent=2) + "\n")
    toolchain = "leanprover/lean4-nightly:" + release["tag_name"]
match = re.fullmatch(r"leanprover/lean4-nightly:nightly-(\d{4}-\d{2}-\d{2})", toolchain)
if not match:
    raise SystemExit("expected an immutable leanprover/lean4-nightly:nightly-YYYY-MM-DD toolchain")
try:
    datetime.date.fromisoformat(match[1])
except ValueError:
    raise SystemExit("invalid nightly release date") from None
(report / "toolchain.txt").write_text(toolchain + "\n")
print(toolchain)
PY
)"

# Keep installed compilers, but never change the caller's Elan settings.
host_elan_home="${ELAN_HOME:-$HOME/.elan}"
source_root="$PWD"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/beam-nightly-XXXXXX")"
test_checkout="$test_root/checkout"
export ELAN_HOME="$test_root/elan"
mkdir -p "$ELAN_HOME"
if [ -d "$host_elan_home/toolchains" ]; then
  ln -s "$(cd "$host_elan_home/toolchains" && pwd -P)" "$ELAN_HOME/toolchains"
fi
# Resolve the SDK without inheriting a different compiler selection or sysroot.
unset ELAN_TOOLCHAIN LEAN_SYSROOT LAKE_CACHE_DIR

run_logged() {
  local name="$1"
  shift
  local rc=0
  "$@" > "$report_dir/$name.log" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    tail -n 120 "$report_dir/$name.log" >&2
  fi
  return "$rc"
}

install_toolchain() {
  local installed
  installed="$(elan toolchain list)" || return "$?"
  if printf '%s\n' "$installed" | awk -v target="$toolchain" \
      '$1 == target { found = 1 } END { exit !found }'; then
    return 0
  fi
  elan toolchain install "$toolchain"
}
run_step "install $toolchain" run_logged install install_toolchain
lean_prefix="$(elan run "$toolchain" lean --print-prefix)"

run_step "clone test checkout" run_logged clone git clone --quiet --local --no-hardlinks "$source_root" "$test_checkout"
# Include uncommitted source edits when reproducing the CI lane locally. Ignored build outputs,
# caches, and worktrees are excluded by Git's source-file inventory; deletions are mirrored too.
python3 - "$test_checkout" "$report_dir/source-files" <<'PY'
import os
from pathlib import Path
import subprocess
import sys

checkout, manifest = map(Path, sys.argv[1:])
for raw in subprocess.check_output(["git", "ls-tree", "-rz", "--name-only", "HEAD"]).split(b"\0"):
    if raw and not os.path.lexists(os.fsdecode(raw)):
        (checkout / os.fsdecode(raw)).unlink(missing_ok=True)
files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"])
manifest.write_bytes(b"".join(raw + b"\0" for raw in files.split(b"\0")
                             if raw and os.path.lexists(os.fsdecode(raw))))
PY
rsync -a --from0 --files-from="$report_dir/source-files" "$source_root/" "$test_checkout/"

python3 - "$source_root" "$toolchain" "$lean_prefix" "$report_dir" <<'PY'
import datetime
import json
import pathlib
import platform
import subprocess
import sys

source, toolchain, prefix, report = sys.argv[1:]
prefix = pathlib.Path(prefix).resolve(strict=True)
def capture(args):
    return subprocess.check_output(args, cwd=source, text=True).strip()
lean_version = capture([prefix / "bin/lean", "--version"])
if toolchain.split(":", 1)[1] not in lean_version:
    raise SystemExit(f"nightly toolchain name/version mismatch: {toolchain}: {lean_version}")
metadata = {
    "beam_commit": capture(["git", "rev-parse", "HEAD"]),
    "source_dirty": bool(capture(["git", "status", "--porcelain"])),
    "toolchain": toolchain,
    "lean_prefix": str(prefix),
    "lean_version": lean_version,
    "lean_githash": capture([prefix / "bin/lean", "--githash"]),
    "lake_version": capture([prefix / "bin/lake", "--version"]),
    "platform": platform.platform(),
    "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
(pathlib.Path(report) / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
PY

cd "$test_checkout"
run_step "qualify nightly toolchain distribution" run_logged native \
  python3 tests/test-native-toolchain.py "$lean_prefix"
printf 'passed\n' > "$report_dir/result.txt"
printf 'nightly toolchain qualification passed: %s\nreport: %s\n' "$toolchain" "$report_dir"
