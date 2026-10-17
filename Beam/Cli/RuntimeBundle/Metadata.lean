/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Fingerprint
import Beam.Cli.RuntimeBundle.Paths
import Beam.Path
import Beam.System

open Lean

namespace Beam.Cli

def bundleMetadataSchemaVersion : Nat := 4

/-- The build reports SDK dependencies explicitly; cache admission never infers them from files. -/
def validSharedRuntimePaths (paths : Array String) : Bool := Id.run do
  if paths.isEmpty then return false
  let directory := if System.Platform.isWindows then "bin" else "lib/lean"
  let mut seen : Std.HashSet String := {}
  for path in paths do
    if !Beam.Installation.relativePath path ||
        (System.FilePath.mk path).parent != some (System.FilePath.mk directory) || seen.contains path then
      return false
    seen := seen.insert path
  return true

private structure BundleMetadata where
  schemaVersion : Nat
  toolchain : String
  toolchainFingerprint : ToolchainFingerprint
  sourceHash : String
  workspace : String
  builtAt : String
  sharedLibraries : Array String
  deriving FromJson, ToJson

private def checkBundleMetadataShape (metadata : BundleMetadata) : Except String Unit := do
  if metadata.schemaVersion != bundleMetadataSchemaVersion then
    throw s!"unsupported bundle metadata schemaVersion {metadata.schemaVersion}"
  if metadata.toolchain.isEmpty then
    throw "bundle metadata toolchain must not be empty"
  if metadata.toolchainFingerprint.leanVersion.isEmpty ||
      metadata.toolchainFingerprint.leanPrefix.isEmpty ||
      metadata.toolchainFingerprint.leanLibDir.isEmpty ||
      metadata.toolchainFingerprint.lakeVersion.isEmpty ||
      !Beam.Installation.hexDigest 40 metadata.toolchainFingerprint.compilerRevision then
    throw "bundle metadata toolchain fingerprint fields must not be empty"
  if metadata.sourceHash.isEmpty then
    throw "bundle metadata sourceHash must not be empty"
  if metadata.workspace.isEmpty then
    throw "bundle metadata workspace must not be empty"
  if metadata.builtAt.isEmpty then
    throw "bundle metadata builtAt must not be empty"
  unless validSharedRuntimePaths metadata.sharedLibraries do
    throw "bundle metadata must name complete relative shared-library inputs"

private def checkBundleMetadataMatches
    (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (metadata : BundleMetadata) : Except String Unit := do
  if metadata.toolchain != toolchain then
    throw s!"bundle metadata toolchain mismatch: expected {toolchain}, got {metadata.toolchain}"
  if metadata.toolchainFingerprint != fingerprint then
    throw "bundle metadata toolchain fingerprint mismatch"
  if metadata.sourceHash != srcHash then
    throw s!"bundle metadata sourceHash mismatch: expected {srcHash}, got {metadata.sourceHash}"

private def bundleMetadataWorkspaceMatches
    (metadata : BundleMetadata) (workspace : System.FilePath) : IO Bool :=
  Beam.sameFilePath (System.FilePath.mk metadata.workspace) workspace

private def bundleArtifactsReady (workspace : System.FilePath) (metadata : BundleMetadata) : IO Bool := do
  let paths := leanBundlePathsFor workspace
  unless (← Beam.regularNonSymlinkFile paths.daemon) &&
      (← Beam.regularNonSymlinkFile paths.plugin) do return false
  for path in metadata.sharedLibraries do
    unless ← Beam.regularNonSymlinkFile (workspace / ".lake/build" / path) do return false
  return true

def bundleMetadataPath (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "metadata.json"

private def readBundleMetadata? (bundleDir : System.FilePath) : IO (Option BundleMetadata) := do
  let path := bundleMetadataPath bundleDir
  unless ← Beam.regularNonSymlinkFile path do
    return none
  try
    let json ← IO.ofExcept <| Json.parse (← IO.FS.readFile path)
    let metadata : BundleMetadata ← IO.ofExcept <| fromJson? json
    pure (some metadata)
  catch _ =>
    pure none

def bundleMetadataJson
    (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint)
    (workspace : System.FilePath)
    (builtAt : String) (sharedLibraries : Array String) : Json :=
  toJson ({
    schemaVersion := bundleMetadataSchemaVersion
    toolchain
    toolchainFingerprint := fingerprint
    sourceHash := srcHash
    workspace := workspace.toString
    builtAt
    sharedLibraries
  } : BundleMetadata)

private def completeBundleMetadata? (bundleDir : System.FilePath) : IO (Option BundleMetadata) := do
  let workspace := bundleWorkspaceFor bundleDir
  let some metadata ← readBundleMetadata? bundleDir
    | return none
  match checkBundleMetadataShape metadata with
  | .error _ => return none
  | .ok () => pure ()
  unless ← bundleArtifactsReady workspace metadata do return none
  unless ← bundleMetadataWorkspaceMatches metadata workspace do
    return none
  pure (some metadata)

/-- Return the source hash only for a structurally complete, artifact-ready bundle. -/
def completeBundleSourceHash? (bundleDir : System.FilePath) : IO (Option String) := do
  pure <| (← completeBundleMetadata? bundleDir).map (·.sourceHash)

def bundleReady (bundleDir : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint) : IO Bool := do
  let some metadata ← completeBundleMetadata? bundleDir
    | return false
  match checkBundleMetadataMatches toolchain srcHash fingerprint metadata with
  | .ok () => pure true
  | .error _ => pure false

def writeBundleMetadata (bundleDir : System.FilePath) (toolchain srcHash : String)
    (fingerprint : ToolchainFingerprint) (workspace : System.FilePath)
    (sharedLibraries : Array String) : IO Unit := do
  let path := bundleMetadataPath bundleDir
  if let some parent := path.parent then
    IO.FS.createDirAll parent
  IO.FS.writeFile path
    ((bundleMetadataJson toolchain srcHash fingerprint workspace (← Beam.utcTimestamp) sharedLibraries).pretty ++ "\n")

/-- Construction consumes the same dependency list that qualified this cached target build. -/
def bundleSharedRuntimePaths (bundleDir : System.FilePath) : IO (Array String) := do
  let some metadata ← completeBundleMetadata? bundleDir
    | throw <| IO.userError "constructed target metadata is incomplete"
  pure metadata.sharedLibraries

end Beam.Cli
