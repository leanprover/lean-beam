/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Protocol

namespace Beam.Mcp

def runtimeSetupErrorPrefix : String :=
  "could not set up Lean Beam MCP runtime"

def runtimeSetupGuidance : String :=
  "install Beam for the project's exact Lean target, then start lean-beam-mcp from that installation"

def runtimeSetupError (message : String) : RpcError :=
  RpcError.invalidRequest s!"{runtimeSetupErrorPrefix}: {message}"

end Beam.Mcp
