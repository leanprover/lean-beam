/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Runtime

/-- Read-only local admission observes cancellation before and after lookup. -/
structure Admission where
  isCancelled : IO Bool

/-- A published Beam runtime generation, retained by its workspace/session owner. -/
structure Identity where
  generation : String
  deriving BEq, Repr

/-- Complete execution paths and identity, independent of installation and workspace layout. -/
structure Description where
  command : String
  plugin : System.FilePath
  /-- The matching daemon also supplies the in-process Lake helper. -/
  daemonBin : System.FilePath
  toolchain : String
  identity : Identity
  deriving BEq, Repr

/-- Execution identity excludes selector labels: aliases of the same runtime remain equivalent. -/
def Description.sameRuntime (left right : Description) : Bool :=
  left.command == right.command && left.plugin == right.plugin &&
    left.daemonBin == right.daemonBin && left.identity == right.identity

end Beam.Runtime
