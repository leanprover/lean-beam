#!/usr/bin/env bash

# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
# Author: Emilio J. Gallego Arias

set -euo pipefail

cd "$(dirname "$0")/.."

lake build Beam.LSP:shared > /dev/null
lake build BeamTest > /dev/null
lake build BeamTest.Fixtures.Deps.DepA > /dev/null
python3 tests/lsp-coverage/check.py

run_case() {
  local name="$1"
  local actual
  echo "interactive: $name"
  actual="$(mktemp)"
  trap 'rm -f "$actual"' RETURN
  lake env lean --run tests/lean/BeamTest/LSP/TestRunner.lean "tests/interactive/${name}.lean" > /dev/null 2> "$actual"
  diff -u "tests/interactive/expected/${name}.out" "$actual"
  rm -f "$actual"
  trap - RETURN
}

run_quiet() {
  local output
  output="$(mktemp)"
  if "$@" > "$output" 2>&1; then
    rm -f "$output"
  else
    local status="$?"
    cat "$output"
    rm -f "$output"
    return "$status"
  fi
}

run_scenario_case() {
  local name="$1"
  echo "scenario: $name"
  run_quiet lake env lean --run tests/lean/BeamTest/LSP/ScenarioRunner.lean "tests/scenario/${name}.scn"
}

run_scenario_api_case() {
  echo "scenario-api"
  run_quiet lake env lean --run tests/lean/BeamTest/LSP/Scenario/ApiTest.lean
}

run_scenario_stress_case() {
  echo "scenario-stress"
  run_quiet lake env lean --run tests/lean/BeamTest/LSP/Scenario/StressTest.lean
}

run_handle_api_case() {
  echo "handle-api"
  run_quiet lake exe beam-lsp-handle-api-test
}

run_handle_restart_case() {
  echo "handle-restart"
  run_quiet lake exe beam-lsp-handle-restart-test
}

run_handle_lifecycle_case() {
  echo "handle-lifecycle"
  run_quiet lake exe beam-lsp-handle-lifecycle-test
}

run_mcts_proof_search_case() {
  echo "mcts-proof-search"
  run_quiet lake env lean --run tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean
}

run_parallel_grind_batch_case() {
  local report
  echo "parallel-grind-batch"
  report="$(mktemp)"
  trap 'rm -f "$report"' RETURN
  lake env lean --run tests/lean/BeamTest/LSP/Scenario/ParallelGrindBatchTest.lean > "$report"
  python3 - "$report" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

assert data["kind"] == "parallelGrindBatchReport", data
assert data["fixture"] == "tests/scenario/docs/ParallelGrind10.lean", data
assert data["todoSorryCount"] == 100, data
assert data["declarationSorryDiagnosticCount"] == 10, data
assert data["remainingSorryDiagnosticCount"] == 0, data
assert data["runAtBatchWallTimeUs"] > 0, data
assert data["changeBatchILeansWallTimeUs"] > 0, data
assert data["saveReady"] is True, data
assert data["saveReadyReason"] == "ok", data
PY
  rm -f "$report"
  trap - RETURN
}

run_search_workload_case() {
  local report
  echo "search-workload"
  report="$(mktemp)"
  trap 'rm -f "$report"' RETURN
  lake env lean --run tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean 48 20260321 > "$report"
  python3 - "$report" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

assert data["kind"] == "searchWorkloadReport", data
assert data["fixture"] == "tests/scenario/docs/MctsProof.lean", data
assert data["playoutsRequested"] == 48, data
assert data["playoutsCompleted"] == 48, data
assert data["solvedPlayouts"] == 48, data
assert data["rootGoalCount"] >= 1, data
assert data["avgStepsPerPlayout"] >= 2, data
assert data["maxStepsPerPlayout"] >= 3, data
ops = data["ops"]
assert ops["mint"]["count"] == 1, ops
assert ops["branchSuccess"]["count"] >= 48, ops
assert ops["linearSuccess"]["count"] >= 48, ops
assert ops["failureProbe"]["count"] >= 10, ops
assert ops["release"]["count"] >= 49, ops
hist = {entry["goals"]: entry["count"] for entry in data["goalHistogram"]}
assert 0 in hist, hist
assert data["totalWallTimeUs"] > 0, data
PY
  rm -f "$report"
  trap - RETURN
}

run_nested_handle_failure_case() {
  echo "nested-handle-failure"
  run_quiet lake exe beam-lsp-nested-handle-failure-test
}

run_request_surface_case() {
  echo "request-surface"
  run_quiet lake exe beam-lsp-request-surface-test
}

run_case asyncEditAwait
run_case commandBasis
run_case commandBlankLine
run_case commandEOF
run_case commandLoggedError
run_case commandNoLeak
run_case commandOutput
run_case proofBasis
run_case proofBasisBefore
run_case proofBulletBlank
run_case proofBulletComment
run_case proofClosedTermBoundary
run_case proofConstructorBoundary
run_case proofInductionWith
run_case proofLoggedError
run_case proofNestedBulletWhitespace
run_case proofNestedConstructorOrder
run_case proofNestedRightSibling
run_case proofNestedHave
run_case proofTermAscriptionError
run_scenario_case cancelPending
run_scenario_case cancelInnerPolling
run_scenario_case changePending
run_scenario_case editOtherDocWhilePending
run_scenario_case handleCancelDsl
run_scenario_case handleDsl
run_scenario_case handleInvalidationDsl
run_scenario_case handleLinearDsl
run_scenario_case handleNestedBranchDsl
run_scenario_case handleNestedRightBranchDsl
run_scenario_case handleProofBranchDsl
run_scenario_case handleSearchCancelDsl
run_scenario_case inDocumentPositions
run_scenario_case outOfRangeLine
run_scenario_case outOfRangeCharacter
run_scenario_case phase2HighConcurrency
run_scenario_case twoDocsSync
run_scenario_case closePending
run_scenario_api_case
run_scenario_stress_case
run_handle_api_case
run_handle_restart_case
run_handle_lifecycle_case
run_mcts_proof_search_case
run_parallel_grind_batch_case
run_request_surface_case
run_search_workload_case
run_nested_handle_failure_case
