/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Source
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

/-- Complete Lean backend configuration for one wrapper-owned workspace. -/
inductive BackendSet where
  | lean (config : LeanBackendConfig)
  deriving Repr

namespace BackendSet

def toWorkspaceBinding (backends : BackendSet) (workspaceId : WorkspaceId)
    (root : System.FilePath) : Beam.Daemon.WorkspaceBinding :=
  match backends with
  | .lean config => {
      workspaceId
      root := root.toString
      bundleId := config.bundleId
      leanCmd? := some config.command
      plugin? := some config.plugin.toString
      toolchain? := some config.toolchain
    }

def daemonArgs : BackendSet → Array String
  | .lean config => #["--lean-cmd", config.command, "--lean-plugin", config.plugin.toString]

private def hashFields (backends : BackendSet) (daemonBin : System.FilePath) : List String :=
  match backends with
  | .lean config => [config.command, config.plugin.toString, daemonBin.toString, config.bundleId]

end BackendSet

/-- Source configuration for one wrapper-owned daemon generation. -/
structure DesiredConfig where
  root : System.FilePath
  backends : BackendSet
  daemonBin : System.FilePath
  deriving Repr

/-- Hash the complete desired configuration using the established wrapper session field order. -/
def DesiredConfig.configHash (config : DesiredConfig) : String :=
  let fields := config.root.toString :: config.backends.hashFields config.daemonBin
  let hash := fields.foldl mixField 14695981039346656037
  s!"{hash.toNat}"

end Beam.Cli
