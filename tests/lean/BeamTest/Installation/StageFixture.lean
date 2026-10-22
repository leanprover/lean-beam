/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Install.Construction

private def copy (source destination : System.FilePath) : IO Unit := do
  Beam.Install.Construction.stageOutput source destination
  let access : IO.AccessRight := { read := true, execution := true }
  IO.setAccessRights destination ⟨{ access with write := true }, access, access⟩

/-- Test setup only: stage already-built same-compiler artifacts without building target runtimes. -/
def main (args : List String) : IO Unit := do
  let [source, destination, lean, selector, commit] := args
    | throw <| IO.userError "expected SOURCE STAGING LEAN SELECTOR COMMIT"
  let source ← Beam.resolveExistingPath source
  let root := System.FilePath.mk destination
  let suffix := if System.Platform.isWindows then ".exe" else ""
  let cli := "libexec/beam-cli" ++ suffix
  let mcp := "libexec/lean-beam-mcp" ++ suffix
  let daemon := "runtimes/0/bin/beam-daemon" ++ suffix
  let some pluginName := (Beam.LSP.Lib.pluginSharedLibPath "").fileName
    | throw <| IO.userError "missing platform plugin filename"
  let plugin := "runtimes/0/" ++ pluginName
  for (input, output) in [
      (source / ".lake/build/bin" / ("beam-cli" ++ suffix), root / cli),
      (source / ".lake/build/bin" / ("lean-beam-mcp" ++ suffix), root / mcp),
      (source / ".lake/build/bin" / ("beam-daemon" ++ suffix), root / daemon),
      (Beam.LSP.Lib.pluginSharedLibPath (source / ".lake/build/lib"), root / plugin),
      (source / "LICENSE", root / "LICENSE")] do
    copy input output
  for wrapper in ["lean-beam", "lean-beam-mcp", "lean-beam-search"] do
    copy (source / "scripts" / wrapper) (root / "bin" / wrapper)
  let compiler := System.FilePath.mk lean
  let compilerRoot := (compiler.parent >>= System.FilePath.parent).getD compiler
  let fingerprint : Beam.Install.ToolchainFingerprint := {
    leanVersion := "same-compiler test fixture", lakeVersion := "same-compiler test fixture"
    leanPrefix := compilerRoot.toString, leanLibDir := (compilerRoot / "lib/lean").toString
    compilerRevision := Beam.compiledCompilerRevision
  }
  Beam.Install.Construction.stageFrontendSharedLibraries source root (source / ".beam/stage-fixture-build") fingerprint
  let libraries ← Beam.Install.buildSharedRuntimePaths (source / ".beam/stage-fixture-build") source fingerprint
  Beam.Install.Construction.stageSharedLibraries (libraries.map (fun path => source / ".lake/build" / System.FilePath.mk path))
    (root / "runtimes/0") "bin"
  let target : Beam.Installation.Target := {
    lean := (← Beam.resolveExistingPath lean).toString, daemon, plugin, toolchain := selector
    compilerRevision := Beam.compiledCompilerRevision
    leanVersion := "same-compiler test fixture", lakeVersion := "same-compiler test fixture"
  }
  let manifest ← Beam.Install.Construction.finalize root (some commit) {
    frontends := { cli, mcp, compilerRevision := Beam.compiledCompilerRevision }
    license := "LICENSE", targets := #[target]
  }
  IO.println manifest.payloadHash
