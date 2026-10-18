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
    #["-Dweak.beam.toolchain=true",
      "-Dweak.beam.buildId=" ++ (get_config? beamBuildId).getD "",
      "-Dweak.beam.sourceRevision=" ++ (get_config? beamSourceRevision).getD ""] else #[]

/-- The revision of the Lean runtime loaded by the selected Lake process. -/
script beamToolchainCompilerId do
  IO.println Lean.githash
  return 0

/-- Stage a complete runtime library without modifying an existing destination in place. -/
private def stageBeamSharedLibrary (src dst : FilePath) : IO Unit := do
  let bytes ← IO.FS.readBinFile src
  let alreadyStaged ← try
    let metadata ← dst.symlinkMetadata
    pure <| metadata.type == .file && (← IO.FS.readBinFile dst) == bytes
  catch
    | .noFileOrDirectory .. => pure false
    | e => throw e
  unless alreadyStaged do
    IO.FS.createDirAll (dst.parent.getD ".")
    let tmp := FilePath.mk s!"{dst}.beam-stage-{← IO.Process.getPID}-{← IO.monoNanosNow}.tmp"
    try
      IO.FS.withFile tmp .writeNew fun handle => handle.write bytes
      IO.FS.rename tmp dst
    catch e =>
      try removeFileIfExists tmp catch _ => pure ()
      throw e

/-- Link the selected Lean/Lake shared libraries and stage their exact runtime dependencies. -/
target beamSharedRuntime (pkg) : Dynlib := do
  let lean ← getLeanInstall
  let dstDir := pkg.buildDir / if System.Platform.isWindows then "bin" else "lib/lean"
  let lake := (LakeInstall.ofLean lean).sharedDynlib
  let copies ← (lake.deps.push lake).mapM fun lib => do
    let dst := dstDir / nameToSharedLib lib.name true
    let input ← inputBinFile lib.path
    input.mapM fun source => do
      -- These are already-built SDK inputs; stage them without adding duplicate split-library
      -- stubs to Lake's artifact cache.
      stageBeamSharedLibrary source dst
  return (Job.collectArray copies).map fun _ => lake

/-- Executables use a sibling lib/lean directory; standalone targets retain that layout privately. -/
def beamSharedRuntimeLinkArgs : Array String :=
  if System.Platform.isWindows then #[]
  else if System.Platform.isOSX then #["-Wl,-rpath,@loader_path/../lib/lean"]
  else #["-Wl,-rpath,$ORIGIN/../lib/lean"]

/-- Construction input only: the exact staged SDK libraries, never a directory search. -/
script beamSharedRuntimeFiles do
  let lean ← getLeanInstall
  let lake := (LakeInstall.ofLean lean).sharedDynlib
  let directory := if System.Platform.isWindows then "bin" else "lib/lean"
  IO.println (Lean.toJson <| (lake.deps.push lake).map fun lib =>
    directory ++ "/" ++ nameToSharedLib lib.name true).compress
  return 0

/-- Compile native helpers with the selected Lean compiler and native SDK headers. -/
private def buildNativeObject (pkg : Package) (name : String) : FetchM (Job FilePath) := do
  let srcFile := pkg.dir / "Beam" / "Native" / (name ++ ".c")
  let oFile := pkg.buildDir / "native" / (name ++ ".o")
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
    let systemIncludes : Array String ← match ← IO.getEnv "BEAM_NATIVE_SYSTEM_INCLUDE_DIRS" with
      | none => pure #[]
      | some value => match Lean.Json.parse value >>= Lean.fromJson? with
        | .ok directories => pure directories
        | .error message => error s!"invalid BEAM_NATIVE_SYSTEM_INCLUDE_DIRS: {message}"
    for directory in systemIncludes do
      unless ← (FilePath.mk directory).isDir do
        error s!"native Windows system include directory does not exist: {directory}"
    pure (#["-resource-dir", resourceDir] ++
      (if systemIncludes.isEmpty then #[] else #["-nostdlibinc"]) ++
      systemIncludes.flatMap fun directory => #["-idirafter", directory])
  else pure #[]
  buildO oFile srcTarget #[] (nativeFlags ++ sdkFlags ++ #["-I", includeDir.toString, "-fPIC"]) compiler
    (extraDepTrace := do
      addLeanTrace
      addPureTrace compiler.toString "compiler"
      pure BuildTrace.nil)


target beamControlDirObj (pkg) : FilePath := buildNativeObject pkg "control_dir"
target beamProcessJobObj (pkg) : FilePath := buildNativeObject pkg "process_job"

lean_lib Beam.LSP where
  globs := #[.andSubmodules `Beam.LSP]
  defaultFacets := #[`shared]

lean_lib Beam where
  defaultFacets := #[`shared]
  moreLinkObjs := #[beamControlDirObj, beamProcessJobObj]

lean_lib BeamTest where
  srcDir := "tests/lean"

lean_exe "beam-system-contract-test" where
  srcDir := "tests/lean"
  root := `BeamTest.SystemContractTest

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
  supportInterpreter := System.Platform.isWindows
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

lean_exe "beam-backend-process-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.BackendProcessTestMain

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

lean_exe "beam-install-runtime" where
  root := `Beam.InstallMain

lean_exe "beam-installation-construction-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Installation.ConstructionTest

lean_exe "beam-installation-manifest-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Installation.ManifestTest

lean_exe "beam-installation-lookup-test" where
  srcDir := "tests/lean"
  root := `BeamTest.Installation.LookupTest

lean_exe "beam-daemon-fixture" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.DaemonFixture
  supportInterpreter := true

lean_exe "beam-lake-helper-client-fixture" where
  srcDir := "tests/lean"
  root := `BeamTest.Broker.LakeHelperClientFixture

lean_exe "beam-installation-stage-fixture" where
  srcDir := "tests/lean"
  root := `BeamTest.Installation.StageFixture
