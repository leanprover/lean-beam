/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Broker.BackendProcessTest
import BeamTest.Broker.WorkspaceOutputTest

def main (args : List String) : IO Unit :=
  match args with
  | [] => do
      BeamTest.Broker.BackendProcessTest.check
      BeamTest.Broker.WorkspaceOutputTest.check
      IO.println "Backend process ownership and output capture tests passed"
  | ["--workspace-output-producer"] => BeamTest.Broker.WorkspaceOutputTest.producer false
  | ["--workspace-output-flood"] => BeamTest.Broker.WorkspaceOutputTest.producer true
  | _ => throw <| IO.userError "unexpected backend process test arguments"
