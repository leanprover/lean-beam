/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Options
import Beam.Mcp.Runtime
import Beam.Mcp.StdioServer
import Beam.Mcp.SelfCheck
import Beam.Cli.Installation

namespace Beam.Mcp.Application

private def resolvedBeamHome? : IO (Option System.FilePath) := do
  match ← IO.getEnv "BEAM_HOME" with
  | some home =>
      try
        pure <| some (← IO.FS.realPath <| System.FilePath.mk home)
      catch _ =>
        pure <| some (System.FilePath.mk home)
  | none => pure none

private def readIdentity (installation : Beam.Cli.Installation) (opts : Options) : IO Beam.Version.Identity := do
  let home? ← resolvedBeamHome?
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  installation.readIdentity {
    name := Beam.Version.mcpServerName
    mcpProtocol? := some Beam.Version.mcpProtocolVersion
    beamHome? := home?.map (·.toString)
    beamCli? := opts.beamCli?
    serverBinary? := some appPath.toString
    wrapper?
  }

/-- Prepare only the effects required by the transport-independent request handler. -/
def serverOptions (installation : Beam.Cli.Installation) (opts : Options) : Server.Options := {
  resolveRuntime := Runtime.mkBrokerConfig {
    leanCmd? := opts.leanCmd?
    leanPlugin? := opts.leanPlugin?
    beamCli? := opts.beamCli?
  }
  identity := readIdentity installation opts
}

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  let installation ← Beam.Cli.Installation.current
  let opts ← installation.mcpOptions opts
  if opts.showVersion then
    IO.println (← readIdentity installation opts).text
    return
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      Server.runStdio (serverOptions installation opts)


end Beam.Mcp.Application
