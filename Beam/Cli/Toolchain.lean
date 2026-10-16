/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Elab.Term
import Lake.Build.Targets
import Beam.Cli.Toolchain.Options
import Beam.Path
import Beam.System
import Beam.LSP.Lib.NativeLib

open Lean

namespace Beam.Cli.Toolchain

elab "toolchainBuildMode" : term => do
  let stx ← if (← getOptions).getBool `beam.toolchain false then `(term| true) else `(term| false)
  Lean.Elab.Term.elabTerm stx none

/-- Fixed at build time; runtime environment variables cannot change this policy. -/
def enabled : Bool := toolchainBuildMode

elab "lakeDeferredCompilationCapability" : term => do
  let stx ← if (← getEnv).contains (.str `Lake.ModuleOutputDescrs "c?") then
    `(term| true) else `(term| false)
  Lean.Elab.Term.elabTerm stx none

/-- Build-time capability used by native distribution qualification. -/
def lakeSupportsDeferredCompilation : Bool := lakeDeferredCompilationCapability

def sysroot : IO System.FilePath := do
  let app ← Beam.resolveExistingPath (← IO.appPath)
  let some bin := app.parent | throw <| IO.userError "missing Beam executable directory"
  let some root := bin.parent | throw <| IO.userError "missing Beam toolchain directory"
  pure root

def home : IO System.FilePath := do
  pure <| (← sysroot) / "lib" / "lean-beam"

def executable (name : String) : IO System.FilePath := do
  let suffix := if System.Platform.isWindows then ".exe" else ""
  pure <| (← sysroot) / "bin" / (name ++ suffix)

structure Provenance where
  schemaVersion : Nat
  sourceCommit : String
  payloadHash : String
  leanVersion : String
  leanGithash : String
  lakeVersion : String
  deriving FromJson, ToJson

def provenance : IO Provenance := do
  let path := (← home) / "provenance.json"
  let p ← IO.ofExcept <| Json.parse (← IO.FS.readFile path) >>= fromJson? (α := Provenance)
  unless p.schemaVersion == 1 && !p.payloadHash.isEmpty && p.leanGithash == Lean.githash do
    throw <| IO.userError s!"invalid bundled Beam provenance at {path}; reinstall this toolchain"
  pure p

def version : IO String := do
  pure (← provenance).leanVersion

def projectLean (root : System.FilePath) : IO System.FilePath := do
  let lean ← executable "lean"
  let p ← provenance
  unless (← Beam.readCmdTrim lean.toString #["--githash"]) == p.leanGithash do
    throw <| IO.userError
      "bundled Beam and Lean use different compiler builds; reinstall this toolchain"
  if ← (root / "lean-toolchain").pathExists then
    let selector := Beam.trimLine (← IO.FS.readFile (root / "lean-toolchain"))
    let out ← try
      IO.Process.output {
        cmd := "elan"
        args := #["run", selector, "lean", "--print-prefix"]
        cwd := root.toString
        -- Inspect the selected executable's own installation, rather than an ambient sysroot.
        env := #[("LEAN_SYSROOT", none)]
      }
    catch _ =>
      throw <| IO.userError <|
        "cannot resolve the project's lean-toolchain selector; install elan to resolve it, " ++
        "then use lean-beam from the project's toolchain"
    let selectedLean := System.FilePath.mk (Beam.trimLine out.stdout) / "bin" /
      lean.fileName.getD "lean"
    unless out.exitCode == 0 && (← Beam.sameFilePath lean selectedLean) do
      throw <| IO.userError <|
        "project does not select the bundled Lean installation; use lean-beam from the project's toolchain. " ++
        s!"Bundled Lean: {lean}. Inspect the project's selector with `elan run SELECTOR lean --print-prefix`."
  pure lean

def daemon : IO System.FilePath := do
  let suffix := if System.Platform.isWindows then ".exe" else ""
  pure <| (← sysroot) / "bin" / ("beam-daemon" ++ suffix)

def plugin : IO System.FilePath := do
  pure <| Beam.LSP.Lib.pluginSharedLibPath (← home)

def runtimeId : IO String := do
  let p ← provenance
  pure s!"toolchain:{p.payloadHash}:{p.leanGithash}"

end Beam.Cli.Toolchain
