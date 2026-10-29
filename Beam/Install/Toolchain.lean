/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Installation.ToolchainPolicy
import Beam.Installation.Components
import Beam.Path
import Beam.System

open Lean

namespace Beam.Install

structure ToolchainFingerprint where
  leanVersion : String
  leanPrefix : String
  leanLibDir : String
  lakeVersion : String
  compilerRevision : String
  deriving BEq, Repr, FromJson, ToJson

def ensureElan : IO Unit := do
  unless ← Beam.commandAvailable "elan" do
    throw <| IO.userError "missing elan on PATH"

private def readRequiredToolchainCmdTrim (toolchain exe : String) (args : Array String := #[]) :
    IO String := do
  let out ← IO.Process.output {
    cmd := "elan"
    args := #["run", toolchain, exe] ++ args
    env := #[("LEAN_SYSROOT", none)]
  }
  if out.exitCode != 0 then
    throw <| IO.userError <| String.intercalate "\n" [
      s!"failed to fingerprint Lean toolchain {toolchain}",
      s!"command: elan run {toolchain} {exe} {String.intercalate " " args.toList}",
      "",
      "stdout:",
      if out.stdout.trimAscii.isEmpty then "(empty)" else out.stdout,
      "",
      "stderr:",
      if out.stderr.trimAscii.isEmpty then "(empty)" else out.stderr
    ]
  let text := Beam.trimLine out.stdout
  if text.isEmpty then
    throw <| IO.userError
      s!"failed to fingerprint Lean toolchain {toolchain}: `elan run {toolchain} {exe}` returned empty stdout"
  pure text

/-- A canonical selector must name the compiler that `lean --version` reports. -/
def expectedCanonicalLeanVersionPrefix? (toolchain : String) : Option String := do
  some s!"Lean (version {← Beam.Installation.ToolchainPolicy.canonicalLeanVersion? toolchain},"

/-- Observe one already selected SDK; every command uses this concrete installation. -/
def fingerprintLeanInstallation (root : System.FilePath) : IO ToolchainFingerprint := do
  let leanPrefix ← Beam.resolveExistingPath root
  let readSelected := fun (exe : String) (args : Array String) => do
    let command := leanPrefix / "bin" / (exe ++ if System.Platform.isWindows then ".exe" else "")
    let out ← IO.Process.output {
      cmd := command.toString, args, env := #[("LEAN_SYSROOT", none)]
    }
    unless out.exitCode == 0 && !out.stdout.trimAscii.isEmpty do
      throw <| IO.userError s!"selected compiler command failed: {command}\n{out.stderr}"
    pure <| Beam.trimLine out.stdout
  let leanVersion ← readSelected "lean" #["--version"]
  let leanLibDir ← readSelected "lean" #["--print-libdir"]
  let lakeVersion ← readSelected "lake" #["--version"]
  let compilerRevision ← readSelected "lean" #["--githash"]
  unless Beam.Installation.hexDigest 40 compilerRevision do
    throw <| IO.userError "selected Lean must report an exact compiler revision"
  pure {
    leanVersion
    leanPrefix := leanPrefix.toString
    leanLibDir
    lakeVersion
    compilerRevision
  }

def toolchainFingerprint (toolchain : String) : IO ToolchainFingerprint := do
  ensureElan
  let leanPrefix ← Beam.resolveExistingPath <| System.FilePath.mk
    (← readRequiredToolchainCmdTrim toolchain "lean" #["--print-prefix"])
  let fingerprint ← fingerprintLeanInstallation leanPrefix
  if let some expectedPrefix := expectedCanonicalLeanVersionPrefix? toolchain then
    unless fingerprint.leanVersion.startsWith expectedPrefix do
      throw <| IO.userError <| String.intercalate "\n" [
        s!"Lean toolchain name/version mismatch: {toolchain}",
        s!"expected `lean --version` to start with: {expectedPrefix}",
        s!"actual `lean --version`: {fingerprint.leanVersion}"
      ]
  pure fingerprint

end Beam.Install
