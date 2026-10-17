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
import Beam.Runtime
import Beam.Installation.Components
import Beam.BuildInfo
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
  buildId : String
  payloadHash : String
  components : Beam.Installation.Components
  artifacts : Array Beam.Installation.Artifact
  deriving BEq, FromJson, ToJson

def Provenance.leanGithash (p : Provenance) : String :=
  p.components.frontends.compilerRevision

def Provenance.leanVersion (p : Provenance) : String :=
  String.intercalate ", " (p.components.targets.toList.map (·.leanVersion))

def Provenance.lakeVersion (p : Provenance) : String :=
  String.intercalate ", " (p.components.targets.toList.map (·.lakeVersion))

/-- Published generation identity; descriptions are not a substitute for the artifact identity. -/
def Provenance.sameGeneration (left right : Provenance) : Bool :=
  left.buildId == right.buildId && left.sourceCommit == right.sourceCommit &&
    left.payloadHash == right.payloadHash && left.leanGithash == right.leanGithash

inductive ResolutionError where
  | invalidProvenance (path : System.FilePath) (detail : String)
  | io (error : IO.Error)

def ResolutionError.message : ResolutionError → String
  | .invalidProvenance path detail =>
      s!"invalid bundled Beam provenance at {path}: {detail}; reinstall this toolchain"
  | .io error => error.toString

def validateProvenance (path : System.FilePath) (compiled : Beam.BuildInfo.Identity)
    (loadedRevision : String) (p : Provenance) : Except ResolutionError Unit := do
  unless p.schemaVersion == 3 && !p.payloadHash.isEmpty && !p.buildId.isEmpty &&
      p.buildId == compiled.buildId && p.sourceCommit == compiled.sourceRevision do
    throw <| .invalidProvenance path "schema or Beam build generation does not match this executable; restart after reinstalling"
  (p.components.validate p.artifacts).mapError (ResolutionError.invalidProvenance path)
  unless p.components.targets.size == 1 &&
      p.components.targets.all (fun target => target.compilerRevision == p.leanGithash) do
    throw <| .invalidProvenance path "bundled target does not match its construction record"
  unless Beam.compilerRevisionsMatch compiled.compilerRevision loadedRevision p.leanGithash do
    throw <| .invalidProvenance path "compiled-against and loaded Lean compiler revisions do not match"

def Layout.readProvenance (sdk : Layout) : IO (Except ResolutionError Provenance) := do
  let path := sdk.home / "provenance.json"
  try
    let parsed := Json.parse (← IO.FS.readFile path) >>= fromJson? (α := Provenance)
    pure do
      let p ← parsed.mapError (ResolutionError.invalidProvenance path)
      validateProvenance path Beam.BuildInfo.compiled Lean.githash p
      pure p
  catch error => pure <| .error <| .io error

end Beam.Cli.Toolchain
