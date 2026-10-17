/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Hash
import Beam.Daemon.Protocol
import Beam.Runtime

open Lean

namespace Beam.Cli

open Beam.Broker

namespace RuntimeDescription

def toWorkspaceBinding (config : Beam.Runtime.Description) (workspaceId : WorkspaceId)
    (root : System.FilePath) : Beam.Daemon.WorkspaceBinding := {
  workspaceId
  root := root.toString
  bundleId := config.identity.generation
  leanCmd := config.command
  plugin := config.plugin.toString
  toolchain := config.toolchain
}

private def hashFields (config : Beam.Runtime.Description) : List String :=
  [config.command, config.plugin.toString, config.daemonBin.toString, config.identity.generation]

end RuntimeDescription

/-- Source configuration for one wrapper-owned daemon generation. -/
structure DesiredConfig where
  root : System.FilePath
  runtime : Beam.Runtime.Description
  deriving Repr

/-- Hash the project root and complete runtime configuration. -/
def DesiredConfig.configHash (config : DesiredConfig) : String :=
  let fields := config.root.toString :: RuntimeDescription.hashFields config.runtime
  let hash := fields.foldl mixField 14695981039346656037
  s!"{hash.toNat}"

/-- Runtime effects selected by the application; callers retain control of when they run. -/
structure RuntimeAccess where
  resolve : System.FilePath → IO DesiredConfig
  attachment : System.FilePath → IO String

end Beam.Cli
