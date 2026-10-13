/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.DaemonManager
import Beam.Cli.InstallLayout
import Beam.Cli.Output
import Beam.Cli.Project
import Beam.Cli.RuntimeBundle
import Beam.Daemon.Debug
import Beam.Daemon.Paths
import Beam.Version

open Lean

namespace Beam.Cli

open Beam.Broker

def printVersion (home : System.FilePath) : IO Unit := do
  let appPath ← IO.appPath
  let wrapper? ← IO.getEnv "BEAM_WRAPPER_PATH"
  let publicCommand? ← IO.getEnv "BEAM_PUBLIC_COMMAND"
  let identity ← Beam.Version.mkRuntimeIdentity
    (publicCommand?.getD "beam-cli")
    (some home)
    (wrapper? := wrapper?)
    (beamCli? := some appPath.toString)
  IO.println identity.text

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

private def printLeanDoctorInfo (home root : System.FilePath) : IO Unit := do
  let toolchain ← leanToolchain root
  let support ← leanToolchainSupport home toolchain
  let toolchainValidated := support.acceptance == .validated
  let toolchainAccepted := support.acceptance.accepted
  let releaseLine :=
    support.acceptance.releaseLine?.map (·.versionText) |>.getD "(not applicable)"
  let leanCmd? ←
    if toolchainAccepted then
      let leanCmd ← leanBin root toolchain
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
  IO.println s!"project toolchain: {toolchain}"
  IO.println s!"project toolchain admission: {support.acceptance.label}"
  IO.println s!"project toolchain validated: {boolText toolchainValidated}"
  IO.println s!"project toolchain release line: {releaseLine}"
  IO.println s!"project toolchain accepted: {boolText toolchainAccepted}"
  IO.println s!"validated toolchains registry: {support.validatedPath}"
  IO.println s!"compatible release lines registry: {support.compatiblePath}"
  IO.println s!"custom toolchains registry: {support.customPath}"
  IO.println s!"lean binary: {leanCmd?.getD rejectedToolchainDiagnosticText}"
  IO.println s!"bundle platform: {platform}"
  IO.println s!"bundle source: {bundleInfo.source}"
  IO.println s!"bundle source hash: {srcHash}"
  IO.println s!"bundle toolchain fingerprint: {bundleInfo.fingerprintHash}"
  IO.println s!"bundle lean version: {bundleInfo.leanVersion}"
  IO.println s!"bundle lean prefix: {bundleInfo.leanPrefix}"
  IO.println s!"bundle lean libdir: {bundleInfo.leanLibDir}"
  IO.println s!"bundle lake version: {bundleInfo.lakeVersion}"
  IO.println "bundle key inputs: toolchain, toolchain fingerprint, platform, source hash"
  IO.println s!"bundle source inputs: {String.intercalate ", " bundleSourceHashInputLabels}"
  IO.println s!"bundle id: {bundleInfo.bundleId}"
  IO.println s!"bundle ready: {boolText bundleInfo.ready}"
  IO.println s!"bundle daemon: {bundleInfo.daemon}"
  IO.println s!"plugin: {bundleInfo.plugin}"

private def printRocqDoctorInfo (home root : System.FilePath) : IO Unit := do
  let daemon ← defaultDaemonPath home
  let daemonReady := ← daemon.pathExists
  IO.println s!"coq-lsp: {(← maybeRocqCmd root).getD ""}"
  IO.println s!"daemon ready: {boolText daemonReady}"
  IO.println s!"daemon binary: {daemon}"

def daemonFailureIncidentDoctorLines
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO (List String) := do
  let incidents ← Beam.Daemon.recentDaemonFailureIncidentPaths root 5 explicitControlDir?
  if incidents.isEmpty then
    pure ["daemon incidents: none"]
  else
    pure <|
      s!"daemon incidents: {incidents.size} recent" ::
        (incidents.toList.map fun path => s!"daemon incident: {path}")

private def printDaemonFailureIncidentDoctorInfo
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO Unit := do
  for line in ← daemonFailureIncidentDoctorLines root explicitControlDir? do
    IO.println line

def doctor (home : System.FilePath) (opts : CliOptions) (backend : Backend) : IO Unit := do
  let root ← projectRoot opts backend
  IO.println s!"beam home: {home}"
  IO.println s!"project root: {root}"
  match backend with
  | .lean => printLeanDoctorInfo home root
  | .rocq => printRocqDoctorInfo home root
  let registry ← Beam.Daemon.registryPathFor root opts.explicitControlDir?
  IO.println s!"registry: {registry}"
  match ← observeProjectRegistry root opts.explicitControlDir? with
  | .live entry =>
      IO.println "daemon status: live"
      IO.println s!"daemon pid: {entry.pid}"
      IO.println s!"daemon endpoint: {Beam.Daemon.endpointSummary (Beam.Daemon.registryEndpoint entry)}"
      IO.println s!"daemon config hash: {entry.configHash}"
  | .draining entry =>
      IO.println "daemon status: draining"
      IO.println s!"daemon generation: {entry.daemonId}"
  | .absent => IO.println "daemon status: absent"
  | .selectorMismatch entry =>
      IO.println "daemon status: session selector mismatch"
      IO.println <| sessionSelectorMismatchMessage root
        (← Beam.Daemon.controlDirFor root opts.explicitControlDir?) entry
  | .recoveryRequired (.invalid problem) =>
      IO.println "daemon status: recovery required"
      IO.println s!"session descriptor error: {problem.detail}"
  | .recoveryRequired (.unusable _ reason) =>
      IO.println "daemon status: unsafe"
      IO.println s!"daemon safety error: {reason.message}"
  printDaemonFailureIncidentDoctorInfo root opts.explicitControlDir?

def printValidatedToolchains (home : System.FilePath) (backendName : String) : IO Unit := do
  match backendName with
  | "lean" =>
      let (_, toolchains) ← validatedLeanToolchains home
      for toolchain in toolchains do
        IO.println toolchain
  | _ =>
      throw <| IO.userError "usage: lean-beam validated-toolchains"

def printCompatibleReleaseLines (home : System.FilePath) : IO Unit := do
  let (_, lines) ← compatibleLeanReleaseLines home
  for line in lines do
    IO.println line.registryEntry

def printInstallLayout : IO Unit := do
  printJsonLine (toJson installLayout)

private def sourceCommitArg? (sourceCommitArg : String) : Option String :=
  if sourceCommitArg == "-" then none else some sourceCommitArg

def printInstallManifest (payloadHash : String) (sourceCommitArg : String)
    (createdWithToolchains : List String) : IO Unit := do
  if createdWithToolchains.isEmpty then
    throw <| IO.userError
      "usage: beam-cli install-manifest <payload-hash> <source-commit|-> <creation-toolchain...>"
  printJsonLine (installManifestJson payloadHash (sourceCommitArg? sourceCommitArg)
    createdWithToolchains)

def printInstallManifestWithSourceCommit
    (manifestPath : System.FilePath)
    (sourceCommitArg : String) : IO Unit := do
  let manifest ← readInstallManifest manifestPath
  unless manifest.schemaVersion == installManifestSchemaVersion do
    throw <| IO.userError
      s!"cannot refresh source commit in install manifest schemaVersion {manifest.schemaVersion}"
  printJsonLine <| toJson { manifest with sourceCommit := sourceCommitArg? sourceCommitArg }

def printMcpConfig (home : System.FilePath) (opts : CliOptions) : IO Unit := do
  let root ← projectRoot opts .lean
  let desired ← desiredConfig home root .lean
  let .lean leanConfig _ := desired.backends
    | throw <| IO.userError s!"could not resolve Lean backend for MCP project root {root}"
  printJsonLine <| Json.mkObj [
    ("root", toJson root.toString),
    ("lean_cmd", toJson leanConfig.command),
    ("lean_plugin", toJson leanConfig.plugin.toString),
    ("lean_lake_helper", toJson desired.daemonBin.toString),
    ("toolchain", toJson leanConfig.toolchain),
    ("bundle_id", toJson leanConfig.bundleId)
  ]

end Beam.Cli
