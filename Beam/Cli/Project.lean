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

abbrev hasRocqProject := Beam.Project.hasRocqProject

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
      | .rocq => hasRocqProject dir
    if found then
      pure (some dir)
    else if dir == System.FilePath.mk "/" then
      pure none
    else
      loop (dir.parent.getD dir)
  loop dir

def projectRoot (opts : CliOptions) (backend : Backend) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root =>
      match backend with
      | .lean => requireLeanProjectRoot root
      | .rocq => pure root
  | none =>
      match ← findRootUpwards (System.FilePath.mk ".") backend with
      | some root =>
          match backend with
          | .lean => requireLeanProjectRoot root
          | .rocq => pure root
      | none =>
          let backendName := match backend with | .lean => "lean" | .rocq => "rocq"
          throw <| IO.userError s!"could not infer {backendName} project root; use --root PATH"

def inferProjectRootAny (start : System.FilePath) : IO System.FilePath := do
  let leanRoot? ← findRootUpwards start .lean
  let rocqRoot? ← findRootUpwards start .rocq
  match leanRoot?, rocqRoot? with
  | none, none =>
      throw <| IO.userError "could not infer project root; use --root PATH"
  | some root, none | none, some root =>
      pure root
  | some leanRoot, some rocqRoot =>
      if ← Beam.sameFilePath leanRoot rocqRoot then
        pure leanRoot
      else
        throw <| IO.userError <|
          "project root is ambiguous; found both " ++
          s!"Lean root {leanRoot} and Rocq root {rocqRoot}; use --root PATH"

def projectRootAny (opts : CliOptions) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none => inferProjectRootAny (System.FilePath.mk ".")

def explicitProjectRoot (opts : CliOptions) (action : String) : IO System.FilePath := do
  match opts.explicitRoot? with
  | some root => pure root
  | none =>
      throw <| IO.userError s!"{action} requires an explicit --root PATH"

-- Elan 4.2 exposes its selected descriptor through `dump-state --no-net`. Decode only that
-- descriptor; channel resolution and installed-toolchain paths are not admission authorities.
private structure ElanRemoteToolchain where
  origin : String
  release : String
  deriving FromJson

private structure ElanLocalToolchain where
  name : String
  deriving FromJson

/-- Decode Elan's selected name without parsing its human-readable selection/provenance text. -/
def selectedElanToolchain (state : Json) : Except String String := do
  let toolchains ← state.getObjVal? "toolchains"
  let active ← toolchains.getObjVal? "active_override"
  let selected ←
    if active == Json.null then
      (← toolchains.getObjVal? "default").getObjVal? "unresolved"
    else
      active.getObjVal? "unresolved"
  match selected.getObjVal? "Remote", selected.getObjVal? "Local" with
  | .ok remote, .error _ =>
      let remote : ElanRemoteToolchain ← fromJson? remote
      pure s!"{remote.origin}:{remote.release}"
  | .error _, .ok localToolchain =>
      let localToolchain : ElanLocalToolchain ← fromJson? localToolchain
      pure localToolchain.name
  | _, _ => throw "expected one Remote or Local Elan toolchain descriptor"

/-- Ask Elan to select the workspace toolchain, including environment and directory overrides. -/
def effectiveLeanToolchain (root : System.FilePath) : IO String := do
  let state ← Beam.readCmdTrim "elan" #["dump-state", "--no-net"] (some root)
  IO.ofExcept <| (Json.parse state >>= selectedElanToolchain).mapError fun error =>
    s!"could not read Elan's toolchain selection for {root}: {error}"

def leanBinForToolchain (root : System.FilePath) (toolchain : String) : IO String := do
  -- Freeze the selection already used for admission and the bundle. An override changing
  -- during bundle preparation must not select a different Lean executable.
  Beam.readCmdTrim "elan" #["run", toolchain, "elan", "which", "lean"] (some root)

def rocqCandidates (root : System.FilePath) : List System.FilePath :=
  [root / "_opam" / "bin" / "coq-lsp", root / "_opam" / "_opam" / "bin" / "coq-lsp"]

def maybeRocqCmd (root : System.FilePath) : IO (Option String) := do
  for candidate in rocqCandidates root do
    if ← candidate.pathExists then
      return some candidate.toString
  match ← IO.getEnv "BEAM_ROCQ_CMD" with
  | some cmd => pure (some cmd)
  | none =>
      if ← Beam.commandAvailable "coq-lsp" then
        pure (some "coq-lsp")
      else
        pure none

def rocqCmd (root : System.FilePath) : IO String := do
  match ← maybeRocqCmd root with
  | some cmd => pure cmd
  | none => throw <| IO.userError s!"could not find coq-lsp for {root}"

end Beam.Cli
