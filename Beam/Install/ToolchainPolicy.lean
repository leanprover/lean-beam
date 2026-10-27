/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.Install

private def canonicalNat? (text : String) : Option Nat := do
  let value ← text.toNat?
  if s!"{value}" == text then some value else none

/-- The exact version of a canonical `leanprover/lean4:vX.Y.Z[-rcN]` selector, if it is one. -/
def canonicalLeanVersion? (toolchain : String) : Option String := do
  let selectorPrefix := "leanprover/lean4:v"
  unless toolchain.startsWith selectorPrefix do none
  let version := (toolchain.drop selectorPrefix.length).toString
  let (stable, rc?) ← match version.splitOn "-" with
    | [stable] => some (stable, none)
    | [stable, prerelease] => do
        unless prerelease.startsWith "rc" do none
        let rc ← canonicalNat? (prerelease.drop 2).toString
        unless rc > 0 do none
        some (stable, some rc)
    | _ => none
  let [major, minor, patch] := stable.splitOn "." | none
  let parts ← [major, minor, patch].mapM canonicalNat?
  let rendered := ".".intercalate (parts.map toString) ++
    match rc? with
    | some rc => s!"-rc{rc}"
    | none => ""
  if rendered == version then some rendered else none

private def registryEntries (text : String) : List String :=
  text.splitOn "\n" |>.map (fun line => line.trimAscii.toString)
    |>.filter (fun line => !line.isEmpty && !line.startsWith "#")

/-- Frozen installer policy for diagnostics; ordinary admission still uses exact membership. -/
def validatedToolchains : List String :=
  registryEntries (include_str "../../validated-lean-toolchains")

private def compatibleReleaseLines : List String :=
  registryEntries (include_str "../../compatible-lean-release-lines")

/-- Mirrors the installer's canonical release-line admission, using the same policy files. -/
def releaseToolchainSupported (toolchain : String) : Bool :=
  validatedToolchains.contains toolchain || Id.run do
    let some version := canonicalLeanVersion? toolchain | return false
    let [major, minor, _] := ((version.splitOn "-").headD "").splitOn "." | return false
    return compatibleReleaseLines.contains s!"leanprover/lean4:v{major}.{minor}"

end Beam.Install
