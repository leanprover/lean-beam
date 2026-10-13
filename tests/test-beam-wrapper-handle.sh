#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

handle_root="$(beam_wrapper_prepare_project_root handle)"
beam_wrapper_start_owner "$handle_root"

(
  cd "$handle_root"

  cat > HandleSmoke.lean <<'EOF'
example : True ∧ True := by
EOF

  handle_snapshot="$(beam_wrapper_update_snapshot HandleSmoke "$beam_script" update HandleSmoke.lean)"

  mint_handle_stdin="$(printf 'constructor' | "$beam_script" run-at-handle HandleSmoke.lean "$handle_snapshot" 0 27 --stdin)"
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle_stdin" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint via --stdin to succeed" >&2
    printf '%s\n' "$mint_handle_stdin" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle_stdin" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint via --stdin to return a lean handle" >&2
    printf '%s\n' "$mint_handle_stdin" >&2
    exit 1
  fi

  handle_mint_file="handle-mint.txt"
  printf 'constructor' > "$handle_mint_file"
  mint_handle_file="$("$beam_script" run-at-handle HandleSmoke.lean "$handle_snapshot" 0 27 --text-file "$handle_mint_file")"
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle_file" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint via --text-file to succeed" >&2
    printf '%s\n' "$mint_handle_file" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle_file" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint via --text-file to return a lean handle" >&2
    printf '%s\n' "$mint_handle_file" >&2
    exit 1
  fi
  branch_handle_file="branch-handle.json"
  printf '%s\n' "$mint_handle_file" > "$branch_handle_file"

  mint_handle="$("$beam_script" run-at-handle HandleSmoke.lean "$handle_snapshot" 0 27 "constructor")"
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle mint to succeed" >&2
    printf '%s\n' "$mint_handle" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$mint_handle" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper handle mint to return a lean handle" >&2
    printf '%s\n' "$mint_handle" >&2
    exit 1
  fi

  branch_step_stdin_err="$(beam_wrapper_mktemp_file run-with-stdin)"
  branch_step_stdin="$(printf 'exact trivial' | BEAM_DEBUG_TEXT=1 "$beam_script" run-with HandleSmoke.lean "$mint_handle_stdin" --stdin 2>"$branch_step_stdin_err")"
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step_stdin" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation via --stdin to succeed" >&2
    printf '%s\n' "$branch_step_stdin" >&2
    cat "$branch_step_stdin_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step_stdin" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation via --stdin to return a successor handle" >&2
    printf '%s\n' "$branch_step_stdin" >&2
    cat "$branch_step_stdin_err" >&2
    exit 1
  fi
  if ! grep -q 'debug text for run-with: source=stdin' "$branch_step_stdin_err"; then
    echo "expected wrapper run-with debug-text mode to report stdin as the continuation text source" >&2
    cat "$branch_step_stdin_err" >&2
    exit 1
  fi

  branch_step_file="$(printf 'exact trivial' | "$beam_script" run-with HandleSmoke.lean --handle-file "$branch_handle_file" --stdin)"
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step_file" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation via --handle-file to succeed" >&2
    printf '%s\n' "$branch_step_file" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step_file" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation via --handle-file to return a successor handle" >&2
    printf '%s\n' "$branch_step_file" >&2
    exit 1
  fi

  stdin_conflict_err="$(beam_wrapper_mktemp_file run-with-stdin-conflict)"
  if printf '%s\n' "$mint_handle" | "$beam_script" run-with HandleSmoke.lean - --stdin >"$stdin_conflict_err" 2>&1; then
    echo "expected wrapper run-with to reject reading both handle json and text from stdin" >&2
    cat "$stdin_conflict_err" >&2
    exit 1
  fi
  if ! grep -q 'cannot read both handle json and continuation text from stdin' "$stdin_conflict_err"; then
    echo "expected wrapper run-with stdin conflict to explain the single-stdin limitation" >&2
    cat "$stdin_conflict_err" >&2
    exit 1
  fi

  branch_step="$(printf '%s\n' "$mint_handle" | "$beam_script" run-with HandleSmoke.lean - "exact trivial")"
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper non-linear handle continuation to succeed" >&2
    printf '%s\n' "$branch_step" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$branch_step" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper non-linear handle continuation to return a successor handle" >&2
    printf '%s\n' "$branch_step" >&2
    exit 1
  fi

  branch_done="$(printf '%s\n' "$branch_step" | "$beam_script" run-with HandleSmoke.lean - "exact trivial")"
  if [ "$(BEAM_JSON_PAYLOAD="$branch_done" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper second non-linear handle continuation to succeed" >&2
    printf '%s\n' "$branch_done" >&2
    exit 1
  fi
  if ! printf '%s\n' "$branch_done" | grep -q '"goals": \[\]'; then
    echo "expected wrapper non-linear handle chain to solve the proof" >&2
    printf '%s\n' "$branch_done" >&2
    exit 1
  fi

  mint_linear="$("$beam_script" run-at-handle HandleSmoke.lean "$handle_snapshot" 0 27 "constructor")"
  if [ "$(BEAM_JSON_PAYLOAD="$mint_linear" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper linear handle mint to succeed" >&2
    printf '%s\n' "$mint_linear" >&2
    exit 1
  fi

  linear_text_file="linear-continuation.txt"
  printf 'exact trivial' > "$linear_text_file"
  linear_handle_file="linear-handle.json"
  printf '%s\n' "$mint_linear" > "$linear_handle_file"
  linear_step="$("$beam_script" run-with-linear HandleSmoke.lean --handle-file "$linear_handle_file" --text-file "$linear_text_file")"
  if [ "$(BEAM_JSON_PAYLOAD="$linear_step" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper linear handle continuation via --handle-file and --text-file to succeed" >&2
    printf '%s\n' "$linear_step" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$linear_step" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected wrapper linear handle continuation via --handle-file and --text-file to return a successor handle" >&2
    printf '%s\n' "$linear_step" >&2
    exit 1
  fi

  linear_reuse_err="$(beam_wrapper_mktemp_file linear-reuse)"
  if printf '%s\n' "$mint_linear" | "$beam_script" run-with HandleSmoke.lean - "exact trivial" >"$linear_reuse_err" 2>&1; then
    echo "expected consumed linear handle to fail when reused" >&2
    cat "$linear_reuse_err" >&2
    exit 1
  fi
  if ! grep -q 'invalidParams' "$linear_reuse_err"; then
    echo "expected consumed linear handle reuse to report invalidParams" >&2
    cat "$linear_reuse_err" >&2
    exit 1
  fi

  release_handle_file="release-handle.json"
  printf '%s\n' "$linear_step" > "$release_handle_file"
  release_out="$("$beam_script" release HandleSmoke.lean --handle-file "$release_handle_file")"
  if [ "$(BEAM_JSON_PAYLOAD="$release_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper handle release via --handle-file to succeed" >&2
    printf '%s\n' "$release_out" >&2
    exit 1
  fi

  release_reuse_err="$(beam_wrapper_mktemp_file release-reuse)"
  if printf '%s\n' "$linear_step" | "$beam_script" run-with HandleSmoke.lean - "exact trivial" >"$release_reuse_err" 2>&1; then
    echo "expected released handle to fail when reused" >&2
    cat "$release_reuse_err" >&2
    exit 1
  fi
  if ! grep -q 'invalidParams' "$release_reuse_err"; then
    echo "expected released handle reuse to report invalidParams" >&2
    cat "$release_reuse_err" >&2
    exit 1
  fi

  close_handle_out="$("$beam_script" close HandleSmoke.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$close_handle_out" read_json_text_field ok)" != "true" ]; then
    echo "expected handle smoke file close to succeed" >&2
    printf '%s\n' "$close_handle_out" >&2
    exit 1
  fi

  portable_wrapper_bin="$beam_wrapper_tmp_root/portable-wrapper-bin"
  system_readlink="$(command -v readlink)"
  mkdir -p "$portable_wrapper_bin"
  ln -sf "$beam_script" "$portable_wrapper_bin/lean-beam"
  ln -sf "$search_helper" "$portable_wrapper_bin/lean-beam-search"
  cat > "$portable_wrapper_bin/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [ "\${1:-}" = "-f" ]; then
  echo "unexpected readlink -f in portability test" >&2
  exit 64
fi

exec "$system_readlink" "\$@"
EOF
  chmod +x "$portable_wrapper_bin/readlink"

  portable_stats_out="$(PATH="$portable_wrapper_bin:$PATH" "$portable_wrapper_bin/lean-beam" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$portable_stats_out" read_json_text_field ok)" != "true" ]; then
    echo "expected symlinked wrapper to work when readlink -f is unavailable" >&2
    printf '%s\n' "$portable_stats_out" >&2
    exit 1
  fi

  portable_helper_snapshot="$(beam_wrapper_update_snapshot "portable HandleSmoke" "$beam_script" update HandleSmoke.lean)"
  portable_helper_root="$(PATH="$portable_wrapper_bin:$PATH" "$portable_wrapper_bin/lean-beam-search" mint HandleSmoke.lean "$portable_helper_snapshot" 0 27 "constructor")"
  if [ "$(BEAM_JSON_PAYLOAD="$portable_helper_root" read_json_text_field ok)" != "true" ]; then
    echo "expected symlinked helper to work when readlink -f is unavailable" >&2
    printf '%s\n' "$portable_helper_root" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$portable_helper_root" read_json_text_field result.handle.backend)" != "lean" ]; then
    echo "expected symlinked helper mint to return a lean handle" >&2
    printf '%s\n' "$portable_helper_root" >&2
    exit 1
  fi

  wrapper_shadow_root="$beam_wrapper_tmp_root/wrapper-shadow-root"
  mkdir -p "$wrapper_shadow_root/scripts" "$wrapper_shadow_root/.lake/build/bin" "$wrapper_shadow_root/libexec"
  cp "$beam_script" "$wrapper_shadow_root/scripts/lean-beam"
  cat > "$wrapper_shadow_root/.lake/build/bin/beam-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'checkout\n'
EOF
  cat > "$wrapper_shadow_root/libexec/beam-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'installed\n'
EOF
  chmod +x "$wrapper_shadow_root/.lake/build/bin/beam-cli" "$wrapper_shadow_root/libexec/beam-cli"

  wrapper_shadow_out="$("$wrapper_shadow_root/scripts/lean-beam" stats)"
  if [ "$wrapper_shadow_out" != "checkout" ]; then
    echo "expected checkout wrapper to prefer .lake/build over sibling libexec when BEAM_HOME is unset" >&2
    printf '%s\n' "$wrapper_shadow_out" >&2
    exit 1
  fi

  wrapper_override_out="$(BEAM_HOME="$wrapper_shadow_root" "$wrapper_shadow_root/scripts/lean-beam" stats)"
  if [ "$wrapper_override_out" != "installed" ]; then
    echo "expected explicit BEAM_HOME to prefer libexec in the overridden runtime" >&2
    printf '%s\n' "$wrapper_override_out" >&2
    exit 1
  fi

  helper_root="$("$search_helper" mint HandleSmoke.lean "$portable_helper_snapshot" 0 27 "constructor")"
  if [ "$(BEAM_JSON_PAYLOAD="$helper_root" read_json_text_field ok)" != "true" ]; then
    echo "expected helper mint to succeed" >&2
    printf '%s\n' "$helper_root" >&2
    exit 1
  fi
  helper_branch="$(printf '%s\n' "$helper_root" | "$search_helper" branch HandleSmoke.lean "exact trivial")"
  if [ "$(BEAM_JSON_PAYLOAD="$helper_branch" read_json_text_field ok)" != "true" ]; then
    echo "expected helper branch to succeed" >&2
    printf '%s\n' "$helper_branch" >&2
    exit 1
  fi
  helper_playout="$(printf '%s\n' "$helper_branch" | "$search_helper" playout HandleSmoke.lean "exact trivial")"
  if [ "$(BEAM_JSON_PAYLOAD="$helper_playout" read_json_text_field ok)" != "true" ]; then
    echo "expected helper playout to succeed" >&2
    printf '%s\n' "$helper_playout" >&2
    exit 1
  fi
  if ! printf '%s\n' "$helper_playout" | grep -q '"goals": \[\]'; then
    echo "expected helper playout to solve the proof" >&2
    printf '%s\n' "$helper_playout" >&2
    exit 1
  fi
  helper_release="$(printf '%s\n' "$helper_root" | "$search_helper" release HandleSmoke.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$helper_release" read_json_text_field ok)" != "true" ]; then
    echo "expected helper release to succeed" >&2
    printf '%s\n' "$helper_release" >&2
    exit 1
  fi
  helper_release_reuse_err="$(beam_wrapper_mktemp_file helper-release-reuse)"
  if printf '%s\n' "$helper_root" | "$search_helper" branch HandleSmoke.lean "exact trivial" >"$helper_release_reuse_err" 2>&1; then
    echo "expected released helper root to fail when reused" >&2
    cat "$helper_release_reuse_err" >&2
    exit 1
  fi
  if ! grep -q 'invalidParams' "$helper_release_reuse_err"; then
    echo "expected released helper root reuse to report invalidParams" >&2
    cat "$helper_release_reuse_err" >&2
    exit 1
  fi

  close_helper_handle_out="$("$beam_script" close HandleSmoke.lean)"
  if [ "$(BEAM_JSON_PAYLOAD="$close_helper_handle_out" read_json_text_field ok)" != "true" ]; then
    echo "expected helper handle smoke file close to succeed" >&2
    printf '%s\n' "$close_helper_handle_out" >&2
    exit 1
  fi
)
