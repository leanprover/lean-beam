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

def read
    (name : String)
    (home? : Option System.FilePath := none)
    (wrapper? : Option String := none)
    (beamCli? : Option String := none)
    (serverBinary? : Option String := none)
    (mcpProtocol? : Option String := none)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none) : IO Identity := do
  if Beam.Cli.Toolchain.enabled then
    let p ← Beam.Cli.Toolchain.provenance
    return {
      name := if name == "beam-cli" then cliName else name
      wrapper? := wrapper?
      beamHome? := home?.map (·.toString)
      beamCli? := beamCli?
      serverBinary? := serverBinary?
      mcpProtocol? := mcpProtocol?
      activeRoot? := activeRoot?.map (·.toString)
      runtimeActive?
      runtimePayload? := some p.payloadHash
      sourceCommit? := some p.sourceCommit
      bundledLean? := some p.leanVersion
    }
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
  pure {
    name
    mcpProtocol?
    wrapper?
    beamHome? := home?.map (·.toString)
    beamCli?
    serverBinary?
    runtimePayload?
    manifest? := manifest?.map (·.toString)
    sourceCommit?
    sourceBranch?
    sourceDirty?
    activeRoot? := activeRoot?.map (·.toString)
    runtimeActive?
    runtimeCurrent?
    runtimeError?
  }

def mcpServerIdentity
    (home? : Option System.FilePath)
    (beamCli? : Option String)
    (serverBinary? : Option String)
    (activeRoot? : Option System.FilePath := none)
    (runtimeActive? : Option Bool := none)
    (wrapper? : Option String := none) : IO Identity :=
  read
    mcpServerName
    home?
    (wrapper? := wrapper?)
    (beamCli? := beamCli?)
    (serverBinary? := serverBinary?)
    (mcpProtocol? := some mcpProtocolVersion)
    (activeRoot? := activeRoot?)
    (runtimeActive? := runtimeActive?)

end Beam.Cli.RuntimeIdentity
