/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Lock
import Beam.Cli.RuntimeBundle.Metadata
import Beam.Cli.RuntimeBundle.Source
import Beam.Path

open Lean

namespace Beam.Cli

private def copyFileInto (srcRoot dstRoot srcPath : System.FilePath) : IO Unit := do
  let rel := Beam.pathRelativeToRootOrSelf srcRoot srcPath
  let dst := dstRoot / rel
  if let some parent := dst.parent then
    IO.FS.createDirAll parent
  IO.FS.writeBinFile dst (← IO.FS.readBinFile srcPath)

private def copyTreeInto (srcRoot dstRoot : System.FilePath) : IO Unit := do
  let files ← collectTreeFiles srcRoot
  for path in files do
    copyFileInto srcRoot dstRoot path

private def ensureBundleWorkspaceOwnedForRewrite (bundleDir workspace : System.FilePath) : IO Unit := do
  unless ← workspace.pathExists do
    return ()
  unless ← workspace.isDir do
    throw <| IO.userError s!"refusing to replace non-directory bundle workspace at {workspace}"
  let resolvedBundleDir ← Beam.resolveExistingPath bundleDir
  let resolvedWorkspace ← Beam.resolveExistingPath workspace
  if Beam.pathRelativeToRoot? resolvedBundleDir resolvedWorkspace |>.isNone then
    throw <| IO.userError s!"refusing to rewrite bundle workspace outside its bundle directory: {workspace}"
  unless ← (bundleWorkspaceOwnerMarker workspace).pathExists do
    throw <| IO.userError s!"refusing to remove unmarked existing bundle workspace at {workspace}"

def syncBundleWorkspace (home bundleDir workspace : System.FilePath) : IO Unit := do
  ensureBundleWorkspaceOwnedForRewrite bundleDir workspace
  if ← workspace.pathExists then
    IO.FS.removeDirAll workspace
  IO.FS.createDirAll workspace
  IO.FS.writeFile (bundleWorkspaceOwnerMarker workspace) "owner=lean-beam\nschema=1\n"
  let files ← collectBundleSourceFiles home
  for path in files do
    copyFileInto home workspace path
  let packagesDir := home / ".lake" / "packages"
  if ← packagesDir.pathExists then
    copyTreeInto packagesDir (workspace / ".lake" / "packages")

private def samePath (left right : System.FilePath) : IO Bool := do
  try
    let left ← IO.FS.realPath left
    let right ← IO.FS.realPath right
    pure (left.normalize == right.normalize)
  catch _ =>
    pure (left.normalize == right.normalize)

private def symlinkForce (src dst : System.FilePath) : IO Unit := do
  try
    IO.FS.removeFile dst
  catch _ =>
    pure ()
  let out ← IO.Process.output {
    cmd := "ln"
    args := #["-s", src.toString, dst.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to create symlink {dst} -> {src}\n{out.stderr}"

private def copyExecutable (src dst : System.FilePath) : IO Unit := do
  IO.FS.writeBinFile dst (← IO.FS.readBinFile src)
  let x : IO.AccessRight := {read := true, write := true, execution := true}
  let rx : IO.AccessRight := {read := true, write := false, execution := true}
  IO.setAccessRights dst ⟨x, rx, rx⟩

private def prepareNonstandardLakeHome
    (bundleDir leanPrefix libDir : System.FilePath) : IO System.FilePath := do
  if System.Platform.isWindows then
    throw <| IO.userError
      "nonstandard Lean libdir toolchains are not supported by the local bundle fallback on Windows"
  let lakeHome := bundleDir / "lake-home"
  let buildDir := lakeHome / ".lake" / "build"
  let binDir := buildDir / "bin"
  let sharedLibDir := buildDir / "lib"
  let lakeLibDir := sharedLibDir / "lean"
  IO.FS.createDirAll binDir
  IO.FS.createDirAll sharedLibDir
  IO.FS.createDirAll lakeLibDir
  copyExecutable (leanPrefix / "bin" / "lake") (binDir / "lake")
  for entry in ← libDir.readDir do
    let name := entry.fileName
    if name.startsWith "lib" then
      pure ()
    else
      symlinkForce entry.path (lakeLibDir / name)
  let standardLibDir := leanPrefix / "lib" / "lean"
  for entry in ← standardLibDir.readDir do
    let name := entry.fileName
    if name.startsWith "lib" then
      symlinkForce entry.path (sharedLibDir / name)
      symlinkForce entry.path (lakeLibDir / name)
  pure lakeHome

private structure LakeInvocation where
  cmd : String
  args : Array String
  env : Array (String × Option String) := #[]

private def lakeInvocationFor (bundleDir : System.FilePath)
    (fingerprint : ToolchainFingerprint) :
    IO LakeInvocation := do
  let leanPrefix := System.FilePath.mk fingerprint.leanPrefix
  let exe := if System.Platform.isWindows then ".exe" else ""
  let default : LakeInvocation := {
    cmd := (leanPrefix / "bin" / ("lake" ++ exe)).toString
    args := #[]
    env := #[("LEAN", some (leanPrefix / "bin" / ("lean" ++ exe)).toString),
      ("LEAN_SYSROOT", some leanPrefix.toString), ("LAKE_HOME", none),
      ("LEAN_PATH", none), ("LEAN_SRC_PATH", none)]
  }
  let libDir := System.FilePath.mk fingerprint.leanLibDir
  let standardLibDir := leanPrefix / "lib" / "lean"
  if ← samePath libDir standardLibDir then
    pure default
  else
    let lakeHome ← prepareNonstandardLakeHome bundleDir leanPrefix libDir
    pure {
      cmd := (lakeHome / ".lake" / "build" / "bin" / "lake").toString
      args := #[]
      env := #[
        ("LAKE_HOME", some lakeHome.toString),
        ("LEAN", some (leanPrefix / "bin" / "lean").toString),
        ("LEAN_SYSROOT", none), ("LEAN_PATH", none), ("LEAN_SRC_PATH", none)
      ]
    }

/-- Query construction inputs from the selected Lake SDK, without scanning its library directory. -/
def buildSharedRuntimePaths (bundleDir workspace : System.FilePath)
    (fingerprint : ToolchainFingerprint) : IO (Array String) := do
  let lake ← lakeInvocationFor bundleDir fingerprint
  let output ← IO.Process.output {
    cmd := lake.cmd
    args := lake.args ++ #["script", "run", "beamSharedRuntimeFiles"]
    env := lake.env
    cwd := workspace.toString
  }
  unless output.exitCode == 0 do
    throw <| IO.userError s!"selected Lake could not report its shared-runtime inputs: {output.stderr}"
  let paths ← IO.ofExcept <| (Json.parse output.stdout >>= fromJson? (α := Array String)).mapError IO.userError
  unless validSharedRuntimePaths paths do
    throw <| IO.userError "selected Lake reported invalid shared-runtime inputs"
  pure paths

private def fallbackBuildFailureMessage (toolchain : String) (cacheRoot bundleDir : System.FilePath)
    (stdout stderr : String) : String :=
  String.intercalate "\n" [
    s!"failed to construct Beam runtime for toolchain {toolchain}",
    s!"construction cache directory: {cacheRoot}",
    s!"bundle workspace: {bundleWorkspaceFor bundleDir}",
    "installation runs `lake build` and may need network access on a cold machine",
    "normal Beam execution never constructs missing targets",
    "",
    "lake stdout:",
    if stdout.trimAscii.isEmpty then "(empty)" else stdout,
    "",
    "lake stderr:",
    if stderr.trimAscii.isEmpty then "(empty)" else stderr
  ]

private def bundleQualificationFailureMessage
    (toolchain : String)
    (workspace probe : System.FilePath)
    (stdout stderr : String) : String :=
  String.intercalate "\n" [
    s!"failed to qualify beam bundle for toolchain {toolchain}",
    "the bundle compiled, but its freshly built Lean plugin did not pass the local load/elaboration probe",
    s!"bundle workspace: {workspace}",
    s!"qualification source: {probe}",
    "the bundle was not marked ready and will not be reused",
    "",
    "qualification stdout:",
    if stdout.trimAscii.isEmpty then "(empty)" else stdout,
    "",
    "qualification stderr:",
    if stderr.trimAscii.isEmpty then "(empty)" else stderr
  ]

private def qualifyToolchainBundle
    (bundleDir workspace : System.FilePath)
    (toolchain : String)
    (lake : LakeInvocation) : IO Unit := do
  let qualificationDir := bundleDir / "qualification"
  let probe := qualificationDir / "Probe.lean"
  IO.FS.createDirAll qualificationDir
  IO.FS.writeFile probe "example : True := by\n  trivial\n"
  let plugin ← Beam.resolveExistingPath (leanBundlePathsFor workspace).plugin
  let probe ← Beam.resolveExistingPath probe
  let out ← IO.Process.output {
    cmd := lake.cmd
    args := lake.args ++ #[
      "env",
      "lean",
      s!"--plugin={plugin}",
      "-Dexperimental.module=true",
      probe.toString
    ]
    env := lake.env
    cwd := workspace.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError <|
      bundleQualificationFailureMessage toolchain workspace probe out.stdout out.stderr
  IO.FS.removeDirAll qualificationDir

def buildToolchainBundle (home : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (cacheRoot bundleDir workspace : System.FilePath) : IO Unit := do
  ensureElan
  let metadata := bundleMetadataPath bundleDir
  if ← metadata.pathExists then
    IO.FS.removeFile metadata
  syncBundleWorkspace home bundleDir workspace
  IO.eprintln s!"building beam bundle for {toolchain}"
  let lake ← lakeInvocationFor bundleDir fingerprint
  let out ← IO.Process.output {
    cmd := lake.cmd
    args := lake.args ++ #["build", "Beam.LSP:shared", "beam-daemon"]
    env := lake.env
    cwd := workspace.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| fallbackBuildFailureMessage toolchain cacheRoot bundleDir out.stdout out.stderr
  qualifyToolchainBundle bundleDir workspace toolchain lake
  let sharedLibraries ← buildSharedRuntimePaths bundleDir workspace fingerprint
  writeBundleMetadata bundleDir toolchain srcHash fingerprint workspace sharedLibraries

def existingToolchainBundleForFingerprint? (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (Option (LeanBundlePaths × String)) := do
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  let workspace := bundleWorkspaceFor bundleDir
  if ← bundleReady bundleDir toolchain srcHash fingerprint then
    let sharedLibraries := (← bundleSharedRuntimePaths bundleDir).map (fun path => workspace / ".lake/build" / System.FilePath.mk path)
    pure <| some ({ leanBundlePathsFor workspace with sharedLibraries }, bundleId)
  else
    pure none

def existingToolchainBundle? (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (Option (LeanBundlePaths × String)) := do
  let fingerprint ← toolchainFingerprint toolchain
  existingToolchainBundleForFingerprint? cacheRoot home toolchain fingerprint

partial def existingToolchainBundleInAnyForFingerprint? (cacheRoots : List System.FilePath)
    (home : System.FilePath) (toolchain : String) (fingerprint : ToolchainFingerprint) :
    IO (Option (LeanBundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | cacheRoot :: rest =>
      match ← existingToolchainBundleForFingerprint? cacheRoot home toolchain fingerprint with
      | some bundle => pure <| some bundle
      | none => existingToolchainBundleInAnyForFingerprint? rest home toolchain fingerprint

partial def existingToolchainBundleInAny? (cacheRoots : List System.FilePath) (home : System.FilePath)
    (toolchain : String) : IO (Option (LeanBundlePaths × String)) := do
  match cacheRoots with
  | [] => pure none
  | _ =>
      let fingerprint ← toolchainFingerprint toolchain
      existingToolchainBundleInAnyForFingerprint? cacheRoots home toolchain fingerprint

def ensureToolchainBundleInForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (LeanBundlePaths × String) := do
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  let workspace := bundleWorkspaceFor bundleDir
  let some platformRoot := bundleDir.parent
    | throw <| IO.userError s!"bundle directory has no platform root: {bundleDir}"
  withLock (bundleBuildLockPath platformRoot bundleId) do
    unless ← bundleReady bundleDir toolchain srcHash fingerprint do
      buildToolchainBundle home toolchain srcHash fingerprint cacheRoot bundleDir workspace
  let sharedLibraries := (← bundleSharedRuntimePaths bundleDir).map (fun path => workspace / ".lake/build" / System.FilePath.mk path)
  pure ({ leanBundlePathsFor workspace with sharedLibraries }, bundleId)

def ensureToolchainBundleIn (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (LeanBundlePaths × String) := do
  ensureAcceptedLeanToolchain home toolchain
  let fingerprint ← toolchainFingerprint toolchain
  ensureToolchainBundleInForFingerprint cacheRoot home toolchain fingerprint

def predictedToolchainBundleForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (LeanBundlePaths × String) := do
  let (bundleDir, bundleId, _) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  pure (leanBundlePathsFor (bundleWorkspaceFor bundleDir), bundleId)

def predictedToolchainBundle (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (LeanBundlePaths × String) := do
  let fingerprint ← toolchainFingerprint toolchain
  predictedToolchainBundleForFingerprint cacheRoot home toolchain fingerprint

end Beam.Cli
