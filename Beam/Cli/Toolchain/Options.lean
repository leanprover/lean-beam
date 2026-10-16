/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

register_option beam.toolchain : Bool := {
  defValue := false
  descr := "build Beam for its containing Lean installation only"
}
