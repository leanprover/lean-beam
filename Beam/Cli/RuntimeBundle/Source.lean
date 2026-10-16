/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.Hash
import Beam.Cli.InstallLayout
import Beam.Path

open Lean

namespace Beam.Cli

partial def collectTreeFiles (current : System.FilePath) : IO (Array System.FilePath) := do
  let entries := (← current.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut files := #[]
  for entry in entries do
    if ← entry.path.isDir then
      files := files ++ (← collectTreeFiles entry.path)
    else
      files := files.push entry.path
  pure files

def sortedPaths (paths : Array System.FilePath) : Array System.FilePath :=
  paths.qsort (fun a b => a.toString < b.toString)

def collectBundleSourceFiles (root : System.FilePath) : IO (Array System.FilePath) := do
  let mut files := #[]
  for name in bundleRootFiles do
    let path := root / name
    if ← path.pathExists then
      files := files.push path
  for dirName in bundleSourceDirs do
    let dir := root / dirName
    if ← dir.pathExists then
      files := files ++ (← collectTreeFiles dir)
  pure <| sortedPaths files

private def mixFileHash (acc : UInt64) (root path : System.FilePath) : IO UInt64 := do
  let rel := Beam.pathRelativeToRootOrSelf root path
  let acc := mixField acc rel
  let bytes ← IO.FS.readBinFile path
  pure <| hashBytes bytes <| hashByte acc 0

def sourceHash (home : System.FilePath) : IO String := do
  let root ← Beam.resolveExistingPath home
  let files ← collectBundleSourceFiles root
  let mut acc : UInt64 := 14695981039346656037
  for path in files do
    acc ← mixFileHash acc root path
  pure s!"{acc.toNat}"

end Beam.Cli
