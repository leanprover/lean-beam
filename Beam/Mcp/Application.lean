/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Options
import Beam.Mcp.StdioServer
import Beam.Installation.Lookup
import Beam.BuildInfo

namespace Beam.Mcp.Application

private def readIdentity (installation : Beam.Installation) : IO Beam.Version.Identity := do
  installation.readIdentity {
    name := Beam.Version.mcpServerName
    mcpProtocol? := some Beam.Version.mcpProtocolVersion
    serverBinary? := some (← IO.appPath).toString
    wrapper? := ← IO.getEnv "BEAM_WRAPPER_PATH"
  }

/-- Both installation adapters use exact membership lookup and retain the startup generation. -/
def serverOptions (installation : Beam.Installation) : Server.Options := Id.run do
  let resolve := fun (context : Beam.Runtime.Admission) (root : System.FilePath) => do
    if ← context.isCancelled then
      return .error <| runtimeSetupError "request was cancelled before runtime lookup"
    match ← installation.lookup root with
    | .error error => pure <| .error <| runtimeSetupError error.message
    | .ok reference => pure <| .ok reference.description
  return {
    resolveRuntime := resolve
    admitRuntime := fun context root recorded => do
      match ← resolve context root with
      | .error error => pure (.error error)
      | .ok current =>
          unless recorded.sameRuntime current do
            return .error <| runtimeSetupError "workspace target changed; call lean_drop_workspace before selecting another installed target"
          pure (.ok ())
    identity := readIdentity installation
  }

def main (args : List String) : IO Unit := do
  if args == ["toolchain-build-info"] then
    unless Beam.Installation.Bundled.enabled do
      throw <| IO.userError "this executable was not built with -KbeamToolchain=true"
    IO.println Beam.BuildInfo.report.compress
    return
  let opts ← IO.ofExcept <| (Beam.Mcp.parseOptions {} args).mapError IO.userError
  let installation ← Beam.Installation.current .mcp
  if opts.showVersion then
    IO.println (← readIdentity installation).text
    return
  Server.runStdio (serverOptions installation)

end Beam.Mcp.Application
