/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallConstruction

/-- Maintainer/installer construction tool. Deliberately absent from the installed artifact set. -/
def main (args : List String) : IO Unit := do
  match args with
  | "construct" :: source :: frontendSdk :: root :: cache :: commit :: toolchains =>
      let manifest ← Beam.Cli.InstallConstruction.construct source frontendSdk root cache
        (if commit == "-" then none else some commit) toolchains
      IO.println manifest.payloadHash
  | ["verify", root] =>
      discard <| Beam.Cli.InstallConstruction.verify root
  | ["verify-installed", root] =>
      Beam.Cli.validateInstalledRuntimeForReuse root
      discard <| Beam.Cli.InstallConstruction.verify root
  | ["layout"] => IO.println (Lean.toJson Beam.Cli.installLayout).compress
  | _ => throw <| IO.userError "usage: beam-install-runtime construct SOURCE FRONTEND-SDK STAGING BUILD-CACHE SOURCE-COMMIT|- TARGET... | verify ROOT | verify-installed ROOT | layout"
