/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Options
import Beam.Mcp.Runtime
import Beam.Mcp.StdioServer
import Beam.Mcp.SelfCheck
import Beam.Cli.Toolchain
import Beam.Cli.RuntimeIdentity

namespace Beam.Mcp.Application

private def resolvedBeamHome? : IO (Option System.FilePath) := do
  match ← IO.getEnv "BEAM_HOME" with
  | some home =>
      try
        pure <| some (← IO.FS.realPath <| System.FilePath.mk home)
      catch _ =>
        pure <| some (System.FilePath.mk home)
  | none => pure none

private def readIdentity (opts : Options) : IO Beam.Version.Identity := do
  let home? ← resolvedBeamHome?
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  Beam.Cli.RuntimeIdentity.mcpServerIdentity home? opts.beamCli? (some appPath.toString)
    (wrapper? := wrapper?)

/-- Prepare only the effects required by the transport-independent request handler. -/
def serverOptions (opts : Options) : Server.Options := {
  resolveRuntime := Runtime.mkBrokerConfig {
    leanCmd? := opts.leanCmd?
    leanPlugin? := opts.leanPlugin?
    beamCli? := opts.beamCli?
  }
  identity := readIdentity opts
}

def main (args : List String) : IO Unit := do
  let opts ←
    match Beam.Mcp.parseOptions {} args with
    | .ok opts => pure opts
    | .error err => throw <| IO.userError err
  let opts ← if Beam.Cli.Toolchain.enabled then do
    let beamCli ← Beam.Cli.Toolchain.executable "lean-beam"
    let mismatch := IO.userError "bundled lean-beam-mcp uses only its containing toolchain"
    unless opts.leanCmd?.isNone && opts.leanPlugin?.isNone do
      throw mismatch
    if let some selected := opts.beamCli? then
      unless ← Beam.sameFilePath beamCli (System.FilePath.mk selected) do
        throw mismatch
    pure { opts with beamCli? := some beamCli.toString }
  else
    pure opts
  if opts.showVersion then
    IO.println (← readIdentity opts).text
    return
  match opts.selfCheckPath? with
  | some path =>
      SelfCheck.run {
        leanCmd? := opts.leanCmd?
        leanPlugin? := opts.leanPlugin?
        beamCli? := opts.beamCli?
      } path
  | none =>
      Server.runStdio (serverOptions opts)


end Beam.Mcp.Application
