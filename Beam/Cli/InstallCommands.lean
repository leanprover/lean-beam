/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallLayout
import Beam.Cli.RuntimeBundle
import Beam.Cli.Output

open Lean

namespace Beam.Cli

def printValidatedToolchains (home : System.FilePath) : IO Unit := do
  let (_, toolchains) ← validatedLeanToolchains home
  for toolchain in toolchains do
    IO.println toolchain

def printCompatibleReleaseLines (home : System.FilePath) : IO Unit := do
  let (_, lines) ← compatibleLeanReleaseLines home
  for line in lines do
    IO.println line.registryEntry

def printInstallLayout : IO Unit := do
  printJsonLine (toJson installLayout)

private def sourceCommitArg? (sourceCommitArg : String) : Option String :=
  if sourceCommitArg == "-" then none else some sourceCommitArg

def printInstallManifest (payloadHash : String) (sourceCommitArg : String)
    (createdWithToolchains : List String) : IO Unit := do
  if createdWithToolchains.isEmpty then
    throw <| IO.userError
      "usage: beam-cli install-manifest <payload-hash> <source-commit|-> <creation-toolchain...>"
  printJsonLine (installManifestJson payloadHash (sourceCommitArg? sourceCommitArg)
    createdWithToolchains)

def printInstallManifestWithSourceCommit
    (manifestPath : System.FilePath)
    (sourceCommitArg : String) : IO Unit := do
  let manifest ← readInstallManifest manifestPath
  unless manifest.schemaVersion == installManifestSchemaVersion do
    throw <| IO.userError
      s!"cannot refresh source commit in install manifest schemaVersion {manifest.schemaVersion}"
  printJsonLine <| toJson { manifest with sourceCommit := sourceCommitArg? sourceCommitArg }

end Beam.Cli
