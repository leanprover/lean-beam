/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonConfig
import Beam.Installation.Lookup
import Beam.Cli.Usage

open Lean

namespace Beam.Cli

/-- Control uses recorded ownership, never current runtime admission or component availability. -/
private def _root_.Beam.Installation.admitControl (installation : Installation)
    (entry : Beam.Daemon.SessionDescriptor) : IO Unit := do
  unless Beam.sameCanonicalPath (System.FilePath.mk entry.installationRoot) installation.home do
    throw <| IO.userError s!"sessionInstallationMismatch: session belongs to Beam installation {entry.installationRoot}, not {installation.home}; use lean-beam from its owning installation or interrupt the original foreground owner. The owner and descriptor were preserved."

private def installationFailure (failure : Beam.Installation.Failure) : CliFailure :=
  match failure with
  | .io error => .internal error
  | _ => .setup failure.message

private def runtimeFor (lookup : System.FilePath → IO (Except Beam.Installation.Failure Beam.Installation.RuntimeRef))
    (root : System.FilePath) : CliM Beam.Runtime.Description := do
  unless ← Beam.Project.hasLeanProject root do
    throw <| .setup s!"could not resolve Lean project at {root}"
  match ← lookup root with
  | .ok reference => pure reference.description
  | .error failure => throw <| installationFailure failure

def _root_.Beam.Installation.runtime (installation : Installation) : RuntimeAccess := {
  resolve := fun root => return { root, runtime := ← runtimeFor installation.lookup root }
  attachment := fun root => return (← runtimeFor installation.lookup root).configHash root
  control := installation.admitControl
}

def _root_.Beam.Installation.cliIdentity (installation : Installation) : IO Beam.Version.Identity := do
  installation.readIdentity {
    name := Beam.Version.cliName
    wrapper? := ← IO.getEnv "BEAM_WRAPPER_PATH"
    beamCli? := some (← IO.appPath).toString
  }

inductive CommandRejection where
  | standalonePrune
  | sdkBuildInfo

def CommandRejection.message : CommandRejection → String
  | .standalonePrune => "bundled lean-beam has no standalone installations to prune"
  | .sdkBuildInfo => "this executable was not built with -KbeamToolchain=true"

def _root_.Beam.Installation.admitCommand (installation : Installation) (args : List String) :
    Except CommandRejection Unit := do
  match args.head? with
  | some "toolchain-build-info" => unless installation.bundled do throw .sdkBuildInfo
  | some "prune" => if installation.bundled then throw .standalonePrune
  | _ => pure ()

def _root_.Beam.Installation.usage (installation : Installation) : String :=
  Beam.Cli.usage <| if installation.bundled then [] else ["  lean-beam prune [--apply]"]

def compilerBuildInfo : Json := Json.mkObj [
  ("compiledLeanRevision", toJson Beam.BuildInfo.compiled.compilerRevision),
  ("loadedLeanRevision", toJson Lean.githash),
  ("sourceRevision", toJson Beam.BuildInfo.compiled.sourceRevision),
  ("buildId", toJson Beam.BuildInfo.compiled.buildId),
  ("lakeSupportsDeferredCompilation", toJson Beam.Installation.Bundled.lakeSupportsDeferredCompilation)
]


def _root_.Beam.Installation.doctorLines (installation : Installation) (root : System.FilePath) : CliM (List String) := do
  let observation ← ExceptT.mk <| pure ((← installation.observe).mapError installationFailure)
  let identity := observation.identity { name := Beam.Version.cliName }
  let runtime ← runtimeFor observation.lookup root
  pure [
    "public command: lean-beam",
    s!"installation root: {installation.home}",
    s!"source commit: {identity.sourceCommit?.getD "(unrecorded)"}",
    s!"runtime payload: {identity.runtimePayload?.getD "(unavailable)"}",
    s!"project target: {runtime.toolchain}",
    "target membership: present",
    s!"lean binary: {runtime.command}",
    s!"bundle id: {runtime.identity.generation}",
    s!"bundle daemon: {runtime.daemonBin}",
    s!"plugin: {runtime.plugin}"
  ]

end Beam.Cli
