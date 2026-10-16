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
import Beam.Cli.DaemonConfig
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

/-- Paths belonging to one containing SDK. Only the installation adapter interprets this layout. -/
structure Layout where
  root : System.FilePath

def Layout.home (sdk : Layout) : System.FilePath := sdk.root / "lib" / "lean-beam"

def Layout.executable (sdk : Layout) (name : String) : System.FilePath :=
  sdk.root / "bin" / (name ++ if System.Platform.isWindows then ".exe" else "")

def Layout.plugin (sdk : Layout) : System.FilePath :=
  Beam.LSP.Lib.pluginSharedLibPath sdk.home

def locate : IO Layout := do
  let app ← Beam.resolveExistingPath (← IO.appPath)
  let some bin := app.parent | throw <| IO.userError "missing Beam executable directory"
  let some sdkRoot := bin.parent | throw <| IO.userError "missing Beam toolchain directory"
  pure { root := sdkRoot }

structure Provenance where
  schemaVersion : Nat
  sourceCommit : String
  payloadHash : String
  leanVersion : String
  leanGithash : String
  lakeVersion : String
  deriving FromJson, ToJson

inductive ResolutionError where
  | invalidProvenance (path : System.FilePath) (detail : String)
  | compilerMismatch
  | selectorUnavailable (selector : String)
  | selectorMismatch (bundled selected : System.FilePath)
  | missingArtifact (kind : String) (path : System.FilePath)
  | io (error : IO.Error)

def ResolutionError.message : ResolutionError → String
  | .invalidProvenance path detail =>
      s!"invalid bundled Beam provenance at {path}: {detail}; reinstall this toolchain"
  | .compilerMismatch =>
      "bundled Beam and Lean use different compiler builds; reinstall this toolchain"
  | .selectorUnavailable selector =>
      s!"cannot resolve the project's lean-toolchain selector '{selector}'; install or link it with elan, then use lean-beam from the project's toolchain"
  | .selectorMismatch bundled _ =>
      "project does not select the bundled Lean installation; use lean-beam from the project's toolchain. " ++
        s!"Bundled Lean: {bundled}. Inspect the project's selector with `elan run SELECTOR lean --print-prefix`."
  | .missingArtifact kind path => s!"missing {kind} at {path}"
  | .io error => error.toString

def validateProvenance (path : System.FilePath) (p : Provenance) : Except ResolutionError Unit := do
  unless p.schemaVersion == 1 && !p.payloadHash.isEmpty && p.leanGithash == Lean.githash do
    throw <| .invalidProvenance path "schema, payload or compiler identity does not match"

def Layout.readProvenance (sdk : Layout) : IO (Except ResolutionError Provenance) := do
  let path := sdk.home / "provenance.json"
  try
    let parsed := Json.parse (← IO.FS.readFile path) >>= fromJson? (α := Provenance)
    pure do
      let p ← parsed.mapError (ResolutionError.invalidProvenance path)
      validateProvenance path p
      pure p
  catch error => pure <| .error <| .io error

/-- Immutable observations from a single operation. The declared selector is not a version label. -/
structure Facts where
  layout : Layout
  provenance : Provenance
  compilerGithash : String
  canonicalLean : System.FilePath
  declaredSelection? : Option (String × System.FilePath)

/-- Pure admission policy: a selector must name this installation, not merely an equal compiler. -/
def validate (root : System.FilePath) (facts : Facts) : Except ResolutionError DesiredConfig := do
  let p := facts.provenance
  validateProvenance (facts.layout.home / "provenance.json") p
  unless facts.compilerGithash == p.leanGithash do
    throw .compilerMismatch
  if let some (_, selected) := facts.declaredSelection? then
    unless selected == facts.canonicalLean do
      throw <| .selectorMismatch (facts.layout.executable "lean") selected
  pure {
    root
    lean := {
      command := (facts.layout.executable "lean").toString
      plugin := facts.layout.plugin
      toolchain := p.leanVersion
      bundleId := s!"toolchain:{p.payloadHash}:{p.leanGithash}"
    }
    daemonBin := facts.layout.executable "beam-daemon"
  }

/-- Observe once for this operation, then apply the pure admission policy. No process-wide cache. -/
def Layout.resolve (sdk : Layout) (root : System.FilePath) :
    IO (Except ResolutionError (Provenance × DesiredConfig)) := do
  try
    let p ← match ← sdk.readProvenance with
      | .ok p => pure p
      | .error error => return .error error
    let lean := sdk.executable "lean"
    let compilerGithash ← Beam.readCmdTrim lean.toString #["--githash"]
    let canonicalLean ← Beam.resolveExistingPath lean
    let declaredSelection? ← if ← (root / "lean-toolchain").pathExists then do
      let selector := Beam.trimLine (← IO.FS.readFile (root / "lean-toolchain"))
      let selected ← try
        IO.Process.output {
          cmd := "elan"
          args := #["run", selector, "lean", "--print-prefix"]
          cwd := root.toString
          env := #[("LEAN_SYSROOT", none)]
        }
      catch _ => return .error <| .selectorUnavailable selector
      unless selected.exitCode == 0 do
        return .error <| .selectorUnavailable selector
      let selectedLean := System.FilePath.mk (Beam.trimLine selected.stdout) / "bin" /
        lean.fileName.getD "lean"
      let selectedLean ← try Beam.resolveExistingPath selectedLean
        catch _ => return .error <| .selectorUnavailable selector
      pure <| some (selector, selectedLean)
    else pure none
    let facts : Facts := {
      layout := sdk
      provenance := p
      compilerGithash
      canonicalLean
      declaredSelection?
    }
    let desired ← match validate root facts with
      | .ok desired => pure desired
      | .error error => return .error error
    for (kind, path) in [("Beam daemon", desired.daemonBin), ("Beam LSP plugin", desired.lean.plugin)] do
      unless ← path.pathExists do return .error <| .missingArtifact kind path
    pure <| .ok (p, desired)
  catch error => pure <| .error <| .io error

end Beam.Cli.Toolchain
