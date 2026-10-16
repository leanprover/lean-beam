/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Elab.Term

namespace Beam

elab "beamCompiledLeanRevision" : term =>
  Lean.Elab.Term.elabTerm (Lean.Syntax.mkStrLit Lean.githash) none

/--
Freeze `Lean.githash` during elaboration; evaluating it later identifies the loaded runtime.
The stamp records the compiler revision used for this module. The build must compile the remaining
Beam objects consistently; this is not an attestation of every object or build configuration.
-/
def compiledCompilerRevision : String := beamCompiledLeanRevision

/-- Revision agreement is a necessary compatibility check, not a complete build-configuration ABI proof. -/
def compilerRevisionsMatch (compiled loaded selected : String) : Bool :=
  !compiled.isEmpty && compiled == loaded && compiled == selected

end Beam
