/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.LSP.Lib.NativeLib
import Beam.System

open Lean

namespace Beam.Cli

structure LeanBundlePaths where
  daemon : System.FilePath
  plugin : System.FilePath
  deriving Repr

def ensurePathExists (kind : String) (path : System.FilePath) : IO Unit := do
  unless ← path.pathExists do
    throw <| IO.userError s!"missing {kind} at {path}"

def ensureLeanBundleExists (paths : LeanBundlePaths) : IO Unit := do
  ensurePathExists "Beam daemon" paths.daemon
  ensurePathExists "Beam LSP plugin" paths.plugin

def beamStateDirName : String :=
  ".beam"

def installBundlesDirName : String :=
  "install-bundles"

def runtimeBundlesDirName : String :=
  "bundles"

/--
The build lock lives beside a bundle rather than inside it so cleanup can remove the complete
bundle directory without deleting the lock that protects that removal.
-/
def bundleBuildLockPath (platformRoot : System.FilePath) (bundleId : String) : System.FilePath :=
  platformRoot / ".locks" / bundleId

def beamStateDir (root : System.FilePath) : System.FilePath :=
  root / beamStateDirName

def skillInstallBundleCacheRoot (agentHome : System.FilePath) : System.FilePath :=
  agentHome / "skills" / "lean-beam" / beamStateDirName / installBundlesDirName

def defaultEnvPath (name : String) (fallback : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv name with
  | some path => pure <| System.FilePath.mk path
  | none => pure fallback

def userHome : IO System.FilePath := do
  match ← IO.getEnv "HOME" with
  | some path => pure <| System.FilePath.mk path
  | none => throw <| IO.userError "missing HOME in environment"

def installBundleCacheRoots : IO (List System.FilePath) := do
  match ← IO.getEnv "BEAM_INSTALL_BUNDLE_DIR" with
  | some path => pure [System.FilePath.mk path]
  | none =>
      let home ← userHome
      let codexHome ← defaultEnvPath "CODEX_HOME" (home / ".codex")
      let claudeHome ← defaultEnvPath "CLAUDE_HOME" (home / ".claude")
      pure [
        skillInstallBundleCacheRoot codexHome,
        skillInstallBundleCacheRoot claudeHome
      ]

def runtimeBundleCacheRoot (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_BUNDLE_DIR" with
  | some path => pure (System.FilePath.mk path)
  | none => pure (beamStateDir root / runtimeBundlesDirName)

/--
Create the project-local Beam state leaf privately when runtime bundle construction is the first
Beam operation for a project. Existing state directories are validated but never chmodded.
-/
def runtimeBundleCacheRootForWrite (root : System.FilePath) : IO System.FilePath := do
  match ← IO.getEnv "BEAM_BUNDLE_DIR" with
  | some path => pure (System.FilePath.mk path)
  | none =>
      let stateDir := beamStateDir root
      Beam.ensurePrivateDir "Beam project state directory" stateDir
      pure (stateDir / runtimeBundlesDirName)

def validatedLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "validated-lean-toolchains"

def compatibleLeanReleaseLinesPath (home : System.FilePath) : System.FilePath :=
  home / "compatible-lean-release-lines"

def customLeanToolchainsPath (home : System.FilePath) : System.FilePath :=
  home / "custom-lean-toolchains"

def bundleWorkspaceOwnerMarkerName : String :=
  ".lean-beam-bundle-workspace"

def bundleWorkspaceFor (bundleDir : System.FilePath) : System.FilePath :=
  bundleDir / "workspace"

def bundleWorkspaceOwnerMarker (workspace : System.FilePath) : System.FilePath :=
  workspace / bundleWorkspaceOwnerMarkerName

def leanBundlePathsFor (workspace : System.FilePath) : LeanBundlePaths :=
  {
    daemon := workspace / ".lake" / "build" / "bin" / "beam-daemon"
    plugin := Beam.LSP.Lib.pluginSharedLibPath (workspace / ".lake" / "build" / "lib")
  }

end Beam.Cli
