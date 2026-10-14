/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake

open Lake DSL
open System

package "beam" where
  enableArtifactCache := true
  restoreAllArtifacts := true

-- Native objects include Lean runtime headers: cache per platform and Lean toolchain.
target beamControlDirObj (pkg) : FilePath := do
  let srcFile := pkg.dir / "Beam" / "Native" / "control_dir.c"
  let oFile := pkg.buildDir / "native" / "control_dir.o"
  let srcTarget ← inputTextFile srcFile
  buildO oFile srcTarget #["-I", (← getLeanIncludeDir).toString] #["-fPIC"]
    (extraDepTrace := getLeanTrace)

target beamPipeObj (pkg) : FilePath := do
  let srcFile := pkg.dir / "Beam" / "Native" / "pipe.c"
  let oFile := pkg.buildDir / "native" / "pipe.o"
  let srcTarget ← inputTextFile srcFile
  buildO oFile srcTarget #["-I", (← getLeanIncludeDir).toString] #["-fPIC"]
    (extraDepTrace := getLeanTrace)

lean_lib Beam.LSP where
  globs := #[.andSubmodules `Beam.LSP]
  defaultFacets := #[`shared]

lean_lib Beam where
  defaultFacets := #[`shared]
  moreLinkObjs := #[beamControlDirObj, beamPipeObj]

lean_lib BeamTest where
  srcDir := "tests/lean"

lean_exe "beam-lsp-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.TestRunner

lean_exe "beam-lsp-scenario-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.ScenarioRunner

lean_exe "beam-lsp-scenario-api-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Scenario.ApiTest

lean_exe "beam-lsp-scenario-stress-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Scenario.StressTest

lean_exe "beam-lsp-handle-api-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Handle.ApiTest

lean_exe "beam-lsp-handle-restart-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Handle.RestartTest

lean_exe "beam-lsp-handle-lifecycle-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Handle.LifecycleTest

lean_exe "beam-lsp-mcts-proof-search-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Scenario.MctsProofSearchTest

lean_exe "beam-lsp-parallel-grind-batch-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Scenario.ParallelGrindBatchTest

lean_exe "beam-lsp-nested-handle-failure-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Handle.NestedHandleFailureTest

lean_exe "beam-lsp-request-surface-test" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.RequestSurfaceTest

lean_exe "beam-lsp-search-workload-report" where
  srcDir := "tests/lean"
  root := `BeamTest.LSP.Scenario.SearchWorkloadReport

lean_exe "beam-daemon" where
  root := `Beam.Broker.ServerMain
  supportInterpreter := true

lean_exe "lean-beam-mcp" where
  root := `Beam.Mcp.ServerMain
  supportInterpreter := true

@[default_target]
lean_exe "beam-cli" where
  root := `Beam.Cli

lean_exe "beam-daemon-smoke-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.SmokeTestMain

lean_exe "beam-sync-concurrency-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.SyncConcurrencyProbe

lean_exe "beam-daemon-save-stream-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.SaveStreamTestMain

lean_exe "beam-daemon-stream-contract-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.StreamContractTestMain

lean_exe "beam-sync-result-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.SyncResultTest

lean_exe "beam-daemon-backend-startup-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.BackendStartupTestMain

lean_exe "beam-broker-protocol-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.ProtocolTest

lean_exe "beam-broker-pending-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.PendingTest

lean_exe "beam-broker-document-state-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.DocumentStateTest

lean_exe "beam-broker-open-docs-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.OpenDocsTest

lean_exe "beam-cli-daemon-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.CliDaemonTest

lean_exe "beam-feedback-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.FeedbackTest

lean_exe "beam-mcp-projection-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.McpProjectionTest

lean_exe "beam-mcp-protocol-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.McpProtocolTest

lean_exe "beam-daemon-rocq-smoke-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.RocqSmokeTest
