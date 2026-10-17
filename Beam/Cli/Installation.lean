/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonConfig
import Beam.Cli.Installation.Lookup
import Beam.Project
import Beam.Cli.Usage

open Lean

namespace Beam.Cli

private def Installation.resolve (installation : Installation) (root : System.FilePath) : IO DesiredConfig := do
  unless ← Beam.Project.hasLeanProject root do
    throw <| IO.userError s!"could not resolve Lean project at {root}"
  let reference ← IO.ofExcept <| (← installation.lookup root).mapError
    (IO.userError ∘ Installation.Failure.message)
  pure { root, runtime := reference.description }

def Installation.runtime (installation : Installation) : RuntimeAccess := {
  resolve := installation.resolve
  attachment := fun root => return (← installation.resolve root).configHash
}

def Installation.cliIdentity (installation : Installation) : IO Beam.Version.Identity := do
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

def Installation.admitCommand (installation : Installation) (args : List String) :
    Except CommandRejection Unit := do
  match args.head? with
  | some "toolchain-build-info" => unless installation.bundled do throw .sdkBuildInfo
  | some "prune" => if installation.bundled then throw .standalonePrune
  | _ => pure ()

def Installation.usage (installation : Installation) : String :=
  Beam.Cli.usage <| if installation.bundled then [] else ["  lean-beam prune [--apply]"]

def compilerBuildInfo : Json := Json.mkObj [
  ("compiledLeanRevision", toJson Beam.BuildInfo.compiled.compilerRevision),
  ("loadedLeanRevision", toJson Lean.githash),
  ("sourceRevision", toJson Beam.BuildInfo.compiled.sourceRevision),
  ("buildId", toJson Beam.BuildInfo.compiled.buildId),
  ("lakeSupportsDeferredCompilation", toJson Toolchain.lakeSupportsDeferredCompilation)
]


def Installation.doctorLines (installation : Installation) (root : System.FilePath) : IO (List String) := do
  let identity ← installation.cliIdentity
  let desired ← installation.resolve root
  pure [
    "public command: lean-beam",
    s!"installation root: {installation.home}",
    s!"source commit: {identity.sourceCommit?.getD "(unrecorded)"}",
    s!"runtime payload: {identity.runtimePayload?.getD "(unavailable)"}",
    s!"project target: {desired.runtime.toolchain}",
    "target membership: present",
    s!"lean binary: {desired.runtime.command}",
    s!"bundle id: {desired.runtime.identity.generation}",
    s!"bundle daemon: {desired.runtime.daemonBin}",
    s!"plugin: {desired.runtime.plugin}"
  ]

end Beam.Cli
