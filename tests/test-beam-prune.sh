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
current_runtime="$versions_root/current-payload"
old_runtime="$versions_root/old-payload"
install_bundle_root="$install_root/state/install-bundles"
bundle_root="$install_bundle_root/linux-test"
current_bundle="$bundle_root/100"
stale_bundle="$bundle_root/200"
incomplete_bundle="$bundle_root/300"
malformed_bundle="$bundle_root/350"
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
  "$beam_cli" install-manifest "$payload" - fixture-toolchain >"$path"
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
  "$current_runtime/bin" \
  "$current_runtime/libexec" \
  "$old_runtime" \
  "$current_bundle" \
  "$stale_bundle" \
  "$incomplete_bundle" \
  "$malformed_bundle"

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$install_root" >"$install_root/.lean-beam-install-root"
write_runtime_manifest current-payload "$current_runtime/manifest.json"
write_runtime_manifest old-payload "$old_runtime/manifest.json"
cp scripts/lean-beam "$current_runtime/bin/lean-beam"
cp "$beam_cli" "$current_runtime/libexec/beam-cli"
mkdir -p "$current_runtime/lib/lean"
while IFS= read -r shared_lib; do
  cp ".lake/build/$(beam_runtime_shared_lib_dir)/$shared_lib" "$current_runtime/lib/lean/$shared_lib"
done < <(beam_runtime_shared_lib_names)
ln -s "$current_runtime" "$install_root/current"

resolved_current_runtime="$(beam_test_realpath "$current_runtime")"
resolved_old_runtime="$(beam_test_realpath "$old_runtime")"
resolved_stale_bundle="$(beam_test_realpath "$stale_bundle")"
resolved_incomplete_bundle="$(beam_test_realpath "$incomplete_bundle")"
resolved_malformed_bundle="$(beam_test_realpath "$malformed_bundle")"

current_version_out="$("$install_root/current/bin/lean-beam" --version)"
assert_output_contains "current installed runtime identity" "$current_version_out" \
  'runtime current: true'
current_link_version_out="$(BEAM_HOME="$install_root/current" "$beam_cli" version)"
assert_output_contains "current installed runtime identity through current link" \
  "$current_link_version_out" 'runtime current: true'
old_version_out="$(BEAM_HOME="$old_runtime" "$beam_cli" version)"
assert_output_contains "old installed runtime identity" "$old_version_out" \
  'runtime current: false'

source_like_runtime="$tmp_root/source-like/versions/checkout"
mkdir -p "$source_like_runtime"
printf '%s\n' '{"payloadHash":"checkout"}' >"$source_like_runtime/manifest.json"
source_like_version_out="$(BEAM_HOME="$source_like_runtime" "$beam_cli" version)"
assert_output_not_contains "source-like runtime identity" "$source_like_version_out" \
  'runtime current:'
assert_output_contains "source-like runtime identity" "$source_like_version_out" \
  'runtime payload: (source tree)'
assert_output_contains "source-like runtime identity" "$source_like_version_out" \
  'manifest: (none)'

# An otherwise empty runtime source tree hashes to the FNV-1a offset basis.
bundle_plugin_name="$(beam_shared_lib_name beam_Beam_LSP)"
write_bundle_artifacts() {
  local bundle_dir="$1"
  local workspace="$bundle_dir/workspace"
  mkdir -p "$workspace/.lake/build/bin" "$workspace/.lake/build/lib"
  : >"$workspace/.lake/build/bin/beam-daemon"
  : >"$workspace/.lake/build/lib/$bundle_plugin_name"
  local shared_lib
  mkdir -p "$workspace/.lake/build/$(beam_runtime_shared_lib_dir)"
  while IFS= read -r shared_lib; do
    : >"$workspace/.lake/build/$(beam_runtime_shared_lib_dir)/$shared_lib"
  done < <(beam_runtime_shared_lib_names)
}
write_complete_bundle() {
  local bundle_dir="$1"
  local source_hash="$2"
  local workspace="$bundle_dir/workspace"
  write_bundle_artifacts "$bundle_dir"
  printf '%s\n' \
    '{' \
    '  "schemaVersion": 2,' \
    '  "toolchain": "fixture-toolchain",' \
    '  "toolchainFingerprint": {' \
    '    "leanVersion": "fixture-lean",' \
    '    "leanPrefix": "/fixture/lean",' \
    '    "leanLibDir": "/fixture/lean/lib",' \
    '    "lakeVersion": "fixture-lake"' \
    '  },' \
    "  \"sourceHash\": \"$source_hash\"," \
    "  \"workspace\": \"$workspace\"," \
    '  "builtAt": "2026-08-05T00:00:00Z"' \
    '}' >"$bundle_dir/metadata.json"
}
write_complete_bundle "$current_bundle" '14695981039346656037'
write_complete_bundle "$stale_bundle" 'stale-source'
write_bundle_artifacts "$malformed_bundle"
printf '%s\n' '{"sourceHash":"14695981039346656037"}' >"$malformed_bundle/metadata.json"

help_out="$(./scripts/lean-beam prune --help)"
assert_output_contains "prune help" "$help_out" 'usage: lean-beam prune [--apply] [--bundles]'
assert_output_contains "prune help" "$help_out" 'remove the displayed paths'
assert_output_contains "prune help" "$help_out" \
  'Apply removes one validated path at a time and reports each successful removal immediately.'

source_wrapper_err="$tmp_root/source-wrapper.err"
if ./scripts/lean-beam prune > /dev/null 2>"$source_wrapper_err"; then
  echo "expected source-checkout prune to fail" >&2
  exit 1
fi
assert_contains_literal "$source_wrapper_err" 'prune is only available from an installed Beam runtime'

unknown_err="$tmp_root/unknown.err"
if "$install_root/current/bin/lean-beam" prune --unknown > /dev/null 2>"$unknown_err"; then
  echo "expected unknown prune option to fail" >&2
  exit 1
fi
assert_contains_literal "$unknown_err" 'usage: lean-beam prune [--apply] [--bundles]'
assert_contains_literal "$unknown_err" 'unknown prune option: --unknown'

noncurrent_err="$tmp_root/noncurrent.err"
if BEAM_HOME="$old_runtime" "$beam_cli" prune > /dev/null 2>"$noncurrent_err"; then
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

dry_run_out="$("$install_root/current/bin/lean-beam" prune --bundles)"
assert_output_contains "prune dry run" "$dry_run_out" 'Beam install prune (dry run)'
assert_output_contains "prune dry run" "$dry_run_out" "current runtime: $resolved_current_runtime"
assert_output_contains "prune dry run" "$dry_run_out" "old runtime: $resolved_old_runtime"
assert_output_contains "prune dry run" "$dry_run_out" 'old runtimes: 1'
assert_output_contains "prune dry run" "$dry_run_out" "stale bundle: $resolved_stale_bundle"
assert_output_contains "prune dry run" "$dry_run_out" "stale bundle: $resolved_incomplete_bundle"
assert_output_contains "prune dry run" "$dry_run_out" "stale bundle: $resolved_malformed_bundle"
assert_output_contains "prune dry run" "$dry_run_out" 'stale bundles: 3'
assert_output_contains "prune dry run" "$dry_run_out" \
  'restart active agents and MCP clients before applying this cleanup'
# shellcheck disable=SC2016
assert_output_contains "prune dry run" "$dry_run_out" \
  'dry run only; rerun `lean-beam prune --apply --bundles` to remove these paths'
assert_file "$old_runtime/manifest.json"
assert_file "$current_bundle/metadata.json"
assert_file "$stale_bundle/metadata.json"

permission_lock_err="$tmp_root/permission-lock.err"
chmod u-w "$install_root"
set +e
BEAM_HOME="$current_runtime" "$beam_cli" prune \
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
BEAM_HOME="$current_runtime" "$beam_cli" prune --apply > /dev/null 2>"$race_err" &
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
assert_file "$current_bundle/metadata.json"
assert_file "$stale_bundle/metadata.json"

partial_runtime="$versions_root/partial-payload"
mkdir "$partial_runtime"
write_runtime_manifest partial-payload "$partial_runtime/manifest.json"
python3 - "$partial_runtime/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["schemaVersion"] = 2
manifest["toolchains"] = manifest.pop("createdWithToolchains")
# Recreate the final layout that Beam actually emitted under schema 2.
artifacts = manifest["artifacts"]
artifacts["rootFiles"].insert(2, "lakefile.toml")
artifacts["runtimePaths"].append(".lake/packages")
artifacts["sourceHashInputs"] = artifacts["rootFiles"] + ["Beam/**"]
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
    stream.write("\n")
PY
resolved_partial_runtime="$(beam_test_realpath "$partial_runtime")"

stale_bundle_lock="$bundle_root/.locks/200"
bundle_lock_held="$tmp_root/bundle-lock-held"
bundle_lock_release="$tmp_root/bundle-lock-release"
mkdir -p "$(dirname "$stale_bundle_lock")"
python3 - "$stale_bundle_lock" "$bundle_lock_held" "$bundle_lock_release" <<'PY' &
import fcntl
import pathlib
import sys
import time

lock_path, held_path, release_path = map(pathlib.Path, sys.argv[1:])
with lock_path.open("a", encoding="utf-8") as lock_file:
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    held_path.touch()
    while not release_path.exists():
        time.sleep(0.05)
PY
lock_writer_pid="$!"
wait_for_file "$bundle_lock_held" "prune bundle-lock holder" 10
bundle_lock_out="$tmp_root/bundle-lock.out"
bundle_lock_err="$tmp_root/bundle-lock.err"
if "$install_root/current/bin/lean-beam" prune --apply --bundles \
    >"$bundle_lock_out" 2>"$bundle_lock_err"; then
  echo "expected prune to respect an active bundle lock" >&2
  exit 1
fi
assert_contains_literal "$bundle_lock_out" "removed runtime: $resolved_partial_runtime"
assert_lock_timeout "$bundle_lock_err"
assert_contains_literal "$bundle_lock_err" \
  'prune stopped before completing the displayed plan; any removals reported above were applied'
# shellcheck disable=SC2016
assert_contains_literal "$bundle_lock_err" \
  'rerun `lean-beam prune --bundles` to preview the remaining paths'
assert_not_exists "$partial_runtime"
touch "$bundle_lock_release"
wait "$lock_writer_pid"
lock_writer_pid=""
assert_file "$stale_bundle/metadata.json"

apply_bundle_out="$("$install_root/current/bin/lean-beam" prune --apply --bundles)"
assert_output_contains "bundle prune apply" "$apply_bundle_out" 'removed runtimes: 0'
assert_output_contains "bundle prune apply" "$apply_bundle_out" \
  "removed stale bundle: $resolved_stale_bundle"
assert_output_contains "bundle prune apply" "$apply_bundle_out" \
  "removed stale bundle: $resolved_incomplete_bundle"
assert_output_contains "bundle prune apply" "$apply_bundle_out" \
  "removed stale bundle: $resolved_malformed_bundle"
assert_output_contains "bundle prune apply" "$apply_bundle_out" 'removed stale bundles: 3'
assert_file "$current_bundle/metadata.json"
assert_not_exists "$stale_bundle"
assert_not_exists "$incomplete_bundle"
assert_not_exists "$malformed_bundle"

owned_bundle_root="$install_root/state/owned-install-bundles"
external_bundle_root="$tmp_root/external-install-bundles"
external_stale_bundle="$external_bundle_root/linux-test/500"
mkdir -p "$external_stale_bundle"
printf '%s\n' '{"sourceHash":"stale-source"}' >"$external_stale_bundle/metadata.json"
mv "$install_bundle_root" "$owned_bundle_root"
ln -s "$external_bundle_root" "$install_bundle_root"
symlinked_bundle_root_err="$tmp_root/symlinked-bundle-root.err"
if "$install_root/current/bin/lean-beam" prune --apply --bundles \
    > /dev/null 2>"$symlinked_bundle_root_err"; then
  echo "expected prune to reject a symlinked installed bundle cache root" >&2
  exit 1
fi
assert_contains_literal "$symlinked_bundle_root_err" \
  'refusing to prune symlinked installed bundle cache root'
assert_file "$external_stale_bundle/metadata.json"
rm -f "$install_bundle_root"
mv "$owned_bundle_root" "$install_bundle_root"

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
invalid_manifest_version_out="$(BEAM_HOME="$invalid_manifest_runtime" "$beam_cli" version)"
assert_output_contains "invalid installed runtime identity" "$invalid_manifest_version_out" \
  'runtime payload: invalid-payload'
assert_output_contains "invalid installed runtime identity" "$invalid_manifest_version_out" \
  'runtime current: false'
assert_output_contains "invalid installed runtime identity" "$invalid_manifest_version_out" \
  'runtime error: invalid install manifest:'
assert_output_not_contains "invalid installed runtime identity" "$invalid_manifest_version_out" \
  'runtime payload: (source tree)'
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

external_bundle="$tmp_root/external-bundle"
mkdir "$external_bundle"
printf '%s\n' '{"sourceHash":"stale-source"}' >"$external_bundle/metadata.json"
ln -s "$external_bundle" "$bundle_root/400"

final_out="$("$install_root/current/bin/lean-beam" prune --bundles)"
assert_output_contains "final prune dry run" "$final_out" 'old runtimes: 0'
assert_output_contains "final prune dry run" "$final_out" 'stale bundles: 0'
if [ ! -L "$bundle_root/400" ]; then
  echo "expected symlinked bundle directory to remain untouched" >&2
  exit 1
fi
assert_file "$external_bundle/metadata.json"

printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'root=.' >"$install_root/.lean-beam-install-root"
relative_marker_version_out="$(
  cd "$install_root"
  BEAM_HOME="$current_runtime" "$beam_cli" version
)"
assert_output_contains "relative install marker identity" "$relative_marker_version_out" \
  'runtime error: invalid Beam install root marker'
relative_marker_err="$tmp_root/relative-marker.err"
if (
  cd "$install_root"
  BEAM_HOME="$current_runtime" "$beam_cli" prune
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
