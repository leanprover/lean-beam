/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Installation

/-- One file in the existing build/install inventory. Paths are relative to their respective roots. -/
structure Artifact where
  source : String
  destination : String
  hash : String
  deriving BEq, FromJson, ToJson

structure Frontends where
  cli : String
  mcp : String
  compilerRevision : String
  deriving BEq, FromJson, ToJson

/-- Construction declares this entire relationship. Selector text is diagnostic, not a provider. -/
structure Target where
  lean : String
  daemon : String
  plugin : String
  toolchain : String
  compilerRevision : String
  leanVersion : String
  lakeVersion : String
  deriving BEq, FromJson, ToJson

/-- Relationships within one artifact inventory, recorded in the existing installation manifest. -/
structure Components where
  frontends : Frontends
  license : String
  targets : Array Target
  deriving BEq, FromJson, ToJson

private def portablePart (part : String) : Bool :=
  let base := ((part.splitOn ".").headD "").toLower
  !part.isEmpty && !part.endsWith "." && !part.endsWith " " &&
    !(["con", "prn", "aux", "nul", "conin$", "conout$", "clock$",
      "com¹", "com²", "com³", "lpt¹", "lpt²", "lpt³"].contains base) &&
    !(List.range 9).any (fun i => base == s!"com{i+1}" || base == s!"lpt{i+1}")

/-- A portable inventory spelling; native filesystem admission still checks canonical membership. -/
def relativePath (path : String) : Bool :=
  !path.isEmpty && !path.startsWith "/" &&
    !path.toList.any (fun c => "\\:<>\"|?*;".contains c || c.toNat < 32) &&
    (path.splitOn "/").all portablePart

def hexDigest (length : Nat) (value : String) : Bool :=
  value.length == length && value.toList.all (fun c =>
    ('0' ≤ c && c ≤ '9') || ('a' ≤ c && c ≤ 'f'))

/-- Reject incomplete/ambiguous construction output; finding extra files never adds a target. -/
def Components.validate (components : Components) (artifacts : Array Artifact) : Except String Unit := do
  unless hexDigest 40 components.frontends.compilerRevision do
    throw "frontend compiler revision must be an exact Git revision"
  if components.targets.isEmpty then throw "installation has no constructed targets"
  let mut destinations : Std.HashSet String := {}
  for artifact in artifacts do
    unless relativePath artifact.source && relativePath artifact.destination do
      throw "artifact paths must be normalized relative paths"
    unless hexDigest 64 artifact.hash do throw "artifact hash must be a SHA-256 digest"
    let key := artifact.destination.toLower
    if destinations.contains key then throw s!"duplicate artifact destination: {artifact.destination}"
    destinations := destinations.insert key
  let mut used : Std.HashSet String := {}
  let mut targets : Std.HashSet String := {}
  let mut paths := #[components.frontends.cli, components.frontends.mcp, components.license]
  for target in components.targets do
    if target.lean.isEmpty || target.toolchain.isEmpty || target.leanVersion.isEmpty || target.lakeVersion.isEmpty then
      throw "target identity and compiler descriptions must not be empty"
    unless (System.FilePath.mk target.lean).isAbsolute || relativePath target.lean do
      throw "target Lean command must be absolute or relative to its installation"
    unless hexDigest 40 target.compilerRevision do throw "target compiler revision must be an exact Git revision"
    let key := if System.Platform.isWindows then target.lean.toLower else target.lean
    if targets.contains key then throw s!"duplicate target Lean installation: {target.lean}"
    targets := targets.insert key
    paths := paths ++ #[target.daemon, target.plugin]
  for path in paths do
    unless relativePath path do throw s!"component is outside its installation: {path}"
    let key := path.toLower
    if used.contains key then throw s!"component path has multiple roles: {path}"
    unless artifacts.any (·.destination == path) do throw s!"component is absent from artifact inventory: {path}"
    used := used.insert key

end Beam.Installation
