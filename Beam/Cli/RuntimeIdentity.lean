/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Version
import Beam.Cli.InstallLayout
import Beam.Cli.Toolchain
import Beam.Git
import Beam.Path

open Lean
open Beam.Version

namespace Beam.Cli.RuntimeIdentity

private def installedRuntimeCurrent
    (home : System.FilePath) (location : Beam.Cli.InstalledRuntimeLocation) : IO Bool := do
  let current := location.installRoot / "current"
  unless ← current.pathExists do
    return false
  Beam.sameFilePath current home

/-- Populate installation metadata without changing the caller's process identity. -/
def managed (base : Identity) (home? : Option System.FilePath) : IO Identity := do
  let runtimeResolution? ←
    match home? with
    | some home => pure <| some (← Beam.Cli.resolveRuntimeHome home)
    | none => pure none
  let installedRuntime? :=
    match runtimeResolution? with
    | some (.installed runtime) => some runtime
    | _ => none
  let invalidRuntime? :=
    match runtimeResolution? with
    | some (.invalidInstalled runtime) => some runtime
    | _ => none
  let sourceHome? :=
    match runtimeResolution? with
    | some (.source home) => some home
    | _ => none
  let manifest? := installedRuntime?.map (·.manifestPath)
    |>.orElse (fun _ => invalidRuntime?.bind (·.manifestPath?))
  let manifestCommit? := installedRuntime?.bind (fun runtime => runtime.manifest.sourceCommit)
  let sourceCommit? ←
    match manifestCommit?, sourceHome? with
    | some commit, _ => pure (some commit)
    | none, some home => Beam.Git.fullCommitAt? home
    | none, none => pure none
  let sourceBranch? ←
    match sourceHome? with
    | some home => Beam.Git.branchAt? home
    | none => pure none
  let sourceDirty? ←
    match sourceHome? with
    | some home => Beam.Git.dirtyAt? home
    | none => pure none
  let runtimeCurrent? ←
    match installedRuntime?, invalidRuntime? with
    | some runtime, _ =>
        pure <| some (← installedRuntimeCurrent runtime.home runtime.location)
    | none, some runtime =>
        pure <| some (← installedRuntimeCurrent runtime.home runtime.location)
    | none, none => pure none
  let runtimePayload? :=
    installedRuntime?.map (·.location.payload)
      |>.orElse (fun _ => invalidRuntime?.map (·.location.payload))
  let runtimeError? :=
    invalidRuntime?.map Beam.Cli.describeInstalledRuntimeError
  pure { base with
    beamHome? := home?.map (·.toString)
    runtimePayload?
    manifest? := manifest?.map (·.toString)
    sourceCommit?
    sourceBranch?
    sourceDirty?
    runtimeCurrent?
    runtimeError?
  }

/-- Render a previously observed SDK identity without further filesystem reads. -/
def bundled (base : Identity) (p : Toolchain.Provenance) : Identity := {
  base with
  name := if base.name == "beam-cli" then cliName else base.name
  runtimePayload? := some p.payloadHash
  sourceCommit? := some p.sourceCommit
  bundledLean? := some p.leanVersion
}

end Beam.Cli.RuntimeIdentity
