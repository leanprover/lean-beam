/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Hash
import Beam.Daemon.Protocol

open Lean

namespace Beam.Cli

open Beam.Broker

/-- The complete resolved configuration of a Lean backend in a wrapper-owned session. -/
structure LeanBackendConfig where
  command : String
  plugin : System.FilePath
  toolchain : String
  bundleId : String
  deriving Repr

namespace LeanBackendConfig

def toWorkspaceBinding (config : LeanBackendConfig) (workspaceId : WorkspaceId)
    (root : System.FilePath) : Beam.Daemon.WorkspaceBinding := {
  workspaceId
  root := root.toString
  bundleId := config.bundleId
  leanCmd := config.command
  plugin := config.plugin.toString
  toolchain := config.toolchain
}

def daemonArgs (config : LeanBackendConfig) : Array String :=
  #["--lean-cmd", config.command, "--lean-plugin", config.plugin.toString]

private def hashFields (config : LeanBackendConfig) (daemonBin : System.FilePath) : List String :=
  [config.command, config.plugin.toString, daemonBin.toString, config.bundleId]

end LeanBackendConfig

/-- Source configuration for one wrapper-owned daemon generation. -/
structure DesiredConfig where
  root : System.FilePath
  lean : LeanBackendConfig
  daemonBin : System.FilePath
  deriving Repr

/-- Hash the project root and complete runtime configuration. -/
def DesiredConfig.configHash (config : DesiredConfig) : String :=
  let fields := config.root.toString :: config.lean.hashFields config.daemonBin
  let hash := fields.foldl mixField 14695981039346656037
  s!"{hash.toNat}"

/-- The attachment contract is about session identity, independent of runtime provenance. -/
inductive SessionRequirement where
  | selected
  | matchingRuntime (configHash : String)

/-- Runtime effects selected by the application; callers retain control of when they run. -/
structure RuntimeAccess where
  resolve : System.FilePath → IO DesiredConfig
  attachment : System.FilePath → IO SessionRequirement

end Beam.Cli
