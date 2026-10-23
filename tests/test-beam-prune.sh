#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh
# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh
# shellcheck source=scripts/shared-lib.sh
. scripts/shared-lib.sh

tmp_root="$(mktemp -d /tmp/beam-prune-XXXXXX)"
install_root="$tmp_root/install-root"
versions_root="$install_root/versions"
current_runtime="$versions_root/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
old_runtime="$versions_root/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
uninstalled_runtime="$tmp_root/uninstalled-runtime"
beam_cli="$PWD/.lake/build/bin/beam-cli"
race_pid=""
lock_writer_pid=""

cleanup() {
  chmod u+w "$install_root" 2>/dev/null || true
  if [ -n "$race_pid" ]; then
    kill "$race_pid" > /dev/null 2>&1 || true
    wait "$race_pid" 2>/dev/null || true
  fi
  if [ -n "$lock_writer_pid" ]; then
    kill "$lock_writer_pid" > /dev/null 2>&1 || true
    wait "$lock_writer_pid" 2>/dev/null || true
  fi
  beam_test_remove_owned_tmp_tree "$tmp_root" beam-prune
}
trap cleanup EXIT

if [ ! -x "$beam_cli" ]; then
  lake build beam-cli
fi

write_runtime_manifest() {
  local payload="$1"
  local path="$2"
  local schema="${3:-4}"
  python3 - "$payload" "$path" "$schema" <<'PYFIXTURE'
import json,sys
payload,path,schema=sys.argv[1:]
paths=['libexec/beam-cli','libexec/lean-beam-mcp','runtimes/0/daemon','runtimes/0/plugin','LICENSE']
json.dump({'schemaVersion':int(schema),'payloadHash':payload,'sourceCommit':None,
 'components':{'frontends':{'cli':paths[0],'mcp':paths[1],'compilerRevision':'a'*40},'license':'LICENSE','targets':[
 {'lean':'/fixture/lean/bin/lean','daemon':paths[2],'plugin':paths[3], 'toolchain':'fixture-toolchain',
 'compilerRevision':'a'*40,'leanVersion':'fixture-lean','lakeVersion':'fixture-lake'}]},
 'artifacts':[{'source':p,'destination':p,'hash':'0'*64} for p in paths]},open(path,'w'))
PYFIXTURE
}

mixed_runtime_state() {
  python3 - "$install_root" "$current_runtime" "$old_runtime" "$1" <<'PYSTATE'
import hashlib
import json
import os
from pathlib import Path
import sys

root, current, old, unsupported = map(Path, sys.argv[1:])
files = [root / '.lean-beam-install-root', current / 'manifest.json',
         current / 'bin/lean-beam', current / 'libexec/beam-cli',
         old / 'manifest.json', old / 'libexec/beam-cli',
         unsupported / 'manifest.json', unsupported / 'retained.txt']
print(json.dumps({
    'current': os.readlink(root / 'current'),
    'files': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in files},
    'members': sorted(str(path) for runtime in [current, old, unsupported]
                      for path in runtime.rglob('*')),
}, sort_keys=True))
PYSTATE
}

write_lock_owner() {
  local lock_dir="$1"
  local pid="$2"
  printf '%s\n' "$pid" >"$lock_dir/pid"
}

assert_lock_timeout() {
  local path="$1"
  assert_contains_literal "$path" 'timed out after '
  assert_contains_literal "$path" ' ms waiting for Beam lock'
  assert_contains_literal "$path" 'timeout: 1000 ms'
}

mkdir -p \
  "$uninstalled_runtime/libexec" \
  "$current_runtime/bin" \
  "$current_runtime/libexec" \
  "$old_runtime/libexec"

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$install_root" >"$install_root/.lean-beam-install-root"
write_runtime_manifest aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$current_runtime/manifest.json"
write_runtime_manifest bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$old_runtime/manifest.json"
cp scripts/lean-beam "$current_runtime/bin/lean-beam"
cp "$beam_cli" "$uninstalled_runtime/libexec/beam-cli"
cp "$beam_cli" "$current_runtime/libexec/beam-cli"
cp "$beam_cli" "$old_runtime/libexec/beam-cli"
python3 - "$PWD" "$uninstalled_runtime" "$current_runtime" "$old_runtime" <<'PYLIBRARIES'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
source = Path(sys.argv[1])
libraries = json.loads(subprocess.check_output(
    ['lake', 'script', 'run', 'beamSharedRuntimeFiles'], cwd=source, text=True))
for directory in map(Path, sys.argv[2:]):
    executable = directory / 'libexec/beam-cli'
    assert not executable.is_symlink() and executable.stat().st_nlink == 1, executable
    for library in libraries:
        relative = Path('libexec') / Path(library).name if os.name == 'nt' else Path(library)
        destination = directory / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / '.lake/build' / library, destination)
PYLIBRARIES
# Darwin can identify a cache-linked build executable by its cache pathname,
# breaking its relative library lookup. Launch an independent copy with matching libraries.
beam_cli="$uninstalled_runtime/libexec/beam-cli"
ln -s "$current_runtime" "$install_root/current"

resolved_current_runtime="$(beam_test_realpath "$current_runtime")"
resolved_old_runtime="$(beam_test_realpath "$old_runtime")"
help_out="$("$beam_cli" prune --help)"
assert_output_contains "prune help" "$help_out" 'usage: lean-beam prune [--apply]'
assert_output_contains "prune help" "$help_out" 'remove the displayed paths'
assert_output_contains "prune help" "$help_out" \
  'Apply removes one validated path at a time and reports each successful removal immediately.'

uninstalled_err="$tmp_root/uninstalled.err"
if "$beam_cli" prune > /dev/null 2>"$uninstalled_err"; then
  echo "expected uninstalled prune to fail" >&2
  exit 1
fi
assert_contains_literal "$uninstalled_err" 'prune is only available from an installed Beam runtime'

unknown_err="$tmp_root/unknown.err"
if "$install_root/current/bin/lean-beam" prune --unknown > /dev/null 2>"$unknown_err"; then
  echo "expected unknown prune option to fail" >&2
  exit 1
fi
assert_contains_literal "$unknown_err" 'usage: lean-beam prune [--apply]'
assert_contains_literal "$unknown_err" 'unknown prune option: --unknown'

noncurrent_err="$tmp_root/noncurrent.err"
if "$old_runtime/libexec/beam-cli" prune > /dev/null 2>"$noncurrent_err"; then
  echo "expected prune from a non-current runtime to fail" >&2
  exit 1
fi
assert_contains_literal "$noncurrent_err" 'refusing to prune from a non-current Beam runtime'

ln -s "$current_runtime" "$versions_root/current-alias"
current_alias_err="$tmp_root/current-alias.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$current_alias_err"; then
  echo "expected prune to reject a symlink alias to the current runtime" >&2
  exit 1
fi
assert_contains_literal "$current_alias_err" 'refusing to prune symlinked runtime path'
rm -f "$versions_root/current-alias"

dry_run_out="$("$install_root/current/bin/lean-beam" prune)"
assert_output_contains "prune dry run" "$dry_run_out" 'Beam install prune (dry run)'
assert_output_contains "prune dry run" "$dry_run_out" "current runtime: $resolved_current_runtime"
assert_output_contains "prune dry run" "$dry_run_out" "old runtime: $resolved_old_runtime"
assert_output_contains "prune dry run" "$dry_run_out" 'old runtimes: 1'
assert_output_contains "prune dry run" "$dry_run_out" \
  'restart active agents and MCP clients before applying this cleanup'
# shellcheck disable=SC2016
assert_output_contains "prune dry run" "$dry_run_out" \
  'dry run only; rerun `lean-beam prune --apply` to remove these paths'
assert_file "$old_runtime/manifest.json"

# Unsupported schema headers model retained generations; they are never decoded or executed.
# Keep the valid old generation sorted before the remnant, to catch partial removal on refusal.
retired_root="$tmp_root/manually-retired"
mkdir "$retired_root"
for schema in 2 3; do
  unsupported_payload="$(printf 'c%063d' "$schema")"
  unsupported_runtime="$versions_root/$unsupported_payload"
  mkdir "$unsupported_runtime"
  write_runtime_manifest "$unsupported_payload" "$unsupported_runtime/manifest.json" "$schema"
  printf 'retained schema %s\n' "$schema" > "$unsupported_runtime/retained.txt"
  resolved_unsupported_runtime="$(beam_test_realpath "$unsupported_runtime")"
  mixed_before="$(mixed_runtime_state "$unsupported_runtime")"
  for operation in preview apply; do
    mixed_args=()
    if [ "$operation" = apply ]; then
      mixed_args+=(--apply)
    fi
    mixed_out="$tmp_root/schema-$schema-$operation.out"
    mixed_err="$tmp_root/schema-$schema-$operation.err"
    if "$install_root/current/bin/lean-beam" prune ${mixed_args[@]+"${mixed_args[@]}"} \
        >"$mixed_out" 2>"$mixed_err"; then
      echo "expected mixed schema-$schema $operation to refuse the whole prune plan" >&2
      exit 1
    fi
    assert_contains_literal "$mixed_err" \
      "refusing to prune runtime with invalid manifest: $resolved_unsupported_runtime/manifest.json"
    assert_contains_literal "$mixed_err" "unsupported install manifest schemaVersion $schema"
    assert_contains_literal "$mixed_err" "review runtime: $resolved_unsupported_runtime"
    assert_contains_literal "$mixed_err" 'stop all its users'
    # shellcheck disable=SC2016
    assert_contains_literal "$mixed_err" 'rerun `lean-beam prune`'
    assert_contains_literal "$mixed_err" 'unknown ownership'
    assert_not_contains "$mixed_out" 'Beam install prune'
    assert_not_contains "$mixed_out" 'removed runtime'
    if [ "$(mixed_runtime_state "$unsupported_runtime")" != "$mixed_before" ]; then
      echo "mixed schema-$schema $operation changed retained runtime state" >&2
      exit 1
    fi
    assert_not_exists "$install_root/.install-lock"
  done
  # This owned fixture has no live users; model an operator moving only the known old remnant.
  mv "$unsupported_runtime" "$retired_root/$unsupported_payload"
  recovered_preview="$("$install_root/current/bin/lean-beam" prune)"
  assert_output_contains "schema-$schema recovery" "$recovered_preview" \
    "old runtime: $resolved_old_runtime"
  assert_output_contains "schema-$schema recovery" "$recovered_preview" 'old runtimes: 1'
  assert_output_not_contains "schema-$schema recovery" "$recovered_preview" \
    "old runtime: $resolved_current_runtime"
done

permission_lock_err="$tmp_root/permission-lock.err"
chmod u-w "$install_root"
set +e
"$current_runtime/libexec/beam-cli" prune \
  > /dev/null 2>"$permission_lock_err"
permission_lock_status="$?"
set -e
chmod u+w "$install_root"
if [ "$permission_lock_status" -eq 0 ]; then
  echo "expected prune to report an install-lock creation error" >&2
  exit 1
fi
assert_contains_literal "$permission_lock_err" '.install-lock'
assert_not_contains "$permission_lock_err" 'timed out after'

race_lock="$install_root/.install-lock"
race_lock_held="$tmp_root/race-lock-held"
race_lock_release="$tmp_root/race-lock-release"
race_err="$tmp_root/race.err"
(
  mkdir "$race_lock"
  touch "$race_lock_held"
  while [ ! -e "$race_lock_release" ]; do
    sleep 0.05
  done
  rm -f "$race_lock/pid"
  rmdir "$race_lock"
) &
lock_writer_pid="$!"
wait_for_file "$race_lock_held" "prune install-lock holder" 10
write_lock_owner "$race_lock" "$lock_writer_pid"
"$current_runtime/libexec/beam-cli" prune --apply > /dev/null 2>"$race_err" &
race_pid="$!"
sleep 0.3
rm -f "$install_root/current"
ln -s "$old_runtime" "$install_root/current"
touch "$race_lock_release"
wait "$lock_writer_pid"
lock_writer_pid=""
set +e
wait "$race_pid"
race_status="$?"
set -e
race_pid=""
if [ "$race_status" -eq 0 ]; then
  echo "expected prune to revalidate the current runtime after acquiring the install lock" >&2
  exit 1
fi
assert_contains_literal "$race_err" 'refusing to prune from a non-current Beam runtime'
assert_file "$old_runtime/manifest.json"
rm -f "$install_root/current"
ln -s "$current_runtime" "$install_root/current"

mkdir "$install_root/.install-lock"
write_lock_owner "$install_root/.install-lock" "$$"
install_lock_err="$tmp_root/install-lock.err"
if "$install_root/current/bin/lean-beam" prune --apply > /dev/null 2>"$install_lock_err"; then
  echo "expected prune to respect the active install lock" >&2
  exit 1
fi
assert_lock_timeout "$install_lock_err"
rm -f "$install_root/.install-lock/pid"
rmdir "$install_root/.install-lock"
assert_file "$old_runtime/manifest.json"

apply_runtime_out="$("$install_root/current/bin/lean-beam" prune --apply)"
assert_output_contains "runtime prune apply" "$apply_runtime_out" 'removed runtimes: 1'
assert_not_exists "$old_runtime"
assert_file "$current_runtime/manifest.json"
for schema in 2 3; do
  unsupported_payload="$(printf 'c%063d' "$schema")"
  assert_file "$retired_root/$unsupported_payload/manifest.json"
  assert_contains_literal "$retired_root/$unsupported_payload/retained.txt" "retained schema $schema"
done

mkdir "$versions_root/unmarked"
unmarked_err="$tmp_root/unmarked.err"
if "$install_root/current/bin/lean-beam" prune --apply > /dev/null 2>"$unmarked_err"; then
  echo "expected prune to reject an unmarked runtime directory" >&2
  exit 1
fi
assert_contains_literal "$unmarked_err" 'refusing to prune unmarked runtime directory'
if [ ! -d "$versions_root/unmarked" ]; then
  echo "expected unmarked runtime directory to remain untouched" >&2
  exit 1
fi
rmdir "$versions_root/unmarked"

invalid_manifest_runtime="$versions_root/invalid-payload"
mkdir "$invalid_manifest_runtime"
write_runtime_manifest invalid-payload "$invalid_manifest_runtime/manifest.json"
python3 - "$invalid_manifest_runtime/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["schemaVersion"] = 1
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
    stream.write("\n")
PY
invalid_manifest_err="$tmp_root/invalid-manifest.err"
if "$install_root/current/bin/lean-beam" prune --apply > /dev/null 2>"$invalid_manifest_err"; then
  echo "expected prune to reject a runtime with an invalid manifest schema" >&2
  exit 1
fi
assert_contains_literal "$invalid_manifest_err" 'refusing to prune runtime with invalid manifest'
assert_file "$invalid_manifest_runtime/manifest.json"
rm -f "$invalid_manifest_runtime/manifest.json"
rmdir "$invalid_manifest_runtime"

symlink_manifest_runtime="$versions_root/symlink-manifest-payload"
symlink_manifest_target="$tmp_root/symlink-manifest-target.json"
mkdir "$symlink_manifest_runtime"
write_runtime_manifest symlink-manifest-payload "$symlink_manifest_target"
ln -s "$symlink_manifest_target" "$symlink_manifest_runtime/manifest.json"
symlink_manifest_err="$tmp_root/symlink-manifest.err"
if "$install_root/current/bin/lean-beam" prune --apply \
    > /dev/null 2>"$symlink_manifest_err"; then
  echo "expected prune to reject a symlinked runtime manifest" >&2
  exit 1
fi
assert_contains_literal "$symlink_manifest_err" \
  'refusing to prune runtime with invalid manifest'
assert_file "$symlink_manifest_target"
rm -f "$symlink_manifest_runtime/manifest.json"
rmdir "$symlink_manifest_runtime"

external_runtime="$tmp_root/external-runtime"
mkdir "$external_runtime"
write_runtime_manifest external-runtime "$external_runtime/manifest.json"
ln -s "$external_runtime" "$versions_root/symlink-payload"
symlink_runtime_err="$tmp_root/symlink-runtime.err"
if "$install_root/current/bin/lean-beam" prune --apply \
    > /dev/null 2>"$symlink_runtime_err"; then
  echo "expected prune to reject a symlinked runtime directory" >&2
  exit 1
fi
assert_contains_literal "$symlink_runtime_err" 'refusing to prune symlinked runtime path'
assert_file "$external_runtime/manifest.json"
rm -f "$versions_root/symlink-payload"

final_out="$("$install_root/current/bin/lean-beam" prune)"
assert_output_contains "final prune dry run" "$final_out" 'old runtimes: 0'

removed_bundles_err="$tmp_root/removed-bundles.err"
if "$install_root/current/bin/lean-beam" prune --apply --bundles > /dev/null 2>"$removed_bundles_err"; then
  echo "expected removed bundle-cache pruning option to fail" >&2
  exit 1
fi
assert_contains_literal "$removed_bundles_err" 'unknown prune option: --bundles'
assert_file "$current_runtime/manifest.json"

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'root=.' >"$install_root/.lean-beam-install-root"
relative_marker_err="$tmp_root/relative-marker.err"
if (
  cd "$install_root"
  "$current_runtime/libexec/beam-cli" prune
) > /dev/null 2>"$relative_marker_err"; then
  echo "expected prune to reject a relative install root marker" >&2
  exit 1
fi
assert_contains_literal "$relative_marker_err" \
  'refusing to prune invalid Beam install root marker'

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'root=' >"$install_root/.lean-beam-install-root"
blank_marker_err="$tmp_root/blank-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$blank_marker_err"; then
  echo "expected prune to reject a blank install root marker" >&2
  exit 1
fi
assert_contains_literal "$blank_marker_err" \
  'refusing to prune install root marker without root'

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$install_root" \
  "root=$install_root" >"$install_root/.lean-beam-install-root"
multiple_marker_err="$tmp_root/multiple-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$multiple_marker_err"; then
  echo "expected prune to reject an install root marker with multiple roots" >&2
  exit 1
fi
assert_contains_literal "$multiple_marker_err" \
  'refusing to prune invalid Beam install root marker'

printf '%s\n' \
  'schema=1' \
  'schema=2' \
  'owner=lean-beam' \
  "root=$install_root" >"$install_root/.lean-beam-install-root"
conflicting_schema_marker_err="$tmp_root/conflicting-schema-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$conflicting_schema_marker_err"; then
  echo "expected prune to reject conflicting install root marker schema fields" >&2
  exit 1
fi
assert_contains_literal "$conflicting_schema_marker_err" \
  'refusing to prune invalid Beam install root marker'

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'owner=other' \
  "root=$install_root" >"$install_root/.lean-beam-install-root"
conflicting_owner_marker_err="$tmp_root/conflicting-owner-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$conflicting_owner_marker_err"; then
  echo "expected prune to reject conflicting install root marker owner fields" >&2
  exit 1
fi
assert_contains_literal "$conflicting_owner_marker_err" \
  'refusing to prune invalid Beam install root marker'

symlink_marker_target="$tmp_root/install-root-marker-target"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$install_root" >"$symlink_marker_target"
rm -f "$install_root/.lean-beam-install-root"
ln -s "$symlink_marker_target" "$install_root/.lean-beam-install-root"
symlink_marker_err="$tmp_root/symlink-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$symlink_marker_err"; then
  echo "expected prune to reject a symlinked install root marker" >&2
  exit 1
fi
assert_contains_literal "$symlink_marker_err" \
  'refusing to prune invalid Beam install root marker'
rm -f "$install_root/.lean-beam-install-root"

ln -s "$tmp_root/missing-install-root-marker-target" \
  "$install_root/.lean-beam-install-root"
broken_symlink_marker_err="$tmp_root/broken-symlink-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$broken_symlink_marker_err"; then
  echo "expected prune to reject a broken symlinked install root marker" >&2
  exit 1
fi
assert_contains_literal "$broken_symlink_marker_err" \
  'refusing to prune invalid Beam install root marker'
rm -f "$install_root/.lean-beam-install-root"

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$tmp_root/not-the-install-root" >"$install_root/.lean-beam-install-root"
mismatched_marker_err="$tmp_root/mismatched-marker.err"
if "$install_root/current/bin/lean-beam" prune > /dev/null 2>"$mismatched_marker_err"; then
  echo "expected prune to reject a mismatched install root marker" >&2
  exit 1
fi
assert_contains_literal "$mismatched_marker_err" \
  'refusing to prune install root with mismatched marker root'

echo "beam install prune tests passed"
