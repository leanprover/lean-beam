/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.DaemonConfig
import Beam.Project
import Beam.Cli.Output
import Beam.Cli.RuntimeBundle
import Beam.Cli.RuntimeIdentity
import Beam.Cli.Toolchain
import Beam.Cli.Usage
import Beam.Mcp.Options

open Lean

namespace Beam.Cli

/-- Application-owned installation choices. Execution and session code never inspect this type. -/
inductive Installation where
  | managed (home : System.FilePath)
  | sdk (layout : Toolchain.Layout)

def Installation.home : Installation → System.FilePath
  | .managed home => home
  | .sdk layout => layout.home

private def managedHome : IO System.FilePath := do
  let home ← match ← IO.getEnv "BEAM_HOME" with
    | some home => pure (System.FilePath.mk home)
    | none =>
        let app ← IO.appPath
        pure <| (List.range 4).foldl (fun path _ => path.parent.getD path) app
  -- Selecting an installation records configuration, not evidence of a usable runtime.
  -- Help, MCP discovery, and owner cleanup must remain available with a missing home.
  try Beam.resolveExistingPath home catch _ => pure home

/-- Select a layout, but do not resolve a project, read provenance, or construct bundles yet. -/
def Installation.current : IO Installation := do
  if Toolchain.enabled then
    pure <| .sdk (← Toolchain.locate)
  else
    pure <| .managed (← managedHome)

private def fromSdkResult (result : Except Toolchain.ResolutionError α) : IO α :=
  IO.ofExcept <| result.mapError (IO.userError ∘ Toolchain.ResolutionError.message)

private def readManagedSelector (root : System.FilePath) : IO String := do
  let path := root / "lean-toolchain"
  unless ← path.pathExists do throw <| IO.userError s!"missing lean-toolchain in {root}"
  pure <| Beam.trimLine (← IO.FS.readFile path)

private def managedLean (root : System.FilePath) : IO String :=
  Beam.readCmdTrim "elan" #["which", "lean"] (some root)

private def resolveManaged (home root : System.FilePath) : IO DesiredConfig := do
  let selector ← readManagedSelector root
  let (bundle, bundleId) ← ensureToolchainBundle root home selector
  ensureLeanBundleExists bundle
  pure {
    root
    lean := {
      command := ← managedLean root
      plugin := bundle.plugin
      toolchain := selector
      bundleId
    }
    daemonBin := bundle.daemon
  }

private def Installation.resolve (installation : Installation) (root : System.FilePath) : IO DesiredConfig := do
  unless ← Beam.Project.hasLeanProject root do
    throw <| IO.userError s!"could not resolve Lean Beam daemon config for {root}"
  match installation with
  | .managed home => resolveManaged home root
  | .sdk layout => pure (← fromSdkResult (← layout.resolve root)).2

def Installation.runtime (installation : Installation) : RuntimeAccess := {
  resolve := installation.resolve
  attachment := fun root =>
    match installation with
    | .managed _ => pure .selected
    | .sdk _ => return .matchingRuntime (← installation.resolve root).configHash
}

def Installation.readIdentity (installation : Installation) (base : Beam.Version.Identity) :
    IO Beam.Version.Identity := do
  match installation with
  | .managed _ =>
      RuntimeIdentity.managed base (base.beamHome?.map System.FilePath.mk)
  | .sdk layout =>
      let p ← fromSdkResult (← layout.readProvenance)
      pure <| RuntimeIdentity.bundled { base with beamHome? := some layout.home.toString } p

def Installation.cliIdentity (installation : Installation) : IO Beam.Version.Identity := do
  let name ← match installation with
    | .managed _ => do
        let publicName? ← IO.getEnv "BEAM_PUBLIC_COMMAND"
        pure (publicName?.getD "beam-cli")
    | .sdk _ => pure Beam.Version.cliName
  installation.readIdentity {
    name
    wrapper? := ← IO.getEnv "BEAM_WRAPPER_PATH"
    beamHome? := some installation.home.toString
    beamCli? := some (← IO.appPath).toString
  }

inductive CommandRejection where
  | standaloneInstall
  | standaloneBundle
  | standalonePrune
  | standaloneRegistry
  | fixedCompatibility
  | sdkBuildInfo

def CommandRejection.message : CommandRejection → String
  | .standaloneInstall => "bundled lean-beam does not provide standalone install or MCP setup commands; use its containing Lean toolchain's installer"
  | .standaloneBundle => "bundled lean-beam uses only its containing toolchain; reinstall that toolchain to repair its runtime"
  | .standalonePrune => "bundled lean-beam has no standalone runtimes to prune"
  | .standaloneRegistry => "bundled lean-beam has no standalone toolchain registry; use version or doctor for its bundled Lean identity"
  | .fixedCompatibility => "bundled lean-beam supports its containing Lean installation only"
  | .sdkBuildInfo => "this executable was not built with -KbeamToolchain=true"

/-- Maintenance-command availability is decided once by the application dispatcher. -/
def Installation.admitCommand (installation : Installation) (args : List String) :
    Except CommandRejection Unit := do
  match installation, args.head? with
  | .managed _, some "toolchain-build-info" => throw .sdkBuildInfo
  | .managed _, _ => pure ()
  | .sdk _, some "bundle-install" => throw .standaloneBundle
  | .sdk _, some "prune" => throw .standalonePrune
  | .sdk _, some "validated-toolchains" => throw .standaloneRegistry
  | .sdk _, some "compatible-release-lines" => throw .fixedCompatibility
  | .sdk _, some command =>
      if ["install-layout", "install-manifest", "install-manifest-with-source-commit",
          "install-runtime-validate"].contains command then throw .standaloneInstall
  | .sdk _, none => pure ()

def Installation.usage (installation : Installation) : String :=
  Beam.Cli.usage <| match installation with
  | .sdk _ => []
  | .managed _ => [
      "  lean-beam prune [--apply] [--bundles]",
      "  lean-beam validated-toolchains",
      "  lean-beam compatible-release-lines"
    ]

def compilerBuildInfo : Json := Json.mkObj [
  ("leanGithash", toJson Lean.githash),
  ("lakeSupportsDeferredCompilation", toJson Toolchain.lakeSupportsDeferredCompilation)
]

/-- Explicit SDK launch overrides are checked at startup, before transport execution. -/
def Installation.mcpOptions (installation : Installation) (opts : Beam.Mcp.Options) : IO Beam.Mcp.Options := do
  match installation with
  | .managed _ => pure opts
  | .sdk layout =>
      let beamCli := layout.executable "lean-beam"
      let mismatch := IO.userError "bundled lean-beam-mcp uses only its containing toolchain"
      unless opts.leanCmd?.isNone && opts.leanPlugin?.isNone do throw mismatch
      if let some selected := opts.beamCli? then
        unless ← Beam.sameFilePath beamCli (System.FilePath.mk selected) do throw mismatch
      pure { opts with beamCli? := some beamCli.toString }

private def rejectedToolchainDiagnosticText : String :=
  "(not resolved for rejected toolchain)"

private structure LeanBundleDoctorInfo where
  source : String
  fingerprintHash : String
  leanVersion : String
  leanPrefix : String
  leanLibDir : String
  lakeVersion : String
  bundleId : String
  ready : Bool
  daemon : String
  plugin : String

private def rejectedLeanBundleDoctorInfo : LeanBundleDoctorInfo := {
  source := "rejected"
  fingerprintHash := rejectedToolchainDiagnosticText
  leanVersion := rejectedToolchainDiagnosticText
  leanPrefix := rejectedToolchainDiagnosticText
  leanLibDir := rejectedToolchainDiagnosticText
  lakeVersion := rejectedToolchainDiagnosticText
  bundleId := rejectedToolchainDiagnosticText
  ready := false
  daemon := rejectedToolchainDiagnosticText
  plugin := rejectedToolchainDiagnosticText
}

private def acceptedLeanBundleDoctorInfo
    (home runtimeRoot : System.FilePath)
    (toolchain : String) : IO LeanBundleDoctorInfo := do
  let fingerprint ← toolchainFingerprint toolchain
  let installed? ← existingToolchainBundleInAnyForFingerprint?
    (← installBundleCacheRoots) home toolchain fingerprint
  let runtime? ← existingToolchainBundleForFingerprint? runtimeRoot home toolchain fingerprint
  let (paths, bundleId, source, ready) ←
    match installed? with
    | some (paths, bundleId) => pure (paths, bundleId, "installed", true)
    | none =>
        match runtime? with
        | some (paths, bundleId) => pure (paths, bundleId, "runtime", true)
        | none =>
            let (paths, bundleId) ← predictedToolchainBundleForFingerprint runtimeRoot home toolchain fingerprint
            pure (paths, bundleId, "missing", false)
  pure {
    source
    fingerprintHash := toolchainFingerprintHash fingerprint
    leanVersion := fingerprint.leanVersion
    leanPrefix := fingerprint.leanPrefix
    leanLibDir := fingerprint.leanLibDir
    lakeVersion := fingerprint.lakeVersion
    bundleId
    ready
    daemon := paths.daemon.toString
    plugin := paths.plugin.toString
  }

private def managedDoctorLines (home root : System.FilePath) : IO (List String) := do
  let toolchain ← readManagedSelector root
  let support ← leanToolchainSupport home toolchain
  let toolchainValidated := support.acceptance == .validated
  let toolchainAccepted := support.acceptance.accepted
  let releaseLine :=
    support.acceptance.releaseLine?.map (·.versionText) |>.getD "(not applicable)"
  let leanCmd? ←
    if toolchainAccepted then
      let leanCmd ← managedLean root
      pure (some leanCmd)
    else
      pure none
  let runtimeRoot ← runtimeBundleCacheRoot root
  let platform ← bundlePlatform
  let srcHash ← sourceHash home
  let bundleInfo ←
    if toolchainAccepted then
      acceptedLeanBundleDoctorInfo home runtimeRoot toolchain
    else
      pure rejectedLeanBundleDoctorInfo
  pure [
    s!"project toolchain: {toolchain}",
    s!"project toolchain admission: {support.acceptance.label}",
    s!"project toolchain validated: {boolText toolchainValidated}",
    s!"project toolchain release line: {releaseLine}",
    s!"project toolchain accepted: {boolText toolchainAccepted}",
    s!"validated toolchains registry: {support.validatedPath}",
    s!"compatible release lines registry: {support.compatiblePath}",
    s!"custom toolchains registry: {support.customPath}",
    s!"lean binary: {leanCmd?.getD rejectedToolchainDiagnosticText}",
    s!"bundle platform: {platform}",
    s!"bundle source: {bundleInfo.source}",
    s!"bundle source hash: {srcHash}",
    s!"bundle toolchain fingerprint: {bundleInfo.fingerprintHash}",
    s!"bundle lean version: {bundleInfo.leanVersion}",
    s!"bundle lean prefix: {bundleInfo.leanPrefix}",
    s!"bundle lean libdir: {bundleInfo.leanLibDir}",
    s!"bundle lake version: {bundleInfo.lakeVersion}",
    "bundle key inputs: toolchain, toolchain fingerprint, platform, source hash",
    s!"bundle source inputs: {String.intercalate ", " bundleSourceHashInputLabels}",
    s!"bundle id: {bundleInfo.bundleId}",
    s!"bundle ready: {boolText bundleInfo.ready}",
    s!"bundle daemon: {bundleInfo.daemon}",
    s!"plugin: {bundleInfo.plugin}"
  ]

def Installation.doctorLines (installation : Installation) (root : System.FilePath) : IO (List String) := do
  match installation with
  | .managed home => managedDoctorLines home root
  | .sdk layout =>
      let (p, desired) ← fromSdkResult (← layout.resolve root)
      pure [
        "public command: lean-beam",
        s!"source commit: {p.sourceCommit}",
        s!"runtime payload: {p.payloadHash}",
        s!"bundled Lean: {p.leanVersion}",
        s!"bundled Lake: {p.lakeVersion}",
        s!"lean binary: {desired.lean.command}",
        "bundle source: toolchain",
        s!"bundle id: {desired.lean.bundleId}",
        "bundle ready: true",
        s!"bundle daemon: {desired.daemonBin}",
        s!"plugin: {desired.lean.plugin}"
      ]

end Beam.Cli
