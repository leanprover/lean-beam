/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Install.Construction

open Beam.Install Beam.Installation

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
  require ((← Construction.generation manifest) == expected)
    "standalone installation digest encoding changed"
  require ((← Construction.generation { manifest with payloadHash := "ignored" }) == expected)
    "standalone installation digest did not blank its own field"
  for changed in #[
      { manifest with schemaVersion := manifest.schemaVersion + 1 },
      { manifest with sourceCommit := some "different source" },
      { manifest with components := { manifest.components with license := "OTHER-LICENSE" } },
      { manifest with artifacts := manifest.artifacts.modify 0 (fun a => { a with hash := "changed" }) },
      { manifest with artifacts := manifest.artifacts.reverse }] do
    require ((← Construction.generation changed) != expected)
      "standalone installation digest omitted record data or inventory order"

private def checkStageOutput (directory : System.FilePath) : IO Unit := do
  let output := directory / "build-output/plugin"
  write directory "build-output/plugin" "qualified fixture bytes"
  let staged := directory / "staged/runtimes/0/plugin"
  Construction.stageOutput output staged
  require ((← IO.FS.readBinFile staged) == (← IO.FS.readBinFile output))
    "staged output differs from its build output"
  rejected "missing build output" <| Construction.stageOutput (directory / "build-output/absent") staged
  rejected "directory build output" <| Construction.stageOutput (directory / "build-output") staged
  unless System.Platform.isWindows do
    -- The harness links `build-output/linked-plugin` to `plugin`.
    rejected "linked build output" <| Construction.stageOutput (directory / "build-output/linked-plugin") staged
  rejected "undeclared shared libraries" <| Construction.stageSharedLibraries #[] (directory / "staged") "bin"
  for paths in [#[], #["lib/lean/../escape.so"], #["lib/lean/a.so", "lib/lean/a.so"], #["other/a.so"]] do
    require (!validSharedRuntimePaths paths) s!"invalid shared-runtime inputs were accepted: {paths}"

private def checkCanonicalVersions : IO Unit := do
  for (toolchain, version) in [("leanprover/lean4:v4.34.0", "4.34.0"),
      ("leanprover/lean4:v4.34.0-rc2", "4.34.0-rc2"), ("leanprover/lean4:v4.34.2", "4.34.2")] do
    require (Beam.Installation.ToolchainPolicy.canonicalLeanVersion? toolchain == some version) s!"canonical selector was not parsed: {toolchain}"
  for invalid in ["leanprover/lean4:v4.34", "leanprover/lean4:v4.34.0-rc0",
      "leanprover/lean4:v4.34.0-rc01", "leanprover/lean4:v04.34.0", "leanprover/lean4:v4.34.0-beta1",
      "leanprover/lean4-nightly:nightly-2026-08-01", "lean4-stage0"] do
    require (Beam.Installation.ToolchainPolicy.canonicalLeanVersion? invalid).isNone s!"noncanonical selector was accepted: {invalid}"
  require (expectedCanonicalLeanVersionPrefix? "leanprover/lean4:v4.34.0-rc2" ==
    some "Lean (version 4.34.0-rc2,") "canonical Lean version prefix should use the exact RC"

/-- Discarding a build directory removes toolchain links without deleting what they point to.
The harness creates `discarded-build/lake-home/.lake/build/lib/lean/Init`, a POSIX link to
`toolchain/lib/lean/Init`. -/
private def checkBuildDirectoryDiscard (directory : System.FilePath) : IO Unit := do
  if System.Platform.isWindows then return
  let toolchainFile := directory / "toolchain/lib/lean/Init/Prelude.olean"
  let buildDir := directory / "discarded-build"
  require (← Beam.pathIsLink (buildDir / "lake-home/.lake/build/lib/lean/Init"))
    "missing toolchain link fixture"
  Construction.discardBuildDirectory buildDir
  require (!(← buildDir.pathExists)) "discarded build directory still exists"
  require ((← IO.FS.readFile toolchainFile) == "toolchain bytes")
    "discarding a build directory deleted the linked toolchain library"

/-- An existing `.construction` entry is refused before any build work and left untouched.
The harness creates `existing-construction-{dir,file,link}/.construction`; the link points at
`existing-construction-target`. -/
private def checkExistingConstructionRefused (directory : System.FilePath) : IO Unit := do
  let kinds := ["dir", "file"] ++ if System.Platform.isWindows then [] else ["link"]
  for kind in kinds do
    let root := directory / s!"existing-construction-{kind}"
    let sentinel := if kind == "file" then root / ".construction"
      else if kind == "dir" then root / ".construction/sentinel"
      else directory / "existing-construction-target/sentinel"
    let before ← IO.FS.readBinFile sentinel
    let refused ← try
      discard <| Construction.construct directory (directory / "no-sdk") root none ["fixture"]
      pure none
    catch error => pure (some (toString error))
    let some message := refused | throw <| IO.userError s!"construction reused an existing {kind}"
    require (message.contains "refusing to reuse an existing construction directory")
      s!"existing {kind} was refused for the wrong reason: {message}"
    require ((← IO.FS.readBinFile sentinel) == before) s!"construction modified an existing {kind}"
    require (!(← (root / "manifest.json").pathExists)) s!"construction published over an existing {kind}"

def main (args : List String) : IO Unit := do
  if let ["stage-output", source, destination] := args then
    Construction.stageOutput source destination
    return
  if let ["nonstandard-target", sdk, source, buildDir, staging] := args then
    let fingerprint ← fingerprintLeanInstallation sdk
    require ((← IO.FS.realPath fingerprint.leanLibDir) !=
      (← IO.FS.realPath (System.FilePath.mk fingerprint.leanPrefix / "lib/lean")))
      "nonstandard fixture selected a standard library layout"
    -- The production per-target path: build, stage the outputs, then qualify the staged plugin.
    let built ← buildTarget source "nonstandard-fixture" fingerprint buildDir
    let staging := System.FilePath.mk staging
    for path in #[built.daemon, built.plugin] ++ built.sharedLibraries do
      let some name := path.fileName | throw <| IO.userError "construction output has no name"
      Construction.stageOutput path (staging / name)
    built.qualify (staging / built.plugin.fileName.get!)
    IO.println (Lean.toJson fingerprint).compress
    return
  if let ["discard-build", buildDir] := args then
    Construction.discardBuildDirectory buildDir
    return
  if let ["lake-environment", sdk, workspace] := args then
    let fingerprint ← fingerprintLeanInstallation sdk
    discard <| buildSharedRuntimePaths (System.FilePath.mk workspace / "construction") workspace fingerprint
    return
  for path in ["bin/CON.exe", "bin/Lpt¹.dll", "bin/helper.", "bin/helper ", "bin/plug?in"] do
    require (!relativePath path) s!"nonportable inventory path was accepted: {path}"
  let [directory] := args | throw <| IO.userError "expected owned fixture directory"
  let directory := System.FilePath.mk directory
  checkGenerationDigest
  checkStageOutput directory
  checkExistingConstructionRefused directory
  checkCanonicalVersions
  checkBuildDirectoryDiscard directory
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
  let oneManifest ← Construction.finalize one (some "source")
    { members with targets := targets.extract 0 1 }
  let twoManifest ← Construction.finalize two (some "source") members
  require (oneManifest.payloadHash != twoManifest.payloadHash)
    "target membership must participate in the generation even when every file is identical"
  require ((← Construction.generation { oneManifest with sourceCommit := some "other-source" }) !=
    oneManifest.payloadHash) "provenance changes must create another generation"
  require (oneManifest.components.targets.size == 1)
    "an unreferenced plugin file must not add support for another target"
  discard <| Construction.verify one
  discard <| Construction.verify two
  let prior ← IO.FS.readBinFile (two / "manifest.json")
  rejected "manifest rewrite" <| Construction.finalize two (some "other-source") members
  require ((← IO.FS.readBinFile (two / "manifest.json")) == prior)
    "rejected construction changed a published record"

  let relocated := directory / "relocated installation with spaces"
  IO.FS.rename two relocated
  let relocatedManifest ← Construction.verify relocated
  require (relocatedManifest.payloadHash == twoManifest.payloadHash)
    "relocation changed the installation generation"
  write relocated "runtimes/0/plugin" "changed bytes"
  rejected "modified artifact" <| Construction.verify relocated
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
    rejected name <| Construction.finalize root none components
    require (!(← (root / "manifest.json").pathExists)) s!"{name} published an invalid set"
  let missing := directory / "missing-target-artifact"
  stage missing
  IO.FS.removeFile (missing / "runtimes/1/daemon")
  rejected "incomplete second target" <| Construction.finalize missing none members
  require (!(← (missing / "manifest.json").pathExists)) "incomplete target was published"
  let linked := directory / "linked-inventory"
  stage linked
  rejected "linked inventory" <| Construction.finalize linked none members
  require (!(← (linked / "manifest.json").pathExists)) "linked inventory was published"
  unless System.Platform.isWindows do
    let nonportable := directory / "nonportable-inventory"
    stage nonportable
    write nonportable "literal\\backslash" "not a directory separator on POSIX"
    rejected "literal backslash filename" <| Construction.finalize nonportable none members
    require (!(← (nonportable / "manifest.json").pathExists)) "nonportable inventory was published"
  IO.println "construction membership, generation, immutability, artifact validation, and relocation passed"
