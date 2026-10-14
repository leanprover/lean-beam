#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
system_git="$(command -v git)"
system_mktemp="$(command -v mktemp)"
system_rm="$(command -v rm)"
system_rsync="$(command -v rsync)"

keep_root=0
print_root=0
custom_command=()

usage() {
  cat <<'EOF'
Usage:
  bash scripts/validate-defensive.sh [--keep-root] [--print-root]
  bash scripts/validate-defensive.sh [--keep-root] [--print-root] -- <command...>

Default validation command sequence:
  1. lake build beam-cli
  2. bash tests/test-beam-install.sh
  3. bash tests/test-beam-slow.sh

This script is a maintainer safety wrapper. It clones the current checkout into /tmp,
overlays the working tree state, sets fake HOME/CODEX_HOME/CLAUDE_HOME/TMPDIR, and
prepends guarded filesystem wrappers for the validation run.
EOF
}

die() {
  echo "$*" >&2
  exit 1
}

log() {
  echo "[validate-defensive] $*" >&2
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep-root)
        keep_root=1
        ;;
      --print-root)
        print_root=1
        ;;
      --)
        shift
        custom_command=("$@")
        return 0
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done
}

expect_owned_validation_root() {
  case "$1" in
    /tmp/beam-validate-*)
      ;;
    *)
      die "refusing to touch unexpected validation root: $1"
      ;;
  esac
}

write_guard_wrapper() {
  local name="$1"
  local real_bin="$2"
  local path="$guard_bin/$name"
  cat >"$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail

real_bin="$real_bin"
validation_root="\${BEAM_VALIDATION_ROOT:?missing BEAM_VALIDATION_ROOT}"

resolve_operand() {
  python3 - "\$1" <<'PY'
import os, sys
path = sys.argv[1]
if os.path.isabs(path):
    print(os.path.normpath(path))
else:
    print(os.path.normpath(os.path.join(os.getcwd(), path)))
PY
}

allowed_path() {
  case "\$1" in
    "\$validation_root"|"\$validation_root"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_operand() {
  local resolved
  resolved="\$(resolve_operand "\$1")"
  if ! allowed_path "\$resolved"; then
    echo "defensive validation blocked $name operand outside allowed roots: \$1 -> \$resolved" >&2
    exit 1
  fi
}

rewrite_tmp_template() {
  case "\$1" in
    "\$validation_root"|"\$validation_root"/*)
      printf '%s\n' "\$1"
      ;;
    /tmp/beam-*|/tmp/tmp.*)
      printf '%s/%s\n' "\$validation_root/tmp" "\$(basename "\$1")"
      ;;
    *)
      printf '%s\n' "\$1"
      ;;
  esac
}
EOF

  case "$name" in
    rm)
      cat >>"$path" <<'EOF'
parsing_operands=0
for arg in "$@"; do
  if [ "$parsing_operands" -eq 1 ]; then
    validate_operand "$arg"
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      ;;
    -*)
      ;;
    *)
      validate_operand "$arg"
      ;;
  esac
done
exec "$real_bin" "$@"
EOF
      ;;
    mv)
      cat >>"$path" <<'EOF'
expect_target_dir=0
parsing_operands=0
for arg in "$@"; do
  if [ "$expect_target_dir" -eq 1 ]; then
    validate_operand "$arg"
    expect_target_dir=0
    continue
  fi
  if [ "$parsing_operands" -eq 1 ]; then
    validate_operand "$arg"
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      ;;
    -t)
      expect_target_dir=1
      ;;
    --target-directory=*)
      validate_operand "${arg#*=}"
      ;;
    -*)
      ;;
    *)
      validate_operand "$arg"
      ;;
  esac
done
exec "$real_bin" "$@"
EOF
      ;;
    mktemp)
      cat >>"$path" <<'EOF'
expect_dir_arg=0
parsing_operands=0
rewritten_args=()
for arg in "$@"; do
  if [ "$expect_dir_arg" -eq 1 ]; then
    validate_operand "$arg"
    rewritten_args+=("$arg")
    expect_dir_arg=0
    continue
  fi
  if [ "$parsing_operands" -eq 1 ]; then
    arg="$(rewrite_tmp_template "$arg")"
    validate_operand "$arg"
    rewritten_args+=("$arg")
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      rewritten_args+=("$arg")
      ;;
    -p|--tmpdir)
      expect_dir_arg=1
      rewritten_args+=("$arg")
      ;;
    --tmpdir=*)
      validate_operand "${arg#*=}"
      rewritten_args+=("$arg")
      ;;
    -*)
      rewritten_args+=("$arg")
      ;;
    *)
      arg="$(rewrite_tmp_template "$arg")"
      validate_operand "$arg"
      rewritten_args+=("$arg")
      ;;
  esac
done
	exec "$real_bin" ${rewritten_args[@]+"${rewritten_args[@]}"}
EOF
      ;;
    mkdir)
      cat >>"$path" <<'EOF'
expect_mode_arg=0
parsing_operands=0
for arg in "$@"; do
  if [ "$expect_mode_arg" -eq 1 ]; then
    expect_mode_arg=0
    continue
  fi
  if [ "$parsing_operands" -eq 1 ]; then
    validate_operand "$arg"
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      ;;
    -m)
      expect_mode_arg=1
      ;;
    --mode=*)
      ;;
    -*)
      ;;
    *)
      validate_operand "$arg"
      ;;
  esac
done
exec "$real_bin" "$@"
EOF
      ;;
    rmdir)
      cat >>"$path" <<'EOF'
parsing_operands=0
for arg in "$@"; do
  if [ "$parsing_operands" -eq 1 ]; then
    validate_operand "$arg"
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      ;;
    -*)
      ;;
    *)
      validate_operand "$arg"
      ;;
  esac
done
exec "$real_bin" "$@"
EOF
      ;;
    cp|ln)
      cat >>"$path" <<'EOF'
parsing_operands=0
for arg in "$@"; do
  if [ "$parsing_operands" -eq 1 ]; then
    validate_operand "$arg"
    continue
  fi
  case "$arg" in
    --)
      parsing_operands=1
      ;;
    -*)
      ;;
    *)
      validate_operand "$arg"
      ;;
  esac
done
exec "$real_bin" "$@"
EOF
      ;;
    *)
      die "unknown guard wrapper: $name"
      ;;
  esac
  chmod +x "$path"
}

run_step() {
  local label="$1"
  shift
  log "$label"
  (
    cd "$clone_root"
    "$@"
  )
}

validation_root="$("$system_mktemp" -d /tmp/beam-validate-XXXXXX)"
expect_owned_validation_root "$validation_root"
clone_root="$validation_root/clone"
guard_bin="$validation_root/bin"
fake_home="$validation_root/home"
fake_codex_home="$validation_root/codex"
fake_claude_home="$validation_root/claude"
fake_tmpdir="$validation_root/tmp"

cleanup() {
  if [ "$keep_root" -eq 1 ]; then
    log "kept validation root: $validation_root"
    return 0
  fi
  expect_owned_validation_root "$validation_root"
  "$system_rm" -rf -- "$validation_root"
}
trap cleanup EXIT

parse_args "$@"

mkdir -p "$guard_bin" "$fake_home" "$fake_codex_home" "$fake_claude_home" "$fake_tmpdir"
write_guard_wrapper rm "$(command -v rm)"
write_guard_wrapper mv "$(command -v mv)"
write_guard_wrapper mktemp "$(command -v mktemp)"
write_guard_wrapper mkdir "$(command -v mkdir)"
write_guard_wrapper rmdir "$(command -v rmdir)"
write_guard_wrapper cp "$(command -v cp)"
write_guard_wrapper ln "$(command -v ln)"

if [ -z "${ELAN_HOME:-}" ] && [ -d "$HOME/.elan" ]; then
  export ELAN_HOME="$HOME/.elan"
fi

export HOME="$fake_home"
export CODEX_HOME="$fake_codex_home"
export CLAUDE_HOME="$fake_claude_home"
export TMPDIR="$fake_tmpdir"
export BEAM_VALIDATION_ROOT="$validation_root"
export PATH="$guard_bin:$PATH"

log "cloning checkout into $clone_root"
"$system_git" clone --quiet --no-hardlinks "$repo_root" "$clone_root"
log "overlaying current working tree state"
"$system_rsync" -a --delete \
  --exclude='.git' \
  --exclude='.lake/' \
  --exclude='.beam/' \
  --exclude='.codex-worktrees/' \
  "$repo_root"/ "$clone_root"/

if [ "$print_root" -eq 1 ]; then
  printf '%s\n' "$validation_root"
fi

if [ "${#custom_command[@]}" -gt 0 ]; then
  run_step "running custom command" ${custom_command[@]+"${custom_command[@]}"}
else
  run_step "lake build beam-cli" lake build beam-cli
  run_step "bash tests/test-beam-install.sh" bash tests/test-beam-install.sh
  run_step "bash tests/test-beam-slow.sh" bash tests/test-beam-slow.sh
fi

log "validation completed"
