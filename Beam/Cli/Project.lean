/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Cli.Args
import Beam.Lean.Workspace
import Beam.Path
import Beam.Project
import Beam.System

open Lean

namespace Beam.Cli

open Beam.Broker

abbrev hasLeanProject := Beam.Project.hasLeanProject

def requireLeanProjectRoot (root : System.FilePath) : IO System.FilePath := do
  match ← Beam.Lean.Workspace.resolveCliRoot root.toString with
  | .ok root => pure root
  | .error err => throw <| IO.userError err.message

partial def findRootUpwards (start : System.FilePath) : IO (Option System.FilePath) := do
  let dir ← Beam.resolveExistingPath start
  let rec loop (dir : System.FilePath) : IO (Option System.FilePath) := do
    let found ← hasLeanProject dir
    if found then
      pure (some dir)
    else if dir == System.FilePath.mk "/" then
      pure none
    else
      loop (dir.parent.getD dir)
  loop dir

def projectRoot (opts : CliOptions) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => requireLeanProjectRoot root
  | none =>
      match ← findRootUpwards (System.FilePath.mk ".") with
      | some root => requireLeanProjectRoot root
      | none => throw <| IO.userError "could not infer lean project root; use --root PATH"

def inferInspectionRoot (start : System.FilePath) : IO System.FilePath := do
  match ← findRootUpwards start with
  | some root => pure root
  | none => throw <| IO.userError "could not infer project root; use --root PATH"

/-- Select an inspection root, retaining explicit roots after Lean project markers disappear. -/
def inspectionRoot (opts : CliOptions) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none => inferInspectionRoot (System.FilePath.mk ".")

def explicitProjectRoot (opts : CliOptions) (action : String) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none =>
      throw <| IO.userError s!"{action} requires an explicit --root PATH"

end Beam.Cli
