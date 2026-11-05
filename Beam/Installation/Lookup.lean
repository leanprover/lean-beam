/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Installation.Manifest
import Beam.Installation.Bundled
import Beam.Installation.LocalTarget
import Beam.Installation.StandaloneLayout
import Beam.Installation.ToolchainPolicy
import Beam.Project
import Beam.Runtime
import Beam.Version

namespace Beam

namespace Installation

inductive Role where
  | cli | mcp | daemon
  deriving BEq

/-- Observed installation context, used only to decide which remedy guidance is appropriate. -/
inductive TargetInstallContext where
  | bundled
  | unrecognized
  | current (installRoot : System.FilePath)
  | unconfirmed (installRoot : System.FilePath)
  deriving BEq

/-- The unavailable selected target and the complete installation it was checked against. -/
structure UnavailableTarget where
  selected : LocalTarget.Selection
  installationRoot : System.FilePath
  installContext : TargetInstallContext := .unrecognized
  retainedTargets : Array String
  sourceCommit? : Option String

inductive TargetRemedy where
  | install (command precondition : String)
  | manual (detail : String)

def TargetRemedy.command? : TargetRemedy → Option String
  | .install command _ => some command
  | .manual _ => none

private def quoteArgument (text : String) : String :=
  "'" ++ text.replace "'" "'\\''" ++ "'"

/-- Only suggest commands the existing source installer accepts; never execute a candidate. -/
private def installerTargetArguments (toolchain : String) : Except String (List String) := do
  if toolchain.isEmpty || toolchain.toList.any (fun c => c.isWhitespace || c.toNat < 32) then
    throw "the installer requires a nonempty Elan toolchain name without whitespace"
  if (System.FilePath.mk toolchain).isAbsolute ||
      ["./", "../", ".\\", "..\\"].any (fun start => toolchain.startsWith start) then
    throw "a filesystem selector must be registered under an Elan link name before installation"
  if Beam.Installation.ToolchainPolicy.releaseToolchainSupported toolchain then
    return ["--toolchain", toolchain]
  if toolchain.startsWith "leanprover/lean4:" then
    throw <| s!"this Beam revision does not support official target '{toolchain}' for installation. " ++
      "Use a Beam revision that supports the project's existing Lean toolchain; " ++
      "leave the project's lean-toolchain and dependency pins unchanged"
  return ["--custom-toolchain", toolchain]

def UnavailableTarget.remedy (target : UnavailableTarget) : TargetRemedy := Id.run do
  if let some requested := target.selected.installerToolchain? then
    if let .error detail := installerTargetArguments requested then return .manual detail
  if let .bundled := target.installContext then
    return .manual <| "bundled Beam serves only its containing Lean installation; use Beam bundled " ++
      "with the selected SDK, or construct a separate standalone Beam installation for that target"
  if let .unconfirmed installRoot := target.installContext then
    return .manual <| s!"this bound generation could not be confirmed as current for {installRoot}; " ++
      "inspect the current installation before choosing the complete target set to retain. " ++
      "No reinstall command was generated from this older or unconfirmed selection"
  let .current installRoot := target.installContext
    | return .manual <| "this installation has no recognized standalone installer location; " ++
        "use a Beam source checkout to construct an installation containing the selected target and all retained targets"
  let some requested := target.selected.installerToolchain?
    | return .manual <| "the source installer accepts Elan toolchain names, not project-local SDK paths; " ++
        "link this SDK with `elan toolchain link NAME SDK_ROOT`, then install it with --custom-toolchain NAME " ++
        "alongside every retained target"
  let mut names := target.retainedTargets.toList
  unless names.contains requested do names := names ++ [requested]
  let mut arguments := []
  for name in names do
    match installerTargetArguments name with
    | .error detail => return .manual <| detail ++ "; no installer command was generated that would drop retained targets"
    | .ok flags => arguments := arguments ++ flags
  let command := "BEAM_INSTALL_ROOT=" ++ quoteArgument installRoot.toString ++
    " ./scripts/install-beam.sh " ++ String.intercalate " " (arguments.map quoteArgument)
  let revision := target.sourceCommit?.map (fun commit => s!" at revision {commit}") |>.getD ""
  return .install command <| s!"From a Beam source checkout{revision}, run this POSIX-shell command. " ++
    "It includes the inspected generation's targets. Before running it, confirm that the current target set " ++
    "still matches this snapshot; the installer replaces the complete selection and will show its write plan. " ++
    "Restart Beam clients to use the newly installed target set."

/-- Render the explanation without embedding the separately typed remedy command. -/
def UnavailableTarget.explanation (target : UnavailableTarget) (remedy : TargetRemedy) : String :=
  let selected := target.selected
  let message := s!"This Beam installation has no runtime for {selected.command}. " ++
    s!"The project's Lean compiler was found via selector '{selected.text}' in {selected.path}; " ++
    s!"bound Beam installation: {target.installationRoot}. "
  match remedy with
  | .install _ precondition => message ++ precondition
  | .manual detail => message ++ detail ++
      ". For custom-target setup, see https://github.com/leanprover/lean-beam/blob/main/docs/CUSTOM_TOOLCHAINS.md"

def UnavailableTarget.message (target : UnavailableTarget) : String :=
  let remedy := target.remedy
  target.explanation remedy ++ (remedy.command?.map ("\n" ++ ·)).getD ""

inductive Failure where
  | invalid (detail : String)
  | changed
  | unavailable (target : UnavailableTarget)
  | noTarget
  | selection (error : Beam.Installation.LocalTarget.Failure)
  | io (error : IO.Error)

def Failure.message : Failure → String
  | .invalid detail => s!"invalid Beam installation: {detail}; reinstall Beam before starting runtime work"
  | .changed => "Beam installation generation changed; restart with a complete installation"
  | .unavailable target => target.message
  | .noTarget => "missing project lean-toolchain; select an exact installed target before starting standalone Beam"
  | .selection error => error.message
  | .io error => error.toString

def Failure.toIOError (failure : Failure) : IO.Error :=
  IO.userError failure.message

private inductive Record where
  | standalone (manifest : InstallManifest)
  | bundled (provenance : Bundled.Provenance)
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

private def Record.isBundled : Record → Bool
  | .standalone _ => false
  | .bundled _ => true

private def require (condition : Bool) (detail : String) : Except Failure Unit :=
  unless condition do throw (.invalid detail)

private def readRecord (root : System.FilePath) (bundled : Bool) : IO (Except Failure Record) := do
  try
    if bundled then
      let layout : Bundled.Layout := ⟨root⟩
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
  unless Beam.sameCanonicalPath canonical path do
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
  unless Beam.sameCanonicalPath command path && (← command.metadata).type == .file do
    throw <| IO.userError s!"recorded target Lean path changed: {path}"
  pure command

private structure ResolvedTarget where
  target : Beam.Installation.Target
  command : System.FilePath
  daemon : System.FilePath
  plugin : System.FilePath

/-- One operation's checked filesystem observation; never a process-wide filesystem cache. -/
structure Observation where
  private mk ::
  private home : System.FilePath
  private record : Record
  private cli : System.FilePath
  private targets : Array ResolvedTarget
  private daemonTarget? : Option Nat

private def checkRecord (root app : System.FilePath) (role : Role)
    (record : Record) : IO (Except Failure Observation) := do
  try
    let components := record.components
    let members ← record.artifacts.mapM fun artifact => do
      pure (artifact.destination, ← memberPath root artifact.destination)
    let member := fun relative => do
      let some (_, path) := members.find? (·.1 == relative)
        | throw <| IO.userError s!"component is absent from inventory: {relative}"
      pure path
    let cli ← member components.frontends.cli
    let mcp ← member components.frontends.mcp
    let mut expectedRevision := components.frontends.compilerRevision
    let mut ownRole := match role with
      | .cli => Beam.sameCanonicalPath app cli
      | .mcp => Beam.sameCanonicalPath app mcp
      | .daemon => false
    let mut targets : Array ResolvedTarget := #[]
    let mut daemonTarget? := none
    for target in components.targets do
      let command ← targetCommand root record.isBundled target
      if targets.any (fun target => Beam.sameCanonicalPath command target.command) then
        return .error (.invalid "duplicate canonical target Lean path")
      let daemon ← member target.daemon
      let plugin ← member target.plugin
      if role == .daemon && Beam.sameCanonicalPath app daemon then
        ownRole := true
        expectedRevision := target.compilerRevision
        daemonTarget? := some targets.size
      targets := targets.push { target, command, daemon, plugin }
    return do
      require ownRole "this executable does not occupy its recorded installation role"
      require (Beam.compilerRevisionsMatch Beam.compiledCompilerRevision Lean.githash expectedRevision)
        "compiled-against, loaded, and recorded compiler revisions differ"
      pure ⟨root, record, cli, targets, daemonTarget?⟩
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
    | .ok record => pure <| (← checkRecord root app role record).map (fun _ => record)
  pure ⟨root, app, role, bundled, snapshot⟩

def current (role : Role := .cli) : IO Installation := do
  openExecutable (← IO.appPath) role Bundled.enabled

/-- Recheck the original generation and every member, retaining the resolved values for this operation. -/
def observe (installation : Installation) : IO (Except Failure Observation) := do
  let original ← match installation.snapshot with
    | .ok original => pure original
    | .error error => return .error error
  let current ← readRecord installation.home installation.bundled
  match current with
  | .error error => return .error error
  | .ok current =>
      unless original == current do return .error .changed
      return ← checkRecord installation.home installation.app installation.role current

/-- Only the installation adapter can mint references; execution receives their complete description. -/
structure RuntimeRef where
  private mk ::
  description : Beam.Runtime.Description

private def Observation.installContext (observation : Observation) : IO TargetInstallContext := do
  if observation.record.isBundled then return .bundled
  let some location := installedRuntimeLocation? observation.home | return .unrecognized
  unless location.payload == observation.record.generation &&
      (← checkInstallRootMarker location.installRoot).isOk do return .unrecognized
  try
    let current ← Beam.resolveExistingPath (location.installRoot / "current")
    if Beam.sameCanonicalPath current observation.home then return .current location.installRoot
  catch _ => pure ()
  return .unconfirmed location.installRoot

/-- Select from checked members; no installation member is resolved a second time. -/
def Observation.lookup (observation : Observation) (root : System.FilePath) : IO (Except Failure RuntimeRef) := do
  let selected ← Beam.Installation.LocalTarget.resolve root (← Beam.Installation.LocalTarget.elanHome)
  let selected ← match selected with
    | .error error => return .error (.selection error)
    | .ok selected => pure selected
  for (resolved, index) in observation.targets.toList.zipIdx do
    if selected.any (fun selected => Beam.sameCanonicalPath resolved.command selected.command) ||
        (selected.isNone && observation.record.isBundled) then
      if observation.daemonTarget?.any (· != index) then
        return .error (.invalid "this target belongs to a different installation-owned daemon")
      return .ok ⟨{
        command := resolved.command.toString
        plugin := resolved.plugin, daemonBin := resolved.daemon, toolchain := resolved.target.toolchain
        identity := ⟨observation.home, observation.record.generation⟩
      }⟩
  let some selected := selected | return .error .noTarget
  return .error <| .unavailable {
    selected, installationRoot := observation.home
    installContext := ← observation.installContext
    retainedTargets := observation.record.components.targets.map (·.toolchain)
    sourceCommit? := observation.record.sourceCommit? }

/-- Exact local lookup; no compiler probe, provider search, or provisioning is possible here. -/
def lookup (installation : Installation) (root : System.FilePath) : IO (Except Failure RuntimeRef) := do
  match ← installation.observe with
  | .ok observation => observation.lookup root
  | .error error => pure (.error error)

private def requireProjectRuntime
    (lookup : System.FilePath → IO (Except Failure RuntimeRef)) (root : System.FilePath) :
    IO Beam.Runtime.Description := do
  unless ← Beam.Project.hasLeanProject root do
    throw <| IO.userError s!"could not resolve Lean project at {root}"
  let reference ← IO.ofExcept <| (← lookup root).mapError Failure.toIOError
  pure reference.description

/-- Application resolution from one observation; discovery and recorded-owner cleanup do not call it. -/
def Observation.projectRuntime (observation : Observation) :
    System.FilePath → IO Beam.Runtime.Description :=
  requireProjectRuntime observation.lookup

def projectRuntime (installation : Installation) (root : System.FilePath) :
    IO Beam.Runtime.Description :=
  requireProjectRuntime installation.lookup root

def Observation.identity (observation : Observation) (base : Beam.Version.Identity) : Beam.Version.Identity :=
  let record := observation.record
  { base with
    beamHome? := some observation.home.toString
    beamCli? := some observation.cli.toString
    runtimePayload? := some record.generation
    sourceCommit? := record.sourceCommit?
    manifest? := some (observation.home /
      (if record.isBundled then "lib/lean-beam/provenance.json" else "manifest.json")).toString
    bundledLean? := if record.isBundled then record.components.targets.toList.head?.map (·.leanVersion) else none
  }

def readIdentity (installation : Installation) (base : Beam.Version.Identity) : IO Beam.Version.Identity := do
  let observation ← IO.ofExcept <| (← installation.observe).mapError Failure.toIOError
  pure (observation.identity base)

end Installation
end Beam
