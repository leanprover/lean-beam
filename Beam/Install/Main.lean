/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Install.Agy
import Beam.Install.ClientConfig
import Beam.Install.Construction
import Beam.Installation.StandaloneLayout

/-- Maintainer/installer construction tool. Deliberately absent from the installed artifact set. -/
def main (args : List String) : IO Unit := do
  match args with
  | "construct" :: source :: frontendSdk :: root :: commit :: toolchains =>
      let manifest ← Beam.Install.Construction.construct source frontendSdk root
        (if commit == "-" then none else some commit) toolchains
      IO.println manifest.payloadHash
  | ["verify", root] =>
      discard <| Beam.Install.Construction.verify root
  | ["verify-installed", root] =>
      Beam.Installation.validateInstalledRuntimeForReuse root
      discard <| Beam.Install.Construction.verify root
  | ["layout"] => IO.println (Lean.toJson Beam.Installation.standaloneLayout).compress
  | "agy-mcp" :: args => Beam.Install.Agy.run args
  | ["codex-mcp", path, snapshot] => Beam.Install.ClientConfig.codexParallelTools path snapshot
  | ["vibe-mcp", path, snapshot, command, "--toolset", toolset] =>
      Beam.Install.ClientConfig.vibeRegistration path snapshot command toolset false
  | ["vibe-mcp", path, snapshot, command, "--toolset", toolset, "--preview"] =>
      Beam.Install.ClientConfig.vibeRegistration path snapshot command toolset true
  | ["claude-mcp", path] => Beam.Install.ClientConfig.claudeUserRegistration path
  | _ => throw <| IO.userError "usage: beam-install-runtime construct SOURCE FRONTEND-SDK STAGING SOURCE-COMMIT|- TARGET... | verify ROOT | verify-installed ROOT | layout | agy-mcp ... | codex-mcp CONFIG SNAPSHOT | vibe-mcp CONFIG SNAPSHOT|- COMMAND --toolset full|core [--preview] | claude-mcp CONFIG"
