/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

namespace Beam.WorkspaceOutput

inductive Source where
  | stdout
  | stderr
  deriving BEq, Repr, Inhabited

structure Chunk where
  source : Source
  text : String
  omittedBefore : Bool := false
  deriving BEq, Repr, Inhabited

/-- These limits cover pending text, not the encoded transport envelope or an in-flight frame. -/
def byteLimit : Nat := 256 * 1024
def recordLimit : Nat := 256
def chunkLimit : Nat := 8192

end Beam.WorkspaceOutput
