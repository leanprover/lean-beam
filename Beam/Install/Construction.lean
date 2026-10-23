/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Installation.Manifest
import Beam.Install.Checksum
import Beam.Install.TargetBuild
import Beam.CompilerRevision

open Lean Beam.Installation

namespace Beam.Install.Construction

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

/-- Hash the complete record with a blank digest: relationships and provenance participate too. -/
private def generationWith (hashes : Checksum.Context) (manifest : InstallManifest) : IO String := do
  hashes.textHash ((toJson { manifest with payloadHash := "" }).pretty ++ "\n")

def generation (manifest : InstallManifest) : IO String := do
  generationWith (← Checksum.select) manifest

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

/-- Validate native root-relative spelling before serializing it into the inventory. -/
def inventoryPath (root path : System.FilePath) : Except String String := do
  let some relative := Beam.pathRelativeToRoot? root path
    | throw s!"construction file is outside its inventory root: {path}"
  let portable := String.intercalate "/" (System.FilePath.mk relative).components
  unless Beam.Installation.relativePath portable do
    throw s!"construction file has a nonportable inventory path: {path}"
  pure portable

private def inventory (hashes : Checksum.Context) (root : System.FilePath) : IO (Array Beam.Installation.Artifact) := do
  (← files root root).mapM fun path => do
    let relative ← IO.ofExcept <| inventoryPath root path
    pure { source := relative, destination := relative, hash := ← hashes.fileHash path }

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
private def finalizeWith (hashes : Checksum.Context) (root : System.FilePath) (sourceCommit : Option String)
    (components : Beam.Installation.Components) : IO InstallManifest := do
  require (!(← (root / "manifest.json").pathExists)) "refusing to rewrite an existing installation manifest"
  let artifacts ← inventory hashes root
  IO.ofExcept <| (components.validate artifacts).mapError IO.userError
  checkTargets root components
  let manifest : InstallManifest := {
    schemaVersion := installManifestSchemaVersion, payloadHash := "", sourceCommit, components, artifacts
  }
  let manifest := { manifest with payloadHash := ← generationWith hashes manifest }
  IO.FS.writeFile (root / "manifest.json") ((toJson manifest).pretty ++ "\n")
  pure manifest

def finalize (root : System.FilePath) (sourceCommit : Option String)
    (components : Beam.Installation.Components) : IO InstallManifest := do
  finalizeWith (← Checksum.select) root sourceCommit components

/-- Construction/reuse verification, including every file. Normal execution does not call this. -/
def verify (root : System.FilePath) : IO InstallManifest := do
  let hashes ← Checksum.select
  let manifest ← readInstallManifest (root / "manifest.json")
  require ((← generationWith hashes manifest) == manifest.payloadHash) "installation record changed after construction"
  let actual ← inventory hashes root
  require (actual == manifest.artifacts) "installation files differ from the published inventory"
  checkTargets root manifest.components
  pure manifest

private def makeExecutable (destination : System.FilePath) : IO Unit := do
  let x : IO.AccessRight := { read := true, write := true, execution := true }
  let rx : IO.AccessRight := { read := true, execution := true }
  IO.setAccessRights destination ⟨x, rx, rx⟩

/-- Copy one declared build output into staging; links and missing outputs are rejected. -/
def stageOutput (source destination : System.FilePath) : IO Unit := do
  if (← Beam.pathIsLink source) || !(← Beam.regularNonSymlinkFile source) then
    throw <| IO.userError s!"missing regular construction output: {source}"
  IO.FS.createDirAll (destination.parent.getD ".")
  IO.FS.writeBinFile destination (← IO.FS.readBinFile source)

/-- Copy the explicit SDK dependency list into this component's private loader layout. -/
def stageSharedLibraries (libraries : Array System.FilePath)
    (root : System.FilePath) (binDirectory : String) : IO Unit := do
  require (!libraries.isEmpty) "constructed runtime has no declared shared libraries"
  let destination := root / if System.Platform.isWindows then binDirectory else "lib/lean"
  for source in libraries do
    let some name := source.fileName | throw <| IO.userError "shared library has no filename"
    stageOutput source (destination / name)

/-- Frontends use their build's selected SDK, independently of the target compiler set. -/
def stageFrontendSharedLibraries (source root buildDir : System.FilePath)
    (fingerprint : ToolchainFingerprint) : IO Unit := do
  require (Beam.compilerRevisionsMatch Beam.compiledCompilerRevision Lean.githash fingerprint.compilerRevision)
    "frontend build, loaded runtime, and construction compiler revisions differ"
  let libraries ← buildSharedRuntimePaths buildDir source fingerprint
  stageSharedLibraries (libraries.map (fun path => source / ".lake/build" / System.FilePath.mk path)) root "libexec"

/-- Temporary build directories live inside staging, so a failed install discards them with it. -/
private def constructionDirName : String := ".construction"

/-- Remove one finished target build. A nonstandard SDK build links its private Lake home to the
selected toolchain's library tree (POSIX only); `removeDirAll` removes those links without
following them, so the toolchain is never touched. -/
def discardBuildDirectory (buildDir : System.FilePath) : IO Unit := do
  if ← buildDir.pathExists then IO.FS.removeDirAll buildDir

/-- Explicit installer work: build each target, copy its outputs into staging, qualify the staged
copies, then publish one record. Each target is built from scratch in a temporary directory; only
Lake's own artifact cache can make a rebuild cheaper. -/
def construct (source frontendSdk root : System.FilePath) (sourceCommit : Option String)
    (toolchains : List String) : IO InstallManifest := do
  require (!toolchains.isEmpty) "installation construction requires at least one target"
  require (!(← (root / "manifest.json").pathExists)) "refusing to extend a published installation"
  let work := root / constructionDirName
  -- Construction owns this directory because it created it: any existing entry, including a link,
  -- is refused and left untouched.
  try IO.FS.createDir work
  catch
    | .alreadyExists .. =>
        throw <| IO.userError s!"refusing to reuse an existing construction directory: {work}"
    | error => throw error
  let hashes ← Checksum.select
  let frontend ← fingerprintLeanInstallation frontendSdk
  stageFrontendSharedLibraries source root (work / "frontend") frontend
  let mut targets : Array Beam.Installation.Target := #[]
  for toolchain in toolchains do
    let fingerprint ← toolchainFingerprint toolchain
    let buildDir := work / toString targets.size
    let built ← buildTarget source toolchain fingerprint buildDir
    let relative := s!"runtimes/{targets.size}"
    let daemon := relative ++ "/bin/" ++ built.daemon.fileName.getD "beam-daemon"
    let plugin := relative ++ "/" ++ built.plugin.fileName.getD "beam-plugin"
    stageOutput built.daemon (root / daemon)
    makeExecutable (root / daemon)
    stageOutput built.plugin (root / plugin)
    stageSharedLibraries built.sharedLibraries (root / relative) "bin"
    -- Qualify and execute only the staged copies, so the checked bytes are the shipped bytes.
    built.qualify (root / plugin)
    let info ← IO.Process.output { cmd := (root / daemon).toString, args := #["build-info"] }
    require (info.exitCode == 0) s!"constructed daemon cannot report its compiler origin: {info.stderr}"
    let build ← IO.ofExcept <| (Json.parse info.stdout).mapError IO.userError
    let compiled ← IO.ofExcept <| (build.getObjValAs? String "compiledLeanRevision").mapError IO.userError
    let loaded ← IO.ofExcept <| (build.getObjValAs? String "loadedLeanRevision").mapError IO.userError
    require (Beam.compilerRevisionsMatch compiled loaded fingerprint.compilerRevision)
      "constructed daemon, loaded runtime, and selected target compiler revisions differ"
    let lean := System.FilePath.mk fingerprint.leanPrefix / "bin" /
      (if System.Platform.isWindows then "lean.exe" else "lean")
    targets := targets.push {
      lean := (← Beam.resolveExistingPath lean).toString, daemon, plugin, toolchain
      compilerRevision := fingerprint.compilerRevision
      leanVersion := fingerprint.leanVersion, lakeVersion := fingerprint.lakeVersion
    }
    discardBuildDirectory buildDir
  discardBuildDirectory work
  finalizeWith hashes root sourceCommit {
    frontends := {
      cli := "libexec/beam-cli"
      mcp := "libexec/lean-beam-mcp"
      compilerRevision := Beam.compiledCompilerRevision
    }
    license := "LICENSE"
    targets
  }

end Beam.Install.Construction
