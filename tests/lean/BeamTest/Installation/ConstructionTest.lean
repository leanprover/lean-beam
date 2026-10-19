/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallConstruction

open Beam.Cli Beam.Installation

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def rejected (label : String) (action : IO α) : IO Unit := do
  let failed ← try action *> pure false catch _ => pure true
  require failed s!"{label} unexpectedly succeeded"

private def write (root : System.FilePath) (path text : String) : IO Unit := do
  let destination := root / path
  if let some parent := destination.parent then IO.FS.createDirAll parent
  IO.FS.writeFile destination text

private def stage (root : System.FilePath) : IO Unit := do
  for path in ["libexec/beam-cli", "libexec/lean-beam-mcp", "LICENSE",
      "runtimes/0/daemon", "runtimes/0/plugin", "runtimes/1/daemon", "runtimes/1/plugin"] do
    write root path s!"fixture bytes for {path}"
  IO.FS.writeBinFile (root / "payload.bin") ⟨#[0, 10, 13, 10, 26, 128, 255]⟩

private def checkGenerationDigest : IO Unit := do
  let fixture ← IO.ofExcept <| Lean.Json.parse (← IO.FS.readFile "tests/fixtures/installation-digests.json")
  let fixture ← IO.ofExcept <| fixture.getObjVal? "standalone"
  let manifest ← IO.ofExcept <| fixture.getObjValAs? InstallManifest "record"
  let expected ← IO.ofExcept <| fixture.getObjValAs? String "sha256"
  require ((← InstallConstruction.generation manifest) == expected)
    "standalone installation digest encoding changed"
  require ((← InstallConstruction.generation { manifest with payloadHash := "ignored" }) == expected)
    "standalone installation digest did not blank its own field"
  for changed in #[
      { manifest with schemaVersion := manifest.schemaVersion + 1 },
      { manifest with sourceCommit := some "different source" },
      { manifest with components := { manifest.components with license := "OTHER-LICENSE" } },
      { manifest with artifacts := manifest.artifacts.modify 0 (fun a => { a with hash := "changed" }) },
      { manifest with artifacts := manifest.artifacts.reverse }] do
    require ((← InstallConstruction.generation changed) != expected)
      "standalone installation digest omitted record data or inventory order"

private def checkConstructionCache (directory : System.FilePath) : IO Unit := do
  let hashes ← ConstructionHash.select
  let cache := directory / "construction-cache"
  let workspace := bundleWorkspaceFor cache
  let paths := leanBundlePathsFor workspace
  let libDirectory := if System.Platform.isWindows then "bin" else "lib/lean"
  let libraries := #[libDirectory ++ "/fixture-a.lib", libDirectory ++ "/fixture-b.lib"]
  let outputs := #[paths.daemon, paths.plugin] ++ libraries.map (fun path => workspace / ".lake/build" / System.FilePath.mk path)
  for output in outputs do
    IO.FS.createDirAll (output.parent.getD ".")
    IO.FS.writeFile output "qualified fixture bytes"
  let fingerprint : ToolchainFingerprint := {
    leanVersion := "fixture Lean", lakeVersion := "fixture Lake"
    leanPrefix := directory.toString, leanLibDir := directory.toString
    compilerRevision := String.ofList (List.replicate 40 'a')
  }
  match ← readVerifiedTarget hashes (directory / "absent-cache") "fixture" "source" fingerprint with
  | .ok none => pure ()
  | _ => throw <| IO.userError "absent cache was not preserved as a cache miss"
  let artifacts ← snapshotBundleArtifacts hashes workspace libraries
  let qualifiedPlugin ← IO.FS.readBinFile paths.plugin
  IO.FS.writeFile paths.plugin "changed during qualification"
  rejected "qualification changed output bytes" <|
    discard <| writeBundleMetadata hashes cache "fixture" "source" fingerprint workspace libraries artifacts
  require (!(← (bundleMetadataPath cache).pathExists))
    "changed qualification published a ready cache record"
  IO.FS.writeBinFile paths.plugin qualifiedPlugin
  let fresh ← writeBundleMetadata hashes cache "fixture" "source" fingerprint workspace libraries artifacts
  let record ← IO.FS.readBinFile (bundleMetadataPath cache)
  let .ok (some admitted) ← readVerifiedTarget hashes cache "fixture" "source" fingerprint
    | throw <| IO.userError "qualified cache fixture was rejected"
  for output in outputs do
    let bytes ← IO.FS.readBinFile output
    IO.FS.writeFile output "substituted output from another build"
    require ((← readVerifiedTarget hashes cache "fixture" "source" fingerprint).toOption.isNone)
      "changed cache produced a verified construction reference"
    rejected "change after cache admission" <| admitted.copyFile output (directory / "staged-cache-output")
    rejected "change after fresh publication" <| fresh.copyFile output (directory / "staged-fresh-output")
    require ((← IO.FS.readBinFile (bundleMetadataPath cache)) == record)
      "cache verification rewrote the qualified record"
    IO.FS.writeBinFile output bytes
    require ((← readVerifiedTarget hashes cache "fixture" "source" fingerprint).toOption.any Option.isSome)
      "restoring qualified bytes did not restore cache admission"

private def checkCacheReadFailures (directory : System.FilePath) : IO Unit := do
  let hashes ← ConstructionHash.select
  let fingerprint : ToolchainFingerprint := {
    leanVersion := "fixture Lean", lakeVersion := "fixture Lake"
    leanPrefix := directory.toString, leanLibDir := directory.toString
    compilerRevision := String.ofList (List.replicate 40 'a')
  }
  for path in [directory / "absent-parents/a/b/cache", directory / "cache-cases/linked-parent/cache"] do
    match ← readVerifiedTarget hashes path "fixture" "source" fingerprint with
    | .ok none => pure ()
    | _ => throw <| IO.userError s!"genuinely absent cache ancestors were not a miss: {path}"
  let names := ["malformed", "directory", "dangling-metadata", "dangling-parent/cache", "unreadable", "blocked-parent/cache",
    "source-mismatch", "compiler-mismatch"] ++ if System.Platform.isWindows then [] else ["fifo"]
  for name in names do
    let result ← readVerifiedTarget hashes (directory / "cache-cases" / name) "fixture" "source" fingerprint
    match result with
    | .error (.io _) => pure ()
    | .error (.invalid detail) =>
        require (name != "unreadable" && name != "blocked-parent/cache")
          s!"cache I/O failure lost its category: {name}"
        if name == "source-mismatch" then require (detail.contains "sourceHash mismatch") "source input mismatch lost"
        if name == "compiler-mismatch" then require (detail.contains "fingerprint mismatch") "compiler input mismatch lost"
    | .ok _ => throw <| IO.userError s!"unusable cache became a miss or verified result: {name}"
  IO.println "cache absence, filesystem failure, and input mismatch classifications passed"

def main (args : List String) : IO Unit := do
  if let ["nonstandard-target", sdk, source, cache, staging] := args then
    let fingerprint ← fingerprintLeanInstallation sdk
    require ((← IO.FS.realPath fingerprint.leanLibDir) !=
      (← IO.FS.realPath (System.FilePath.mk fingerprint.leanPrefix / "lib/lean")))
      "nonstandard fixture selected a standard library layout"
    let hashes ← ConstructionHash.select
    let inputs ← captureConstructionInputs source
    let bundle ← obtainVerifiedTarget hashes inputs cache source "nonstandard-fixture" fingerprint
    let paths := bundle.paths
    for path in #[paths.daemon, paths.plugin] ++ paths.sharedLibraries do
      let some name := path.fileName | throw <| IO.userError "construction output has no name"
      bundle.copyFile path (System.FilePath.mk staging / name)
    IO.println (Lean.toJson fingerprint).compress
    return
  if let ["lake-environment", sdk, workspace] := args then
    let fingerprint ← fingerprintLeanInstallation sdk
    discard <| buildSharedRuntimePaths (System.FilePath.mk workspace / "cache") workspace fingerprint
    return
  if let ["cache-errors", directory] := args then
    checkCacheReadFailures directory
    return
  for path in ["bin/CON.exe", "bin/Lpt¹.dll", "bin/helper.", "bin/helper ", "bin/plug?in"] do
    require (!relativePath path) s!"nonportable inventory path was accepted: {path}"
  let [directory] := args | throw <| IO.userError "expected owned fixture directory"
  let directory := System.FilePath.mk directory
  checkGenerationDigest
  checkConstructionCache directory
  -- Library fixture data, not an alternate composition mode in a shipped executable.
  let mut targets : Array Beam.Installation.Target := #[]
  for i in [:2] do
    let relative := s!"sdk-{i}/bin/lean"
    write directory relative "not executable; construction finalization must not invoke it"
    targets := targets.push {
      lean := (← Beam.resolveExistingPath (directory / relative)).toString
      daemon := s!"runtimes/{i}/daemon", plugin := s!"runtimes/{i}/plugin"
      toolchain := s!"fixture-{i}", compilerRevision := String.ofList (List.replicate 40 'a')
      leanVersion := "fixture Lean", lakeVersion := "fixture Lake"
    }
  let members : Components := {
    frontends := {
      cli := "libexec/beam-cli"
      mcp := "libexec/lean-beam-mcp"
      compilerRevision := String.ofList (List.replicate 40 'a')
    }
    license := "LICENSE", targets
  }
  let first :: _ := targets.toList | throw <| IO.userError "fixture has no first target"
  let one := directory / "one-target"
  let two := directory / "two-targets"
  stage one
  stage two
  let oneManifest ← InstallConstruction.finalize one (some "source")
    { members with targets := targets.extract 0 1 }
  let twoManifest ← InstallConstruction.finalize two (some "source") members
  require (oneManifest.payloadHash != twoManifest.payloadHash)
    "target membership must participate in the generation even when every file is identical"
  require ((← InstallConstruction.generation { oneManifest with sourceCommit := some "other-source" }) !=
    oneManifest.payloadHash) "provenance changes must create another generation"
  require (oneManifest.components.targets.size == 1)
    "an unreferenced plugin file must not add support for another target"
  discard <| InstallConstruction.verify one
  discard <| InstallConstruction.verify two
  let prior ← IO.FS.readBinFile (two / "manifest.json")
  rejected "manifest rewrite" <| InstallConstruction.finalize two (some "other-source") members
  require ((← IO.FS.readBinFile (two / "manifest.json")) == prior)
    "rejected construction changed a published record"

  let relocated := directory / "relocated installation with spaces"
  IO.FS.rename two relocated
  let relocatedManifest ← InstallConstruction.verify relocated
  require (relocatedManifest.payloadHash == twoManifest.payloadHash)
    "relocation changed the installation generation"
  write relocated "runtimes/0/plugin" "changed bytes"
  rejected "modified artifact" <| InstallConstruction.verify relocated
  require ((← IO.FS.readBinFile (relocated / "manifest.json")) == prior)
    "failed artifact verification rewrote metadata"

  let invalids : Array (String × Components) := #[
    ("empty", { members with targets := #[] }),
    ("duplicate", { members with targets := #[first, first] }),
    ("foreign", { members with frontends := { members.frontends with cli := "/foreign/beam-cli" } }),
    ("missing", { members with frontends := { members.frontends with mcp := "libexec/not-installed" } }),
    ("shared", { members with frontends := { members.frontends with mcp := members.frontends.cli } })
  ]
  for (name, components) in invalids do
    let root := directory / name
    stage root
    rejected name <| InstallConstruction.finalize root none components
    require (!(← (root / "manifest.json").pathExists)) s!"{name} published an invalid set"
  let missing := directory / "missing-target-artifact"
  stage missing
  IO.FS.removeFile (missing / "runtimes/1/daemon")
  rejected "incomplete second target" <| InstallConstruction.finalize missing none members
  require (!(← (missing / "manifest.json").pathExists)) "incomplete target was published"
  let linked := directory / "linked-inventory"
  stage linked
  rejected "linked inventory" <| InstallConstruction.finalize linked none members
  require (!(← (linked / "manifest.json").pathExists)) "linked inventory was published"
  unless System.Platform.isWindows do
    let nonportable := directory / "nonportable-inventory"
    stage nonportable
    write nonportable "literal\\backslash" "not a directory separator on POSIX"
    rejected "literal backslash filename" <| InstallConstruction.finalize nonportable none members
    require (!(← (nonportable / "manifest.json").pathExists)) "nonportable inventory was published"
  IO.println "construction membership, generation, immutability, artifact validation, and relocation passed"
