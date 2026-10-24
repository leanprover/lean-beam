/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Install.Construction
import Beam.Cli.Installation

open Beam Beam.Cli Beam.Installation

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

private def admitsControl (installation : Installation) (owner daemon : System.FilePath) : IO Bool := do
  let entry : Beam.Daemon.SessionDescriptor := {
    schemaVersion := Beam.Daemon.registrySchemaVersion
    lifecycle := .live, daemonId := "fixture", capability := "fixture"
    pid := 1, ownerPid := 1, port := 1
    workspace := {
      workspaceId := "fixture", root := owner.toString
      leanCmd := "unused", plugin := "unused", toolchain := "fixture", bundleId := "fixture"
    }
    configHash := "fixture", daemonBin := daemon.toString
    installationRoot := owner.toString, startedAt := "fixture"
  }
  match ← (installation.runtime.control .stop owner (owner / ".beam") entry).run with
  | .ok () => pure true
  | .error failure =>
      require (failure.failure.error.code == "sessionInstallationMismatch")
        "ownership admission must preserve the typed installation mismatch"
      pure false

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
  Beam.Install.Construction.finalize root none {
    frontends := { cli, mcp, compilerRevision := Lean.githash }
    license := "LICENSE", targets
  }

private def checkShadowedAlias (directory : System.FilePath) (phase : String) : IO Unit := do
  let suffix := if System.Platform.isWindows then ".exe" else ""
  let home := directory / s!"shadowed-alias-{phase}"
  discard <| stage directory home
  let installation ← Beam.Installation.openExecutable (home / ("libexec/beam-cli" ++ suffix)) .cli false
  let project := directory / "project"
  IO.FS.writeFile (project / "lean-toolchain") "leanprover/lean4:v4.33.1\n"
  match phase, ← installation.lookup project with
  | "absent", .ok reference | "removed", .ok reference =>
      let exact ← Beam.resolveExistingPath (directory / "sdk-0/bin" / ("lean" ++ suffix))
      require (Beam.sameCanonicalPath exact reference.description.command)
        "removing the alias did not restore the exact installed release"
  | "healthy", .error (.unavailable command) =>
      let foreign ← Beam.resolveExistingPath (directory / "foreign/bin" / ("lean" ++ suffix))
      require (Beam.sameCanonicalPath command foreign) "healthy alias did not shadow the exact release"
  | "missing-compiler", .error (.selection (.io _))
    | "nonfile-compiler", .error (.selection (.io _))
    | "dangling", .error (.selection (.io _)) => pure ()
  | "observation-error", .error (.selection (.io error)) =>
      match error with
      | .userError _ => throw <| IO.userError "alias observation error lost its typed I/O failure"
      | _ => pure ()
  | _, .ok _ => throw <| IO.userError s!"shadowing alias {phase} admitted the exact installed release"
  | _, .error error => throw <| IO.userError s!"unexpected shadowing alias {phase} failure: {error.message}"
  IO.println s!"shadowing alias transition passed: {phase}"

private def runFullFixture (directory : System.FilePath) : IO Unit := do
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
  let installation ← Beam.Installation.openExecutable (g / ("libexec/beam-cli" ++ suffix)) .cli false
  let other ← Beam.Installation.openExecutable (h / ("libexec/beam-cli" ++ suffix)) .cli false
  let selector := fun text => IO.FS.writeFile (project / "lean-toolchain") (text ++ "\n")
  let selectors := ["absent", "valid-link", "dangling-link", "unreadable"] ++
    if System.Platform.isWindows then [] else ["fifo", "fifo-link"]
  for name in selectors do
    let selected ← Beam.Installation.LocalTarget.resolve (directory / "selectors" / name)
      (some (directory / "elan"))
    match name, selected with
    | "absent", .ok none => pure ()
    | "valid-link", .ok (some command) =>
        require (command.toString == first.lean) "selector symlink chose the wrong target"
    | "dangling-link", .error (.io _) | "unreadable", .error (.io _)
      | "fifo", .error (.io _) | "fifo-link", .error (.io _) => pure ()
    | _, _ => throw <| IO.userError s!"selector absence/error distinction failed: {name}"

  require (← Beam.pathIsLink (directory / "elan/toolchains/fixture-alias"))
    "real Elan link was not recognized"
  let nulPath := System.FilePath.mk <|
    (directory / "elan/toolchains/fixture-alias").toString ++ String.singleton (Char.ofNat 0)
  let nulRejected ← try Beam.pathIsLink nulPath *> pure false catch _ => pure true
  require nulRejected "link inspection accepted an embedded NUL"
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
  let daemon ← Beam.Installation.openExecutable (g / first.daemon) .daemon false
  require (← admitsControl installation g (g / first.daemon))
    "standalone cleanup rejected its owning daemon"
  for foreign in [h, g / "independent-H", g / "runtimes/0"] do
    require (!(← admitsControl installation foreign (foreign / "bin/beam-daemon")))
      "standalone cleanup admitted an independent installation"
  rejected daemon project
  selector "fixture-alias"
  discard <| accepted daemon project
  let impostor ← Beam.Installation.openExecutable (g / first.daemon) .cli false
  rejected impostor project

  -- Bundled cleanup has the same exact-root rule without requiring provenance or a plugin.
  let native := directory / "bundled-G"
  let cli := "bin/lean-beam" ++ suffix
  let nativeDaemon := "bin/beam-daemon" ++ suffix
  write native cli "fixture frontend"
  let bundled ← Beam.Installation.openExecutable (native / cli) .cli true
  require (← admitsControl bundled native (native / nativeDaemon))
    "bundled cleanup required unavailable runtime metadata or artifacts"
  for foreign in [directory / "bundled-H", native / "independent-H", native / "runtimes/0"] do
    require (!(← admitsControl bundled foreign (foreign / nativeDaemon)))
      "bundled cleanup admitted an independent installation"

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

def main (args : List String) : IO Unit := do
  match args with
  | [directory] => runFullFixture directory
  | [directory, "shadowed-alias", phase] =>
      checkShadowedAlias (← Beam.resolveExistingPath directory) phase
  | _ => throw <| IO.userError "expected owned fixture directory and optional shadowing-alias phase"
