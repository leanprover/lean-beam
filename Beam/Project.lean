/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Project

def hasLeanProject (root : System.FilePath) : IO Bool := do
  return (← (root / "lean-toolchain").pathExists) ||
    (← (root / "lakefile.toml").pathExists) ||
    (← (root / "lakefile.lean").pathExists)

end Beam.Project
