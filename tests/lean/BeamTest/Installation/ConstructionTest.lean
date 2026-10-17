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

def main (args : List String) : IO Unit := do
  for path in ["bin/CON.exe", "bin/Lpt¹.dll", "bin/helper.", "bin/helper ", "bin/plug?in"] do
    require (!relativePath path) s!"nonportable inventory path was accepted: {path}"
  let [directory] := args | throw <| IO.userError "expected owned fixture directory"
  let directory := System.FilePath.mk directory
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
