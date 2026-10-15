/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Broker

/-- Complete process configuration for one Lean backend. -/
structure LeanBackendConfig where
  command : String
  plugin : System.FilePath
  lakeHelper? : Option System.FilePath := none
  deriving BEq, Inhabited, Repr

/--
Runtime configuration for one broker workspace.

The optional backends permit an intentionally backend-less standalone bootstrap workspace. Once a
backend is present, its required process configuration is complete by construction.
-/
structure BrokerConfig where
  root : System.FilePath
  lean? : Option LeanBackendConfig := none
  deriving BEq, Inhabited, Repr

namespace BrokerConfig

/-- Assemble the typed runtime model from optional fields at a process boundary. -/
def ofOptions
    (root : System.FilePath)
    (leanCommand? : Option String)
    (leanPlugin? : Option System.FilePath) : Except String BrokerConfig := do
  let lean? ←
    match leanCommand?, leanPlugin? with
    | none, none => pure none
    | some command, some plugin => pure <| some { command, plugin }
    | _, _ => throw "Lean backend configuration requires a command and plugin together"
  pure {
    root
    lean?
  }

end BrokerConfig

end Beam.Broker
