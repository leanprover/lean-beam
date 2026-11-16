/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.Installation.Manifest

open Lean

namespace Beam.Installation

structure StandaloneLayout where
  rootFiles : List String
  runtimePaths : List String
  wrapperPaths : List String
  deriving BEq, FromJson, ToJson

structure InstalledRuntimeLocation where
  installRoot : System.FilePath
  versionsRoot : System.FilePath
  payload : String

structure InstalledRuntime where
  home : System.FilePath
  location : InstalledRuntimeLocation
  manifestPath : System.FilePath
  manifest : InstallManifest

inductive InstallRootMarkerError where
  | missing
  | invalid
  | missingRoot
  | mismatchedRoot

inductive InstalledRuntimeError where
  | invalidInstallRootMarker (error : InstallRootMarkerError)
  | missingManifest
  | invalidManifest (message : String)
  | mismatchedPayload (manifestPayload : String)

structure InvalidInstalledRuntime where
  home : System.FilePath
  location : InstalledRuntimeLocation
  manifestPath? : Option System.FilePath
  error : InstalledRuntimeError

inductive RuntimeHomeResolution where
  | source (home : System.FilePath)
  | installed (runtime : InstalledRuntime)
  | invalidInstalled (runtime : InvalidInstalledRuntime)

def installRuntimePaths : List String :=
  ["libexec/beam-cli", "libexec/lean-beam-mcp"]

def installWrapperPaths : List String :=
  ["bin/lean-beam", "bin/lean-beam-search", "bin/lean-beam-mcp"]

def standaloneLayout : StandaloneLayout :=
  {
    rootFiles := ["LICENSE"]
    runtimePaths := installRuntimePaths
    wrapperPaths := installWrapperPaths
  }

def installedRuntimeLocation? (home : System.FilePath) : Option InstalledRuntimeLocation := do
  let versionsRoot ← home.parent
  guard (versionsRoot.fileName == some "versions")
  let installRoot ← versionsRoot.parent
  let payload ← home.fileName
  pure { installRoot, versionsRoot, payload }

def checkInstallRootMarker
    (installRoot : System.FilePath) : IO (Except InstallRootMarkerError Unit) := do
  let marker := installRoot / ".lean-beam-install-root"
  let markerMetadata ←
    try
      Beam.observeEntry marker
    catch _ =>
      return .error .invalid
  if markerMetadata == .absent then return .error .missing
  unless markerMetadata == .file do
    return .error .invalid
  try
    let resolvedInstallRoot ← Beam.resolveExistingPath installRoot
    let resolvedMarker ← Beam.resolveExistingPath marker
    unless resolvedMarker.toString ==
        (resolvedInstallRoot / ".lean-beam-install-root").toString do
      return .error .invalid
    let fields := (← IO.FS.readFile marker).splitOn "\n"
    let schemaFields := fields.filter (fun field => field.startsWith "schema=")
    unless schemaFields == ["schema=1"] do
      return .error .invalid
    let ownerFields := fields.filter (fun field => field.startsWith "owner=")
    unless ownerFields == ["owner=lean-beam"] do
      return .error .invalid
    let rootFields := fields.filter (fun field => field.startsWith "root=")
    let rootField ←
      match rootFields with
      | [] => return .error .missingRoot
      | [rootField] => pure rootField
      | _ => return .error .invalid
    let markedRoot := System.FilePath.mk (rootField.drop 5).toString
    if markedRoot.toString.isEmpty then
      return .error .missingRoot
    unless markedRoot.isAbsolute do
      return .error .invalid
    if ← Beam.sameFilePath markedRoot installRoot then
      pure <| .ok ()
    else
      pure <| .error .mismatchedRoot
  catch _ =>
    pure <| .error .invalid

def describeInstalledRuntimeError (runtime : InvalidInstalledRuntime) : String :=
  match runtime.error with
  | .invalidInstallRootMarker .missing =>
      "missing Beam install root marker"
  | .invalidInstallRootMarker .invalid =>
      "invalid Beam install root marker"
  | .invalidInstallRootMarker .missingRoot =>
      "Beam install root marker has no root"
  | .invalidInstallRootMarker .mismatchedRoot =>
      "Beam install root marker names a different root"
  | .missingManifest =>
      "missing install manifest"
  | .invalidManifest message =>
      s!"invalid install manifest: {message}"
  | .mismatchedPayload manifestPayload =>
      s!"install manifest payloadHash {manifestPayload} does not match runtime directory {runtime.location.payload}"

def resolveRuntimeHome (home : System.FilePath) : IO RuntimeHomeResolution := do
  let home ← Beam.resolveExistingPath home
  let some location := installedRuntimeLocation? home
    | return .source home
  match ← checkInstallRootMarker location.installRoot with
  | .error .missing => return .source home
  | .error error =>
      return .invalidInstalled {
        home
        location
        manifestPath? := none
        error := .invalidInstallRootMarker error
      }
  | .ok () => pure ()
  let manifestPath := home / "manifest.json"
  unless ← manifestPath.pathExists do
    return .invalidInstalled {
      home
      location
      manifestPath? := none
      error := .missingManifest
    }
  try
    unless ← Beam.regularNonSymlinkFile manifestPath do
      throw <| IO.userError "install manifest must be a regular non-symlinked file"
    let resolvedManifestPath ← Beam.resolveExistingPath manifestPath
    unless resolvedManifestPath.toString == manifestPath.toString do
      throw <| IO.userError "install manifest must be a regular non-symlinked file"
    let manifest ← readInstallManifest manifestPath
    unless manifest.payloadHash == location.payload do
      return .invalidInstalled {
        home
        location
        manifestPath? := some manifestPath
        error := .mismatchedPayload manifest.payloadHash
      }
    pure <| .installed { home, location, manifestPath, manifest }
  catch e =>
    pure <| .invalidInstalled {
      home
      location
      manifestPath? := some manifestPath
      error := .invalidManifest (toString e)
    }

def validateInstalledRuntimeForReuse (home : System.FilePath) : IO Unit := do
  match ← resolveRuntimeHome home with
  | .installed _ => pure ()
  | .source resolved =>
      throw <| IO.userError s!"refusing to reuse non-installed Beam runtime: {resolved}"
  | .invalidInstalled runtime =>
      throw <| IO.userError <|
        s!"refusing to reuse invalid installed Beam runtime at {runtime.home}: " ++
          describeInstalledRuntimeError runtime


end Beam.Installation
