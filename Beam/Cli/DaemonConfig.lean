/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Daemon.Protocol
import Beam.Runtime
import Beam.Cli.Error

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

end RuntimeDescription

/-- Source configuration for one wrapper-owned daemon generation. -/
structure DesiredConfig where
  root : System.FilePath
  runtime : Beam.Runtime.Description
  deriving Repr

/-- Hash the project root and complete runtime configuration. -/
def DesiredConfig.configHash (config : DesiredConfig) : String :=
  config.runtime.configHash config.root

/-- Runtime effects selected by the application; callers retain control of when they run. -/
structure RuntimeAccess where
  resolve : System.FilePath → CliM DesiredConfig
  attachment : System.FilePath → CliM String
  control : Beam.Daemon.SessionDescriptor → IO Unit

end Beam.Cli
