#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=tests/lib/beam-wrapper-common.sh
. tests/lib/beam-wrapper-common.sh

beam_wrapper_init

project_root="$(beam_wrapper_prepare_project_root probe)"
beam_wrapper_start_owner "$project_root"

(
  cd "$project_root"
  "$beam_script" stats > /dev/null
)

registry_path="$(beam_wrapper_registry_path "$project_root")"
beam_wrapper_expect_file "$registry_path"

pid1="$(read_json_field "$registry_path" pid)"
port1="$(read_json_field "$registry_path" port)"
root1="$(read_json_field "$registry_path" workspace.root)"
if [ "$root1" != "$(beam_test_realpath "$project_root")" ]; then
  echo "wrapper registry root mismatch: expected $project_root, got $root1" >&2
  exit 1
fi
if ! kill -0 "$pid1" 2>/dev/null; then
  echo "expected Beam daemon pid $pid1 to be alive" >&2
  exit 1
fi

(
  cd "$project_root"
  "$beam_script" stats > /dev/null
  command_snapshot="$(beam_wrapper_update_snapshot CommandA "$beam_script" update CommandA.lean)"
  signature_snapshot="$(beam_wrapper_update_snapshot SignatureHelp "$beam_script" update SignatureHelp.lean)"
  position_empty_snapshot="$(beam_wrapper_update_snapshot PositionEmptyLine "$beam_script" update PositionEmptyLine.lean)"
  position_utf16_snapshot="$(beam_wrapper_update_snapshot PositionUtf16 "$beam_script" update PositionUtf16.lean)"
  goal_snapshot="$(beam_wrapper_update_snapshot GoalSmoke "$beam_script" update GoalSmoke.lean)"
  todo_snapshot="$(beam_wrapper_update_snapshot TodoSmoke "$beam_script" update TodoSmoke.lean)"

  cmd_err="$(beam_wrapper_mktemp_file progress)"
  cmd_out="$(BEAM_PROGRESS=1 "$beam_script" run-at CommandA.lean "$command_snapshot" 0 2 "#check answerA" 2>"$cmd_err")"
  if [ "$(BEAM_JSON_PAYLOAD="$cmd_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper run-at to succeed" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$cmd_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper run-at payload success" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  run_at_progress_done="$(BEAM_JSON_PAYLOAD="$cmd_out" read_json_text_field fileProgress.done)"
  if [ "$run_at_progress_done" != "true" ] && [ "$run_at_progress_done" != "false" ]; then
    echo "expected wrapper run-at to expose top-level fileProgress" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if [ -n "$(BEAM_JSON_PAYLOAD="$cmd_out" read_json_text_field clientRequestId)" ]; then
    echo "expected anonymous wrapper run-at to hide generated clientRequestId" >&2
    printf '%s\n' "$cmd_out" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if ! grep -q 'waiting for a ready Lean snapshot' "$cmd_err"; then
    echo "expected wrapper run-at progress stderr output" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if ! grep -q 'run-at complete' "$cmd_err"; then
    echo "expected wrapper run-at completion stderr output" >&2
    cat "$cmd_err" >&2
    exit 1
  fi
  if grep -q 'beam\[' "$cmd_err" || grep -q 'beam-wrapper-' "$cmd_err"; then
    echo "expected anonymous wrapper progress stderr not to leak the generated clientRequestId" >&2
    cat "$cmd_err" >&2
    exit 1
  fi

  stale_command_snapshot="$command_snapshot"
  printf '\n-- wrapper stale-snapshot probe\n' >> CommandA.lean
  command_snapshot="$(beam_wrapper_update_snapshot CommandA-changed "$beam_script" update CommandA.lean)"
  stale_snapshot_out="$(beam_wrapper_mktemp_file stale-snapshot-out)"
  stale_snapshot_err="$(beam_wrapper_mktemp_file stale-snapshot-err)"
  if "$beam_script" run-at CommandA.lean "$stale_command_snapshot" 0 2 "#check answerA" \
      >"$stale_snapshot_out" 2>"$stale_snapshot_err"; then
    echo "expected wrapper run-at with a stale snapshot to fail" >&2
    cat "$stale_snapshot_out" >&2
    cat "$stale_snapshot_err" >&2
    exit 1
  fi
  assert_json_file_field_equals "stale wrapper run-at" "$stale_snapshot_out" \
    error.code contentModified "$stale_snapshot_err"
  assert_json_file_field_equals "stale wrapper run-at" "$stale_snapshot_out" \
    error.data.reason snapshotMismatch "$stale_snapshot_err"
  assert_json_file_field_equals "stale wrapper run-at" "$stale_snapshot_out" \
    error.data.expectedSnapshot "$stale_command_snapshot" "$stale_snapshot_err"
  assert_json_file_field_equals "stale wrapper run-at" "$stale_snapshot_out" \
    error.data.currentSnapshot "$command_snapshot" "$stale_snapshot_err"
  stale_snapshot_uri="$(json_file_text_field "$stale_snapshot_out" error.data.uri)"
  case "$stale_snapshot_uri" in
    */CommandA.lean)
      ;;
    *)
      echo "expected stale wrapper run-at to report a CommandA.lean uri, got ${stale_snapshot_uri:-<empty>}" >&2
      print_json_file_assertion_context "$stale_snapshot_out" "$stale_snapshot_err"
      exit 1
      ;;
  esac

  multiline_stdin_out="$(printf 'def stdinProbe : Nat :=\n  42' | "$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 --stdin)"
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_stdin_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper run-at --stdin probe to succeed" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_stdin_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper run-at --stdin payload success" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_stdin_out" read_json_array_len result.messages)" != "0" ]; then
    echo "expected wrapper run-at --stdin multiline declaration to produce no messages" >&2
    printf '%s\n' "$multiline_stdin_out" >&2
    exit 1
  fi

  probe_text_file="multiline-probe.lean"
  printf 'def fileProbe : Nat :=\n  42' > "$probe_text_file"
  multiline_file_out="$("$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 --text-file "$probe_text_file")"
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_file_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper run-at --text-file probe to succeed" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_file_out" read_json_text_field result.success)" != "true" ]; then
    echo "expected wrapper run-at --text-file payload success" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$multiline_file_out" read_json_array_len result.messages)" != "0" ]; then
    echo "expected wrapper run-at --text-file multiline declaration to produce no messages" >&2
    printf '%s\n' "$multiline_file_out" >&2
    exit 1
  fi

  delimiter_out="$("$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 -- $'--stdin\n#check answer')"
  if [ "$(BEAM_JSON_PAYLOAD="$delimiter_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper run-at -- delimiter path to treat leading --stdin as text" >&2
    printf '%s\n' "$delimiter_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$delimiter_out" | grep -q 'answer : Nat'; then
    echo "expected wrapper run-at -- delimiter path to keep the leading --stdin text as a comment" >&2
    printf '%s\n' "$delimiter_out" >&2
    exit 1
  fi

  debug_text_err="$(beam_wrapper_mktemp_file debug-text)"
  debug_text_out="$(printf 'def debugProbe : Nat :=\n  42' | BEAM_DEBUG_TEXT=1 "$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 --stdin 2>"$debug_text_err")"
  if [ "$(BEAM_JSON_PAYLOAD="$debug_text_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper debug-text probe to succeed" >&2
    printf '%s\n' "$debug_text_out" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'debug text for run-at: source=stdin' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report stdin as the text source" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'containsNewline=true' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to report a real newline" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'containsLiteralBackslashN=false' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to distinguish literal backslash-n from a real newline" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'escaped="def debugProbe : Nat :=\\n  42"' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print the escaped probe text" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi
  if ! grep -q 'utf8Hex=' "$debug_text_err" || ! grep -q '0a' "$debug_text_err"; then
    echo "expected wrapper debug-text mode to print UTF-8 bytes including the newline byte" >&2
    cat "$debug_text_err" >&2
    exit 1
  fi

  literal_newline_err="$(beam_wrapper_mktemp_file literal-newline)"
  literal_newline_out="$("$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 'def _probe_tmp : Nat := 0\n' 2>"$literal_newline_err")"
  if [ "$(BEAM_JSON_PAYLOAD="$literal_newline_out" read_json_text_field ok)" != "true" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to stay a payload failure, not a transport error" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$literal_newline_out" read_json_text_field result.success)" != "false" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to fail in the run-at payload" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if ! grep -q "literal characters '\\\\n'" "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to print a newline hint" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if ! grep -q 'probe failed inside Lean; the request completed and returned result.success=false' "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n probe to distinguish a probe failure from a request failure" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if [ -n "$(BEAM_JSON_PAYLOAD="$literal_newline_out" read_json_text_field clientRequestId)" ]; then
    printf '%s\n' "expected wrapper literal-\\n probe to hide generated clientRequestId" >&2
    printf '%s\n' "$literal_newline_out" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi
  if grep -q 'beam\[' "$literal_newline_err" || grep -q 'beam-wrapper-' "$literal_newline_err"; then
    printf '%s\n' "expected wrapper literal-\\n stderr not to leak the generated clientRequestId" >&2
    cat "$literal_newline_err" >&2
    exit 1
  fi

  blank_ok_out="$("$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 0 "#check answer")"
  if [ "$(BEAM_JSON_PAYLOAD="$blank_ok_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper blank-line probe at character 0 to succeed" >&2
    printf '%s\n' "$blank_ok_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$blank_ok_out" | grep -q 'answer : Nat'; then
    echo "expected wrapper blank-line probe at character 0 to expose answer type information" >&2
    printf '%s\n' "$blank_ok_out" >&2
    exit 1
  fi

  blank_err="$(beam_wrapper_mktemp_file empty-line)"
  if "$beam_script" run-at PositionEmptyLine.lean "$position_empty_snapshot" 1 1 "#check answer" >"$blank_err" 2>&1; then
    echo "expected wrapper blank-line probe at character 1 to be rejected" >&2
    cat "$blank_err" >&2
    exit 1
  fi
  if ! grep -q 'character 1 is beyond max character 0 for line 1' "$blank_err"; then
    echo "expected wrapper blank-line invalid position error message" >&2
    cat "$blank_err" >&2
    exit 1
  fi
  if ! grep -q 'run-at request failed before probe execution (invalidParams)' "$blank_err"; then
    echo "expected wrapper blank-line invalid position path to distinguish request failure from probe failure" >&2
    cat "$blank_err" >&2
    exit 1
  fi

  utf16_ok_out="$("$beam_script" run-at PositionUtf16.lean "$position_utf16_snapshot" 1 5 "#check Nat")"
  if [ "$(BEAM_JSON_PAYLOAD="$utf16_ok_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper UTF-16 boundary probe to succeed" >&2
    printf '%s\n' "$utf16_ok_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$utf16_ok_out" | grep -q 'Nat : Type'; then
    echo "expected wrapper UTF-16 boundary probe to expose Nat type information" >&2
    printf '%s\n' "$utf16_ok_out" >&2
    exit 1
  fi

  utf16_err="$(beam_wrapper_mktemp_file utf16)"
  if "$beam_script" run-at PositionUtf16.lean "$position_utf16_snapshot" 1 6 "#check Nat" >"$utf16_err" 2>&1; then
    echo "expected wrapper UTF-16 out-of-range probe to be rejected" >&2
    cat "$utf16_err" >&2
    exit 1
  fi
  if ! grep -q 'character 6 is beyond max character 5 for line 1' "$utf16_err"; then
    echo "expected wrapper UTF-16 invalid position error message" >&2
    cat "$utf16_err" >&2
    exit 1
  fi

  stats_out="$("$beam_script" stats)"
  if [ "$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper stats to succeed" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  run_at_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.run_at.count)"
  if [ "${run_at_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one run_at request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

  hover_out="$("$beam_script" hover CommandA.lean "$command_snapshot" 0 4)"
  if [ "$(BEAM_JSON_PAYLOAD="$hover_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper hover probe to succeed" >&2
    printf '%s\n' "$hover_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$hover_out" | grep -q 'answerA : Nat'; then
    echo "expected wrapper hover probe to expose answerA type information" >&2
    printf '%s\n' "$hover_out" >&2
    exit 1
  fi

  signature_help_out="$("$beam_script" signature-help SignatureHelp.lean "$signature_snapshot" 4 12)"
  if [ "$(BEAM_JSON_PAYLOAD="$signature_help_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper signature-help probe to succeed" >&2
    printf '%s\n' "$signature_help_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$signature_help_out" | grep -q 'x y : Nat'; then
    echo "expected wrapper signature-help probe to expose function parameter information" >&2
    printf '%s\n' "$signature_help_out" >&2
    exit 1
  fi

  definition_out="$("$beam_script" definition CommandA.lean "$command_snapshot" 0 4)"
  if [ "$(BEAM_JSON_PAYLOAD="$definition_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper definition probe to succeed" >&2
    printf '%s\n' "$definition_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$definition_out" | grep -q 'CommandA.lean'; then
    echo "expected wrapper definition probe to point at CommandA.lean" >&2
    printf '%s\n' "$definition_out" >&2
    exit 1
  fi

  references_nav_out="$("$beam_script" references CommandA.lean "$command_snapshot" 0 4)"
  if [ "$(BEAM_JSON_PAYLOAD="$references_nav_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper references probe to succeed" >&2
    printf '%s\n' "$references_nav_out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$references_nav_out" | grep -q 'CommandA.lean'; then
    echo "expected wrapper references probe to include CommandA.lean" >&2
    printf '%s\n' "$references_nav_out" >&2
    exit 1
  fi

  document_symbols_out="$("$beam_script" document-symbols CommandA.lean "$command_snapshot")"
  if [ "$(BEAM_JSON_PAYLOAD="$document_symbols_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper document-symbols probe to succeed" >&2
    printf '%s\n' "$document_symbols_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$document_symbols_out" read_json_text_field result.0.name)" != "answerA" ]; then
    echo "expected wrapper document-symbols probe to list answerA" >&2
    printf '%s\n' "$document_symbols_out" >&2
    exit 1
  fi

  workspace_symbols_out="$("$beam_script" workspace-symbols answerA)"
  if [ "$(BEAM_JSON_PAYLOAD="$workspace_symbols_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper workspace-symbols probe to succeed" >&2
    printf '%s\n' "$workspace_symbols_out" >&2
    exit 1
  fi
  BEAM_JSON_PAYLOAD="$workspace_symbols_out" read_json_array_len result > /dev/null

  goals_prev_out="$("$beam_script" goals before GoalSmoke.lean "$goal_snapshot" 1 2)"
  if [ "$(BEAM_JSON_PAYLOAD="$goals_prev_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper goals before probe to succeed" >&2
    printf '%s\n' "$goals_prev_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$goals_prev_out" read_json_text_field result.goals.0.target)" != "True" ]; then
    echo "expected wrapper goals before probe to expose the open True goal" >&2
    printf '%s\n' "$goals_prev_out" >&2
    exit 1
  fi

  goals_after_out="$("$beam_script" goals after GoalSmoke.lean "$goal_snapshot" 1 2)"
  if [ "$(BEAM_JSON_PAYLOAD="$goals_after_out" read_json_text_field ok)" != "true" ]; then
    echo "expected wrapper goals after probe to succeed" >&2
    printf '%s\n' "$goals_after_out" >&2
    exit 1
  fi
  if [ "$(BEAM_JSON_PAYLOAD="$goals_after_out" read_json_array_len result.goals)" != "0" ]; then
    echo "expected wrapper goals after probe to expose no remaining goals" >&2
    printf '%s\n' "$goals_after_out" >&2
    exit 1
  fi

  todo_out="$("$beam_script" todo TodoSmoke.lean "$todo_snapshot" 13 0 14 0 --kind sorry --suggest none)"
  assert_json_field_equals "wrapper todo" "$todo_out" ok true
  assert_json_array_len_equals "wrapper todo" "$todo_out" result.items 1
  assert_json_field_equals "wrapper todo" "$todo_out" result.items.0.kind sorry
  assert_json_field_equals "wrapper todo" "$todo_out" result.items.0.runAtPosition.line 13
  assert_json_field_equals "wrapper todo" "$todo_out" result.items.0.runAtPosition.character 2
  assert_json_field_absent "wrapper todo" "$todo_out" result.items.0.runAtText

  stats_out="$("$beam_script" stats)"
  hover_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.hover.count)"
  if [ "${hover_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one hover request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  signature_help_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.signature_help.count)"
  if [ "${signature_help_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one signature_help request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  definition_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.definition.count)"
  if [ "${definition_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one definition request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  references_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.references.count)"
  if [ "${references_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one references request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  document_symbols_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.document_symbols.count)"
  if [ "${document_symbols_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one document_symbols request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  workspace_symbols_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.workspace_symbols.count)"
  if [ "${workspace_symbols_count:-0}" -lt 1 ]; then
    echo "expected wrapper stats to record at least one workspace_symbols request" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi
  goals_count="$(BEAM_JSON_PAYLOAD="$stats_out" read_json_text_field result.byBackend.lean.ops.goals.count)"
  if [ "${goals_count:-0}" -lt 2 ]; then
    echo "expected wrapper stats to record at least two goals requests" >&2
    printf '%s\n' "$stats_out" >&2
    exit 1
  fi

)

pid1_repeat="$(read_json_field "$registry_path" pid)"
port1_repeat="$(read_json_field "$registry_path" port)"
if [ "$pid1" != "$pid1_repeat" ] || [ "$port1" != "$port1_repeat" ]; then
  echo "wrapper unexpectedly restarted the Beam daemon for the same project" >&2
  exit 1
fi
