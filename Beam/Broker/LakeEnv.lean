/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Config.Env
import Lake.Config.InstallPath
import Lake.CLI.Serve
import Lake.Load.Workspace
import Beam.Broker.LakeHelper
import Beam.CompilerRevision

open System
open Std
open Lean

namespace Beam.Broker

open Lake

private def computeLakeEnv (command : String) : IO Lake.Env := do
  if command.trimAscii.isEmpty then throw <| IO.userError "empty selected Lean command"
  let some lean ← Lake.findLeanCmdInstall? command
    | throw <| IO.userError s!"could not load the selected Lean installation: {command}"
  let lake := Lake.LakeInstall.ofLean lean
  let elan? ← Lake.findElanInstall?
  match ← (Lake.Env.compute lake lean elan?).toBaseIO with
  | .ok env => pure env
  | .error err => throw <| IO.userError s!"failed to compute Lake environment: {err}"

/-- Live Lean values require agreement with both the elaborating compiler and loaded runtime. -/
private def compilerRevisionsMatch (lakeEnv : Lake.Env) : Bool :=
  Beam.compilerRevisionsMatch Beam.compiledCompilerRevision Lean.githash lakeEnv.lean.githash

private def detectConfigFile? (root : FilePath) : IO (Option (FilePath × FilePath)) := do
  let leanConfig := root / "lakefile.lean"
  if ← leanConfig.pathExists then
    pure <| some (System.FilePath.mk "lakefile.lean", leanConfig)
  else
    let tomlConfig := root / "lakefile.toml"
    if ← tomlConfig.pathExists then
      pure <| some (System.FilePath.mk "lakefile.toml", tomlConfig)
    else
      pure none

private def detectConfigFile (root : FilePath) : IO (FilePath × FilePath) := do
  match ← detectConfigFile? root with
  | some config => pure config
  | none => throw <| IO.userError s!"could not find lakefile.lean or lakefile.toml under {root}"

private def loadWorkspaceWithConfig (root : FilePath) (lakeEnv : Lake.Env)
    (relConfigFile configFile : FilePath) : IO (Option Workspace × Array String) := do
  let loadConfig : LoadConfig := {
    lakeEnv := lakeEnv
    wsDir := root
    relPkgDir := System.FilePath.mk "."
    pkgDir := root
    relConfigFile := relConfigFile
    configFile := configFile
    updateToolchain := false
  }
  let messages ← IO.mkRef (#[] : Array String)
  let stderr ← IO.getStderr
  let ws? ← LoggerIO.run?' (Lake.loadWorkspace loadConfig) fun entry => do
    let text := entry.toString
    messages.modify (·.push text)
    -- Rendering uses the existing raw stderr channel. A presentation failure must not
    -- change workspace loading or the invalid-configuration fallback below.
    if entry.level ≥ Lake.LogLevel.info then
      discard <| (do stderr.putStr (text ++ "\n"); stderr.flush).toBaseIO
  pure (ws?, ← messages.get)

private def loadWorkspaceFailureMessage
    (root : FilePath)
    (messages : Array String) : String :=
  let lines :=
    #[s!"failed to load Lake workspace at {root}"] ++
    (if messages.isEmpty then #[] else #["Lake log:"] ++ messages)
  String.intercalate "\n" lines.toList

inductive WorkspaceLoadResult where
  | loaded (workspace : Workspace)
  | leanBuildMismatch

def loadWorkspaceForRoot (root : FilePath) (leanCmd : String) : IO WorkspaceLoadResult := do
  let (relConfigFile, configFile) ← detectConfigFile root
  let lakeEnv ← computeLakeEnv leanCmd
  unless compilerRevisionsMatch lakeEnv do
    return .leanBuildMismatch
  let (ws?, messages) ← loadWorkspaceWithConfig root lakeEnv relConfigFile configFile
  if let some ws := ws? then
    pure <| .loaded ws
  else
    throw <| IO.userError <| loadWorkspaceFailureMessage root messages

/-- Helper-side Lake evaluation for its bound target; never selects a process strategy. -/
def computeServerEnvironment
    (root : FilePath)
    (leanCmd : String) : IO LeanServerLakeEnv := do
  let lakeEnv ← computeLakeEnv leanCmd
  unless compilerRevisionsMatch lakeEnv do
    throw <| IO.userError "installed Lake helper and selected target have different compiler revisions; repair or reinstall this Beam installation"
  -- A matching target without a Lake configuration still needs its base runtime environment.
  let fallback : LeanServerLakeEnv := {
    env := lakeEnv.vars
    moreServerArgs := #[]
  }
  let some (relConfigFile, configFile) ← detectConfigFile? root
    | pure fallback
  let (ws?, messages) ← loadWorkspaceWithConfig root lakeEnv relConfigFile configFile
  if let some ws := ws? then
    pure {
      env := ws.augmentedEnvVars
      moreServerArgs := ws.root.moreGlobalServerArgs
    }
  else
    pure {
      env := lakeEnv.vars.push
        (Lake.invalidConfigEnvVar, some <| String.intercalate "\n" messages.toList)
      moreServerArgs := #[]
    }

end Beam.Broker
