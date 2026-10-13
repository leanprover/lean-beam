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
  buildDir := if (get_config? beamToolchain) == some "true" then
    ".lake/toolchain-build" else ".lake/build"
  moreLinkArgs := if System.Platform.isWindows then #["-ladvapi32"] else #[]
  moreLeanArgs := if (get_config? beamToolchain) == some "true" then
    #["-Dweak.beam.toolchain=true"] else #[]

/-- Used by the native distribution builder to check the selected Lake process's exact ABI. -/
script beamToolchainCompilerId do
  IO.println Lean.githash
  return 0

/-- Link the selected Lean/Lake shared libraries and stage their exact runtime dependencies. -/
target beamSharedRuntime (pkg) : Dynlib := do
  let lean ← getLeanInstall
  let srcDir := leanSharedLibDir lean.sysroot
  let dstDir := pkg.buildDir / if System.Platform.isWindows then "bin" else "lib/lean"
  let names := #["Init_shared", "leanshared_1", "leanshared_2", "leanshared", "Lake_shared"]
  let copies ← names.mapM fun name => do
    let src := srcDir / s!"lib{name}.{sharedLibExt}"
    let dst := dstDir / s!"lib{name}.{sharedLibExt}"
    let input ← inputBinFile src
    input.mapM fun source => do
      -- These are already-built toolchain inputs. Older Lake caches cannot store identical
      -- split-library stubs twice, so stage them directly without caching duplicate artifacts.
      let bytes ← IO.FS.readBinFile source
      let alreadyStaged ← (do
        try
          let metadata ← dst.symlinkMetadata
          pure <| metadata.type == .file && (← IO.FS.readBinFile dst) == bytes
        catch _ => pure false
        : IO Bool)
      unless alreadyStaged do
        IO.FS.createDirAll dstDir
        removeFileIfExists dst
        IO.FS.writeBinFile dst bytes
      return dst
  return (Job.collectArray copies).map fun _ =>
    let deps := names[:4].toArray.map fun name =>
      ({ name, path := srcDir / s!"lib{name}.{sharedLibExt}" } : Dynlib)
    { name := "Lake_shared", path := srcDir / s!"libLake_shared.{sharedLibExt}", deps }

/-- All source, standalone-install, and native-toolchain layouts use the same relative libdir. -/
def beamSharedRuntimeLinkArgs : Array String :=
  if System.Platform.isWindows then #[]
  else if System.Platform.isOSX then #["-Wl,-rpath,@loader_path/../lib/lean"]
  else #["-Wl,-rpath,$ORIGIN/../lib/lean"]

/-- Compile the control-directory helper with the selected Lean compiler and native SDK headers. -/
target beamControlDirObj (pkg) : FilePath := do
  let srcFile := pkg.dir / "Beam" / "Native" / "control_dir.c"
  let oFile := pkg.buildDir / "native" / "control_dir.o"
  let srcTarget ← inputTextFile srcFile
  let lean ← getLeanInstall
  let includeDir ← getLeanIncludeDir
  let compiler ← getLeanCc
  -- Lean's packaged generated-C sysroot contains no OS headers. These helpers call OS APIs,
  -- so retain the selected compiler/configuration flags with its native system header search.
  let (nativeFlags, _) := lean.ccFlags.foldl (init := ((#[] : Array String), false))
    fun (flags, skipNext) flag =>
      if skipNext then (flags, false)
      else if flag == "--sysroot" || (flag == "-isystem" && System.Platform.isWindows) then
        -- The full Windows SDK supplies clang intrinsics too. Including the packaged subset
        -- as well makes stdatomic.h's include_next hit a second copy with the same include guard.
        (flags, true)
      else if flag == "-nostdinc" || flag.startsWith "--sysroot=" then (flags, false)
      else (flags.push flag, false)
  let sdkFlags ← if System.Platform.isOSX then do
    let sdk ← IO.Process.output { cmd := "xcrun", args := #["--show-sdk-path"] }
    unless sdk.exitCode == 0 do error s!"cannot locate the native Apple SDK: {sdk.stderr}"
    pure #["-isysroot", sdk.stdout.trimAscii.toString]
  else if System.Platform.isWindows then do
    -- The packaged compiler omits intrinsics used by the full Windows SDK. Borrow native SDK
    -- headers while still compiling with the selected Lean compiler and linking its libraries.
    let resourceDir ← match ← IO.getEnv "BEAM_NATIVE_CLANG_RESOURCE_DIR" with
      | some dir => pure dir
      | none => do
        let sdk ← IO.Process.output { cmd := "clang", args := #["--print-resource-dir"] }
        unless sdk.exitCode == 0 do error "cannot locate native clang SDK headers"
        pure sdk.stdout.trimAscii.toString
    unless ← (FilePath.mk resourceDir / "include" / "x86intrin.h").pathExists do
      error "native Windows builds require a full clang SDK on PATH (for example MSYS2 clang64)"
    pure #["-resource-dir", resourceDir]
  else pure #[]
  buildO oFile srcTarget #[] (nativeFlags ++ sdkFlags ++ #["-I", includeDir.toString, "-fPIC"]) compiler
    (extraDepTrace := do
      addLeanTrace
      addPureTrace compiler.toString "compiler"
      pure BuildTrace.nil)


lean_lib Beam.LSP where
  globs := #[.andSubmodules `Beam.LSP]
  defaultFacets := #[`shared]

lean_lib Beam where
  defaultFacets := #[`shared]
  moreLinkObjs := #[beamControlDirObj]

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
  moreLinkLibs := #[beamSharedRuntime]
  moreLinkArgs := beamSharedRuntimeLinkArgs

lean_exe "lean-beam-mcp" where
  root := `Beam.Mcp.ServerMain
  supportInterpreter := true
  moreLinkLibs := #[beamSharedRuntime]
  moreLinkArgs := beamSharedRuntimeLinkArgs

@[default_target]
lean_exe "beam-cli" where
  root := `Beam.Cli
  moreLinkLibs := #[beamSharedRuntime]
  moreLinkArgs := beamSharedRuntimeLinkArgs

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
