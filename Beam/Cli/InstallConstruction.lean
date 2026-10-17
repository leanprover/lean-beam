/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallLayout
import Beam.Cli.RuntimeBundle.Build
import Beam.CompilerRevision

open Lean

namespace Beam.Cli.InstallConstruction

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def digestOutput (output : IO.Process.Output) : IO String := do
  require (output.exitCode == 0) s!"SHA-256 command failed ({output.exitCode}): {output.stderr}"
  let token := (output.stdout.splitOn " ").headD ""
  -- Both checksum tools prefix the line with one backslash when escaping the filename.
  let hash := if token.startsWith "\\" then (token.drop 1).toString else token
  require (Beam.Installation.hexDigest 64 hash) s!"invalid SHA-256 digest: {repr token}"
  pure hash

private def hashCommand : IO (String × Array String) := do
  let commands : Array (String × Array String) := #[
    ("sha256sum", #["--binary"]), ("shasum", #["-a", "256", "--binary"])
  ]
  for (cmd, args) in commands do
    let usable ← try
      let output ← IO.Process.output { cmd, args := #["--version"] }
      pure (output.exitCode == 0)
    catch _ => pure false
    if usable then return (cmd, args)
  throw <| IO.userError "installation construction requires sha256sum or shasum"

private def fileHash (path : System.FilePath) : IO String := do
  let (cmd, args) ← hashCommand
  digestOutput (← IO.Process.output { cmd, args := args.push path.toString })

/-- Hash the complete record with a blank digest: relationships and provenance participate too. -/
def generation (manifest : InstallManifest) : IO String := do
  let (cmd, args) ← hashCommand
  digestOutput (← IO.Process.output { cmd, args }
    (some ((toJson { manifest with payloadHash := "" }).pretty ++ "\n")))

private partial def files (root directory : System.FilePath) : IO (Array System.FilePath) := do
  let mut result := #[]
  for entry in (← directory.readDir).qsort (fun a b => a.fileName < b.fileName) do
    if ← Beam.pathIsLink entry.path then
      throw <| IO.userError s!"installation contains a symlink or special file: {entry.path}"
    match (← entry.path.symlinkMetadata).type with
    | .dir => result := result ++ (← files root entry.path)
    | .file =>
        unless entry.path == root / "manifest.json" do result := result.push entry.path
    | _ => throw <| IO.userError s!"installation contains a symlink or special file: {entry.path}"
  pure result

private def inventory (root : System.FilePath) : IO (Array Beam.Installation.Artifact) := do
  (← files root root).mapM fun path => do
    -- The record uses '/' on every host; filesystem paths retain their native spelling.
    let relative := String.intercalate "/"
      (System.FilePath.mk (Beam.pathRelativeToRootOrSelf root path)).components
    pure { source := relative, destination := relative, hash := ← fileHash path }

private def checkTargets (root : System.FilePath) (components : Beam.Installation.Components) : IO Unit := do
  let mut selected : Std.HashSet String := {}
  for target in components.targets do
    let command := System.FilePath.mk target.lean
    require command.isAbsolute "standalone target Lean command must name its constructed installation"
    let canonical ← Beam.resolveExistingPath command
    require (canonical.toString == target.lean) "target Lean command must be canonical at construction"
    let key := if System.Platform.isWindows then canonical.toString.toLower else canonical.toString
    require (!selected.contains key) s!"duplicate target Lean installation: {canonical}"
    selected := selected.insert key
    for path in #[target.daemon, target.plugin] do
      require (← Beam.regularNonSymlinkFile (root / path)) s!"missing constructed component: {path}"

/-- Finish a staged installation. This operation never modifies an already published generation. -/
def finalize (root : System.FilePath) (sourceCommit : Option String)
    (components : Beam.Installation.Components) : IO InstallManifest := do
  require (!(← (root / "manifest.json").pathExists)) "refusing to rewrite an existing installation manifest"
  let artifacts ← inventory root
  IO.ofExcept <| (components.validate artifacts).mapError IO.userError
  checkTargets root components
  let manifest : InstallManifest := {
    schemaVersion := installManifestSchemaVersion, payloadHash := "", sourceCommit, components, artifacts
  }
  let manifest := { manifest with payloadHash := ← generation manifest }
  IO.FS.writeFile (root / "manifest.json") ((toJson manifest).pretty ++ "\n")
  pure manifest

/-- Construction/reuse verification, including every file. Normal execution does not call this. -/
def verify (root : System.FilePath) : IO InstallManifest := do
  let manifest ← readInstallManifest (root / "manifest.json")
  require ((← generation manifest) == manifest.payloadHash) "installation record changed after construction"
  let actual ← inventory root
  require (actual == manifest.artifacts) "installation files differ from the published inventory"
  checkTargets root manifest.components
  pure manifest

private def copyExecutable (source destination : System.FilePath) : IO Unit := do
  IO.FS.createDirAll (destination.parent.getD ".")
  IO.FS.writeBinFile destination (← IO.FS.readBinFile source)
  let x : IO.AccessRight := { read := true, write := true, execution := true }
  let rx : IO.AccessRight := { read := true, execution := true }
  IO.setAccessRights destination ⟨x, rx, rx⟩

/-- Copy the explicit SDK dependency list into this component's private loader layout. -/
def stageSharedLibraries (libraries : Array System.FilePath)
    (root : System.FilePath) (binDirectory : String) : IO Unit := do
  require (!libraries.isEmpty) "constructed runtime has no declared shared libraries"
  let destination := root / if System.Platform.isWindows then binDirectory else "lib/lean"
  IO.FS.createDirAll destination
  for source in libraries do
    let some name := source.fileName | throw <| IO.userError "shared library has no filename"
    require (← Beam.regularNonSymlinkFile source) s!"missing staged SDK library: {source}"
    IO.FS.writeBinFile (destination / name) (← IO.FS.readBinFile source)

/-- Frontends use their build's selected SDK, independently of the target compiler set. -/
def stageFrontendSharedLibraries (source root cache : System.FilePath)
    (fingerprint : ToolchainFingerprint) : IO Unit := do
  require (Beam.compilerRevisionsMatch Beam.compiledCompilerRevision Lean.githash fingerprint.compilerRevision)
    "frontend build, loaded runtime, and construction compiler revisions differ"
  let libraries ← buildSharedRuntimePaths cache source fingerprint
  stageSharedLibraries (libraries.map (fun path => source / ".lake/build" / System.FilePath.mk path)) root "libexec"

/-- Explicit installer work: qualify targets, copy their bytes into staging, then publish a record. -/
def construct (source frontendSdk root cache : System.FilePath) (sourceCommit : Option String)
    (toolchains : List String) : IO InstallManifest := do
  require (!toolchains.isEmpty) "installation construction requires at least one target"
  require (!(← (root / "manifest.json").pathExists)) "refusing to extend a published installation"
  let frontend ← fingerprintLeanInstallation frontendSdk
  stageFrontendSharedLibraries source root cache frontend
  let mut targets : Array Beam.Installation.Target := #[]
  for toolchain in toolchains do
    let fingerprint ← toolchainFingerprint toolchain
    let (paths, _) ← ensureToolchainBundleInForFingerprint cache source toolchain fingerprint
    let info ← IO.Process.output { cmd := paths.daemon.toString, args := #["build-info"] }
    require (info.exitCode == 0) s!"constructed daemon cannot report its compiler origin: {info.stderr}"
    let build ← IO.ofExcept <| (Json.parse info.stdout).mapError IO.userError
    let compiled ← IO.ofExcept <| (build.getObjValAs? String "compiledLeanRevision").mapError IO.userError
    let loaded ← IO.ofExcept <| (build.getObjValAs? String "loadedLeanRevision").mapError IO.userError
    require (Beam.compilerRevisionsMatch compiled loaded fingerprint.compilerRevision)
      "constructed daemon, loaded runtime, and selected target compiler revisions differ"
    let relative := s!"runtimes/{targets.size}"
    let directory := root / relative
    IO.FS.createDirAll (directory / "bin")
    let daemon := relative ++ "/bin/" ++ paths.daemon.fileName.getD "beam-daemon"
    let plugin := relative ++ "/" ++ paths.plugin.fileName.getD "beam-plugin"
    copyExecutable paths.daemon (root / daemon)
    IO.FS.writeBinFile (root / plugin) (← IO.FS.readBinFile paths.plugin)
    stageSharedLibraries paths.sharedLibraries directory "bin"
    let lean := System.FilePath.mk fingerprint.leanPrefix / "bin" /
      (if System.Platform.isWindows then "lean.exe" else "lean")
    targets := targets.push {
      lean := (← Beam.resolveExistingPath lean).toString, daemon, plugin, toolchain
      compilerRevision := fingerprint.compilerRevision
      leanVersion := fingerprint.leanVersion, lakeVersion := fingerprint.lakeVersion
    }
  finalize root sourceCommit {
    frontends := {
      cli := "libexec/beam-cli"
      mcp := "libexec/lean-beam-mcp"
      compilerRevision := Beam.compiledCompilerRevision
    }
    license := "LICENSE"
    targets
  }

end Beam.Cli.InstallConstruction
