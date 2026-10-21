#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
. scripts/shared-lib.sh
# shellcheck source=tests/lib/assertions.sh
. tests/lib/assertions.sh
# shellcheck source=tests/lib/ci-steps.sh
. tests/lib/ci-steps.sh
# shellcheck source=tests/lib/install-fixtures.sh
. tests/lib/install-fixtures.sh
# shellcheck source=tests/lib/wait.sh
. tests/lib/wait.sh
# shellcheck source=tests/lib/toolchain-registry.sh
. tests/lib/toolchain-registry.sh

BEAM_TEST_SUITE="${BEAM_TEST_SUITE:-install}"
BEAM_INSTALL_TEST_PRESEED_ELAN="${BEAM_INSTALL_TEST_PRESEED_ELAN:-auto}"

if ! validated_registry_entries="$(beam_test_read_registry_entries validated-lean-toolchains)"; then
  echo "failed to read validated Lean toolchain registry" >&2
  exit 1
fi

tmp_root="$(mktemp -d /tmp/beam-install-XXXXXX)"
declare -a installed_owner_pids=()
declare -a installed_owner_roots=()
host_elan_home="${ELAN_HOME:-}"
if [ -z "$host_elan_home" ] && [ -d "$HOME/.elan" ]; then
  host_elan_home="$HOME/.elan"
fi

cleanup() {
  local owner_pid owner_root
  if [ -x "${installed_lean_beam:-}" ]; then
    for owner_root in ${installed_owner_roots[@]+"${installed_owner_roots[@]}"}; do
      "$installed_lean_beam" --root "$owner_root" stop > /dev/null 2>&1 || true
    done
  fi
  for owner_pid in ${installed_owner_pids[@]+"${installed_owner_pids[@]}"}; do
    if kill -0 "$owner_pid" 2>/dev/null; then
      kill -INT "$owner_pid" 2>/dev/null || true
    fi
    wait "$owner_pid" 2>/dev/null || true
  done
  expect_owned_tmp_dir "$tmp_root"
  rm -rf -- "$tmp_root"
}
trap cleanup EXIT

export HOME="$tmp_root/home"
export CODEX_HOME="$tmp_root/codex"
export CLAUDE_HOME="$tmp_root/claude"
export PI_CODING_AGENT_DIR="$tmp_root/pi-agent"
export OPENCODE_CONFIG_DIR="$tmp_root/opencode"
export VIBE_HOME="$tmp_root/vibe"
export BEAM_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$BEAM_INSTALL_ROOT"

run_step "install prune" bash tests/test-beam-prune.sh
run_step "install publication" bash tests/test-install-publication.sh

validated_toolchains=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  validated_toolchains+=("$line")
done <<< "$validated_registry_entries"
toolchain="$(awk 'NR==1 {print $1}' lean-toolchain)"
if [ -z "$toolchain" ]; then
  echo "missing pinned Lean toolchain in lean-toolchain" >&2
  exit 1
fi
if ! printf '%s\n' ${validated_toolchains[@]+"${validated_toolchains[@]}"} | grep -qxF "$toolchain"; then
  echo "pinned Lean toolchain is not in validated-lean-toolchains: $toolchain" >&2
  exit 1
fi
source_checkout="$tmp_root/source-checkout"

assert_doctor_contains() {
  local label="$1"
  local output="$2"
  local expected="$3"
  assert_output_contains "$label doctor output" "$output" "$expected"
}

assert_doctor_not_contains() {
  local label="$1"
  local output="$2"
  local unexpected="$3"
  assert_output_not_contains "$label doctor output" "$output" "$unexpected"
}

assert_symlink_target() {
  local path="$1"
  local expected="$2"
  local actual resolved_expected
  actual="$(beam_test_realpath "$path")"
  resolved_expected="$(beam_test_realpath "$expected")"
  if [ "$actual" != "$resolved_expected" ]; then
    echo "unexpected symlink target for $path: expected $resolved_expected, got $actual" >&2
    exit 1
  fi
}

assert_runtime_layout() {
  local runtime_root="$1"
  assert_file "$runtime_root/LICENSE"
  for source in Beam.lean Beam lakefile.lean lake-manifest.json lean-toolchain \
      validated-lean-toolchains compatible-lean-release-lines custom-lean-toolchains; do
    assert_not_exists "$runtime_root/$source"
  done
  assert_file "$runtime_root/libexec/beam-cli"
  assert_not_exists "$runtime_root/libexec/beam-daemon"
  assert_not_exists "$runtime_root/libexec/beam-client"
  assert_file "$runtime_root/libexec/lean-beam-mcp"
  assert_not_exists "$runtime_root/.lake/build"
  assert_file "$runtime_root/bin/lean-beam"
  assert_file "$runtime_root/bin/lean-beam-search"
  assert_file "$runtime_root/bin/lean-beam-mcp"
  assert_not_exists "$runtime_root/bin/beam"
  assert_not_exists "$runtime_root/bin/beam-lean-search"
}

assert_manifest_metadata() {
  local manifest_path="$1"
  local expected_payload="$2"
  local expected_source_commit="$3"
  shift 3
  python3 - "$manifest_path" "$expected_payload" "$expected_source_commit" "$@" <<'PY'
import json
import os
import sys

manifest_path, expected_payload, expected_source_commit, *expected_toolchains = sys.argv[1:]
with open(manifest_path, "r", encoding="utf-8") as f:
    manifest = json.load(f)
layout = json.loads(os.environ["BEAM_INSTALL_LAYOUT_JSON"])

if manifest.get("schemaVersion") != 4:
    raise SystemExit(f"unexpected manifest schemaVersion: {manifest.get('schemaVersion')}")
if manifest.get("payloadHash") != expected_payload:
    raise SystemExit("unexpected installation generation")
if manifest.get("sourceCommit") != (expected_source_commit or None):
    raise SystemExit("unexpected source revision")
if any(key in manifest for key in ['createdWithToolchains','toolchains','toolchain']):
    raise SystemExit("manifest contains an obsolete selection/provenance list")
components = manifest['components']
if [target['toolchain'] for target in components['targets']] != expected_toolchains:
    raise SystemExit("manifest does not name the constructed target set")
artifacts = manifest['artifacts']
if not isinstance(artifacts, list):
    raise SystemExit("missing artifact inventory")
by_path = {entry['destination']:entry for entry in artifacts}
if len(by_path) != len(artifacts):
    raise SystemExit("duplicate artifact paths")
import hashlib
runtime_root = os.path.dirname(manifest_path)
for relative, entry in by_path.items():
    path = os.path.join(runtime_root, relative)
    if os.path.islink(path) or not os.path.isfile(path):
        raise SystemExit(f"inventory file is missing or symlinked: {path}")
    with open(path,'rb') as stream:
        if hashlib.sha256(stream.read()).hexdigest() != entry['hash']:
            raise SystemExit(f"wrong published file hash: {path}")
for relative in (layout['rootFiles'] + layout['runtimePaths'] + layout['wrapperPaths']):
    if relative not in by_path:
        raise SystemExit(f"required artifact missing from inventory: {relative}")
for target in components['targets']:
    if not os.path.isabs(target['lean']):
        raise SystemExit("standalone target compiler is not a fixed installation path")
    for role in ['daemon','plugin']:
        if target[role] not in by_path or not target[role].startswith('runtimes/'):
            raise SystemExit(f"unowned target component: {target}")

PY
}

assert_version_count() {
  local versions_root="$1"
  local expected="$2"
  local actual
  if [ -d "$versions_root" ]; then
    actual="$(find "$versions_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  else
    actual="0"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "expected $expected installed runtime version(s) under $versions_root, got $actual" >&2
    exit 1
  fi
}

path_without_elan() {
  local old_ifs="$IFS"
  local dir=""
  local filtered=()
  IFS=':'
  for dir in $PATH; do
    [ -n "$dir" ] || dir="."
    if [ -x "$dir/elan" ]; then
      continue
    fi
    filtered+=("$dir")
  done
  IFS="$old_ifs"
  (
    IFS=':'
    printf '%s' "${filtered[*]}"
  )
}

assert_no_construction_state() {
  local install_root="$1"
  local version=""
  assert_not_exists "$install_root/state"
  for version in "$install_root"/versions/*; do
    assert_not_exists "$version/.construction"
  done
  if compgen -G "$install_root/.staging-*" > /dev/null; then
    echo "construction retained a staging tree under $install_root" >&2
    exit 1
  fi
}

run_install_from_source() {
  preseed_elan_home "$HOME/.elan" ${validated_toolchains[@]+"${validated_toolchains[@]}"}
  (
    cd "$source_checkout"
    bash scripts/install-beam.sh --dont-ask "$@" > /dev/null
  )
}

assert_install_rejects_marker() {
  local label="$1"
  local install_root="$2"
  local expected="$3"
  local marker_err="$tmp_root/${label}.err"
  local marker_home="$tmp_root/${label}-home"
  mkdir -p "$marker_home"
  if (
    cd "$source_checkout"
    HOME="$marker_home" BEAM_INSTALL_ROOT="$install_root" \
      bash scripts/install-beam.sh --dont-ask --toolchain "$toolchain" \
        > /dev/null 2>"$marker_err"
  ); then
    echo "expected install to reject $label" >&2
    cat "$marker_err" >&2
    exit 1
  fi
  assert_contains_literal "$marker_err" "$expected"
  assert_not_exists "$install_root/versions"
  remove_tmp_file "$marker_err"
}

beam_test_overlay_install_source . "$source_checkout"
path_no_elan="$(path_without_elan)"
if PATH="$path_no_elan" command -v elan >/dev/null 2>&1; then
  echo "failed to construct a PATH without elan for the negative install test" >&2
  exit 1
fi
missing_elan_err="$(mktemp "$tmp_root/install-missing-elan-XXXXXX")"
if (
  cd "$source_checkout"
  PATH="$path_no_elan" bash scripts/install-beam.sh > /dev/null 2>"$missing_elan_err"
); then
  echo "expected install to fail when elan is missing from PATH" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
if ! grep -q 'missing elan on PATH' "$missing_elan_err"; then
  echo "expected missing-elan install failure to explain the prebuild requirement" >&2
  cat "$missing_elan_err" >&2
  remove_tmp_file "$missing_elan_err"
  exit 1
fi
remove_tmp_file "$missing_elan_err"
assert_not_exists "$HOME/.local"
assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"
assert_not_exists "$BEAM_INSTALL_ROOT/current"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 0
assert_not_exists "$BEAM_INSTALL_ROOT/state"

relative_root_err="$(mktemp "$tmp_root/install-relative-root-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_INSTALL_ROOT="relative/install-root" bash scripts/install-beam.sh > /dev/null 2>"$relative_root_err"
); then
  echo "expected install to fail when BEAM_INSTALL_ROOT is relative" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
if ! grep -q 'install root must be an absolute path' "$relative_root_err"; then
  echo "expected relative install root failure to explain the absolute-path requirement" >&2
  cat "$relative_root_err" >&2
  remove_tmp_file "$relative_root_err"
  exit 1
fi
remove_tmp_file "$relative_root_err"
assert_not_exists "$source_checkout/relative"

missing_owner_root="$tmp_root/install-marker-missing-owner"
mkdir -p "$missing_owner_root"
printf '%s\n' \
  'schema=1' \
  "root=$missing_owner_root" >"$missing_owner_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker missing owner" \
  "$missing_owner_root" \
  'refusing to use Beam install root marker without owner=lean-beam'

missing_marker_root="$tmp_root/install-marker-missing-root"
mkdir -p "$missing_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' >"$missing_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker missing root" \
  "$missing_marker_root" \
  'refusing to use Beam install root marker without root'

mismatched_marker_root="$tmp_root/install-marker-mismatched-root"
other_marker_root="$tmp_root/install-marker-other-root"
mkdir -p "$mismatched_marker_root" "$other_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$other_marker_root" >"$mismatched_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker mismatched root" \
  "$mismatched_marker_root" \
  'refusing to use Beam install root marker naming a different root'

relative_marker_root="$tmp_root/install-marker-relative-root"
mkdir -p "$relative_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'root=.' >"$relative_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker relative root" \
  "$relative_marker_root" \
  'refusing to use Beam install root marker with non-absolute root'

blank_marker_root="$tmp_root/install-marker-blank-root"
mkdir -p "$blank_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'root=' >"$blank_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker blank root" \
  "$blank_marker_root" \
  'refusing to use Beam install root marker without root'

multiple_marker_root="$tmp_root/install-marker-multiple-roots"
mkdir -p "$multiple_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$multiple_marker_root" \
  "root=$multiple_marker_root" >"$multiple_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker multiple roots" \
  "$multiple_marker_root" \
  'refusing to use Beam install root marker with multiple roots'

conflicting_schema_marker_root="$tmp_root/install-marker-conflicting-schema"
mkdir -p "$conflicting_schema_marker_root"
printf '%s\n' \
  'schema=1' \
  'schema=2' \
  'owner=lean-beam' \
  "root=$conflicting_schema_marker_root" >"$conflicting_schema_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker conflicting schema" \
  "$conflicting_schema_marker_root" \
  'refusing to use Beam install root marker with invalid schema fields'

conflicting_owner_marker_root="$tmp_root/install-marker-conflicting-owner"
mkdir -p "$conflicting_owner_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  'owner=other' \
  "root=$conflicting_owner_marker_root" >"$conflicting_owner_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker conflicting owner" \
  "$conflicting_owner_marker_root" \
  'refusing to use Beam install root marker with invalid owner fields'

symlink_marker_root="$tmp_root/install-marker-symlink"
symlink_marker_target="$tmp_root/install-marker-symlink-target"
mkdir -p "$symlink_marker_root"
printf '%s\n' \
  'schema=1' \
  'owner=lean-beam' \
  "root=$symlink_marker_root" >"$symlink_marker_target"
ln -s "$symlink_marker_target" "$symlink_marker_root/.lean-beam-install-root"
assert_install_rejects_marker \
  "install marker symlink" \
  "$symlink_marker_root" \
  'refusing to use non-file Beam install root marker'

invalid_approval_home="$tmp_root/invalid-approval-home"
invalid_approval_install_root="$tmp_root/invalid-approval-install-root"
invalid_approval_transcript="$tmp_root/install-invalid-approval-transcript"
mkdir -p "$invalid_approval_home"
if beam_install_run_interactive_from_source \
    "$invalid_approval_transcript" "$invalid_approval_home" "$invalid_approval_install_root" \
    $'\n\n\nmaybe\n'; then
  echo "expected interactive install to reject an unknown write approval response" >&2
  cat "$invalid_approval_transcript" >&2
  exit 1
fi
assert_contains "$invalid_approval_transcript" 'Write Locations'
assert_contains "$invalid_approval_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$invalid_approval_transcript" 'unknown write-permission response: maybe'
assert_not_exists "$invalid_approval_install_root"
remove_tmp_file "$invalid_approval_transcript"

change_alias_home="$tmp_root/change-alias-home"
change_alias_install_root="$tmp_root/change-alias-install-root"
change_alias_transcript="$tmp_root/install-change-alias-transcript"
mkdir -p "$change_alias_home"
if beam_install_run_interactive_from_source \
    "$change_alias_transcript" "$change_alias_home" "$change_alias_install_root" \
    $'\n\n\nc\n\n\nN\n'; then
  echo "expected interactive install to stop after change alias then denied write permission" >&2
  cat "$change_alias_transcript" >&2
  exit 1
fi
assert_contains "$change_alias_transcript" 'Write Locations'
assert_contains "$change_alias_transcript" 'Change Locations'
assert_contains_literal "$change_alias_transcript" "Command directory [$change_alias_home/.local/bin]"
assert_contains_literal "$change_alias_transcript" "Runtime install root [$change_alias_install_root]"
assert_contains_literal "$change_alias_transcript" "Command directory: $change_alias_home/.local/bin"
assert_contains_literal "$change_alias_transcript" "Runtime root: $change_alias_install_root"
assert_contains "$change_alias_transcript" 'cancelled before: Write Locations'
assert_not_exists "$change_alias_install_root"
remove_tmp_file "$change_alias_transcript"

interactive_home="$tmp_root/interactive-home"
interactive_install_root="$tmp_root/interactive-install-root"
interactive_transcript="$tmp_root/install-interactive-transcript"
mkdir -p "$interactive_home"
if ! beam_install_run_interactive_from_source "$interactive_transcript" "$interactive_home" "$interactive_install_root" $'\n\n\nY\n'; then
  echo "expected interactive default install to succeed" >&2
  cat "$interactive_transcript" >&2
  exit 1
fi
assert_contains "$interactive_transcript" 'Prebuild toolchains'
assert_contains "$interactive_transcript" 'Lean agent skill targets to install'
assert_contains "$interactive_transcript" 'MCP clients'
assert_contains "$interactive_transcript" 'commands'
assert_contains "$interactive_transcript" 'Write Locations'
assert_contains "$interactive_transcript" 'Lean Beam will create or update the following locations:'
assert_contains "$interactive_transcript" 'Command directory'
assert_contains "$interactive_transcript" 'Runtime root'
assert_not_contains "$interactive_transcript" 'Bundle cache'
assert_contains "$interactive_transcript" 'Source build output'
assert_contains "$interactive_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$interactive_transcript" 'building beam runtime artifacts'
assert_contains "$interactive_transcript" 'MCP restart'
assert_not_contains "$interactive_transcript" 'Allow this edit?'
assert_file "$interactive_install_root/.lean-beam-install-root"
assert_file "$interactive_home/.local/bin/lean-beam"
assert_not_exists "$interactive_home/.codex"
assert_not_exists "$interactive_home/.claude"
assert_not_exists "$interactive_home/.pi"
assert_not_exists "$interactive_home/.config/opencode"
remove_tmp_file "$interactive_transcript"

interactive_claude_home="$tmp_root/interactive-claude-home"
interactive_claude_install_root="$tmp_root/interactive-claude-install-root"
interactive_claude_config_home="$tmp_root/interactive-claude-sandbox"
interactive_claude_config="$interactive_claude_config_home/.claude.json"
interactive_claude_transcript="$tmp_root/install-interactive-claude-transcript"
interactive_mcp_stub_bin="$tmp_root/interactive-mcp-stubs"
interactive_mcp_stub_log="$tmp_root/interactive-mcp-stubs.log"
mkdir -p "$interactive_claude_home"
beam_install_setup_mcp_cli_stubs "$interactive_mcp_stub_bin" "$interactive_mcp_stub_log"
if BEAM_TEST_MCP_STUB_LOG="$interactive_mcp_stub_log" PATH="$interactive_mcp_stub_bin:$PATH" \
    beam_install_run_interactive_from_source \
      "$interactive_claude_transcript" "$interactive_claude_home" "$interactive_claude_install_root" \
      $'\n\n3\nchange\n\n\n'"$interactive_claude_config"$'\nN\n'; then
  echo "expected interactive Claude MCP install to stop when write permission is denied" >&2
  cat "$interactive_claude_transcript" >&2
  exit 1
fi
assert_contains "$interactive_claude_transcript" 'Write Locations'
assert_contains "$interactive_claude_transcript" 'Change Locations'
assert_contains "$interactive_claude_transcript" 'Command directory'
assert_contains "$interactive_claude_transcript" 'Runtime install root'
assert_contains_literal "$interactive_claude_transcript" \
  "Claude Code user config [$interactive_claude_home/.claude.json]"
assert_contains_literal "$interactive_claude_transcript" "$interactive_claude_config"
assert_contains_literal "$interactive_claude_transcript" "Claude Code config: $interactive_claude_config"
assert_contains "$interactive_claude_transcript" 'Allow lean-beam to write to these locations?'
assert_contains "$interactive_claude_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_claude_install_root"
assert_not_exists "$interactive_claude_home/.claude.json"
remove_tmp_file "$interactive_claude_transcript"

interactive_codex_home="$tmp_root/interactive-codex-home"
interactive_codex_install_root="$tmp_root/interactive-codex-install-root"
interactive_codex_custom_home="$tmp_root/interactive-codex-sandbox"
interactive_codex_custom_bin="$tmp_root/interactive-codex-bin"
interactive_codex_custom_runtime="$tmp_root/interactive-codex-runtime"
interactive_codex_transcript="$tmp_root/install-interactive-codex-transcript"
mkdir -p "$interactive_codex_home"
if beam_install_run_interactive_from_source \
    "$interactive_codex_transcript" "$interactive_codex_home" "$interactive_codex_install_root" \
    $'\n\n2\nchange\n'"$interactive_codex_custom_bin"$'\n'"$interactive_codex_custom_runtime"$'\n'"$interactive_codex_custom_home"$'\nN\n'; then
  echo "expected interactive Codex MCP install to stop when write permission is denied" >&2
  cat "$interactive_codex_transcript" >&2
  exit 1
fi
assert_contains "$interactive_codex_transcript" 'Write Locations'
assert_contains "$interactive_codex_transcript" 'Change Locations'
assert_contains_literal "$interactive_codex_transcript" "Command directory [$interactive_codex_home/.local/bin]"
assert_contains_literal "$interactive_codex_transcript" "Runtime install root [$interactive_codex_install_root]"
assert_contains_literal "$interactive_codex_transcript" "Codex home [$CODEX_HOME]"
assert_contains_literal "$interactive_codex_transcript" "Command directory: $interactive_codex_custom_bin"
assert_contains_literal "$interactive_codex_transcript" "Runtime root: $interactive_codex_custom_runtime"
assert_contains_literal "$interactive_codex_transcript" "Codex home: $interactive_codex_custom_home"
assert_contains_literal "$interactive_codex_transcript" "Codex config: $interactive_codex_custom_home/config.toml"
assert_contains "$interactive_codex_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_codex_custom_bin"
assert_not_exists "$interactive_codex_custom_runtime"
assert_not_exists "$interactive_codex_custom_home"
remove_tmp_file "$interactive_codex_transcript"

interactive_opencode_home="$tmp_root/interactive-opencode-home"
interactive_opencode_install_root="$tmp_root/interactive-opencode-install-root"
interactive_opencode_custom_bin="$tmp_root/interactive-opencode-bin"
interactive_opencode_custom_runtime="$tmp_root/interactive-opencode-runtime"
interactive_opencode_transcript="$tmp_root/install-interactive-opencode-transcript"
mkdir -p "$interactive_opencode_home"
if beam_install_run_interactive_from_source \
    "$interactive_opencode_transcript" "$interactive_opencode_home" "$interactive_opencode_install_root" \
    $'\n\n4\nchange\n'"$interactive_opencode_custom_bin"$'\n'"$interactive_opencode_custom_runtime"$'\nN\n'; then
  echo "expected interactive OpenCode MCP install to stop when write permission is denied" >&2
  cat "$interactive_opencode_transcript" >&2
  exit 1
fi
assert_contains "$interactive_opencode_transcript" 'Write Locations'
assert_contains "$interactive_opencode_transcript" 'Change Locations'
assert_contains_literal "$interactive_opencode_transcript" "Command directory [$interactive_opencode_home/.local/bin]"
assert_contains_literal "$interactive_opencode_transcript" "Runtime install root [$interactive_opencode_install_root]"
assert_contains_literal "$interactive_opencode_transcript" "Command directory: $interactive_opencode_custom_bin"
assert_contains_literal "$interactive_opencode_transcript" "Runtime root: $interactive_opencode_custom_runtime"
assert_contains "$interactive_opencode_transcript" 'Manual follow-up'
assert_contains_literal "$interactive_opencode_transcript" 'OpenCode MCP registration requires manual steps after install.'
assert_not_contains "$interactive_opencode_transcript" 'Run after install: opencode mcp add'
assert_not_contains "$interactive_opencode_transcript" 'MCP command:'
assert_contains "$interactive_opencode_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_opencode_custom_bin"
assert_not_exists "$interactive_opencode_custom_runtime"
remove_tmp_file "$interactive_opencode_transcript"

interactive_vibe_home="$tmp_root/interactive-vibe-home"
interactive_vibe_install_root="$tmp_root/interactive-vibe-install-root"
interactive_vibe_custom_home="$tmp_root/interactive-vibe-sandbox"
interactive_vibe_custom_bin="$tmp_root/interactive-vibe-bin"
interactive_vibe_custom_runtime="$tmp_root/interactive-vibe-runtime"
interactive_vibe_transcript="$tmp_root/install-interactive-vibe-transcript"
mkdir -p "$interactive_vibe_home"
if beam_install_run_interactive_from_source \
    "$interactive_vibe_transcript" "$interactive_vibe_home" "$interactive_vibe_install_root" \
    $'\n\n5\nchange\n'"$interactive_vibe_custom_bin"$'\n'"$interactive_vibe_custom_runtime"$'\n'"$interactive_vibe_custom_home"$'\nN\n'; then
  echo "expected interactive Mistral Vibe MCP install to stop when write permission is denied" >&2
  cat "$interactive_vibe_transcript" >&2
  exit 1
fi
assert_contains "$interactive_vibe_transcript" 'Write Locations'
assert_contains "$interactive_vibe_transcript" 'Change Locations'
assert_contains_literal "$interactive_vibe_transcript" "Command directory [$interactive_vibe_home/.local/bin]"
assert_contains_literal "$interactive_vibe_transcript" "Runtime install root [$interactive_vibe_install_root]"
assert_contains_literal "$interactive_vibe_transcript" "Mistral Vibe home [$VIBE_HOME]"
assert_contains_literal "$interactive_vibe_transcript" "Mistral Vibe home: $interactive_vibe_custom_home"
assert_contains_literal "$interactive_vibe_transcript" "Mistral Vibe config: $interactive_vibe_custom_home/config.toml"
assert_contains "$interactive_vibe_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_vibe_custom_bin"
assert_not_exists "$interactive_vibe_custom_runtime"
assert_not_exists "$interactive_vibe_custom_home"
remove_tmp_file "$interactive_vibe_transcript"

run_step "install default runtime" run_install_from_source
expected_source_commit="$(git -C "$source_checkout" rev-parse HEAD 2>/dev/null || true)"
install_layout_json="$(cd "$source_checkout" && ./.lake/build/bin/beam-install-runtime layout)"

installed_lean_beam="$HOME/.local/bin/lean-beam"
installed_helper="$HOME/.local/bin/lean-beam-search"
installed_mcp="$HOME/.local/bin/lean-beam-mcp"
installed_runtime_root="$BEAM_INSTALL_ROOT/current"

start_installed_owner() {
  local root="$1"
  local label="$2"
  local owner_out="$tmp_root/$label-owner.out"
  local owner_err="$tmp_root/$label-owner.err"
  local owner_pid
  "$installed_lean_beam" --root "$root" serve > "$owner_out" 2> "$owner_err" &
  owner_pid="$!"
  installed_owner_pids+=("$owner_pid")
  installed_owner_roots+=("$root")
  if ! wait_for_file_text "$owner_err" "serving Beam session" "$label session owner" 600 0.1; then
    echo "expected installed wrapper owner to become ready for $root" >&2
    cat "$owner_out" >&2
    cat "$owner_err" >&2
    return 1
  fi
}

if [ ! -L "$installed_lean_beam" ]; then
  echo "expected installed lean-beam symlink at $installed_lean_beam" >&2
  exit 1
fi

if [ ! -L "$installed_helper" ]; then
  echo "expected installed lean-beam-search symlink at $installed_helper" >&2
  exit 1
fi

if [ ! -L "$installed_mcp" ]; then
  echo "expected installed lean-beam-mcp symlink at $installed_mcp" >&2
  exit 1
fi

assert_symlink_target "$installed_lean_beam" "$installed_runtime_root/bin/lean-beam"
assert_symlink_target "$installed_helper" "$installed_runtime_root/bin/lean-beam-search"
assert_symlink_target "$installed_mcp" "$installed_runtime_root/bin/lean-beam-mcp"
assert_not_exists "$HOME/.local/bin/beam"
assert_not_exists "$HOME/.local/bin/beam-lean-search"
assert_runtime_layout "$installed_runtime_root"
assert_file "$BEAM_INSTALL_ROOT/.lean-beam-install-root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
installed_version_root="$(beam_test_realpath "$installed_runtime_root")"
installed_payload_id="$(basename "$installed_version_root")"
assert_file "$installed_runtime_root/manifest.json"
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"
installed_lean_beam_version="$("$installed_lean_beam" --version)"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "lean-beam 0.2.0-beta"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "wrapper: $installed_version_root/bin/lean-beam"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam home: $installed_version_root"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam cli: $installed_version_root/libexec/beam-cli"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "runtime payload: $installed_payload_id"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "manifest: $installed_version_root/manifest.json"
if [ -n "$expected_source_commit" ]; then
  assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "source commit: $expected_source_commit"
fi
installed_mcp_version="$("$installed_mcp" --version)"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "lean-beam-mcp 0.2.0-beta"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "mcp protocol: 2026-07-28"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "wrapper: $installed_version_root/bin/lean-beam-mcp"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "server binary: $installed_version_root/libexec/lean-beam-mcp"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "beam cli: $installed_version_root/libexec/beam-cli"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "runtime payload: $installed_payload_id"
assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "manifest: $installed_version_root/manifest.json"
if [ -n "$expected_source_commit" ]; then
  assert_output_contains "installed lean-beam-mcp --version" "$installed_mcp_version" "source commit: $expected_source_commit"
fi

immutable_manifest="$tmp_root/immutable-manifest.json"
cp "$installed_version_root/manifest.json" "$immutable_manifest"
run_step "reuse complete immutable installation" run_install_from_source --toolchain "$toolchain"
cmp "$immutable_manifest" "$installed_version_root/manifest.json"
remove_tmp_file "$immutable_manifest"
assert_symlink_target "$installed_runtime_root" "$installed_version_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1

reuse_guard_backup="$tmp_root/runtime-reuse-LICENSE"
reuse_guard_err="$tmp_root/runtime-reuse.err"
cp "$installed_version_root/LICENSE" "$reuse_guard_backup"
printf '\n-- corrupt installed runtime reuse fixture\n' >>"$installed_version_root/LICENSE"
if run_install_from_source --toolchain "$toolchain" 2>"$reuse_guard_err"; then
  mv "$reuse_guard_backup" "$installed_version_root/LICENSE"
  echo "expected reinstall to reject a corrupted content-addressed runtime" >&2
  exit 1
fi
mv "$reuse_guard_backup" "$installed_version_root/LICENSE"
assert_contains_literal "$reuse_guard_err" \
  'installation files differ from the published inventory'
assert_symlink_target "$installed_runtime_root" "$installed_version_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
assert_not_exists "$BEAM_INSTALL_ROOT/.install-lock"
remove_tmp_file "$reuse_guard_err"

reuse_mode_err="$tmp_root/runtime-reuse-mode.err"
chmod -x "$installed_version_root/libexec/beam-cli"
if run_install_from_source --toolchain "$toolchain" 2>"$reuse_mode_err"; then
  chmod +x "$installed_version_root/libexec/beam-cli"
  echo "expected reinstall to reject a runtime with a non-executable command" >&2
  exit 1
fi
chmod +x "$installed_version_root/libexec/beam-cli"
assert_contains_literal "$reuse_mode_err" \
  'installed runtime has a non-executable command:'
assert_symlink_target "$installed_runtime_root" "$installed_version_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
assert_not_exists "$BEAM_INSTALL_ROOT/.install-lock"
remove_tmp_file "$reuse_mode_err"

reuse_legacy_manifest_backup="$tmp_root/runtime-reuse-legacy-manifest.json"
reuse_legacy_manifest_err="$tmp_root/runtime-reuse-legacy-manifest.err"
cp "$installed_version_root/manifest.json" "$reuse_legacy_manifest_backup"
python3 - "$installed_version_root/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["schemaVersion"] = 2
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
    stream.write("\n")
PY
if run_install_from_source --toolchain "$toolchain" 2>"$reuse_legacy_manifest_err"; then
  mv "$reuse_legacy_manifest_backup" "$installed_version_root/manifest.json"
  echo "expected reinstall to reject a cleanup-only schema-2 runtime manifest" >&2
  exit 1
fi
mv "$reuse_legacy_manifest_backup" "$installed_version_root/manifest.json"
assert_contains_literal "$reuse_legacy_manifest_err" \
  'unsupported install manifest schemaVersion 2'
assert_symlink_target "$installed_runtime_root" "$installed_version_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
assert_not_exists "$BEAM_INSTALL_ROOT/.install-lock"
remove_tmp_file "$reuse_legacy_manifest_err"

reuse_manifest_backup="$tmp_root/runtime-reuse-manifest.json"
reuse_manifest_err="$tmp_root/runtime-reuse-manifest.err"
cp "$installed_version_root/manifest.json" "$reuse_manifest_backup"
python3 - "$installed_version_root/manifest.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as stream:
    manifest = json.load(stream)
manifest["schemaVersion"] = 999
with open(path, "w", encoding="utf-8") as stream:
    json.dump(manifest, stream)
    stream.write("\n")
PY
if run_install_from_source --toolchain "$toolchain" 2>"$reuse_manifest_err"; then
  mv "$reuse_manifest_backup" "$installed_version_root/manifest.json"
  echo "expected reinstall to reject an invalid typed runtime manifest" >&2
  exit 1
fi
mv "$reuse_manifest_backup" "$installed_version_root/manifest.json"
assert_contains_literal "$reuse_manifest_err" \
  'unsupported install manifest schemaVersion 999'
assert_symlink_target "$installed_runtime_root" "$installed_version_root"
assert_version_count "$BEAM_INSTALL_ROOT/versions" 1
assert_not_exists "$BEAM_INSTALL_ROOT/.install-lock"
remove_tmp_file "$reuse_manifest_err"

assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"
assert_no_construction_state "$BEAM_INSTALL_ROOT"

# Construction builds every target from scratch inside its own staging tree. It refuses to reuse
# or remove a construction directory it did not create.
blocked_staging="$tmp_root/blocked-staging"
mkdir -p "$blocked_staging/.construction"
printf 'sentinel\n' >"$blocked_staging/.construction/user-file.txt"
blocked_construction_err="$(mktemp "$tmp_root/construction-existing-XXXXXX")"
frontend_sdk="$(elan run "$toolchain" lean --print-prefix)"
if "$source_checkout/.lake/build/bin/beam-install-runtime" construct "$source_checkout" \
    "$frontend_sdk" "$blocked_staging" "${expected_source_commit:--}" "$toolchain" \
    > /dev/null 2>"$blocked_construction_err"; then
  echo "expected construction to reject an existing construction directory" >&2
  exit 1
fi
assert_contains "$blocked_construction_err" 'refusing to reuse an existing construction directory'
remove_tmp_file "$blocked_construction_err"
assert_file "$blocked_staging/.construction/user-file.txt"
assert_not_exists "$blocked_staging/manifest.json"

run_custom_toolchain_install_test() (
  set -e

  local custom_toolchain="beam-test-custom"
  local custom_elan_home="$tmp_root/custom-elan"
  local custom_install_home="$tmp_root/custom-home"
  local custom_install_root="$tmp_root/custom-install-root"
  local host_lean_path=""
  local custom_toolchain_dir=""
  local custom_installed_lean_beam=""
  local custom_installed_runtime_root=""
  local custom_installed_version_root=""
  local custom_installed_payload_id=""
  local custom_project_root=""
  local custom_doctor_out=""

  mkdir -p "$custom_elan_home" "$custom_install_home" "$custom_install_root"
  preseed_elan_home "$custom_elan_home" "$toolchain"
  if [ -n "$host_elan_home" ]; then
    host_lean_path="$(ELAN_HOME="$host_elan_home" elan which lean)"
  else
    host_lean_path="$(elan which lean)"
  fi
  custom_toolchain_dir="$(dirname "$(dirname "$host_lean_path")")"
  ELAN_HOME="$custom_elan_home" elan toolchain link "$custom_toolchain" "$custom_toolchain_dir" > /dev/null
  (
    cd "$source_checkout"
    HOME="$custom_install_home" BEAM_INSTALL_ROOT="$custom_install_root" ELAN_HOME="$custom_elan_home" \
      bash scripts/install-beam.sh --dont-ask --custom-toolchain "$custom_toolchain" > /dev/null
  )
  custom_installed_lean_beam="$custom_install_home/.local/bin/lean-beam"
  custom_installed_runtime_root="$custom_install_root/current"
  assert_runtime_layout "$custom_installed_runtime_root"
  assert_version_count "$custom_install_root/versions" 1
  custom_installed_version_root="$(beam_test_realpath "$custom_installed_runtime_root")"
  custom_installed_payload_id="$(basename "$custom_installed_version_root")"
  BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata \
    "$custom_installed_runtime_root/manifest.json" \
    "$custom_installed_payload_id" \
    "$expected_source_commit" \
    "$custom_toolchain"
  assert_no_construction_state "$custom_install_root"

  custom_project_root="$tmp_root/custom-project"
  rsync -a --exclude='.beam/' tests/save_olean_project/ "$custom_project_root"/
  printf '%s\n' "$custom_toolchain" > "$custom_project_root/lean-toolchain"
  custom_doctor_out="$(ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" doctor)"
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" "project target: $custom_toolchain"
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" 'target membership: present'
  assert_doctor_contains "custom toolchain" "$custom_doctor_out" "installation root: $custom_installed_version_root"
  custom_owner_err="$custom_project_root/custom-owner.err"
  ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" serve \
    > /dev/null 2>"$custom_owner_err" &
  custom_owner_pid="$!"
  if ! wait_for_file_text "$custom_owner_err" "serving Beam session" "custom-toolchain session owner" 600 0.1; then
    exit 1
  fi
  ELAN_HOME="$custom_elan_home" "$custom_installed_lean_beam" --root "$custom_project_root" stop > /dev/null
  wait_for_exit "$custom_owner_pid" "custom-toolchain session owner" 120 0.1
  wait "$custom_owner_pid"
)

run_step "install custom toolchain runtime" run_custom_toolchain_install_test

release_pre_all_validated_disk() {
  remove_tmp_tree "$blocked_staging"
  remove_tmp_tree "$tmp_root/custom-elan"
  remove_tmp_tree "$tmp_root/custom-home"
  remove_tmp_tree "$tmp_root/custom-install-root"
  remove_tmp_tree "$tmp_root/custom-project"
}

run_step "release install temp trees before all-validated" release_pre_all_validated_disk

run_step "install all validated targets" run_install_from_source --all-validated

run_construction_native_test() (
  cd "$source_checkout"
  ELAN_HOME="$HOME/.elan" python3 tests/test-installation-construction-native.py
)

run_step "two-target construction, reuse, and failure fences" run_construction_native_test

assert_version_count "$BEAM_INSTALL_ROOT/versions" 2
all_targets_root="$(beam_test_realpath "$installed_runtime_root")"
all_targets_payload="$(basename "$all_targets_root")"
if [ "$all_targets_root" = "$installed_version_root" ]; then
  echo "expected a changed target set to publish another generation" >&2
  exit 1
fi
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$all_targets_payload" "$expected_source_commit" ${validated_toolchains[@]+"${validated_toolchains[@]}"}
assert_no_construction_state "$BEAM_INSTALL_ROOT"

rocq_no_target_err="$(mktemp "$tmp_root/rocq-skill-no-target-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --rocq-skill > /dev/null 2>"$rocq_no_target_err"
); then
  echo "expected the removed --rocq-skill option to fail" >&2
  remove_tmp_file "$rocq_no_target_err"
  exit 1
fi
assert_contains "$rocq_no_target_err" "unknown option: --rocq-skill"
remove_tmp_file "$rocq_no_target_err"
assert_not_exists "$CODEX_HOME"
assert_not_exists "$CLAUDE_HOME"
assert_not_exists "$PI_CODING_AGENT_DIR"
assert_not_exists "$OPENCODE_CONFIG_DIR"
assert_not_exists "$VIBE_HOME"

run_step "install Lean skills" run_install_from_source --toolchain "$toolchain" --all-skills

for skills_home in "$CODEX_HOME/skills" "$CLAUDE_HOME/skills" "$PI_CODING_AGENT_DIR/skills" "$OPENCODE_CONFIG_DIR/skills" "$VIBE_HOME/skills"; do
  assert_file "$skills_home/lean-beam/SKILL.md"
  assert_file "$skills_home/lean-beam/.lean-beam-skill"
  assert_not_exists "$skills_home/rocq-beam"
done
assert_version_count "$BEAM_INSTALL_ROOT/versions" 2
BEAM_INSTALL_LAYOUT_JSON="$install_layout_json" assert_manifest_metadata "$installed_runtime_root/manifest.json" "$installed_payload_id" "$expected_source_commit" "$toolchain"

mcp_stub_bin="$tmp_root/mcp-stubs"
mcp_stub_log="$tmp_root/mcp-stubs.log"
beam_install_setup_mcp_cli_stubs "$mcp_stub_bin" "$mcp_stub_log"
mkdir -p "$CODEX_HOME"
printf 'model = "fixture-model"\n' >"$CODEX_HOME/config.toml"
run_step "register MCP clients" beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$mcp_stub_log" --toolchain "$toolchain" --all-mcp
assert_contains_literal "$mcp_stub_log" "codex|mcp|add|lean-beam|--|$installed_mcp"
assert_contains_literal "$CODEX_HOME/config.toml" 'model = "fixture-model"'
assert_contains_literal "$CODEX_HOME/config.toml" "[mcp_servers.'lean-beam']"
assert_contains_literal "$CODEX_HOME/config.toml" 'supports_parallel_tool_calls = true'
python3 - "$CODEX_HOME/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
server = config["mcp_servers"]["lean-beam"]
if server.get("supports_parallel_tool_calls") is not True:
    raise SystemExit(f"Codex lean-beam server does not enable parallel tool calls: {server}")
PY
assert_contains_literal "$mcp_stub_log" "claude|mcp|remove|--scope|user|lean-beam"
assert_contains_literal "$mcp_stub_log" "claude|mcp|add|--scope|user|lean-beam|--|$installed_mcp"
assert_not_exists "$OPENCODE_CONFIG_DIR/opencode.json"
assert_file "$VIBE_HOME/config.toml"
assert_contains_literal "$VIBE_HOME/config.toml" '[[mcp_servers]]'
assert_contains_literal "$VIBE_HOME/config.toml" 'name = "lean-beam"'
assert_contains_literal "$VIBE_HOME/config.toml" 'transport = "stdio"'
assert_contains_literal "$VIBE_HOME/config.toml" "command = \"$installed_mcp\""
assert_contains_literal "$VIBE_HOME/config.toml" 'args = []'
assert_contains_literal "$VIBE_HOME/config.toml" 'tool_timeout_sec = 600'

run_step "inspect installed client configuration" \
  python3 tests/test-client-doctor-installed.py "$installed_lean_beam" "$tmp_root"

# Exercise the default separately from OPENCODE_CONFIG_DIR so shell/Lean drift is visible.
xdg_config_home="$tmp_root/xdg-config"
run_step "install OpenCode skill with XDG default" env -u OPENCODE_CONFIG_DIR \
  XDG_CONFIG_HOME="$xdg_config_home" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" --opencode
assert_file "$xdg_config_home/opencode/skills/lean-beam/SKILL.md"
run_step "inspect installed XDG client configuration" env -u OPENCODE_CONFIG_DIR \
  XDG_CONFIG_HOME="$xdg_config_home" \
  python3 tests/test-client-doctor-installed.py "$installed_lean_beam" "$tmp_root"

custom_codex_home="$tmp_root/codex-sandbox"
custom_codex_mcp_stub_log="$tmp_root/mcp-stubs-custom-codex.log"
run_step "register Codex MCP with custom home" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$custom_codex_mcp_stub_log" \
    --toolchain "$toolchain" --codex-mcp --codex-home "$custom_codex_home"
if [ ! -d "$custom_codex_home" ]; then
  echo "expected installer to create custom Codex home" >&2
  exit 1
fi
assert_contains_literal "$custom_codex_mcp_stub_log" \
  "codex|mcp|add|lean-beam|--|$installed_mcp|CODEX_HOME=$custom_codex_home"
assert_contains_literal "$custom_codex_home/config.toml" 'supports_parallel_tool_calls = true'

symlink_codex_home="$tmp_root/codex-symlink-config"
symlink_codex_target="$tmp_root/codex-symlink-target.toml"
symlink_codex_err="$tmp_root/codex-symlink-config.err"
symlink_codex_stub_log="$tmp_root/mcp-stubs-symlink-codex.log"
mkdir -p "$symlink_codex_home"
printf 'sentinel = "preserve"\n' >"$symlink_codex_target"
ln -s "$symlink_codex_target" "$symlink_codex_home/config.toml"
if beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$symlink_codex_stub_log" \
    --toolchain "$toolchain" --codex-mcp --codex-home "$symlink_codex_home" \
    2>"$symlink_codex_err"; then
  echo "expected Codex MCP registration to reject a symlinked config" >&2
  exit 1
fi
assert_contains "$symlink_codex_err" "refusing to edit symlinked Codex MCP config"
assert_contains_literal "$symlink_codex_target" 'sentinel = "preserve"'
assert_not_exists "$symlink_codex_stub_log"

claude_default_snapshot="$tmp_root/claude-default-before-custom.json"
cp -p "$HOME/.claude.json" "$claude_default_snapshot"
custom_claude_config_home="$tmp_root/claude-sandbox"
custom_claude_config="$custom_claude_config_home/.claude.json"
custom_mcp_stub_log="$tmp_root/mcp-stubs-custom-claude.log"
run_step "register Claude MCP with custom config" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$custom_mcp_stub_log" \
    --toolchain "$toolchain" --claude-mcp --claude-mcp-config "$custom_claude_config"
if [ ! -d "$custom_claude_config_home" ]; then
  echo "expected installer to create custom Claude MCP config home" >&2
  exit 1
fi
assert_contains_literal "$custom_mcp_stub_log" \
  "claude|mcp|remove|--scope|user|lean-beam|HOME=$custom_claude_config_home"
assert_contains_literal "$custom_mcp_stub_log" \
  "claude|mcp|add|--scope|user|lean-beam|--|$installed_mcp|HOME=$custom_claude_config_home"
assert_file "$custom_claude_config"
python3 - "$HOME/.claude.json" "$claude_default_snapshot" <<'PY_CLAUDE'
from pathlib import Path
import sys
original, snapshot = map(Path, sys.argv[1:])
assert original.read_bytes() == snapshot.read_bytes(), "custom Claude registration changed default config"
assert original.stat().st_mtime_ns == snapshot.stat().st_mtime_ns, "custom Claude registration rewrote default config"
assert original.stat().st_mode == snapshot.stat().st_mode, "custom Claude registration changed default permissions"
PY_CLAUDE

custom_vibe_home="$tmp_root/vibe-sandbox"
mkdir -p "$custom_vibe_home"
cat >"$custom_vibe_home/config.toml" <<'EOF'
model = "devstral-medium-latest"

[[mcp_servers]]
name = "other-server"
transport = "stdio"
command = "other-mcp"
args = ["--flag"]
tool_timeout_sec = 600
EOF
run_step "register Mistral Vibe MCP with custom home" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --vibe-mcp --vibe-home "$custom_vibe_home"
sed -i.bak \
  -e 's/^\[\[mcp_servers\]\]$/[[mcp_servers]] # existing table/' \
  -e 's/^name = "lean-beam"$/name = "lean-beam" # existing server/' \
  "$custom_vibe_home/config.toml"
remove_tmp_file "$custom_vibe_home/config.toml.bak"
run_step "re-register Mistral Vibe MCP without duplicating the entry" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --vibe-mcp --vibe-home "$custom_vibe_home"
assert_contains_literal "$custom_vibe_home/config.toml" 'model = "devstral-medium-latest"'
assert_contains_literal "$custom_vibe_home/config.toml" 'name = "other-server"'
assert_contains_literal "$custom_vibe_home/config.toml" 'name = "lean-beam"'
assert_contains_literal "$custom_vibe_home/config.toml" "command = \"$installed_mcp\""
if [ "$(grep -c 'name = "lean-beam"' "$custom_vibe_home/config.toml")" -ne 1 ]; then
  echo "expected exactly one lean-beam entry in the Mistral Vibe config" >&2
  cat "$custom_vibe_home/config.toml" >&2
  exit 1
fi

default_vibe_home="$tmp_root/vibe-default-config"
mkdir -p "$default_vibe_home"
cat >"$default_vibe_home/config.toml" <<'EOF'
api_timeout = 720.0
tool_paths = []
mcp_servers = []
enabled_tools = []

[tools.write_file]
permission = "ask"
EOF
run_step "register Mistral Vibe MCP over default empty mcp_servers assignment" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --vibe-mcp --vibe-home "$default_vibe_home"
if grep -Fq 'mcp_servers = []' "$default_vibe_home/config.toml"; then
  echo "expected installer to drop the default empty mcp_servers assignment" >&2
  cat "$default_vibe_home/config.toml" >&2
  exit 1
fi
assert_contains_literal "$default_vibe_home/config.toml" 'api_timeout = 720.0'
assert_contains_literal "$default_vibe_home/config.toml" '[tools.write_file]'
assert_contains_literal "$default_vibe_home/config.toml" 'name = "lean-beam"'
python3 - "$default_vibe_home/config.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    config = tomllib.load(f)
servers = config["mcp_servers"]
assert len(servers) == 1, servers
assert servers[0]["name"] == "lean-beam", servers
PY

inline_vibe_home="$tmp_root/vibe-inline-config"
mkdir -p "$inline_vibe_home"
cat >"$inline_vibe_home/config.toml" <<'EOF'
mcp_servers = [{ name = "other-server", transport = "stdio", command = "other-mcp" }]
EOF
inline_vibe_err="$(mktemp "$tmp_root/vibe-inline-config-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --vibe-mcp \
    --vibe-home "$inline_vibe_home" > /dev/null 2>"$inline_vibe_err"
); then
  echo "expected --vibe-mcp to refuse inline mcp_servers entries" >&2
  remove_tmp_file "$inline_vibe_err"
  exit 1
fi
assert_contains "$inline_vibe_err" "inline mcp_servers entries"
assert_contains_literal "$inline_vibe_home/config.toml" 'name = "other-server"'
remove_tmp_file "$inline_vibe_err"

opencode_mcp_transcript="$tmp_root/opencode-mcp-manual-transcript"
preseed_elan_home "$HOME/.elan" "$toolchain"
run_step "show OpenCode MCP setup" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" --opencode-mcp \
    >"$opencode_mcp_transcript" 2>&1
assert_contains "$opencode_mcp_transcript" 'Manual Step Required: OpenCode MCP'
assert_contains_literal "$opencode_mcp_transcript" 'run                opencode mcp add'
assert_contains_literal "$opencode_mcp_transcript" 'name               lean-beam'
assert_contains_literal "$opencode_mcp_transcript" 'type               local'
assert_contains_literal "$opencode_mcp_transcript" "command            $installed_mcp"
assert_not_exists "$OPENCODE_CONFIG_DIR/opencode.json"
remove_tmp_file "$opencode_mcp_transcript"

relative_codex_home_err="$(mktemp "$tmp_root/codex-mcp-relative-home-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_TEST_MCP_STUB_LOG="$mcp_stub_log" PATH="$mcp_stub_bin:$PATH" \
    bash scripts/install-beam.sh --dont-ask --codex-mcp \
      --codex-home relative/.codex > /dev/null 2>"$relative_codex_home_err"
); then
  echo "expected --codex-home to reject relative paths" >&2
  remove_tmp_file "$relative_codex_home_err"
  exit 1
fi
assert_contains "$relative_codex_home_err" "Codex home must be an absolute path"
remove_tmp_file "$relative_codex_home_err"

relative_claude_config_err="$(mktemp "$tmp_root/claude-mcp-relative-config-XXXXXX")"
if (
  cd "$source_checkout"
  BEAM_TEST_MCP_STUB_LOG="$mcp_stub_log" PATH="$mcp_stub_bin:$PATH" \
    bash scripts/install-beam.sh --dont-ask --claude-mcp \
      --claude-mcp-config relative/.claude.json > /dev/null 2>"$relative_claude_config_err"
); then
  echo "expected --claude-mcp-config to reject relative paths" >&2
  remove_tmp_file "$relative_claude_config_err"
  exit 1
fi
assert_contains "$relative_claude_config_err" "Claude Code MCP config must be an absolute path"
remove_tmp_file "$relative_claude_config_err"

relative_pi_home_err="$(mktemp "$tmp_root/pi-skill-relative-home-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --pi --pi-home relative/.pi/agent > /dev/null 2>"$relative_pi_home_err"
); then
  echo "expected --pi-home to reject relative paths" >&2
  remove_tmp_file "$relative_pi_home_err"
  exit 1
fi
assert_contains "$relative_pi_home_err" "Pi Agent home must be an absolute path"
remove_tmp_file "$relative_pi_home_err"

relative_opencode_config_dir_err="$(mktemp "$tmp_root/opencode-relative-config-dir-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --opencode \
    --opencode-config-dir relative/opencode > /dev/null 2>"$relative_opencode_config_dir_err"
); then
  echo "expected --opencode-config-dir to reject relative paths" >&2
  remove_tmp_file "$relative_opencode_config_dir_err"
  exit 1
fi
assert_contains "$relative_opencode_config_dir_err" "OpenCode config dir must be an absolute path"
remove_tmp_file "$relative_opencode_config_dir_err"

relative_vibe_home_err="$(mktemp "$tmp_root/vibe-mcp-relative-home-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --vibe-mcp \
    --vibe-home relative/.vibe > /dev/null 2>"$relative_vibe_home_err"
); then
  echo "expected --vibe-home to reject relative paths" >&2
  remove_tmp_file "$relative_vibe_home_err"
  exit 1
fi
assert_contains "$relative_vibe_home_err" "Mistral Vibe home must be an absolute path"
remove_tmp_file "$relative_vibe_home_err"

blocked_home="$tmp_root/blocked-home"
blocked_install_root="$tmp_root/blocked-install-root"
blocked_lean_beam_dir="$blocked_home/.local/bin/lean-beam"
mkdir -p "$blocked_lean_beam_dir" "$blocked_install_root"
blocked_wrapper_err="$(mktemp "$tmp_root/install-wrapper-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_home" BEAM_INSTALL_ROOT="$blocked_install_root" \
    bash scripts/install-beam.sh --dont-ask > /dev/null 2>"$blocked_wrapper_err"
); then
  echo "expected install to fail when the wrapper target path is a real directory" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
if ! grep -q "refusing to replace directory at $blocked_lean_beam_dir" "$blocked_wrapper_err"; then
  echo "expected wrapper-directory install failure to explain the refusal" >&2
  cat "$blocked_wrapper_err" >&2
  remove_tmp_file "$blocked_wrapper_err"
  exit 1
fi
remove_tmp_file "$blocked_wrapper_err"
if [ ! -d "$blocked_lean_beam_dir" ]; then
  echo "expected blocked wrapper directory to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_home/.local/bin/lean-beam-search"
assert_not_exists "$blocked_home/.local/bin/lean-beam-mcp"
assert_not_exists "$blocked_home/.local/bin/beam"
assert_not_exists "$blocked_home/.local/bin/beam-lean-search"
assert_not_exists "$blocked_install_root/current"
assert_not_exists "$blocked_install_root/versions"
assert_not_exists "$blocked_install_root/state"

blocked_file_home="$tmp_root/blocked-file-home"
blocked_file_install_root="$tmp_root/blocked-file-install-root"
blocked_lean_beam_file="$blocked_file_home/.local/bin/lean-beam"
mkdir -p "$(dirname "$blocked_lean_beam_file")" "$blocked_file_install_root"
printf 'user file\n' >"$blocked_lean_beam_file"
blocked_file_err="$(mktemp "$tmp_root/install-wrapper-file-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_file_home" BEAM_INSTALL_ROOT="$blocked_file_install_root" \
    bash scripts/install-beam.sh --dont-ask > /dev/null 2>"$blocked_file_err"
); then
  echo "expected install to fail when the wrapper target path is a regular file" >&2
  cat "$blocked_file_err" >&2
  remove_tmp_file "$blocked_file_err"
  exit 1
fi
assert_contains "$blocked_file_err" "refusing to replace non-Beam path at $blocked_lean_beam_file"
remove_tmp_file "$blocked_file_err"
if [ "$(cat "$blocked_lean_beam_file")" != "user file" ]; then
  echo "expected blocked wrapper file to remain untouched" >&2
  exit 1
fi
assert_not_exists "$blocked_file_home/.local/bin/lean-beam-search"
assert_not_exists "$blocked_file_home/.local/bin/lean-beam-mcp"
assert_not_exists "$blocked_file_install_root/current"

blocked_skill_home="$tmp_root/blocked-skill-home"
blocked_skill_install_root="$tmp_root/blocked-skill-install-root"
blocked_codex_home="$tmp_root/blocked-codex"
mkdir -p "$blocked_skill_home" "$blocked_codex_home/skills/lean-beam"
printf 'user skill\n' >"$blocked_codex_home/skills/lean-beam/custom.txt"
blocked_skill_err="$(mktemp "$tmp_root/install-skill-dir-XXXXXX")"
if (
  cd "$source_checkout"
  HOME="$blocked_skill_home" CODEX_HOME="$blocked_codex_home" \
    CLAUDE_HOME="$tmp_root/blocked-claude" BEAM_INSTALL_ROOT="$blocked_skill_install_root" \
    bash scripts/install-beam.sh --dont-ask --codex > /dev/null 2>"$blocked_skill_err"
); then
  echo "expected install to fail when the skill target directory is unmarked" >&2
  cat "$blocked_skill_err" >&2
  remove_tmp_file "$blocked_skill_err"
  exit 1
fi
assert_contains "$blocked_skill_err" "refusing to replace unmarked existing lean-beam skill directory"
remove_tmp_file "$blocked_skill_err"
assert_file "$blocked_codex_home/skills/lean-beam/custom.txt"
assert_not_exists "$blocked_codex_home/skills/rocq-beam"

run_step "select complete installation for external project" run_install_from_source --all-validated
assert_symlink_target "$installed_runtime_root" "$all_targets_root"
assert_file "$installed_version_root/manifest.json"

remove_tmp_tree "$source_checkout"

project_root="$tmp_root/external-project"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root"/
project_toolchain="$(awk 'NR==1 {print $1}' "$project_root/lean-toolchain")"
if [ -z "$project_toolchain" ]; then
  echo "missing Lean toolchain in external install smoke project" >&2
  exit 1
fi

doctor_out="$("$installed_lean_beam" --root "$project_root" doctor)"
assert_doctor_contains "installed wrapper" "$doctor_out" "project target: $project_toolchain"
assert_doctor_contains "installed wrapper" "$doctor_out" 'target membership: present'
assert_doctor_contains "installed wrapper" "$doctor_out" "installation root: $all_targets_root"
assert_doctor_not_contains "installed wrapper" "$doctor_out" '.lake/packages'
for removed_command in bundle-install mcp-config validated-toolchains compatible-release-lines; do
  removed_command_err="$tmp_root/removed-$removed_command.err"
  if "$installed_lean_beam" --root "$project_root" "$removed_command" \
      > /dev/null 2>"$removed_command_err"; then
    echo "expected shipped $removed_command construction/provider command to be absent" >&2
    exit 1
  fi
  remove_tmp_file "$removed_command_err"
done

mcp_smoke_out="$(mktemp "$tmp_root/install-mcp-smoke-out-XXXXXX")"
mcp_smoke_err="$(mktemp "$tmp_root/install-mcp-smoke-err-XXXXXX")"
if ! python3 tests/lib/process_watchdog.py --timeout "${BEAM_MCP_SMOKE_WATCHDOG_SECONDS:-600}" -- \
    python3 tests/lib/installed-mcp-smoke.py "$installed_mcp" "$project_root" >"$mcp_smoke_out" 2>"$mcp_smoke_err"
then
  echo "expected installed MCP wrapper smoke to succeed" >&2
  cat "$mcp_smoke_out" >&2
  cat "$mcp_smoke_err" >&2
  remove_tmp_file "$mcp_smoke_out"
  remove_tmp_file "$mcp_smoke_err"
  exit 1
fi
remove_tmp_file "$mcp_smoke_out"
remove_tmp_file "$mcp_smoke_err"

if [ -d "$project_root/.beam" ]; then
  project_beam_mode="$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode), "o"))' "$project_root/.beam")"
  if [ "$project_beam_mode" != "700" ]; then
    echo "expected Beam-created project state to be private, got mode $project_beam_mode" >&2
    exit 1
  fi
fi

unavailable_project_root="$tmp_root/external-project-unavailable"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$unavailable_project_root"/
unavailable_target="beam-test-unavailable-$(basename "$tmp_root")"
printf '%s\n' "$unavailable_target" > "$unavailable_project_root/lean-toolchain"
unavailable_shim="$tmp_root/unavailable-selector-bin"
unavailable_probe_log="$tmp_root/unavailable-selector-probes"
mkdir "$unavailable_shim"
cat > "$unavailable_shim/elan" <<'SHPROBE'
#!/bin/sh
printf 'invoked\n' >> "$BEAM_TEST_ELAN_LOG"
exit 99
SHPROBE
chmod +x "$unavailable_shim/elan"

unavailable_doctor_err="$tmp_root/unavailable-target-doctor.err"
if env PATH="$unavailable_shim:$PATH" BEAM_TEST_ELAN_LOG="$unavailable_probe_log" \
    "$installed_lean_beam" --root "$unavailable_project_root" doctor \
    > /dev/null 2>"$unavailable_doctor_err"; then
  echo "expected unavailable target lookup to fail" >&2
  exit 1
fi
assert_contains_literal "$unavailable_doctor_err" "$unavailable_target"
assert_contains_literal "$unavailable_doctor_err" 'unavailable locally'
remove_tmp_file "$unavailable_doctor_err"

unavailable_err="$(mktemp "$tmp_root/install-unavailable-target-XXXXXX")"
env PATH="$unavailable_shim:$PATH" BEAM_TEST_ELAN_LOG="$unavailable_probe_log" \
  "$installed_lean_beam" --root "$unavailable_project_root" serve >"$unavailable_err" 2>&1 &
unavailable_owner_pid="$!"
if ! wait_for_exit "$unavailable_owner_pid" "unavailable-target session owner" 120 0.1; then
  kill -INT "$unavailable_owner_pid" 2>/dev/null || true
  wait "$unavailable_owner_pid" 2>/dev/null || true
  echo "expected installed wrapper owner admission to reject an unavailable target promptly" >&2
  cat "$unavailable_err" >&2
  remove_tmp_file "$unavailable_err"
  exit 1
fi
if wait "$unavailable_owner_pid"; then
  echo "expected installed wrapper owner admission to reject an unavailable target" >&2
  cat "$unavailable_err" >&2
  remove_tmp_file "$unavailable_err"
  exit 1
fi
if ! grep -q "$unavailable_target" "$unavailable_err"; then
  echo "expected unavailable target failure to name the rejected toolchain" >&2
  cat "$unavailable_err" >&2
  remove_tmp_file "$unavailable_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'install or link its exact Lean installation' "$unavailable_err"; then
  echo "expected unavailable target failure to explain explicit target setup" >&2
  cat "$unavailable_err" >&2
  remove_tmp_file "$unavailable_err"
  exit 1
fi
remove_tmp_file "$unavailable_err"
assert_not_exists "$unavailable_probe_log"

(
  cd "$project_root"
  lake build SaveSmoke/A.lean > /dev/null
  printf 'def bVal : Nat := "broken"\n' > SaveSmoke/B.lean
)

start_installed_owner "$project_root" "installed-stale"

stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-XXXXXX")"
if "$installed_lean_beam" --root "$project_root" sync SaveSmoke/A.lean >"$stale_sync_err" 2>&1; then
  echo "expected installed wrapper sync to fail on a stale imported target" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
if ! grep -q '"code": "syncBarrierIncomplete"' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import sync failure to expose syncBarrierIncomplete" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
# shellcheck disable=SC2016
if ! grep -q 'Run `lake build` or fix the upstream module first' "$stale_sync_err"; then
  echo "expected installed wrapper stale-import sync failure to include a recovery hint" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
remove_tmp_file "$stale_sync_err"

project_root_standalone="$tmp_root/external-project-standalone"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root_standalone"/

cat > "$project_root_standalone/StandaloneSaveSmoke.lean" <<'EOF'
import SaveSmoke.B

#check bVal
EOF

start_installed_owner "$project_root_standalone" "installed-standalone"

standalone_sync="$("$installed_lean_beam" --root "$project_root_standalone" sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("error") is None else 1)'; then
  echo "expected installed wrapper sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-XXXXXX")"
if "$installed_lean_beam" --root "$project_root_standalone" save StandaloneSaveSmoke.lean >"$standalone_save_err" 2>&1; then
  echo "expected installed wrapper save to reject a standalone file outside the Lake module graph" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q '"code": "saveTargetNotModule"' "$standalone_save_err"; then
  echo "expected installed wrapper standalone save failure to expose saveTargetNotModule" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! grep -q 'save only works for synced files that belong to the current Lake workspace package graph' "$standalone_save_err"; then
  echo "expected installed wrapper standalone save failure to explain the Lake module requirement" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
remove_tmp_file "$standalone_save_err"
