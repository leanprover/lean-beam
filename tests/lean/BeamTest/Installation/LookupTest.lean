/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallConstruction
import Beam.Cli.Installation

open Beam.Cli

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def write (root : System.FilePath) (relative text : String) : IO Unit := do
  let path := root / relative
  if let some parent := path.parent then IO.FS.createDirAll parent
  IO.FS.writeFile path text

private def accepted (installation : Installation) (project : System.FilePath) : IO Beam.Runtime.Description := do
  match ← installation.lookup project with
  | .ok reference => pure reference.description
  | .error error => throw <| IO.userError error.message

private def rejected (installation : Installation) (project : System.FilePath) : IO Unit := do
  match ← installation.lookup project with
  | .error _ => pure ()
  | .ok _ => throw <| IO.userError "unavailable or invalid installation unexpectedly admitted a runtime"

private def stage (directory root : System.FilePath) : IO InstallManifest := do
  let suffix := if System.Platform.isWindows then ".exe" else ""
  let mut targets := #[]
  for i in [:2] do
    let daemon := s!"runtimes/{i}/bin/daemon{suffix}"
    let plugin := s!"runtimes/{i}/plugin"
    write root daemon "fixture daemon must never be invoked during lookup"
    write root plugin "fixture plugin must never be loaded during lookup"
    targets := targets.push {
      lean := (← Beam.resolveExistingPath (directory / s!"sdk-{i}" / "bin" / ("lean" ++ suffix))).toString
      daemon, plugin, toolchain := s!"fixture-{i}"
      compilerRevision := Lean.githash, leanVersion := "Lean fixture", lakeVersion := "Lake fixture"
    }
  let cli := "libexec/beam-cli" ++ suffix
  let mcp := "libexec/lean-beam-mcp" ++ suffix
  for path in [cli, mcp, "LICENSE"] do write root path s!"fixed bytes for {path}"
  InstallConstruction.finalize root none {
    frontends := { cli, mcp, compilerRevision := Lean.githash }
    license := "LICENSE", targets
  }

def main (args : List String) : IO Unit := do
  let [directory] := args | throw <| IO.userError "expected owned fixture directory"
  let directory ← Beam.resolveExistingPath directory
  let suffix := if System.Platform.isWindows then ".exe" else ""
  let project := directory / "project"
  let g := directory / "installation-G"
  let h := directory / "installation-H"
  let record ← stage directory g
  let [first, secondTarget] := record.components.targets.toList
    | throw <| IO.userError "expected two fixture targets"
  let foreignRecord ← stage directory h
  require (record.payloadHash == foreignRecord.payloadHash) "fixture installations must have identical versions and bytes"
  let installation ← Installation.openExecutable (g / ("libexec/beam-cli" ++ suffix)) .cli false
  let other ← Installation.openExecutable (h / ("libexec/beam-cli" ++ suffix)) .cli false
  let selector := fun text => IO.FS.writeFile (project / "lean-toolchain") (text ++ "\n")

  require (← Beam.pathIsLink (directory / "elan/toolchains/fixture-alias"))
    "real Elan link was not recognized"
  let nulPath := System.FilePath.mk <|
    (directory / "elan/toolchains/fixture-alias").toString ++ String.singleton (Char.ofNat 0)
  require (!(← Beam.pathIsLink nulPath)) "link inspection accepted an embedded NUL"
  for ordinary in ["ordinary-local", "stable", "beta", "nightly", "lean-toolchain"] do
    require (!(← Beam.pathIsLink (directory / "elan/toolchains" / ordinary)))
      "an ordinary directory was mistaken for a local Elan link"
  selector "fixture-alias"
  let original ← accepted installation project
  require (original.command == first.lean) "local alias chose the wrong target"
  require (!original.sameRuntime (← accepted other project)) "independent installations shared a runtime identity"
  selector "../sdk-0"
  require (original.sameRuntime (← accepted installation project)) "project-relative alias changed the retained binding"
  selector "leanprover/lean4:v4.33.1"
  require (original.sameRuntime (← accepted installation project)) "exact installed descriptor changed the binding"
  selector "fixture-second"
  let second ← accepted installation project
  require (second.command == secondTarget.lean) "second target did not use its recorded runtime"
  require (!second.sameRuntime original) "different targets shared execution identity"

  -- The daemon is independently restricted to its own target, even within the same installation.
  let daemon ← Installation.openExecutable (g / first.daemon) .daemon false
  rejected daemon project
  selector "fixture-alias"
  discard <| accepted daemon project
  let impostor ← Installation.openExecutable (g / first.daemon) .cli false
  rejected impostor project

  for unavailable in ["foreign-alias", "ordinary-local", "stable", "beta", "nightly",
      "lean-toolchain", "missing-target"] do
    selector unavailable
    rejected installation project
  IO.FS.removeFile (project / "lean-toolchain")
  rejected installation project
  selector "fixture-alias"
  -- Changing a launcher pointer cannot retarget a process bound to concrete G.
  require (original.sameRuntime (← accepted installation project)) "process changed its concrete installation"
  let prior ← IO.FS.readFile (g / "manifest.json")
  let replacement := { record with sourceCommit := some "replacement" }
  IO.FS.writeFile (g / "manifest.json") ((Lean.toJson replacement).pretty ++ "\n")
  rejected installation project
  IO.FS.writeFile (g / "manifest.json") prior
  IO.FS.removeFile (g / secondTarget.plugin)
  rejected installation project
  -- A plausible target remains available in H; a broken G must never borrow it.
  discard <| accepted other project
  IO.println "exact lookup, aliases, target ownership, retained generation, and independent installation isolation passed"
