/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Installation.StandaloneLayout
import Beam.Path

open Lean Beam.Installation

namespace Beam.Cli

private structure PruneOptions where
  apply : Bool := false
  help : Bool := false

private structure PruneContext where
  home : System.FilePath
  installRoot : System.FilePath
  versionsRoot : System.FilePath

private structure PrunePlan where
  oldRuntimes : Array System.FilePath := #[]

private def installLockPollMs : Nat :=
  100

/--
Coordinate pruning with the bootstrap shell installer, which owns `.install-lock` as a directory.

Unlike the old generic directory lock, this compatibility boundary never reaps a purportedly stale
owner: `mkdir` is the only acquisition operation and only the process that created the directory
removes it. A crashed installer therefore fails closed and requires explicit operator recovery.
-/
private partial def acquireInstallLockUntil
    (lockDir : System.FilePath)
    (startedNanos deadlineNanos timeoutMs : Nat) : IO Unit := do
  let acquired ←
    try
      IO.FS.createDir lockDir
      pure true
    catch
    | .alreadyExists .. => pure false
    | error => throw error
  if acquired then
    return
  let now ← IO.monoNanosNow
  if now >= deadlineNanos then
    let waitedMs := (now - startedNanos) / 1000000
    throw <| IO.userError <|
      s!"timed out after {waitedMs} ms waiting for Beam lock {lockDir}; timeout: {timeoutMs} ms"
  IO.sleep installLockPollMs.toUInt32
  acquireInstallLockUntil lockDir startedNanos deadlineNanos timeoutMs

private def releaseInstallLock (lockDir : System.FilePath) : IO Unit := do
  let pidPath := lockDir / "pid"
  if ← pidPath.pathExists then
    IO.FS.removeFile pidPath
  IO.FS.removeDir lockDir

private inductive InstallLockFailure where
  | ioError (error : IO.Error)
  | operationAndCleanup (operation cleanup : IO.Error)

private def InstallLockFailure.toIOError : InstallLockFailure → IO.Error
  | .ioError error => error
  | .operationAndCleanup operation cleanup =>
      IO.userError s!"{operation}\nfailed to release Beam install lock after prune failure:\n{cleanup}"

private def withInstallLockTimeout
    (lockDir : System.FilePath)
    (timeoutMs : Nat)
    (act : IO α) : EIO InstallLockFailure α := do
  let startedNanos ← IO.monoNanosNow
  (acquireInstallLockUntil lockDir startedNanos
    (startedNanos + timeoutMs * 1000000) timeoutMs).toEIO .ioError
  -- mkdir transfers ownership before any fallible initialization runs in act.
  let operation ← act.toBaseIO
  let cleanup ← (releaseInstallLock lockDir).toBaseIO
  match operation, cleanup with
  | .ok value, .ok () => pure value
  | .error error, .ok () | .ok _, .error error => throw <| .ioError error
  | .error operation, .error cleanup => throw <| .operationAndCleanup operation cleanup

private def pruneUsage : String :=
  "usage: lean-beam prune [--apply]"

private def pruneHelp : String :=
  String.intercalate "\n" [
    pruneUsage,
    "",
    "Preview and optionally remove old installed Beam runtimes.",
    "",
    "options:",
    "  --apply      remove the displayed paths",
    "  -h, --help   show this help",
    "",
    "Restart active agents and MCP clients before using --apply.",
    "Apply removes one validated path at a time and reports each successful removal immediately."
  ]

private def parsePruneOptions (args : List String) : Except String PruneOptions := do
  let mut opts : PruneOptions := {}
  for arg in args do
    match arg with
    | "--apply" => opts := { opts with apply := true }
    | "-h" | "--help" => opts := { opts with help := true }
    | _ => throw s!"{pruneUsage}\nunknown prune option: {arg}"
  pure opts

private def fail (message : String) : IO α :=
  throw <| IO.userError message

private def requireOwnedInstallRoot (installRoot : System.FilePath) : IO Unit := do
  let marker := installRoot / ".lean-beam-install-root"
  match ← checkInstallRootMarker installRoot with
  | .ok () => pure ()
  | .error .missing =>
      fail s!"refusing to prune unmarked Beam install root: {installRoot}"
  | .error .invalid =>
      fail s!"refusing to prune invalid Beam install root marker: {marker}"
  | .error .missingRoot =>
      fail s!"refusing to prune install root marker without root: {marker}"
  | .error .mismatchedRoot =>
      fail s!"refusing to prune install root with mismatched marker root: {marker}"

private def validatedRuntimePayload (versionsRoot : System.FilePath)
    (path : System.FilePath) : IO Unit := do
  let resolved ← Beam.resolveExistingPath path
  unless resolved.toString == path.toString do
    fail s!"refusing to prune symlinked runtime path: {path}"
  unless resolved.parent == some versionsRoot do
    fail s!"refusing to prune non-canonical runtime path: {path}"
  let some location := installedRuntimeLocation? resolved
    | fail s!"runtime path has no installed-runtime location: {resolved}"
  unless location.versionsRoot == versionsRoot do
    fail s!"refusing to prune runtime outside versions root: {resolved}"
  match ← resolveRuntimeHome resolved with
  | .installed _ => pure ()
  | .source _ =>
      fail s!"refusing to prune unmarked runtime directory: {resolved}"
  | .invalidInstalled runtime =>
      match runtime.error with
      | .missingManifest =>
          fail s!"refusing to prune unmarked runtime directory: {resolved}"
      | .invalidManifest message =>
          fail <| String.intercalate "\n" [
            s!"refusing to prune runtime with invalid manifest: {resolved / "manifest.json"}",
            message,
            s!"review runtime: {resolved}",
            "For a known retired runtime, stop all its users and preserve it outside `versions`; then rerun `lean-beam prune`.",
            "Keep the current runtime, symlinked entries, and entries of unknown ownership in place."
          ]
      | .mismatchedPayload _ =>
          fail <| s!"refusing to prune runtime with mismatched manifest payloadHash: {resolved}"
      | .invalidInstallRootMarker _ =>
          fail <| s!"refusing to prune runtime under an invalid Beam install root: {resolved}"

private def resolvePruneContext (home : System.FilePath) : IO PruneContext := do
  let home ← Beam.resolveExistingPath home
  let some location := installedRuntimeLocation? home
    | fail s!"prune is only available from an installed Beam runtime: {home}"
  pure {
    home
    installRoot := location.installRoot
    versionsRoot := location.versionsRoot
  }

private def validatePruneContext (ctx : PruneContext) : IO Unit := do
  let home := ctx.home
  let installRoot := ctx.installRoot
  requireOwnedInstallRoot installRoot
  let currentPath := installRoot / "current"
  unless ← currentPath.pathExists do
    fail s!"missing current Beam runtime link: {currentPath}"
  let current ← Beam.resolveExistingPath currentPath
  unless current.toString == home.toString do
    fail <| String.intercalate "\n" [
      s!"refusing to prune from a non-current Beam runtime: {home}",
      s!"current Beam runtime: {current}",
      "rerun prune through the installed `lean-beam` command"
    ]
  validatedRuntimePayload ctx.versionsRoot home

private def oldRuntimePaths (ctx : PruneContext) : IO (Array System.FilePath) := do
  let entries := (← ctx.versionsRoot.readDir).qsort (fun a b => a.fileName < b.fileName)
  let mut paths := #[]
  for entry in entries do
    unless ← entry.path.isDir do
      fail s!"refusing to prune unexpected non-directory in versions root: {entry.path}"
    let resolved ← Beam.resolveExistingPath entry.path
    validatedRuntimePayload ctx.versionsRoot entry.path
    if resolved.toString != ctx.home.toString then
      paths := paths.push resolved
  pure paths

private def prunePlan (ctx : PruneContext) : IO PrunePlan := do
  pure { oldRuntimes := ← oldRuntimePaths ctx }

private def printPrunePlan (ctx : PruneContext)
    (opts : PruneOptions) (plan : PrunePlan) : IO Unit := do
  IO.println s!"Beam install prune ({if opts.apply then "apply" else "dry run"})"
  IO.println s!"install root: {ctx.installRoot}"
  IO.println s!"current runtime: {ctx.home}"
  for path in plan.oldRuntimes do
    IO.println s!"old runtime: {path}"
  IO.println s!"old runtimes: {plan.oldRuntimes.size}"
  if !opts.apply && !plan.oldRuntimes.isEmpty then
    IO.println "restart active agents and MCP clients before applying this cleanup"
    IO.println "dry run only; rerun `lean-beam prune --apply` to remove these paths"

private def removeOldRuntime (ctx : PruneContext) (path : System.FilePath) : IO Bool := do
  if !(← path.pathExists) then
    return false
  let resolved ← Beam.resolveExistingPath path
  if resolved.toString == ctx.home.toString then
    fail s!"refusing to prune current Beam runtime: {resolved}"
  validatedRuntimePayload ctx.versionsRoot resolved
  IO.FS.removeDirAll resolved
  pure true

private def applyPrune (ctx : PruneContext) (plan : PrunePlan) : IO Nat := do
  let mut removed := 0
  for path in plan.oldRuntimes do
    if ← removeOldRuntime ctx path then
      removed := removed + 1
      IO.println s!"removed runtime: {path}"
  pure removed

def runPrune (home : System.FilePath) (args : List String) : IO Unit := do
  let opts ← IO.ofExcept <| parsePruneOptions args
  if opts.help then
    IO.println pruneHelp
    return
  let ctx ← resolvePruneContext home
  let lockDir := ctx.installRoot / ".install-lock"
  EIO.toIO InstallLockFailure.toIOError <| withInstallLockTimeout lockDir 1000 do
    let selfPid ← IO.Process.getPID
    IO.FS.writeFile (lockDir / "pid") s!"{selfPid}\n"
    validatePruneContext ctx
    let plan ← prunePlan ctx
    printPrunePlan ctx opts plan
    if opts.apply then
      try
        let runtimesRemoved ← applyPrune ctx plan
        IO.println s!"removed runtimes: {runtimesRemoved}"
      catch e =>
        IO.eprintln <|
          "prune stopped before completing the displayed plan; any removals reported above were applied"
        IO.eprintln "rerun `lean-beam prune` to preview the remaining paths"
        throw e

end Beam.Cli
