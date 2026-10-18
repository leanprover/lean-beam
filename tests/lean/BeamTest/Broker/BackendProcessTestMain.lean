/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Broker.BackendProcessTest

def main : IO Unit := do
  BeamTest.Broker.BackendProcessTest.check
  IO.println "Backend process ownership tests passed"
