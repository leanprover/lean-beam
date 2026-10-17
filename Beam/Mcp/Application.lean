/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Options
import Beam.Mcp.StdioServer
import Beam.Mcp.SelfCheck
import Beam.Cli.Installation

namespace Beam.Mcp.Application

private def readIdentity (installation : Beam.Cli.Installation) : IO Beam.Version.Identity := do
  installation.readIdentity {
    name := Beam.Version.mcpServerName
    mcpProtocol? := some Beam.Version.mcpProtocolVersion
    serverBinary? := some (← IO.appPath).toString
    wrapper? := ← IO.getEnv "BEAM_WRAPPER_PATH"
  }

/-- Both installation adapters use exact membership lookup and retain the startup generation. -/
def serverOptions (installation : Beam.Cli.Installation) : Server.Options := Id.run do
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
      | .error error => pure <| .error { error with
          message := error.message ++ "; call lean_drop_workspace before selecting a different installed target" }
      | .ok current =>
          unless recorded.sameRuntime current do
            return .error <| runtimeSetupError "workspace target changed; call lean_drop_workspace before selecting another installed target"
          pure (.ok ())
    identity := readIdentity installation
  }

def main (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| (Beam.Mcp.parseOptions {} args).mapError IO.userError
  let installation ← Beam.Cli.Installation.current .mcp
  if opts.showVersion then
    IO.println (← readIdentity installation).text
    return
  match opts.selfCheckPath? with
  | some path => SelfCheck.run path
  | none => Server.runStdio (serverOptions installation)

end Beam.Mcp.Application
