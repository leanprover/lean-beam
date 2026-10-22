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

def doctor (home : System.FilePath) (inspect : System.FilePath → CliM (List String))
    (opts : CliOptions) : CliM Unit := do
  let root ← inspectionRoot opts
  let registry ← Beam.Daemon.registryPathFor root opts.explicitControlDir?
  let mut lines := [s!"beam home: {home}", s!"project root: {root}", s!"registry: {registry}"]
  lines := lines ++ (← match ← observeProjectRegistry root opts.explicitControlDir? with
    | .live entry => pure [
        "daemon status: live", s!"daemon pid: {entry.pid}",
        s!"daemon endpoint: {Beam.Daemon.endpointSummary (Beam.Daemon.registryEndpoint entry)}",
        s!"daemon config hash: {entry.configHash}"]
    | .draining entry => pure ["daemon status: draining", s!"daemon generation: {entry.daemonId}"]
    | .absent => pure ["daemon status: absent"]
    | .selectorMismatch entry => pure ["daemon status: session selector mismatch",
        sessionSelectorMismatchMessage root (← Beam.Daemon.controlDirFor root opts.explicitControlDir?) entry]
    | .recoveryRequired (.invalid problem) => pure ["daemon status: recovery required",
        s!"session descriptor error: {problem.detail}"]
    | .recoveryRequired (.unusable _ reason) => pure ["daemon status: unsafe",
        s!"daemon safety error: {reason.message}"])
  lines := lines ++ (← daemonFailureIncidentDoctorLines root opts.explicitControlDir?)
  try
    let inspection ← inspect root
    for line in lines ++ inspection do IO.println line
  catch failure =>
      throw { failure with failure := { failure.failure with error := {
        failure.failure.error with data? := some (Json.mkObj [("diagnostics", toJson lines)]) } } }

end Beam.Cli
