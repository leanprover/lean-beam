/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Cli.Args
import Beam.Cli.RuntimeBundle
import Beam.Lean.Workspace
import Beam.Path
import Beam.Project
import Beam.System

open Lean

namespace Beam.Cli

open Beam.Broker

partial def climbParents (path : System.FilePath) (count : Nat) : System.FilePath :=
  match count with
  | 0 => path
  | n + 1 => climbParents (path.parent.getD path) n

def beamHome : IO System.FilePath := do
  match ← IO.getEnv "BEAM_HOME" with
  | some root =>
      Beam.resolveExistingPath <| System.FilePath.mk root
  | none =>
      let app ← IO.appPath
      Beam.resolveExistingPath <| climbParents app 4

abbrev hasLeanProject := Beam.Project.hasLeanProject

def requireLeanProjectRoot (root : System.FilePath) : IO System.FilePath := do
  match ← Beam.Lean.Workspace.resolveCliRoot root.toString with
  | .ok root => pure root
  | .error err => throw <| IO.userError err.message

partial def findRootUpwards (start : System.FilePath) (backend : Backend) : IO (Option System.FilePath) := do
  let dir ← Beam.resolveExistingPath start
  let rec loop (dir : System.FilePath) : IO (Option System.FilePath) := do
    let found ←
      match backend with
      | .lean => hasLeanProject dir
    if found then
      pure (some dir)
    else if dir == System.FilePath.mk "/" then
      pure none
    else
      loop (dir.parent.getD dir)
  loop dir

def projectRoot (opts : CliOptions) (_backend : Backend) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => requireLeanProjectRoot root
  | none =>
      match ← findRootUpwards (System.FilePath.mk ".") .lean with
      | some root => requireLeanProjectRoot root
      | none => throw <| IO.userError "could not infer lean project root; use --root PATH"

def inferProjectRootAny (start : System.FilePath) : IO System.FilePath := do
  match ← findRootUpwards start .lean with
  | some root => pure root
  | none => throw <| IO.userError "could not infer project root; use --root PATH"

def projectRootAny (opts : CliOptions) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none => inferProjectRootAny (System.FilePath.mk ".")

def explicitProjectRoot (opts : CliOptions) (action : String) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none =>
      throw <| IO.userError s!"{action} requires an explicit --root PATH"

def leanToolchain (root : System.FilePath) : IO String := do
  let path := root / "lean-toolchain"
  unless ← path.pathExists do
    throw <| IO.userError s!"missing lean-toolchain in {root}"
  pure <| Beam.trimLine (← IO.FS.readFile path)

def leanBin (root : System.FilePath) : IO String :=
  Beam.readCmdTrim "elan" #["which", "lean"] (some root)

end Beam.Cli
