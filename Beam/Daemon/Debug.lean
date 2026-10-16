/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Daemon.Paths
import Beam.Daemon.Registry
import Beam.System

open Lean

namespace Beam.Daemon

def daemonFailureIncidentEntries
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO (Array IO.FS.DirEntry) := do
  try
    let dir ← daemonFailureIncidentDirFor root explicitControlDir?
    unless ← dir.pathExists do
      return #[]
    let entries ← dir.readDir
    pure <| (entries.filter (fun entry => entry.fileName.endsWith ".json")).qsort
      (fun a b => a.fileName < b.fileName)
  catch _ =>
    pure #[]

def recentDaemonFailureIncidentPaths
    (root : System.FilePath)
    (limit : Nat := 5)
    (explicitControlDir? : Option System.FilePath := none) :
    IO (Array System.FilePath) := do
  let entries ← daemonFailureIncidentEntries root explicitControlDir?
  let keep := min limit entries.size
  let recent := entries.toList.drop (entries.size - keep)
  pure <| recent.foldl (fun acc entry => acc.push entry.path) #[]

private def recentDaemonFailureIncidentJson
    (root : System.FilePath)
    (limit : Nat := 5)
    (explicitControlDir? : Option System.FilePath := none) :
    IO (Array Json) := do
  let paths ← recentDaemonFailureIncidentPaths root limit explicitControlDir?
  let mut incidents := #[]
  for path in paths do
    let payload ←
      try
        let text ← IO.FS.readFile path
        match Json.parse text with
        | .ok json => pure json
        | .error err =>
            pure <| Json.mkObj [
              ("path", toJson path.toString),
              ("parseError", toJson err)
            ]
      catch e =>
        pure <| Json.mkObj [
          ("path", toJson path.toString),
          ("readError", toJson e.toString)
        ]
    incidents := incidents.push <| payload.setObjVal! "path" (toJson path.toString)
  pure incidents

private def tailLines (text : String) (count : Nat := 20) : String :=
  let lines := text.splitOn "\n"
  let keep := min count lines.length
  String.intercalate "\n" <| lines.drop (lines.length - keep)

def registryEndpointSummary (entry : SessionDescriptor) : String :=
  endpointSummary (registryEndpoint entry)

def startupLogTail?
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) :
    IO (Option (System.FilePath × String)) := do
  try
    let logPath ← daemonStartupLogPathFor root explicitControlDir?
    if ← logPath.pathExists then
      let logText := Beam.trimLine (← IO.FS.readFile logPath)
      if logText.isEmpty then
        pure none
      else
        pure <| some (logPath, tailLines logText)
    else
      pure none
  catch _ =>
    pure none

def daemonRegistryContext?
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO (Option String) := do
  try
    let path ← registryPathFor root explicitControlDir?
    match ← readRegistryAt path with
    | .absent => pure none
    | .invalid problem =>
        pure <| some s!"Beam daemon registry ({path}):\n  status: invalid\n  detail: {problem.detail}"
    | .current entry =>
        let workspace := entry.workspace
        let workspaceLines := [
          s!"  workspace: {workspace.workspaceId}",
          s!"    root: {workspace.root}",
          s!"    toolchain: {workspace.toolchain}",
          s!"    bundleId: {workspace.bundleId}"
        ]
        let lines := ([
          s!"Beam daemon registry ({path}):",
          s!"  schemaVersion: {entry.schemaVersion}",
          s!"  lifecycle: {repr entry.lifecycle}",
          s!"  daemonId: {entry.daemonId}",
          s!"  pid: {entry.pid} (diagnostic only)",
          s!"  endpoint: {registryEndpointSummary entry}",
          s!"  startedAt: {entry.startedAt}",
          s!"  configHash: {entry.configHash}"
        ] ++ workspaceLines)
        pure <| some <| String.intercalate "\n" lines
  catch _ =>
    pure none

def daemonDebugContextJson
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO Json := do
  let registryFile ← registryPathFor root explicitControlDir?
  let registryRead ← readRegistryAt registryFile
  let registry := registryRead.entry?
  let startupLogTail ← startupLogTail? root explicitControlDir?
  let incidents ← recentDaemonFailureIncidentJson root 5 explicitControlDir?
  pure <| Json.mkObj <|
    [
      ("registryPath", toJson registryFile.toString),
      ("registryReadStatus", toJson registryRead.status),
      ("registryReadDetail", match registryRead.detail? with
        | some detail => toJson detail
        | none => Json.null),
      ("registry", match registry with
        | some entry => entry.redactedJson
        | none => Json.null),
      ("registryEndpoint", match registry.map registryEndpointSummary with | some endpoint => toJson endpoint | none => Json.null),
      ("recentDaemonIncidents", toJson incidents)
    ] ++
    (match startupLogTail with
    | some (path, tail) => [
        ("startupLogPath", toJson path.toString),
        ("startupLogTail", toJson tail)
      ]
    | none => [])

end Beam.Daemon
