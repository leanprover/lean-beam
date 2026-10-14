#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# Shared helper functions for installer tests. Callers provide the install-test
# globals such as tmp_root, host_elan_home, source_checkout, and validated_toolchains.
# shellcheck disable=SC2154

# shellcheck source=tests/lib/tmp-guards.sh
. tests/lib/tmp-guards.sh

beam_test_overlay_install_source() {
  rsync -a \
    --exclude='.git' \
    --exclude='.lake/' \
    --exclude='.beam/' \
    --exclude='.codex-worktrees/' \
    "$1"/ "$2"/
}

expect_owned_tmp_dir() {
  beam_test_expect_owned_tmp_dir "$1" beam-install
}

expect_path_within_tmp_root() {
  beam_test_expect_path_within_owned_tmp_dir "$1" "$tmp_root" beam-install
}

remove_tmp_tree() {
  local path="$1"
  beam_test_remove_tmp_tree_within_owned_tmp_dir "$path" "$tmp_root" beam-install
}

remove_tmp_file() {
  local path="$1"
  expect_path_within_tmp_root "$path"
  rm -f -- "$path"
}

elan_toolchain_dir_name() {
  printf '%s\n' "$1" | sed 's,/,--,g; s,:,---,g'
}

host_toolchain_dir_for() {
  local toolchain="$1"
  local normalized=""
  if [ -z "$host_elan_home" ] || [ ! -d "$host_elan_home/toolchains" ]; then
    return 1
  fi
  if [ -d "$host_elan_home/toolchains/$toolchain" ]; then
    printf '%s\n' "$host_elan_home/toolchains/$toolchain"
    return 0
  fi
  normalized="$(elan_toolchain_dir_name "$toolchain")"
  if [ -d "$host_elan_home/toolchains/$normalized" ]; then
    printf '%s\n' "$host_elan_home/toolchains/$normalized"
    return 0
  fi
  return 1
}

preseed_elan_home() {
  local target_elan_home="$1"
  shift
  local toolchain=""
  local host_toolchain_dir=""
  local target_toolchain_dir=""

  case "$BEAM_INSTALL_TEST_PRESEED_ELAN" in
    0|false|False|FALSE|no|No|NO|off|Off|OFF)
      return 0
      ;;
    auto|1|true|True|TRUE|yes|Yes|YES|on|On|ON|require)
      ;;
    *)
      echo "unknown BEAM_INSTALL_TEST_PRESEED_ELAN mode: $BEAM_INSTALL_TEST_PRESEED_ELAN" >&2
      exit 1
      ;;
  esac

  expect_path_within_tmp_root "$target_elan_home"
  mkdir -p "$target_elan_home/toolchains"
  for toolchain in "$@"; do
    [ -n "$toolchain" ] || continue
    if host_toolchain_dir="$(host_toolchain_dir_for "$toolchain")"; then
      target_toolchain_dir="$target_elan_home/toolchains/$(basename "$host_toolchain_dir")"
      if [ ! -e "$target_toolchain_dir" ]; then
        ln -s "$host_toolchain_dir" "$target_toolchain_dir"
      fi
    elif [ "$BEAM_INSTALL_TEST_PRESEED_ELAN" = "require" ]; then
      echo "host elan cache is missing $toolchain; install it or set BEAM_INSTALL_TEST_PRESEED_ELAN=auto" >&2
      exit 1
    fi
  done
}

beam_install_setup_mcp_cli_stubs() {
  local stub_bin="$1"
  local log_path="$2"
  mkdir -p "$stub_bin"
  rm -f -- "$log_path"
  cat > "$stub_bin/codex" <<'SH'
#!/usr/bin/env bash
{
  printf 'codex'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '|CODEX_HOME=%s' "${CODEX_HOME:-}"
  printf '\n'
} >> "$BEAM_TEST_MCP_STUB_LOG"
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "add" ] && [ "${3:-}" = "lean-beam" ]; then
  mkdir -p "${CODEX_HOME:?}"
  {
    if [ -s "$CODEX_HOME/config.toml" ]; then
      printf '\n'
    fi
    # Exercise a valid literal-quoted key so the installer cannot assume a bare key.
    printf "[mcp_servers.'lean-beam']\n"
    printf 'command = "%s"\n' "${5:?}"
    printf 'supports_parallel_tool_calls = false\n'
  } >> "$CODEX_HOME/config.toml"
fi
exit 0
SH
  cat > "$stub_bin/claude" <<'SH'
#!/usr/bin/env bash
{
  printf 'claude'
  for arg in "$@"; do
    printf '|%s' "$arg"
  done
  printf '|HOME=%s' "${HOME:-}"
  printf '\n'
} >> "$BEAM_TEST_MCP_STUB_LOG"
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "add" ]; then
  python3 - "$HOME/.claude.json" "${7:?}" <<'PY_CLAUDE'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text()) if path.exists() else {}
config.setdefault("mcpServers", {})["lean-beam"] = {
    "type": "stdio", "command": sys.argv[2], "args": [],
}
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(config))
PY_CLAUDE
fi
exit 0
SH
  chmod +x "$stub_bin/codex" "$stub_bin/claude"
}

beam_install_run_with_mcp_stubs() {
  local stub_bin="$1"
  local log_path="$2"
  shift 2
  preseed_elan_home "$HOME/.elan" ${validated_toolchains[@]+"${validated_toolchains[@]}"}
  (
    cd "$source_checkout" || exit
    BEAM_TEST_MCP_STUB_LOG="$log_path" PATH="$stub_bin:$PATH" \
      bash scripts/install-beam.sh --dont-ask "$@" > /dev/null
  )
}

beam_install_run_interactive_from_source() {
  local transcript="$1"
  local install_home="$2"
  local install_root="$3"
  local input_text="$4"
  shift 4
  preseed_elan_home "$install_home/.elan" ${validated_toolchains[@]+"${validated_toolchains[@]}"}
  (
    cd "$source_checkout" || exit
    python3 - "$transcript" "$install_home" "$install_root" "$input_text" "$@" <<'PY'
import errno
import os
import pty
import select
import subprocess
import sys

transcript_path = sys.argv[1]
install_home = sys.argv[2]
install_root = sys.argv[3]
input_text = sys.argv[4]
cmd = ["bash", "scripts/install-beam.sh", *sys.argv[5:]]
env = os.environ.copy()
env["HOME"] = install_home
env["BEAM_INSTALL_ROOT"] = install_root

master, slave = pty.openpty()
proc = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True, env=env)
os.close(slave)
if input_text:
    os.write(master, input_text.encode())

chunks = []
while True:
    ready, _, _ = select.select([master], [], [], 0.1)
    if master in ready:
        try:
            data = os.read(master, 4096)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        chunks.append(data)
    if proc.poll() is not None:
        while True:
            try:
                data = os.read(master, 4096)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not data:
                break
            chunks.append(data)
        break

rc = proc.wait()
os.close(master)
with open(transcript_path, "wb") as f:
    f.write(b"".join(chunks))
sys.exit(rc)
PY
  )
}
