/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

register_option beam.buildId : String := {
  defValue := ""
  descr := "native Beam build generation recorded by the distribution builder"
}

register_option beam.sourceRevision : String := {
  defValue := ""
  descr := "Beam source revision recorded by the distribution builder"
}
