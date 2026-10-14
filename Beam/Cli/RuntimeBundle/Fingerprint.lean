/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.RuntimeBundle.Source
import Beam.Cli.RuntimeBundle.ToolchainPolicy
import Beam.System

open Lean

namespace Beam.Cli

structure ToolchainFingerprint where
  leanVersion : String
  leanPrefix : String
  leanLibDir : String
  lakeVersion : String
  deriving BEq, Repr, FromJson, ToJson

/-- Reuse the installation fingerprinted for the bundle instead of selecting a compiler again. -/
def ToolchainFingerprint.leanCommand (fingerprint : ToolchainFingerprint) : String :=
  let suffix := if System.Platform.isWindows then ".exe" else ""
  ((System.FilePath.mk fingerprint.leanPrefix) / "bin" / ("lean" ++ suffix)).toString

def bundlePlatform : IO String := do
  let system := ← Beam.readCmdTrim "uname" #["-s"]
  let machine := ← Beam.readCmdTrim "uname" #["-m"]
  pure s!"{system.toLower}-{machine.toLower}"

def ensureElan : IO Unit := do
  unless ← Beam.commandAvailable "elan" do
    throw <| IO.userError "missing elan on PATH"

private def readRequiredToolchainCmdTrim (toolchain exe : String) (args : Array String := #[]) :
    IO String := do
  let out ← IO.Process.output {
    cmd := "elan"
    args := #["run", toolchain, exe] ++ args
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

def toolchainFingerprintKey (fingerprint : ToolchainFingerprint) : String :=
  String.intercalate "\n" [
    "lean-version", fingerprint.leanVersion,
    "lean-prefix", fingerprint.leanPrefix,
    "lean-libdir", fingerprint.leanLibDir,
    "lake-version", fingerprint.lakeVersion
  ]

def toolchainFingerprintHash (fingerprint : ToolchainFingerprint) : String :=
  s!"{hashString (toolchainFingerprintKey fingerprint) |>.toNat}"

def expectedCanonicalLeanVersionPrefix? (toolchain : String) : Option String := do
  let canonical ← parseCanonicalLeanToolchain? toolchain
  some s!"Lean (version {canonical.versionText},"

def toolchainFingerprint (toolchain : String) : IO ToolchainFingerprint := do
  ensureElan
  let leanVersion ← readRequiredToolchainCmdTrim toolchain "lean" #["--version"]
  if let some expectedPrefix := expectedCanonicalLeanVersionPrefix? toolchain then
    unless leanVersion.startsWith expectedPrefix do
      throw <| IO.userError <| String.intercalate "\n" [
        s!"Lean toolchain name/version mismatch: {toolchain}",
        s!"expected `lean --version` to start with: {expectedPrefix}",
        s!"actual `lean --version`: {leanVersion}"
      ]
  let leanPrefix ← readRequiredToolchainCmdTrim toolchain "lean" #["--print-prefix"]
  let leanLibDir ← readRequiredToolchainCmdTrim toolchain "lean" #["--print-libdir"]
  let lakeVersion ← readRequiredToolchainCmdTrim toolchain "lake" #["--version"]
  pure {
    leanVersion
    leanPrefix
    leanLibDir
    lakeVersion
  }

def bundleIdFor (toolchain : String) (fingerprint : ToolchainFingerprint) (source platformKey : String) :
    String :=
  let acc := mixField 14695981039346656037 toolchain
  let acc := mixField acc (toolchainFingerprintKey fingerprint)
  let acc := mixField acc source
  let acc := mixField acc platformKey
  s!"{acc.toNat}"

def bundleDirForFingerprint (cacheRoot home : System.FilePath) (toolchain : String)
    (fingerprint : ToolchainFingerprint) : IO (System.FilePath × String × String) := do
  let platformKey ← bundlePlatform
  let srcHash ← sourceHash home
  let bundleId := bundleIdFor toolchain fingerprint srcHash platformKey
  pure (cacheRoot / platformKey / bundleId, bundleId, srcHash)

def bundleDirFor (cacheRoot home : System.FilePath) (toolchain : String) :
    IO (System.FilePath × String × String × ToolchainFingerprint) := do
  let fingerprint ← toolchainFingerprint toolchain
  let (bundleDir, bundleId, srcHash) ← bundleDirForFingerprint cacheRoot home toolchain fingerprint
  pure (bundleDir, bundleId, srcHash, fingerprint)

end Beam.Cli
