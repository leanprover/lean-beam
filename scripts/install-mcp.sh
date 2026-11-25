#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

# MCP client selection and registration helpers for scripts/install-beam.sh.
# This file is sourced by the installer and intentionally uses its state.
# shellcheck disable=SC2034,SC2154

prompt_mcp_registration_selection() {
  local selection=""
  local target=""
  selection="$(prompt_agent_target_multi_choice \
    "MCP Registration" \
    "Register lean-beam-mcp with:" \
    "MCP clients" \
    "MCP registration" \
    "codex|Codex|c" \
    "claude|Claude Code|claude-code" \
    "opencode|OpenCode|o open-code" \
    "vibe|Mistral Vibe|v mistral mistral-vibe" \
    "agy|Antigravity|antigravity")"
  register_codex_mcp=0
  register_claude_mcp=0
  register_opencode_mcp=0
  register_vibe_mcp=0
  register_agy_mcp=0
  for target in $selection; do
    case "$target" in
      none)
        ;;
      codex)
        register_codex_mcp=1
        ;;
      claude)
        register_claude_mcp=1
        ;;
      opencode)
        register_opencode_mcp=1
        ;;
      vibe)
        register_vibe_mcp=1
        ;;
      agy)
        register_agy_mcp=1
        ;;
    esac
  done
}

verify_requested_mcp_clients() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    validate_codex_home
    ensure_codex_mcp_config_replaceable
    if ! command -v codex >/dev/null 2>&1; then
      die "cannot register Codex MCP server because codex is not on PATH"
    fi
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    validate_claude_mcp_config_path
    if ! command -v claude >/dev/null 2>&1; then
      die "cannot register Claude Code MCP server because claude is not on PATH"
    fi
  fi
  if [ "$register_vibe_mcp" -eq 1 ]; then
    validate_vibe_home
    ensure_vibe_mcp_config_replaceable
  fi
  if [ "$register_agy_mcp" -eq 1 ]; then
    validate_agy_home
    edit_agy_mcp_config preflight
  fi
}

ensure_codex_mcp_config_replaceable() {
  if [ -L "$codex_mcp_config" ]; then
    die "refusing to edit symlinked Codex MCP config at $codex_mcp_config"
  fi
  if [ -e "$codex_mcp_config" ] && [ ! -f "$codex_mcp_config" ]; then
    die "refusing to edit non-file Codex MCP config at $codex_mcp_config"
  fi
}

ensure_vibe_mcp_config_replaceable() {
  if [ -L "$vibe_mcp_config" ]; then
    die "refusing to edit symlinked Mistral Vibe config at $vibe_mcp_config"
  fi
  if [ -e "$vibe_mcp_config" ] && [ ! -f "$vibe_mcp_config" ]; then
    die "refusing to edit non-file Mistral Vibe config at $vibe_mcp_config"
  fi
  require_vibe_mcp_servers_appendable
}

# TOML forbids extending an inline `mcp_servers = [...]` array with [[mcp_servers]]
# tables. The installer removes Vibe's default empty assignment, but refuses to
# rewrite inline entries it cannot merge safely.
require_vibe_mcp_servers_appendable() {
  if [ ! -f "$vibe_mcp_config" ]; then
    return 0
  fi
  if awk '
    /^[[:space:]]*\[/ { exit 0 }
    /^[[:space:]]*mcp_servers[[:space:]]*=/ {
      if ($0 !~ /^[[:space:]]*mcp_servers[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*(#.*)?$/) {
        exit 1
      }
    }
  ' "$vibe_mcp_config"; then
    return 0
  fi
  die "refusing to edit Mistral Vibe config with inline mcp_servers entries at $vibe_mcp_config; move them to [[mcp_servers]] tables first"
}

ensure_mcp_config_dir() {
  local path="$1"
  local label="$2"
  require_absolute_path "$path" "$label"
  require_not_root "$path" "$label"
  if [ -e "$path" ]; then
    if [ ! -d "$path" ]; then
      die "refusing to use non-directory $label at $path"
    fi
    return 0
  fi
  mkdir -p "$path"
}

set_codex_parallel_tool_calls() {
  local tmp_config=""
  if [ -L "$codex_mcp_config" ] || [ ! -f "$codex_mcp_config" ]; then
    die "Codex did not write a regular MCP config at $codex_mcp_config"
  fi
  tmp_config="$(mktemp "$codex_home/.config.toml.lean-beam-XXXXXX")"
  if ! awk '
    BEGIN {
      single_quote = sprintf("%c", 39)
      mcp_key = "(mcp_servers|\"mcp_servers\"|" single_quote "mcp_servers" single_quote ")"
      server_key = "(lean-beam|\"lean-beam\"|" single_quote "lean-beam" single_quote ")"
      target_table = "^\\[" mcp_key "\\." server_key "\\]$"
    }
    {
      compact_header = $0
      sub(/\][[:space:]]*#.*$/, "]", compact_header)
      gsub(/[[:space:]]/, "", compact_header)
    }
    compact_header ~ target_table {
      print
      print "supports_parallel_tool_calls = true"
      saw_target = 1
      in_target = 1
      next
    }
    /^[[:space:]]*\[/ {
      in_target = 0
      print
      next
    }
    in_target && /^[[:space:]]*supports_parallel_tool_calls[[:space:]]*=/ { next }
    { print }
    END { if (!saw_target) exit 2 }
  ' "$codex_mcp_config" >"$tmp_config"; then
    rm -f -- "$tmp_config"
    die "Codex MCP config does not contain the registered lean-beam server table: $codex_mcp_config"
  fi
  mv "$tmp_config" "$codex_mcp_config"
}

register_codex_mcp_server() {
  ensure_mcp_config_dir "$codex_home" "Codex home"
  ensure_codex_mcp_config_replaceable
  CODEX_HOME="$codex_home" codex mcp add lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  set_codex_parallel_tool_calls
  registered_mcp_targets+=("Codex: lean-beam")
}

register_claude_mcp_server() {
  ensure_mcp_config_dir "$claude_mcp_home" "Claude Code MCP config home"
  HOME="$claude_mcp_home" claude mcp remove --scope user lean-beam >/dev/null 2>&1 || true
  HOME="$claude_mcp_home" claude mcp add --scope user lean-beam -- "$bin_home/lean-beam-mcp" >/dev/null
  registered_mcp_targets+=("Claude Code: lean-beam")
}

register_opencode_mcp_server() {
  manual_mcp_targets+=("OpenCode: lean-beam")
}

# Print the Mistral Vibe config with any existing lean-beam [[mcp_servers]] block,
# the top-level default empty `mcp_servers = []` assignment, and trailing blank
# lines removed, so re-registration replaces instead of duplicating and the
# appended [[mcp_servers]] table stays valid TOML.
vibe_mcp_config_without_lean_beam_server() {
  awk '
    function flush_block() {
      if (in_block && !block_is_lean_beam) {
        printf "%s", block
      }
      block = ""
      in_block = 0
      block_is_lean_beam = 0
    }
    /^[[:space:]]*\[\[[[:space:]]*mcp_servers[[:space:]]*\]\][[:space:]]*(#.*)?$/ {
      seen_table = 1
      flush_block()
      in_block = 1
      block = $0 "\n"
      next
    }
    /^[[:space:]]*\[/ {
      seen_table = 1
      flush_block()
      print
      next
    }
    {
      if (in_block) {
        block = block $0 "\n"
        if ($0 ~ /^[[:space:]]*name[[:space:]]*=[[:space:]]*"lean-beam"[[:space:]]*(#.*)?$/) {
          block_is_lean_beam = 1
        }
      } else if (seen_table \
        || $0 !~ /^[[:space:]]*mcp_servers[[:space:]]*=[[:space:]]*\[[[:space:]]*\][[:space:]]*(#.*)?$/) {
        print
      }
    }
    END { flush_block() }
  ' "$1" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) {
        last--
      }
      for (i = 1; i <= last; i++) {
        print lines[i]
      }
    }
  '
}

register_vibe_mcp_server() {
  local tmp_config=""
  local tmp_config_has_content=0
  local mcp_command="$bin_home/lean-beam-mcp"
  case "$mcp_command" in
    *'"'*|*\\*)
      die "refusing to write Mistral Vibe MCP command path containing quotes or backslashes: $mcp_command"
      ;;
  esac
  ensure_mcp_config_dir "$vibe_home" "Mistral Vibe home"
  ensure_vibe_mcp_config_replaceable
  confirm_path_edit "register lean-beam MCP server in the Mistral Vibe config" "$vibe_mcp_config"
  tmp_config="$(mktemp "$vibe_home/.config.toml.lean-beam-XXXXXX")"
  if [ -f "$vibe_mcp_config" ]; then
    vibe_mcp_config_without_lean_beam_server "$vibe_mcp_config" >"$tmp_config"
  fi
  if [ -s "$tmp_config" ]; then
    tmp_config_has_content=1
  fi
  {
    if [ "$tmp_config_has_content" -eq 1 ]; then
      printf '\n'
    fi
    printf '[[mcp_servers]]\n'
    printf 'name = "lean-beam"\n'
    printf 'transport = "stdio"\n'
    printf 'command = ["%s"]\n' "$mcp_command"
    printf 'args = []\n'
    printf 'tool_timeout_sec = 600\n'
  } >>"$tmp_config"
  mv "$tmp_config" "$vibe_mcp_config"
  registered_mcp_targets+=("Mistral Vibe: lean-beam")
}

edit_agy_mcp_config() {
  local action="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    die "cannot register Antigravity MCP server because python3 is not on PATH"
  fi
  # Keep the original input on fd 3 while Python reads its program from stdin.
  python3 - "$action" "$agy_mcp_config" "$bin_home/lean-beam-mcp" "$dont_ask" 3<&0 <<'PY'
from decimal import Decimal, DecimalException
from difflib import unified_diff
import json
import os
from pathlib import Path
import stat
import sys
from uuid import uuid4

action, requested_path, command, dont_ask = sys.argv[1:]
requested_path = Path(requested_path)


def physical_path():
    # Follow directory aliases but never resolve the config leaf itself.
    return requested_path.parent.resolve() / requested_path.name


def file_stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_config(path, dir_fd=None):
    name = path if dir_fd is None else path.name
    try:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None, b""
    if stat.S_ISLNK(info.st_mode):
        raise ValueError(f"refusing to edit symlinked Antigravity MCP config at {path}")
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"refusing to edit non-regular Antigravity MCP config at {path}")
    writable = (
        os.access(name, os.W_OK, dir_fd=dir_fd)
        if dir_fd is None or os.access in os.supports_dir_fd
        else os.access(path, os.W_OK)
    )
    if not info.st_mode & 0o222 or not writable:
        raise ValueError(f"refusing to edit read-only Antigravity MCP config at {path}; make it writable first")

    # Never follow a leaf symlink or block on a FIFO introduced before open.
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    with os.fdopen(fd, "rb") as stream:
        stamp = file_stamp(info)
        if file_stamp(os.fstat(fd)) == stamp:
            raw = stream.read()
            if file_stamp(os.fstat(fd)) == stamp:
                return stamp, raw
    raise ValueError(f"Antigravity MCP config changed while reading {path}; rerun the installer")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"non-finite JSON constant {value}")


def dump_json(value, depth=0):
    inner = "  " * (depth + 1)
    outer = "  " * depth
    if isinstance(value, dict) and value:
        items = (f"{inner}{dump_json(key)}: {dump_json(item, depth + 1)}" for key, item in value.items())
        return "{\n" + ",\n".join(items) + f"\n{outer}}}"
    if isinstance(value, list) and value:
        items = (inner + dump_json(item, depth + 1) for item in value)
        return "[\n" + ",\n".join(items) + f"\n{outer}]"
    if isinstance(value, Decimal):
        if not value.is_finite():
            raise ValueError("non-finite JSON number")
        return str(value)
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def plan_edit(path, raw):
    try:
        source = raw.decode("utf-8-sig")
        empty = not source.strip(" \t\r\n")
        config = {} if empty else json.loads(
            source,
            object_pairs_hook=unique_object,
            parse_constant=reject_constant,
            parse_float=Decimal,
            parse_int=Decimal,
        )
        if not isinstance(config, dict):
            raise ValueError("root JSON value must be an object")
        servers = config.setdefault("mcpServers", {})
        if not isinstance(servers, dict):
            raise ValueError("'mcpServers' must be a JSON object")
    except (ValueError, DecimalException, RecursionError) as exc:
        raise ValueError(f"refusing to edit invalid Antigravity MCP config at {path}: {exc}") from None

    exists = "lean-beam" in servers
    before = servers.get("lean-beam", {})
    conflict = None
    if not isinstance(before, dict):
        conflict = "must be a JSON object"
    elif before.get("disabled", False) is not False:
        conflict = "'disabled' must be false or absent"
    elif any(key in before for key in ("url", "serverUrl", "httpUrl")):
        conflict = "remove the remote transport (url, serverUrl, or httpUrl)"
    elif before.get("args", []) != []:
        conflict = "'args' must be an empty list or absent"
    elif "command" in before and not isinstance(before["command"], str):
        conflict = "'command' must be a string or absent"
    elif any(before.get(key, "stdio") != "stdio" for key in ("type", "transport")):
        conflict = "'type' and 'transport' must specify stdio if present"
    elif "cwd" in before and not isinstance(before["cwd"], str):
        conflict = "'cwd' must be a string or absent"
    if conflict:
        raise ValueError(
            f"refusing to edit conflicting 'mcpServers.lean-beam' in Antigravity MCP config at {path}: "
            f"{conflict}; adjust or rename the entry and rerun the installer"
        )

    after = {**before, "command": command, "disabled": False}
    servers["lean-beam"] = after
    try:
        output = (dump_json(config) + "\n").encode("utf-8")
    except (ValueError, RecursionError):
        raise ValueError(f"refusing to edit Antigravity MCP config at {path}; cannot serialize as UTF-8 JSON") from None
    return before if exists else None, after, output, empty


def approve_edit(path, before, after, output, empty):
    if not os.isatty(3):
        raise ValueError(f"refusing to edit Antigravity MCP config at {path} without confirmation; rerun with --dont-ask")
    print(f"\nInstaller wants to register lean-beam MCP server in the Antigravity config at {path}", file=sys.stderr)
    if empty:
        print(output.decode("utf-8"), end="", file=sys.stderr)
    else:
        # Use no context so unchanged values in the targeted entry stay out of the preview too.
        old_lines = dump_json(before).split("\n") if before is not None else []
        diff = unified_diff(
            old_lines, dump_json(after).split("\n"),
            fromfile="mcpServers.lean-beam (before)", tofile="mcpServers.lean-beam (after)", n=0, lineterm="",
        )
        print("\n".join(diff), file=sys.stderr)
    print("Allow this edit? [y/N] ", end="", file=sys.stderr, flush=True)
    with os.fdopen(3, encoding="utf-8", errors="replace") as terminal:
        if terminal.readline().strip().lower() not in ("y", "yes"):
            raise ValueError(f"cancelled before editing Antigravity MCP config at {path}")


def replace_config(path, stamp, raw, output):
    if physical_path() != path:
        raise ValueError(f"Antigravity MCP config location changed before writing {path}; rerun the installer")
    path.parent.mkdir(parents=True, exist_ok=True)
    dir_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        # Keep staging, replacement, and cleanup in the same directory even if it is moved.
        staged = f".{path.name}.lean-beam-{uuid4().hex}"
        fd = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=dir_fd)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(output)
                stream.flush()
                if stamp is not None:
                    os.fchmod(fd, stat.S_IMODE(stamp[2]))
            if (physical_path() != path
                    or not os.path.samestat(os.fstat(dir_fd), path.parent.stat())
                    or read_config(path, dir_fd) != (stamp, raw)):
                raise ValueError(f"Antigravity MCP config changed before writing {path}; rerun the installer")
            os.replace(staged, path.name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except BaseException:
            try:
                os.unlink(staged, dir_fd=dir_fd)
            except FileNotFoundError:
                pass
            raise
    finally:
        os.close(dir_fd)


path = requested_path
try:
    path = physical_path()
    if action == "location":
        print(path)
    else:
        stamp, raw = read_config(path)
        before, after, output, empty = plan_edit(path, raw)
        if action == "write" and before != after:
            if dont_ask == "0":
                approve_edit(path, before, after, output, empty)
            replace_config(path, stamp, raw, output)
except ValueError as exc:
    raise SystemExit(str(exc))
except (OSError, RuntimeError) as exc:
    raise SystemExit(f"cannot access or update Antigravity MCP config at {path}: {exc}")
PY
}

register_agy_mcp_server() {
  edit_agy_mcp_config write
  registered_mcp_targets+=("Antigravity: lean-beam")
}

register_requested_mcp_servers() {
  if [ "$register_codex_mcp" -eq 1 ]; then
    register_codex_mcp_server
  fi
  if [ "$register_claude_mcp" -eq 1 ]; then
    register_claude_mcp_server
  fi
  if [ "$register_opencode_mcp" -eq 1 ]; then
    register_opencode_mcp_server
  fi
  if [ "$register_vibe_mcp" -eq 1 ]; then
    register_vibe_mcp_server
  fi
  if [ "$register_agy_mcp" -eq 1 ]; then
    register_agy_mcp_server
  fi
}
