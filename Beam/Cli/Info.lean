/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Cli.DaemonManager
import Beam.Cli.Output
import Beam.Cli.Project
import Beam.Daemon.Debug
import Beam.Daemon.Paths
import Beam.Version

open Lean

namespace Beam.Cli

open Beam.Broker

def printVersion (identity : IO Beam.Version.Identity) : IO Unit := do
  IO.println (← identity).text

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

def doctor (home : System.FilePath) (inspect : System.FilePath → IO (List String)) (opts : CliOptions) : IO Unit := do
  let root ← inspectionRoot opts
  IO.println s!"beam home: {home}"
  IO.println s!"project root: {root}"
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
  (← IO.getStdout).flush
  for line in ← inspect root do IO.println line

end Beam.Cli
