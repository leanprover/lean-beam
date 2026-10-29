/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Install

/-- Source-checkout files that a target build needs, relative to the checkout root. -/
def sourceRootFiles : List String :=
  ["LICENSE", "Beam.lean", "lakefile.lean", "lake-manifest.json", "lean-toolchain",
    "validated-lean-toolchains", "compatible-lean-release-lines"]

def sourceDirs : List String :=
  ["Beam"]

partial def collectTreeFiles (current : System.FilePath) : IO (Array System.FilePath) := do
  let entries := (← current.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut files := #[]
  for entry in entries do
    if ← entry.path.isDir then
      files := files ++ (← collectTreeFiles entry.path)
    else
      files := files.push entry.path
  pure files

/-- Every present source file a target build copies, in a stable order. -/
def collectSourceFiles (root : System.FilePath) : IO (Array System.FilePath) := do
  let mut files := #[]
  for name in sourceRootFiles do
    let path := root / name
    if ← path.pathExists then
      files := files.push path
  for dirName in sourceDirs do
    let dir := root / dirName
    if ← dir.pathExists then
      files := files ++ (← collectTreeFiles dir)
  pure <| files.qsort (fun a b => a.toString < b.toString)

end Beam.Install
