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
import Beam.Daemon.Paths
import Beam.System

open Lean

namespace Beam.Cli

open Beam.Broker

abbrev hasLeanProject := Beam.Project.hasLeanProject

def requireLeanProjectRoot (root : System.FilePath) : CliM System.FilePath := do
  match ← Beam.Lean.Workspace.resolveCliRoot root.toString with
  | .ok root => pure root
  | .error err => throw <| CliFailure.usage err.message

partial def findRootUpwards (start : System.FilePath) : IO (Option System.FilePath) := do
  let dir ← Beam.resolveExistingPath start
  let rec loop (dir : System.FilePath) : IO (Option System.FilePath) := do
    let found ← hasLeanProject dir
    if found then
      pure (some dir)
    else
      match dir.parent with
      | none => pure none
      | some parent => loop parent
  loop dir

/-- Reject unsafe selected session leaves without creating or repairing them. -/
private def validateSessionSelection (opts : CliOptions) (root : System.FilePath) : CliM System.FilePath := do
  if opts.explicitControlDir?.isNone then
    if let some base ← IO.getEnv "BEAM_SESSION_ROOT" then
      unless (System.FilePath.mk base).isAbsolute do
        throw <| .argument "BEAM_SESSION_ROOT" base
          (fun preview => s!"BEAM_SESSION_ROOT must be an absolute path, got '{preview}'")
  let dir ← Beam.Daemon.controlDirFor root opts.explicitControlDir?
  match ← Beam.observePrivateDir dir with
  | .absent | .privateDir => pure root
  | observation =>
      throw <| .setup s!"unsafe Beam session directory {dir}: {observation.problem.getD "invalid directory"}; select a dedicated private directory; Beam does not change ownership or permissions on existing paths"

def projectRoot (opts : CliOptions) : CliM System.FilePath := do
  let root ← match opts.explicitRoot? with
    | some root => requireLeanProjectRoot root
    | none =>
        match ← findRootUpwards (System.FilePath.mk ".") with
        | some root => requireLeanProjectRoot root
        | none => throw <| CliFailure.usage "could not infer lean project root; use --root PATH"
  validateSessionSelection opts root

def inferInspectionRoot (start : System.FilePath) : CliM System.FilePath := do
  match ← findRootUpwards start with
  | some root => pure root
  | none => throw <| CliFailure.usage "could not infer project root; use --root PATH"

/-- Select an inspection root, retaining explicit roots after Lean project markers disappear. -/
def inspectionRoot (opts : CliOptions) : CliM System.FilePath := do
  let root ← match opts.explicitRoot? with
    | some root => pure root
    | none => inferInspectionRoot (System.FilePath.mk ".")
  validateSessionSelection opts root

def explicitProjectRoot (opts : CliOptions) (action : String) : CliM System.FilePath := do
  match opts.explicitRoot? with
  | some root => validateSessionSelection opts root
  | none =>
      throw <| CliFailure.usage s!"{action} requires an explicit --root PATH"

end Beam.Cli
