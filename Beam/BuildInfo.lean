/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Elab.Term
import Beam.BuildInfo.Options
import Beam.CompilerRevision

namespace Beam.BuildInfo

-- Emit literals during elaboration: these must not become reads of current installed metadata.
elab "beamCompiledBuildId" : term => do
  Lean.Elab.Term.elabTerm
    (Lean.Syntax.mkStrLit (beam.buildId.get (← Lean.getOptions))) none

elab "beamCompiledSourceRevision" : term => do
  Lean.Elab.Term.elabTerm
    (Lean.Syntax.mkStrLit (beam.sourceRevision.get (← Lean.getOptions))) none

structure Identity where
  compilerRevision : String
  sourceRevision : String
  buildId : String
  deriving BEq, Repr

/-- The compiler revision and native generation frozen into this Beam module. -/
def compiled : Identity := {
  compilerRevision := Beam.compiledCompilerRevision
  sourceRevision := beamCompiledSourceRevision
  buildId := beamCompiledBuildId
}

/-- Executable-local identity for construction before installation metadata is published. -/
def report : Lean.Json := Lean.Json.mkObj [
  ("compiledLeanRevision", Lean.toJson compiled.compilerRevision),
  ("loadedLeanRevision", Lean.toJson Lean.githash),
  ("sourceRevision", Lean.toJson compiled.sourceRevision),
  ("buildId", Lean.toJson compiled.buildId)
]

end Beam.BuildInfo
