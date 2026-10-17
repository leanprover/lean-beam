/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Path
import Beam.System

namespace Beam.Installation.LocalTarget

inductive Failure where
  | unavailable (selector : String)
  | floating (selector : String)
  | io (error : IO.Error)

def Failure.message : Failure → String
  | .unavailable selector =>
      s!"project target '{selector}' is unavailable locally; install or link its exact Lean installation, then reinstall Beam with that target"
  | .floating selector =>
      s!"project selector '{selector}' requires remote resolution; pin an exact locally installed target or use an explicit local link"
  | .io error => error.toString

def elanHome : IO (Option System.FilePath) := do
  if let some home ← IO.getEnv "ELAN_HOME" then return some home
  let name := if System.Platform.isWindows then "USERPROFILE" else "HOME"
  return (← IO.getEnv name).map fun home => System.FilePath.mk home / ".elan"

private def executableName : String :=
  if System.Platform.isWindows then "lean.exe" else "lean"

private def leanIn? (toolchainRoot : System.FilePath) : IO (Option System.FilePath) := do
  try
    let command := toolchainRoot / "bin" / executableName
    unless (← command.metadata).type == .file do return none
    pure <| some (← Beam.resolveExistingPath command)
  catch _ => pure none

private def directoryName? (name : String) : Option String := do
  let encoded := (name.replace "/" "--").replace ":" "---"
  guard (!encoded.isEmpty && encoded != "." && encoded != ".." &&
    !encoded.toList.any (fun c => c == '\\' || c.toNat < 32))
  pure encoded

private def linkedLean? (home : System.FilePath) (release : String) : IO (Option System.FilePath) := do
  let some name := directoryName? release | return none
  let path := home / "toolchains" / name
  try
    unless ← Beam.pathIsLink path do return none
    leanIn? path
  catch _ => pure none

/-- Resolve only local context. No candidate executable, elan command, download, or build runs. -/
def resolve (root : System.FilePath) (home? : Option System.FilePath) :
    IO (Except Failure (Option System.FilePath)) := do
  try
    let marker := root / "lean-toolchain"
    unless ← marker.pathExists do return .ok none
    let selector := ((← IO.FS.readFile marker).splitOn "\n").headD "" |>.trimAscii.toString
    if selector.isEmpty then return .error (.unavailable selector)
    let path := System.FilePath.mk selector
    let toolchainRoot := if path.isAbsolute then path else root / path
    if let some command ← leanIn? toolchainRoot then return .ok (some command)
    if path.isAbsolute || ["./", "../", ".\\", "..\\"].any (fun start => selector.startsWith start) then
      return .error (.unavailable selector)
    let (origin, release) ← match selector.splitOn ":" with
      | [release] => pure ("leanprover/lean4", release)
      | [origin, release] => pure (origin, release)
      | _ => return .error (.unavailable selector)
    let some home := home? | return .error (.unavailable selector)
    -- Elan gives a locally linked release name precedence over the remote descriptor.
    if let some command ← linkedLean? home release then return .ok (some command)
    if ["stable", "beta", "nightly", "lean-toolchain"].contains release then
      return .error (.floating selector)
    let origin := if release.startsWith "nightly" && !origin.endsWith "-nightly" then
      origin ++ "-nightly" else origin
    let release := if release.toList.head?.any Char.isDigit then "v" ++ release else release
    let some name := directoryName? (origin ++ ":" ++ release)
      | return .error (.unavailable selector)
    if let some command ← leanIn? (home / "toolchains" / name) then return .ok (some command)
    return .error (.unavailable selector)
  catch error => return .error (.io error)

end Beam.Installation.LocalTarget
