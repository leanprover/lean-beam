/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Args
import Beam.Cli.Commands
import Beam.Cli.Installation

namespace Beam.Cli

def main (args : List String) : IO Unit := do
  let installation ← Installation.current
  let opts ← parseCliOptions {} args
  runCommand installation opts

end Beam.Cli

def main := Beam.Cli.main
