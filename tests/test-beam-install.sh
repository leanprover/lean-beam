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
export BEAM_AGY_HOME="$tmp_root/agy-home"
export BEAM_INSTALL_ROOT="$tmp_root/install-root"

mkdir -p "$HOME" "$BEAM_INSTALL_ROOT"

run_step "install prune" bash tests/test-beam-prune.sh
run_step "install publication" bash tests/test-install-publication.sh
run_step "install lock cleanup" bash tests/test-install-lock.sh
run_step "installer setup summary" python3 tests/test-install-summary.py

install_admission_start="$(date +%s)"
printf '[%s] installer admission and interactive plans\n' "$BEAM_TEST_SUITE"

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

assert_cli_error_json() {
  local payload_file="$1"
  local expected_code="$2"
  local expected_message_fragment="${3:-}"
  python3 - "$payload_file" "$expected_code" "$expected_message_fragment" <<'PY'
import json, pathlib, sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text())
error = response.get("error", {})
if response.get("ok") is not False or error.get("code") != sys.argv[2]:
    raise SystemExit(f"expected {sys.argv[2]} error response, got {response!r}")
if sys.argv[3] and sys.argv[3] not in error.get("message", ""):
    raise SystemExit(f"expected error message to contain {sys.argv[3]!r}, got {response!r}")
PY
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

test_agy_selection_aliases() {
  local choice=""
  local transcript="$tmp_root/agy-selection-transcript"
  local selection_home="$tmp_root/agy-selection-home"
  local selection_root="$tmp_root/agy-selection-root"
  mkdir -p "$selection_home"
  for choice in agy antigravity a all; do
    if beam_install_run_interactive_from_source "$transcript" "$selection_home" "$selection_root" \
        $'\n'"$choice"$'\n'"$choice"$'\nN\n'; then
      echo "expected interactive install to stop when write permission is denied" >&2
      return 1
    fi
    assert_contains "$transcript" 'cancelled before: Write Locations'
    python3 - "$transcript" "$choice" <<'PY'
from pathlib import Path
import re
import sys

transcript = Path(sys.argv[1]).read_text()
plan = transcript.split("Install Plan", 1)[1].split("Write Locations", 1)[0]
labels = set(re.findall(r"^  (\w+(?: \w+)* (?:skills|MCP))\s+", plan, re.MULTILINE))
skills = {"Codex", "Claude", "Pi Agent", "OpenCode", "Mistral Vibe", "Antigravity"}
clients = skills - {"Pi Agent"}
expected = {"Antigravity skills", "Antigravity MCP"}
if sys.argv[2] in ("a", "all"):
    expected = {f"{agent} skills" for agent in skills} | {f"{agent} MCP" for agent in clients}
assert labels == expected, (sys.argv[2], labels, expected)
PY
  done
  assert_not_exists "$selection_root"
}

test_agy_mcp_config() {
  (
    cd "$source_checkout" || exit
    python3 - "$tmp_root" <<'PYTHON_AGY'
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import shutil
import stat
import struct
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
bin_home = root / "bin with spaces"
command = str(bin_home / "lean-beam-mcp")
new_entry = {"command": command, "disabled": False}
expected_config = {"mcpServers": {"lean-beam": new_entry}}
bash = shutil.which("bash")
runtime = Path(".lake/build/bin/beam-install-runtime").resolve()
essential_bin = root / "agy-essential-bin"
essential_bin.mkdir()
for name in ("awk", "basename", "cat", "chmod", "cmp", "cp", "date", "dirname", "elan",
             "env", "find", "grep", "ln", "mkdir", "mktemp", "mv", "readlink", "rm", "rmdir",
             "sed", "sha256sum", "shasum", "sort", "tr", "uname"):
    if tool := shutil.which(name):
        (essential_bin / name).symlink_to(tool)
env = dict(os.environ, PATH=str(essential_bin))
assert shutil.which("python3", path=env["PATH"]) is None
assert shutil.which("agy", path=env["PATH"]) is None


def shell(home, program, *args):
    return [bash, "-c", '. scripts/install-beam.sh\nset_agy_home "$1"\nshift\n' + program,
            "agy-fixture", str(home), *map(str, args)]


def registration(home, action="write", interactive=False):
    return shell(home, """
        set_bin_home "$1"
        dont_ask="$2"
        register_agy_mcp=1
        validate_requested_location_config
        if [ "$3" = write ]; then
          plan_agy_mcp_registration
          register_agy_mcp_server
        fi
        """, bin_home, "0" if interactive else "1", action)


def run(argv, environment=env):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, env=environment, text=True, timeout=20)


def fixture(label, raw=None, mode=0o640):
    home = root / f"agy-{label}"
    path = home / ".gemini/config/mcp_config.json"
    if raw is not None:
        path.parent.mkdir(parents=True)
        path.write_bytes(raw)
        path.chmod(mode)
    return home, path


def assert_no_staging(path):
    assert not list(path.parent.glob(".mcp_config.json.lean-beam-*")), path


def refuse(result, message, path):
    assert result.returncode != 0 and message in result.stdout, result.stdout
    assert_no_staging(path)


valid = rb"""{
  "user": 1e400,
  "precise": 0.123456789012345678901234567890123456789,
  "mcpServers": {
    "other": {"command": "/bin/echo", "env": {"API_KEY": "secret-do-not-print"}},
    "lean-beam": {
      "command": "/old",
      "enabledTools": ["lean_goal"],
      "disabledTools": ["lean_run_code"],
      "env": {"LABEL": "caf\u00e9"},
      "timeoutSeconds": 30,
      "args": [],
      "cwd": "/workspace",
      "headers": {"custom": "\uD83D\uDE00"},
      "custom": {"nested": [true, null]},
      "apiKey": "sk-SECRET-TRAILING"
    }
  },
  "hugeExponent": -9E+999999999999999999999999999999
}
"""
home, path = fixture("no-python-or-agy", valid)
expected = json.loads(valid, parse_float=lambda _: None)
expected["mcpServers"]["lean-beam"].update(new_entry)
result = run(registration(home))
assert result.returncode == 0 and not result.stdout, result.stdout
payload = path.read_bytes()
assert payload.startswith(b"{\n  \"user\": ") and payload.endswith(b"\n}\n"), payload
assert json.loads(payload, parse_float=lambda _: None) == expected
assert list(json.loads(payload, parse_float=lambda _: None)) == list(expected)
assert list(json.loads(payload, parse_float=lambda _: None)["mcpServers"]["lean-beam"]) == list(expected["mcpServers"]["lean-beam"])
for number in (b"1e400", b"0.123456789012345678901234567890123456789",
               b"-9E+999999999999999999999999999999"):
    assert number in payload
assert stat.S_IMODE(path.stat().st_mode) == 0o640
assert_no_staging(path)
installed = path.stat()
result = run(registration(home, interactive=True))
assert result.returncode == 0 and not result.stdout, result.stdout
assert (path.stat().st_ino, path.stat().st_mtime_ns, path.read_bytes()) == (
    installed.st_ino, installed.st_mtime_ns, payload)

for label, raw in (
    ("absent", None),
    ("zero-byte", b""),
    ("whitespace", b" \t\r\n"),
    ("bom-blank", b"\xef\xbb\xbf \t\r\n"),
    ("bom", b'\xef\xbb\xbf{"user": "kept"}\n'),
):
    home, path = fixture(label, raw)
    result = run(registration(home))
    assert result.returncode == 0 and not result.stdout, result.stdout
    expected = {**expected_config, "user": "kept"} if label == "bom" else expected_config
    assert json.loads(path.read_bytes()) == expected
    assert stat.S_IMODE(path.stat().st_mode) == (0o600 if raw is None else 0o640)

home, path = fixture("missing-command", b'{"mcpServers":{"lean-beam":{"timeout":60}}}')
result = run(registration(home))
assert result.returncode == 0 and not result.stdout, result.stdout
assert json.loads(path.read_bytes()) == {"mcpServers": {"lean-beam": {**new_entry, "timeout": 60}}}

for label, raw, message in (
    ("malformed", b"{not json\n", "invalid Antigravity MCP config"),
    ("root", b"[]", "root JSON value must be an object"),
    ("servers-array", b'{"mcpServers":[]}', "'mcpServers' must be a JSON object"),
    ("servers-null", b'{"mcpServers":null}', "'mcpServers' must be a JSON object"),
    ("duplicate", rb'{"mcpServers":{"other":{"nested":{"key":1,"k\u0065y":2}}}}', "duplicate JSON object key"),
    ("nan", b'{"value":NaN}', "invalid Antigravity MCP config"),
    ("infinity", b'{"value":Infinity}', "invalid Antigravity MCP config"),
    ("negative-infinity", b'{"value":-Infinity}', "invalid Antigravity MCP config"),
    ("leading-zero", b'{"value":01}', "invalid Antigravity MCP config"),
    ("bad-exponent", b'{"value":1e+}', "invalid JSON exponent"),
    ("surrogate-high", rb'{"value":"\ud800"}', "unpaired Unicode surrogate"),
    ("surrogate-low", rb'{"value":"\udfff"}', "unpaired Unicode surrogate"),
    ("deep", b"[" * 130 + b"0" + b"]" * 130, "JSON nesting exceeds"),
    ("oversized", b" " * (1024 * 1024 + 1), "1 MiB size limit"),
    ("double-bom", b"\xef\xbb\xbf\xef\xbb\xbf{}", "invalid Antigravity MCP config"),
    ("non-rfc-blank", b"\x0b", "invalid Antigravity MCP config"),
    ("line-comments", b'{// user settings\n"other": true}', "comments or trailing commas"),
    ("trailing-comma", b'{"other": true,}', "comments or trailing commas"),
):
    home, path = fixture(label, raw)
    result = run(registration(home))
    refuse(result, message, path)
    if message == "comments or trailing commas":
        assert "agy mcp add" in result.stdout, result.stdout
    assert path.read_bytes() == raw, label

for label, entry, reason in (
    ("entry-null", None, "must be a JSON object"),
    ("disabled", {"disabled": True}, "'disabled' must be false or absent"),
    ("disabled-number", {"disabled": 0}, "'disabled' must be a boolean"),
    ("url", {"url": "https://example.invalid"}, "remote transport"),
    ("server-url", {"serverUrl": "https://example.invalid"}, "remote transport"),
    ("http-url", {"httpUrl": None}, "remote transport"),
    ("args", {"args": ["--custom"]}, "'args' must be an empty array, Beam's --toolset flag, or absent"),
    ("args-object", {"args": {}}, "'args' must be an array of strings"),
    ("command-array", {"command": ["/old"]}, "'command' must be a string"),
    ("transport", {"transport": "http"}, "'transport' must specify stdio"),
    ("type", {"type": "sse"}, "'type' must specify stdio"),
    ("cwd", {"cwd": {}}, "'cwd' must be a string or absent"),
    ("env-array", {"env": []}, "'env' must be a JSON object"),
    ("env-value", {"env": {"NUMBER": 1}}, "'env' must be a JSON object"),
    ("enabled-object", {"enabledTools": {}}, "'enabledTools' must be an array of strings"),
    ("disabled-item", {"disabledTools": [1]}, "'disabledTools' must be an array of strings"),
    ("timeout-string", {"timeoutSeconds": "ten minutes"}, "'timeoutSeconds' must be an integer"),
    ("timeout-float", {"timeoutSeconds": 2.5}, "'timeoutSeconds' must be an integer"),
):
    raw = json.dumps({"mcpServers": {"lean-beam": entry}}, indent=2).encode()
    home, path = fixture(label, raw)
    result = run(registration(home))
    refuse(result, "conflicting 'mcpServers.lean-beam'", path)
    assert reason in result.stdout and path.read_bytes() == raw, (label, result.stdout)

home, path = fixture("physical-parent", valid)
alias_home = root / "agy-alias"
alias_home.symlink_to(home, target_is_directory=True)
result = run(registration(alias_home / "." / "missing"))
assert result.returncode == 0 and not result.stdout, result.stdout
assert (home / "missing/.gemini/config/mcp_config.json").is_file()
assert path.read_bytes() == valid

target = root / "agy-link-target.json"
target.write_bytes(valid)
for label, message in (
    ("symlink", "symlinked Antigravity MCP config"),
    ("directory", "non-regular Antigravity MCP config"),
    ("fifo", "non-regular Antigravity MCP config"),
    ("read-only", "read-only Antigravity MCP config"),
):
    home, path = fixture(label, valid if label == "read-only" else None, 0o444)
    if label == "symlink":
        path.parent.mkdir(parents=True)
        path.symlink_to(target)
    elif label == "directory":
        path.mkdir(parents=True)
    elif label == "fifo":
        path.parent.mkdir(parents=True)
        os.mkfifo(path)
    # On POSIX root, -w can succeed on permission bits alone; the native planner still refuses.
    if label != "read-only" or os.geteuid() != 0:
        refuse(run(registration(home, action="preflight")), message, path)
    refuse(run(registration(home)), message, path)
assert target.read_bytes() == valid


def interactive(argv, replies, before_reply=lambda: None, initial=b""):
    master, slave = pty.openpty()
    proc = subprocess.Popen(argv, stdin=slave, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, env=env)
    os.close(slave)
    try:
        if initial:
            os.write(master, initial)
        preview = b""
        while b"Allow this edit? [y/N]" not in preview:
            ready, _, _ = select.select([proc.stdout], [], [], 10)
            assert ready, preview
            chunk = os.read(proc.stdout.fileno(), 4096)
            assert chunk, preview
            preview += chunk
        before_reply()
        os.write(master, replies)
        output, _ = proc.communicate(timeout=20)
        return proc.returncode, preview.decode(), (preview + output).decode()
    finally:
        os.close(master)
        if proc.poll() is None:
            proc.kill()
            proc.communicate()


def installer(home, *args):
    # Exercise real admission, publication and the native writer with a prebuilt construction tool.
    # Skip generation assembly here; the full installer tests assemble and publish real runtimes.
    return shell(home, """
        set_install_root "$1"
        set_bin_home "$2"
        shift 2
        ensure_runtime_artifacts() { printf 'fixture build reached\n'; }
        prepare_install_version() {
          prepared_version_root="$versions_root/fixture"
          mkdir -p "$prepared_version_root/bin"
          remove_owned_staging_dir "$1"
        }
        main --toolchain "$(<lean-toolchain)" --agy-mcp "$@"
        """, root / f"{home.name}-runtime", root / f"{home.name}-bin", *args)


home, path = fixture("decline-preview", valid)
rc, preview, transcript = interactive(installer(home, "--agy"), b"N\n", initial=b"Y\n")
assert rc != 0 and "cancelled before editing" in transcript, transcript
assert str(path) in preview and 'fixture build reached' in preview, preview
assert '-  "command": "/old"\n' in preview and '+  "disabled": false\n' in preview, preview
assert all(secret not in transcript for secret in
           ("sk-SECRET-TRAILING", "apiKey", "secret-do-not-print", "API_KEY", "/bin/echo")), transcript
assert path.read_bytes() == valid
assert not (root / f"{home.name}-runtime/current").exists()
assert not (root / f"{home.name}-bin").exists()
assert not (path.parent / "skills").exists()
assert_no_staging(path)

home, path = fixture("lifecycle-invalid", b'{"mcpServers":null}')
refuse(run(installer(home, "--dont-ask", "--agy")), "'mcpServers' must be a JSON object", path)
assert not (root / f"{home.name}-runtime/current").exists()
assert not (root / f"{home.name}-bin").exists()
assert not (path.parent / "skills").exists()

if sys.platform.startswith("linux") and not os.access("/sys", os.W_OK):
    protected = Path("/sys") / root.name
else:
    locked = root / "locked-agy-ancestor"
    locked.mkdir(mode=0o500)
    protected = locked / "missing"
if not os.access(protected.parent, os.W_OK):
    result = run(installer(protected, "--dont-ask"))
    assert result.returncode != 0 and "not writable and searchable" in result.stdout, result.stdout
    assert "fixture build reached" not in result.stdout, result.stdout

home, path = fixture("closed-stdin")
argv = installer(home, "--dont-ask")
argv[2] = "exec 0<&-\n" + argv[2]
result = run(argv)
assert result.returncode == 0, result.stdout
assert "MCP: registered this run" in result.stdout, result.stdout
after = path.stat()
result = run(argv)
assert result.returncode == 0 and "MCP: already registered" in result.stdout, result.stdout
assert (path.stat().st_ino, path.stat().st_mtime_ns) == (after.st_ino, after.st_mtime_ns)

home, path = fixture("interactive-new")
rc, preview, transcript = interactive(registration(home, interactive=True), b"y\n")
assert rc == 0 and '"mcpServers":' in preview and command in preview, transcript
assert json.loads(path.read_bytes()) == expected_config

home, path = fixture("interactive-empty", b" \n")
rc, preview, transcript = interactive(registration(home, interactive=True), b"n\n")
assert rc != 0 and '"mcpServers":' in preview, transcript
assert path.read_bytes() == b" \n"
assert_no_staging(path)

concurrent = b'{"changed": true}\n'
home, path = fixture("concurrent-edit", valid)
rc, _, transcript = interactive(registration(home, interactive=True), b"y\n",
                                lambda: path.write_bytes(concurrent))
assert rc != 0 and "changed before writing" in transcript, transcript
assert path.read_bytes() == concurrent
assert_no_staging(path)

home, path = fixture("concurrent-symlink", valid)
def introduce_symlink():
    path.unlink()
    path.symlink_to(target)

rc, _, transcript = interactive(registration(home, interactive=True), b"y\n", introduce_symlink)
assert rc != 0 and "symlinked Antigravity MCP config" in transcript, transcript
assert path.is_symlink() and target.read_bytes() == valid
assert_no_staging(path)

# Verify the actual metadata and byte hash passed across plan/apply.
home, path = fixture("fingerprint", valid)
plan = subprocess.run([runtime, "agy-mcp", "plan", path, command], env=env,
                      capture_output=True, text=True, timeout=10, check=True)
state, fingerprint, physical = plan.stdout.splitlines()
assert state == "edit" and physical == str(path), plan
assert fingerprint.endswith(":" + hashlib.sha256(valid).hexdigest()), fingerprint

if sys.platform.startswith("linux"):
    # Deterministically create a competing file at link, after every pre-publication check.
    # A forced rename failure also exercises staged file cleanup at the write boundary.
    injection = root / "agy-publication-fault.c"
    injection.write_text(r"""
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

static int is_leaf(const char *path) {
  const char *slash = strrchr(path, '/');
  return strcmp(slash ? slash + 1 : path, "mcp_config.json") == 0;
}
int link(const char *oldpath, const char *newpath) {
  if (is_leaf(newpath)) {
    int fd = open(newpath, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) _exit(88);
    const char contents[] = "{\"competing\":true}\n";
    if (write(fd, contents, sizeof contents - 1) != sizeof contents - 1) _exit(89);
    close(fd);
  }
  int (*next)(const char *, const char *) = dlsym(RTLD_NEXT, "link");
  return next(oldpath, newpath);
}
int rename(const char *oldpath, const char *newpath) {
  if (is_leaf(newpath)) {
    errno = EIO;
    return -1;
  }
  int (*next)(const char *, const char *) = dlsym(RTLD_NEXT, "rename");
  return next(oldpath, newpath);
}
""", encoding="utf-8")
    library = injection.with_suffix(".so")
    compiler = shutil.which("cc") or shutil.which("clang")
    subprocess.run([compiler, "-shared", "-fPIC", injection, "-o", library, "-ldl"], check=True)
    injected = dict(env, LD_PRELOAD=str(library))

    home, path = fixture("concurrent-create")
    refuse(run(registration(home), injected), "changed before writing", path)
    assert path.read_bytes() == b'{"competing":true}\n'

    home, path = fixture("replace-failure", valid)
    refuse(run(registration(home), injected), "cannot replace the Antigravity MCP config", path)
    assert path.read_bytes() == valid
PYTHON_AGY
  )
}

run_step "Antigravity selection aliases" test_agy_selection_aliases

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

run_step "Antigravity MCP config validation, writes, and approvals" test_agy_mcp_config

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

interactive_agy_home="$tmp_root/interactive-agy-home"
interactive_agy_install_root="$tmp_root/interactive-agy-install-root"
interactive_agy_custom_home="$tmp_root/interactive-agy-sandbox"
interactive_agy_custom_bin="$tmp_root/interactive-agy-bin"
interactive_agy_custom_runtime="$tmp_root/interactive-agy-runtime"
interactive_agy_transcript="$tmp_root/install-interactive-agy-transcript"
mkdir -p "$interactive_agy_home"
if BEAM_TEST_MCP_STUB_LOG="$interactive_mcp_stub_log" PATH="$interactive_mcp_stub_bin:$PATH" \
    beam_install_run_interactive_from_source \
      "$interactive_agy_transcript" "$interactive_agy_home" "$interactive_agy_install_root" \
      $'\n\n6\nchange\n'"$interactive_agy_custom_bin"$'\n'"$interactive_agy_custom_runtime"$'\n'"$interactive_agy_custom_home"$'\nN\n'; then
  echo "expected interactive Antigravity MCP install to stop when write permission is denied" >&2
  cat "$interactive_agy_transcript" >&2
  exit 1
fi
assert_contains "$interactive_agy_transcript" 'Write Locations'
assert_contains "$interactive_agy_transcript" 'Change Locations'
assert_contains_literal "$interactive_agy_transcript" "Command directory [$interactive_agy_home/.local/bin]"
assert_contains_literal "$interactive_agy_transcript" "Runtime install root [$interactive_agy_install_root]"
assert_contains_literal "$interactive_agy_transcript" "Antigravity home [$BEAM_AGY_HOME]"
assert_contains_literal "$interactive_agy_transcript" "Antigravity home: $interactive_agy_custom_home"
assert_contains_literal "$interactive_agy_transcript" \
  "Antigravity config: $(cd -P "$tmp_root" && pwd)/interactive-agy-sandbox/.gemini/config/mcp_config.json"
assert_contains "$interactive_agy_transcript" 'cancelled before: Write Locations'
assert_not_exists "$interactive_agy_custom_bin"
assert_not_exists "$interactive_agy_custom_runtime"
assert_not_exists "$interactive_agy_custom_home"
remove_tmp_file "$interactive_agy_transcript"

printf '[%s] installer admission and interactive plans finished in %ss\n' \
  "$BEAM_TEST_SUITE" "$(( $(date +%s) - install_admission_start ))"

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
if [ "${installed_lean_beam_version%%$'\n'*}" != "lean-beam 0.2.0" ]; then
  echo "expected installed lean-beam version 0.2.0" >&2
  exit 1
fi
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "wrapper: $installed_version_root/bin/lean-beam"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam home: $installed_version_root"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "beam cli: $installed_version_root/libexec/beam-cli"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "runtime payload: $installed_payload_id"
assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "manifest: $installed_version_root/manifest.json"
if [ -n "$expected_source_commit" ]; then
  assert_output_contains "installed lean-beam --version" "$installed_lean_beam_version" "source commit: $expected_source_commit"
fi
installed_mcp_version="$("$installed_mcp" --version)"
if [ "${installed_mcp_version%%$'\n'*}" != "lean-beam-mcp 0.2.0" ]; then
  echo "expected installed lean-beam-mcp version 0.2.0" >&2
  exit 1
fi
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
assert_not_exists "$BEAM_AGY_HOME"

run_step "install Lean skills" run_install_from_source --toolchain "$toolchain" --all-skills

for skills_home in "$CODEX_HOME/skills" "$CLAUDE_HOME/skills" "$PI_CODING_AGENT_DIR/skills" "$OPENCODE_CONFIG_DIR/skills" "$VIBE_HOME/skills" "$BEAM_AGY_HOME/.gemini/config/skills"; do
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
assert_contains_literal "$VIBE_HOME/config.toml" "command = [\"$installed_mcp\"]"
assert_contains_literal "$VIBE_HOME/config.toml" 'args = []'
assert_contains_literal "$VIBE_HOME/config.toml" 'tool_timeout_sec = 600'
assert_not_contains "$mcp_stub_log" "agy must not be invoked"
assert_file "$BEAM_AGY_HOME/.gemini/config/mcp_config.json"
python3 - "$BEAM_AGY_HOME/.gemini/config/mcp_config.json" "$installed_mcp" <<'PY'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    config = json.load(f)
server = config["mcpServers"]["lean-beam"]
assert server["command"] == sys.argv[2], server
assert server["disabled"] is False, server
PY

run_step "inspect installed client configuration" \
  python3 tests/test-client-doctor-installed.py "$installed_lean_beam" "$tmp_root"

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
assert_contains_literal "$custom_vibe_home/config.toml" "command = [\"$installed_mcp\"]"
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

custom_agy_home="$tmp_root/agy-sandbox"
custom_agy_mcp_stub_log="$tmp_root/mcp-stubs-custom-agy.log"
run_step "register Antigravity MCP with custom home" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$custom_agy_mcp_stub_log" \
    --toolchain "$toolchain" --agy-mcp --agy-home "$custom_agy_home" <&-
assert_not_exists "$custom_agy_mcp_stub_log"
assert_file "$custom_agy_home/.gemini/config/mcp_config.json"

relative_agy_home_err="$(mktemp "$tmp_root/agy-relative-home-XXXXXX")"
if beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$tmp_root/mcp-stubs-relative-agy.log" \
    --toolchain "$toolchain" --agy-mcp --agy-home relative-agy-home \
    2>"$relative_agy_home_err"; then
  echo "expected --agy-home to reject relative paths" >&2
  remove_tmp_file "$relative_agy_home_err"
  exit 1
fi
assert_contains "$relative_agy_home_err" "Antigravity home must be an absolute path"
remove_tmp_file "$relative_agy_home_err"

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

core_codex_home="$tmp_root/codex-core-sandbox"
core_codex_stub_log="$tmp_root/mcp-stubs-core-codex.log"
run_step "register Codex MCP with --mcp-toolset core" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$core_codex_stub_log" \
    --toolchain "$toolchain" --codex-mcp --mcp-toolset core --codex-home "$core_codex_home"
assert_contains_literal "$core_codex_stub_log" \
  "codex|mcp|add|lean-beam|--|$installed_mcp|--toolset|core|CODEX_HOME=$core_codex_home"
assert_contains_literal "$core_codex_home/config.toml" 'args = ["--toolset", "core"]'
assert_contains_literal "$core_codex_home/config.toml" 'supports_parallel_tool_calls = true'

core_claude_home="$tmp_root/claude-core-sandbox"
core_claude_config="$core_claude_home/.claude.json"
core_claude_stub_log="$tmp_root/mcp-stubs-core-claude.log"
run_step "register Claude MCP with --mcp-toolset core" \
  beam_install_run_with_mcp_stubs "$mcp_stub_bin" "$core_claude_stub_log" \
    --toolchain "$toolchain" --claude-mcp --mcp-toolset core --claude-mcp-config "$core_claude_config"
assert_contains_literal "$core_claude_stub_log" \
  "claude|mcp|add|--scope|user|lean-beam|--|$installed_mcp|--toolset|core|HOME=$core_claude_home"
assert_contains_literal "$core_claude_config" '"args": ["--toolset", "core"]'

core_vibe_home="$tmp_root/vibe-core-sandbox"
run_step "register Mistral Vibe MCP with --mcp-toolset core" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --vibe-mcp --mcp-toolset core --vibe-home "$core_vibe_home"
assert_contains_literal "$core_vibe_home/config.toml" 'args = ["--toolset", "core"]'

core_agy_home="$tmp_root/agy-core-sandbox"
run_step "register Antigravity MCP with --mcp-toolset core" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --agy-mcp --mcp-toolset core --agy-home "$core_agy_home"
python3 - "$core_agy_home/.gemini/config/mcp_config.json" "$installed_mcp" <<'PY'
import json, sys
config = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert config["mcpServers"]["lean-beam"] == {
    "command": sys.argv[2],
    "disabled": False,
    "args": ["--toolset", "core"],
}, config
PY
run_step "switch Antigravity MCP back to --mcp-toolset full" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --agy-mcp --mcp-toolset full --agy-home "$core_agy_home"
python3 - "$core_agy_home/.gemini/config/mcp_config.json" "$installed_mcp" <<'PY'
import json, sys
config = json.loads(open(sys.argv[1], encoding="utf-8").read())
assert config["mcpServers"]["lean-beam"] == {
    "command": sys.argv[2],
    "disabled": False,
}, config
PY

core_opencode_transcript="$tmp_root/opencode-mcp-core-transcript"
run_step "show OpenCode MCP setup with --mcp-toolset core" \
  bash "$source_checkout/scripts/install-beam.sh" --dont-ask --toolchain "$toolchain" \
    --opencode-mcp --mcp-toolset core >"$core_opencode_transcript" 2>&1
assert_contains_literal "$core_opencode_transcript" "command            $installed_mcp --toolset core"
remove_tmp_file "$core_opencode_transcript"

invalid_toolset_err="$(mktemp "$tmp_root/invalid-mcp-toolset-XXXXXX")"
if (
  cd "$source_checkout"
  bash scripts/install-beam.sh --dont-ask --codex-mcp --mcp-toolset bogus >/dev/null 2>"$invalid_toolset_err"
); then
  echo "expected invalid --mcp-toolset value to fail" >&2
  remove_tmp_file "$invalid_toolset_err"
  exit 1
fi
assert_contains "$invalid_toolset_err" "invalid value for --mcp-toolset: bogus"
remove_tmp_file "$invalid_toolset_err"

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
if ! grep -q 'restore or link its exact Lean installation, then retry' "$unavailable_err"; then
  echo "expected unavailable target failure to explain SDK recovery" >&2
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

stale_sync_out="$(mktemp "$tmp_root/install-stale-sync-out-XXXXXX")"
stale_sync_err="$(mktemp "$tmp_root/install-stale-sync-err-XXXXXX")"
if "$installed_lean_beam" --root "$project_root" sync SaveSmoke/A.lean >"$stale_sync_out" 2>"$stale_sync_err"; then
  echo "expected installed wrapper sync to fail on a stale imported target" >&2
  cat "$stale_sync_out" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_out"
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
if ! assert_cli_error_json "$stale_sync_out" syncBarrierIncomplete \
    'Follow recovery_plan in order; stop if a step fails'; then
  echo "expected installed wrapper stale-import sync failure to expose syncBarrierIncomplete" >&2
  cat "$stale_sync_out" >&2
  cat "$stale_sync_err" >&2
  remove_tmp_file "$stale_sync_out"
  remove_tmp_file "$stale_sync_err"
  exit 1
fi
python3 - "$stale_sync_out" <<'PYRECOVERY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as stream:
    error = json.load(stream)["error"]
assert error["data"]["recovery_plan"] == ['lean-beam refresh "SaveSmoke/A.lean"'], error
assert "rebuild only after cleanup completes" in error["message"], error
assert "fileProgress=" not in error["message"], error
PYRECOVERY
remove_tmp_file "$stale_sync_out"
remove_tmp_file "$stale_sync_err"

project_root_standalone="$tmp_root/external-project-standalone"
rsync -a --exclude='.beam/' tests/save_olean_project/ "$project_root_standalone"/

cat > "$project_root_standalone/StandaloneSaveSmoke.lean" <<'EOF'
import SaveSmoke.B

#check bVal
EOF

start_installed_owner "$project_root_standalone" "installed-standalone"

standalone_sync="$("$installed_lean_beam" --root "$project_root_standalone" sync StandaloneSaveSmoke.lean)"
if ! printf '%s\n' "$standalone_sync" | python3 -c 'import json,sys; payload=json.load(sys.stdin); sys.exit(0 if payload.get("ok") is True else 1)'; then
  echo "expected installed wrapper sync to succeed on a standalone file the daemon can open" >&2
  printf '%s\n' "$standalone_sync" >&2
  exit 1
fi

standalone_save_out="$(mktemp "$tmp_root/install-standalone-save-out-XXXXXX")"
standalone_save_err="$(mktemp "$tmp_root/install-standalone-save-err-XXXXXX")"
if "$installed_lean_beam" --root "$project_root_standalone" save StandaloneSaveSmoke.lean >"$standalone_save_out" 2>"$standalone_save_err"; then
  echo "expected installed wrapper save to reject a standalone file outside the Lake module graph" >&2
  cat "$standalone_save_out" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_out"
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
if ! assert_cli_error_json "$standalone_save_out" saveTargetNotModule \
    'save only works for synced files that belong to the current Lake workspace package graph'; then
  echo "expected installed wrapper standalone save failure to expose saveTargetNotModule" >&2
  cat "$standalone_save_out" >&2
  cat "$standalone_save_err" >&2
  remove_tmp_file "$standalone_save_out"
  remove_tmp_file "$standalone_save_err"
  exit 1
fi
remove_tmp_file "$standalone_save_out"
remove_tmp_file "$standalone_save_err"
