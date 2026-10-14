/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Paths
import Beam.System

open Lean

namespace Beam.Cli

/-- Moving Elan selectors cannot serve as admitted runtime identities. -/
def isMovingLeanToolchain (name : String) : Bool :=
  ["stable", "beta", "nightly", "lean-toolchain"].contains
    ((name.splitOn ":").getLast?.getD name)

def nonCommentLines (text : String) : List String :=
  (text.splitOn "\n").filterMap fun raw =>
    let line := Beam.trimLine raw
    if line.isEmpty || line.startsWith "#" then none else some line

def canonicalLeanToolchainPrefix : String :=
  "leanprover/lean4:v"

private def canonicalNat? (text : String) : Option Nat := do
  let value ← text.toNat?
  if s!"{value}" == text then some value else none

structure LeanReleaseLine where
  major : Nat
  minor : Nat
  deriving BEq, Repr

def LeanReleaseLine.versionText (line : LeanReleaseLine) : String :=
  s!"{line.major}.{line.minor}"

def LeanReleaseLine.registryEntry (line : LeanReleaseLine) : String :=
  canonicalLeanToolchainPrefix ++ line.versionText

def parseLeanReleaseLine? (text : String) : Option LeanReleaseLine := do
  unless text.startsWith canonicalLeanToolchainPrefix do
    none
  let versionText := (text.drop canonicalLeanToolchainPrefix.length).toString
  let [majorText, minorText] := versionText.splitOn "."
    | none
  let major ← canonicalNat? majorText
  let minor ← canonicalNat? minorText
  let line : LeanReleaseLine := { major, minor }
  if line.registryEntry == text then some line else none

structure CanonicalLeanToolchain where
  releaseLine : LeanReleaseLine
  patch : Nat
  rc? : Option Nat := none
  deriving BEq, Repr

def CanonicalLeanToolchain.versionText (toolchain : CanonicalLeanToolchain) : String :=
  let stable := s!"{toolchain.releaseLine.versionText}.{toolchain.patch}"
  match toolchain.rc? with
  | some rc => s!"{stable}-rc{rc}"
  | none => stable

def CanonicalLeanToolchain.name (toolchain : CanonicalLeanToolchain) : String :=
  canonicalLeanToolchainPrefix ++ toolchain.versionText

private def parseLeanPrerelease? (text : String) : Option Nat := do
  unless text.startsWith "rc" do
    none
  let numberText := (text.drop 2).toString
  let rc ← canonicalNat? numberText
  if rc > 0 && s!"rc{rc}" == text then some rc else none

private def parseCanonicalLeanVersion?
    (versionText : String)
    (rc? : Option Nat) : Option CanonicalLeanToolchain := do
  let [majorText, minorText, patchText] := versionText.splitOn "."
    | none
  let major ← canonicalNat? majorText
  let minor ← canonicalNat? minorText
  let patch ← canonicalNat? patchText
  some { releaseLine := { major, minor }, patch, rc? }

def parseCanonicalLeanToolchain? (text : String) : Option CanonicalLeanToolchain := do
  unless text.startsWith canonicalLeanToolchainPrefix do
    none
  let versionText := (text.drop canonicalLeanToolchainPrefix.length).toString
  let parsed ←
    match versionText.splitOn "-" with
    | [stable] => parseCanonicalLeanVersion? stable none
    | [stable, prerelease] => do
        let rc ← parseLeanPrerelease? prerelease
        parseCanonicalLeanVersion? stable (some rc)
    | _ => none
  if parsed.name == text then some parsed else none

def validatedLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := validatedLeanToolchainsPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing validated Lean toolchain registry at {path}"
  let mut toolchains := []
  for entry in nonCommentLines (← IO.FS.readFile path) do
    unless (parseCanonicalLeanToolchain? entry).isSome do
      throw <| IO.userError s!"invalid validated Lean toolchain in {path}: {entry}"
    if toolchains.elem entry then
      throw <| IO.userError s!"duplicate validated Lean toolchain in {path}: {entry}"
    toolchains := toolchains ++ [entry]
  pure (path, toolchains)

def compatibleLeanReleaseLines (home : System.FilePath) : IO (System.FilePath × List LeanReleaseLine) := do
  let path := compatibleLeanReleaseLinesPath home
  unless ← path.pathExists do
    throw <| IO.userError s!"missing compatible Lean release-line registry at {path}"
  let mut lines := []
  for entry in nonCommentLines (← IO.FS.readFile path) do
    let some line := parseLeanReleaseLine? entry
      | throw <| IO.userError s!"invalid compatible Lean release line in {path}: {entry}"
    if lines.elem line then
      throw <| IO.userError s!"duplicate compatible Lean release line in {path}: {entry}"
    lines := lines ++ [line]
  pure (path, lines)

def customLeanToolchains (home : System.FilePath) : IO (System.FilePath × List String) := do
  let path := customLeanToolchainsPath home
  unless ← path.pathExists do
    return (path, [])
  pure (path, nonCommentLines (← IO.FS.readFile path))

inductive LeanToolchainAcceptance where
  | validated
  | releaseLine (line : LeanReleaseLine)
  | custom
  | unsupported
  deriving BEq, Repr

def LeanToolchainAcceptance.accepted : LeanToolchainAcceptance → Bool
  | .validated => true
  | .releaseLine _ => true
  | .custom => true
  | .unsupported => false

def LeanToolchainAcceptance.label : LeanToolchainAcceptance → String
  | .validated => "validated"
  | .releaseLine _ => "release-line"
  | .custom => "custom"
  | .unsupported => "unsupported"

def LeanToolchainAcceptance.releaseLine? : LeanToolchainAcceptance → Option LeanReleaseLine
  | .releaseLine line => some line
  | _ => none

structure LeanToolchainSupport where
  validatedPath : System.FilePath
  compatiblePath : System.FilePath
  customPath : System.FilePath
  acceptance : LeanToolchainAcceptance
  deriving Repr

def leanToolchainSupport (home : System.FilePath) (toolchain : String) : IO LeanToolchainSupport := do
  let (validatedPath, validatedToolchains) ← validatedLeanToolchains home
  let (compatiblePath, compatibleReleaseLines) ← compatibleLeanReleaseLines home
  let (customPath, customToolchains) ← customLeanToolchains home
  let acceptance :=
    if isMovingLeanToolchain toolchain then
      .unsupported
    else if validatedToolchains.elem toolchain then
      .validated
    else
      match parseCanonicalLeanToolchain? toolchain with
      | some canonical =>
          if compatibleReleaseLines.elem canonical.releaseLine then
            .releaseLine canonical.releaseLine
          else if customToolchains.elem toolchain then
            .custom
          else
            .unsupported
      | none =>
          if customToolchains.elem toolchain then .custom else .unsupported
  pure {
    validatedPath
    compatiblePath
    customPath
    acceptance
  }

def ensureAcceptedLeanToolchain (home : System.FilePath) (toolchain : String) : IO Unit := do
  let support ← leanToolchainSupport home toolchain
  unless support.acceptance.accepted do
    throw <| IO.userError <| String.intercalate "\n" [
      s!"unsupported Lean toolchain: {toolchain}",
      s!"validated toolchain registry: {support.validatedPath}",
      s!"compatible release-line registry: {support.compatiblePath}",
      s!"custom toolchain registry: {support.customPath}",
      "run `lean-beam validated-toolchains` to list the validated toolchains",
      "run `lean-beam compatible-release-lines` to list canonical RC and patch release lines",
      "for local Lean development toolchains, reinstall Beam with `./scripts/install-beam.sh --custom-toolchain TOOLCHAIN`"
    ]

end Beam.Cli
