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

private def computeLakeEnv (leanCmd? : Option String) : IO Lake.Env := do
  let elan? ← Lake.findElanInstall?
  let (lean?, lake?) ←
    match leanCmd? with
    | some command =>
        if command.trimAscii.isEmpty then
          throw <| IO.userError "empty selected Lean command"
        let some lean ← Lake.findLeanCmdInstall? command
          | throw <| IO.userError s!"could not load the selected Lean installation: {command}"
        pure (some lean, some (Lake.LakeInstall.ofLean lean))
    | none =>
        -- Trusted in-process library callers may use Lake's own context. Shipped applications
        -- always provide their admitted installation command and never enter this branch.
        let (_, lean?, lake?) ← Lake.findInstall?
        pure (lean?, lake?)
  let some lean := lean?
    | throw <| IO.userError "could not locate Lean installation for Lake workspace loading"
  let some lake := lake?
    | throw <| IO.userError "could not locate Lake installation for workspace loading"
  match ← (Lake.Env.compute lake lean elan?).toBaseIO with
  | .ok env => pure env
  | .error err => throw <| IO.userError s!"failed to compute Lake environment: {err}"

/-- Live Lean values require agreement with both the elaborating compiler and loaded runtime. -/
private def canLoadWorkspaceInProcess (lakeEnv : Lake.Env) : Bool :=
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
  let (ws?, log) ← LoggerIO.captureLog <| Lake.loadWorkspace loadConfig
  let messages := log.entries.map fun entry => entry.toString
  pure (ws?, messages)

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

def loadWorkspaceForRoot (root : FilePath) (leanCmd? : Option String) : IO WorkspaceLoadResult := do
  let (relConfigFile, configFile) ← detectConfigFile root
  let lakeEnv ← computeLakeEnv leanCmd?
  unless canLoadWorkspaceInProcess lakeEnv do
    return .leanBuildMismatch
  let (ws?, messages) ← loadWorkspaceWithConfig root lakeEnv relConfigFile configFile
  if let some ws := ws? then
    pure <| .loaded ws
  else
    throw <| IO.userError <| loadWorkspaceFailureMessage root messages

private def leanServerLakeEnvInProcess
    (root : FilePath)
    (leanCmd? : Option String) : IO LeanServerLakeEnv := do
  let lakeEnv ← computeLakeEnv leanCmd?
  -- Always preserve the target runtime environment: the Beam plugin links against target Lean/Lake
  -- libraries even when there is no Lake configuration or this Lake version cannot load it.
  let fallback : LeanServerLakeEnv := {
    env := lakeEnv.vars
    moreServerArgs := #[]
  }
  if !canLoadWorkspaceInProcess lakeEnv then
    return fallback
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

def leanServerLakeEnv
    (root : FilePath)
    (leanCmd? : Option String)
    (lakeHelper? : Option FilePath := none)
    (control : LakeHelperControl := {}) : IO (Except BrokerFailure LeanServerLakeEnv) := do
  try
    match lakeHelper?, leanCmd? with
    | some helper, some _ =>
        runLakeHelperServerEnv helper ({
          root := root.toString
        } : LakeHelperEnvRequest) control
    | _, _ =>
        return .ok (← leanServerLakeEnvInProcess root leanCmd?)
  catch error => pure <| .error {
    code := .internalError, message := error.toString
  }

end Beam.Broker
