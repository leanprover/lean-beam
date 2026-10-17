/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.InstallLayout
import Beam.Cli.Toolchain
import Beam.Installation.LocalTarget
import Beam.Runtime
import Beam.Version

namespace Beam.Cli

namespace Installation

inductive Role where
  | cli | mcp | daemon
  deriving BEq

inductive Failure where
  | invalid (detail : String)
  | changed
  | unavailable (command : System.FilePath)
  | noTarget
  | selection (error : Beam.Installation.LocalTarget.Failure)
  | io (error : IO.Error)

def Failure.message : Failure → String
  | .invalid detail => s!"invalid Beam installation: {detail}; reinstall Beam before starting runtime work"
  | .changed => "Beam installation generation changed; restart with a complete installation"
  | .unavailable command =>
      s!"project target {command} is not a member of this Beam installation; install Beam for that target"
  | .noTarget => "missing project lean-toolchain; select an exact installed target before starting standalone Beam"
  | .selection error => error.message
  | .io error => error.toString

private inductive Record where
  | standalone (manifest : InstallManifest)
  | bundled (provenance : Toolchain.Provenance)
  deriving BEq

private def Record.components : Record → Beam.Installation.Components
  | .standalone m => m.components
  | .bundled p => p.components

private def Record.artifacts : Record → Array Beam.Installation.Artifact
  | .standalone m => m.artifacts
  | .bundled p => p.artifacts

private def Record.generation : Record → String
  | .standalone m => m.payloadHash
  | .bundled p => s!"{p.buildId}:{p.payloadHash}"

private def Record.sourceCommit? : Record → Option String
  | .standalone m => m.sourceCommit
  | .bundled p => some p.sourceCommit

private def equalPath (left right : System.FilePath) : Bool :=
  let key := fun (path : System.FilePath) =>
    if System.Platform.isWindows then path.normalize.toString.toLower else path.toString
  key left == key right

private def require (condition : Bool) (detail : String) : Except Failure Unit :=
  unless condition do throw (.invalid detail)

private def readRecord (root : System.FilePath) (bundled : Bool) : IO (Except Failure Record) := do
  try
    if bundled then
      let layout : Toolchain.Layout := ⟨root⟩
      return (← layout.readProvenance).map .bundled |>.mapError (fun error => .invalid error.message)
    let path := root / "manifest.json"
    unless ← Beam.regularNonSymlinkFile path do return .error (.invalid "missing regular manifest.json")
    let manifest ← readInstallManifest path
    return .ok (.standalone manifest)
  catch error => return .error (.io error)

private def memberPath (root : System.FilePath) (relative : String) : IO System.FilePath := do
  let path := root / relative
  unless ← Beam.regularNonSymlinkFile path do
    throw <| IO.userError s!"missing regular component: {path}"
  let canonical ← Beam.resolveExistingPath path
  unless equalPath canonical path do
    throw <| IO.userError s!"component escapes its recorded path: {path}"
  pure canonical

private def targetCommand (root : System.FilePath) (bundled : Bool)
    (target : Beam.Installation.Target) : IO System.FilePath := do
  let path := System.FilePath.mk target.lean
  if bundled then
    unless !path.isAbsolute && target.lean ==
        (if System.Platform.isWindows then "bin/lean.exe" else "bin/lean") do
      throw <| IO.userError "bundled target must name the containing Lean executable"
    return ← memberPath root target.lean
  unless path.isAbsolute do throw <| IO.userError "standalone target Lean path is not absolute"
  let command ← Beam.resolveExistingPath path
  unless equalPath command path && (← command.metadata).type == .file do
    throw <| IO.userError s!"recorded target Lean path changed: {path}"
  pure command

private def checkRecord (root app : System.FilePath) (role : Role) (bundled : Bool)
    (record : Record) : IO (Except Failure Unit) := do
  try
    let components := record.components
    for artifact in record.artifacts do discard <| memberPath root artifact.destination
    let cli ← memberPath root components.frontends.cli
    let mcp ← memberPath root components.frontends.mcp
    let mut expectedRevision := components.frontends.compilerRevision
    let mut ownRole := match role with
      | .cli => equalPath app cli
      | .mcp => equalPath app mcp
      | .daemon => false
    let mut commands : Array System.FilePath := #[]
    for target in components.targets do
      let command ← targetCommand root bundled target
      if commands.any (equalPath command) then return .error (.invalid "duplicate canonical target Lean path")
      commands := commands.push command
      let daemon ← memberPath root target.daemon
      discard <| memberPath root target.plugin
      if role == .daemon && equalPath app daemon then
        ownRole := true
        expectedRevision := target.compilerRevision
    return do
      require ownRole "this executable does not occupy its recorded installation role"
      require (Beam.compilerRevisionsMatch Beam.compiledCompilerRevision Lean.githash expectedRevision)
        "compiled-against, loaded, and recorded compiler revisions differ"
  catch error => return .error (.io error)

end Installation

/-- A process is anchored to one concrete installation and its original record, never `current`. -/
structure Installation where
  private mk ::
  home : System.FilePath
  private app : System.FilePath
  private role : Installation.Role
  bundled : Bool
  private snapshot : Except Installation.Failure Installation.Record

namespace Installation

/-- Establish a process binding. Library fixtures may supply an executable; shipped mains use appPath. -/
def openExecutable (executable : System.FilePath) (role : Role) (bundled : Bool) : IO Installation := do
  let app ← Beam.resolveExistingPath executable
  let directory := app.parent.getD app
  let root := if bundled || role != .daemon then directory.parent.getD directory else
    (directory.parent >>= System.FilePath.parent >>= System.FilePath.parent).getD directory
  let snapshot ← readRecord root bundled
  let snapshot ← match snapshot with
    | .error error => pure (.error error)
    | .ok record => pure <| (← checkRecord root app role bundled record).map (fun _ => record)
  pure ⟨root, app, role, bundled, snapshot⟩

def current (role : Role := .cli) : IO Installation := do
  openExecutable (← IO.appPath) role Toolchain.enabled

private def observe (installation : Installation) : IO (Except Failure Record) := do
  let original ← match installation.snapshot with
    | .ok original => pure original
    | .error error => return .error error
  let current ← readRecord installation.home installation.bundled
  match current with
  | .error error => return .error error
  | .ok current =>
      unless original == current do return .error .changed
      return (← checkRecord installation.home installation.app installation.role installation.bundled current).map
        (fun _ => original)

/-- Only the installation adapter can mint references; execution receives their complete description. -/
structure RuntimeRef where
  private mk ::
  description : Beam.Runtime.Description

/-- Exact local lookup; no compiler probe, provider search, or provisioning is possible here. -/
def lookup (installation : Installation) (root : System.FilePath) : IO (Except Failure RuntimeRef) := do
  let record ← match ← installation.observe with
    | .ok record => pure record
    | .error error => return .error error
  let selected ← Beam.Installation.LocalTarget.resolve root (← Beam.Installation.LocalTarget.elanHome)
  let selected ← match selected with
    | .error error => return .error (.selection error)
    | .ok selected => pure selected
  try
    for target in record.components.targets do
      let command ← targetCommand installation.home installation.bundled target
      if selected.any (equalPath command) || (selected.isNone && installation.bundled) then
        let plugin ← memberPath installation.home target.plugin
        let daemonBin ← memberPath installation.home target.daemon
        if installation.role == .daemon && !equalPath installation.app daemonBin then
          return .error (.invalid "this target belongs to a different installation-owned daemon")
        return .ok ⟨{
          command := command.toString, plugin, daemonBin, toolchain := target.toolchain
          identity := ⟨s!"installation:{installation.home}:{record.generation}"⟩
        }⟩
    return .error <| match selected with
      | some command => .unavailable command
      | none => .noTarget
  catch error => return .error (.io error)

def readIdentity (installation : Installation) (base : Beam.Version.Identity) : IO Beam.Version.Identity := do
  let record ← IO.ofExcept <| (← installation.observe).mapError (IO.userError ∘ Failure.message)
  pure { base with
    beamHome? := some installation.home.toString
    beamCli? := some (installation.home / record.components.frontends.cli).toString
    runtimePayload? := some record.generation
    sourceCommit? := record.sourceCommit?
    manifest? := some (installation.home /
      (if installation.bundled then "lib/lean-beam/provenance.json" else "manifest.json")).toString
    bundledLean? := if installation.bundled then record.components.targets.toList.head?.map (·.leanVersion) else none
  }

end Installation
end Beam.Cli
