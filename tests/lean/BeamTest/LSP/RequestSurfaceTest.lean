/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.LSP.Handle.Api
import BeamTest.LSP.Handle.Lifecycle
import BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest
import BeamTest.LSP.Requests.Goals.BasicTest
import BeamTest.LSP.Requests.RunAt.BasicTest
import BeamTest.LSP.Requests.RunAt.ProfileTest
import BeamTest.LSP.Requests.Save.BasicTest
import BeamTest.LSP.Requests.Todo.BasicTest

namespace BeamTest.LSP.RequestSurfaceTest

def main : IO Unit := BeamTest.LSP.Scenario.run do
  BeamTest.LSP.Requests.RunAt.BasicTest.run
  BeamTest.LSP.Requests.RunAt.ProfileTest.run
  BeamTest.LSP.Requests.Goals.BasicTest.run
  BeamTest.LSP.Requests.Todo.BasicTest.run
  BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest.run
  BeamTest.LSP.Requests.Save.BasicTest.run
  BeamTest.LSP.Handle.Api.run
  BeamTest.LSP.Handle.Lifecycle.run

end BeamTest.LSP.RequestSurfaceTest

def main := BeamTest.LSP.RequestSurfaceTest.main
