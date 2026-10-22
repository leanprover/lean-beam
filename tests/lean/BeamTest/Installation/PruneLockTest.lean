/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Cli.Prune

open Lean

namespace BeamTest.Installation.PruneLockTest

-- Keep fault cases fixture-only and type checked without exporting lock internals.
local macro "prunePrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.Cli.Prune name.getId)

private abbrev LockFailure := prunePrivate% Beam.Cli.InstallLockFailure

private def withLock (path : System.FilePath) (act : IO α) :=
  ((prunePrivate% Beam.Cli.withInstallLockTimeout) path 0 act).toBaseIO

private def renderFailure (failure : LockFailure) : IO.Error :=
  (prunePrivate% Beam.Cli.InstallLockFailure.toIOError) failure

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def injectedError : IO.Error :=
  .permissionDenied (some "initialization-marker") 13 "injected initialization failure"

private def requireInjected (error : IO.Error) : IO Unit := do
  match error with
  | .permissionDenied (some "initialization-marker") code "injected initialization failure" =>
      require (code == 13) "the original OS error code changed"
  | _ => throw <| IO.userError "the original typed initialization error was lost"

private def failed (result : Except LockFailure α) : IO LockFailure :=
  match result with
  | .error failure => pure failure
  | .ok _ => throw <| IO.userError "lock operation unexpectedly succeeded"

private def requireReleased (lockDir : System.FilePath) : IO Unit := do
  require (!(← lockDir.pathExists)) "owned lock was not removed"
  match ← withLock lockDir (pure 73) with
  | .ok value => require (value == 73) "reacquisition lost the action result"
  | .error _ => throw <| IO.userError "owned lock could not be reacquired immediately"
  require (!(← lockDir.pathExists)) "reacquisition left its owned lock behind"

private def successful (root : System.FilePath) : IO Unit := do
  let lockDir := root / "successful"
  let result ← withLock lockDir do
    require (← lockDir.isDir) "action did not own a directory"
    require (!(← (lockDir / "pid").pathExists)) "PID initialization ran outside the protected action"
    IO.FS.writeFile (lockDir / "pid") "fixture-owner\n"
    pure 42
  match result with
  | .ok value => require (value == 42) "successful action result changed"
  | .error _ => throw <| IO.userError "successful owned lock reported failure"
  requireReleased lockDir

private def initializationFailure (root : System.FilePath) (partialPid : Bool) : IO Unit := do
  let lockDir := root / if partialPid then "partial-pid" else "before-pid"
  let tailRan ← IO.mkRef false
  let failure ← failed (← withLock lockDir do
    require (!(← (lockDir / "pid").pathExists)) "initialization started before cleanup protection"
    if partialPid then IO.FS.writeFile (lockDir / "pid") "partial"
    let initializePid : IO Unit := throw injectedError
    initializePid
    tailRan.set true)
  match failure with
  | (prunePrivate% Beam.Cli.InstallLockFailure.ioError) error => requireInjected error
  | (prunePrivate% Beam.Cli.InstallLockFailure.operationAndCleanup) _ _ =>
      throw <| IO.userError "normal initialization cleanup failed"
  requireInjected (renderFailure failure)
  require (!(← tailRan.get)) "action continued after initialization failed"
  requireReleased lockDir

private def contention (root : System.FilePath) : IO Unit := do
  let lockDir := root / "another-owner"
  IO.FS.createDir lockDir
  let sentinel := "another owner's PID bytes; never interpret or signal\n"
  IO.FS.writeFile (lockDir / "pid") sentinel
  let ran ← IO.mkRef false
  let failure ← failed (← withLock lockDir (ran.set true))
  match failure with
  | (prunePrivate% Beam.Cli.InstallLockFailure.ioError) (.userError _) => pure ()
  | _ => throw <| IO.userError "contention did not retain its acquisition error"
  require (!(← ran.get)) "contending action ran without owning the lock"
  require ((← IO.FS.readFile (lockDir / "pid")) == sentinel) "contender changed another owner's PID"
  require (← lockDir.isDir) "contender removed another owner's directory"

private def acquisitionFailure (root : System.FilePath) : IO Unit := do
  let lockDir := root / "missing-parent/lock"
  let ran ← IO.mkRef false
  let failure ← failed (← withLock lockDir (ran.set true))
  match renderFailure failure with
  | .noFileOrDirectory .. => pure ()
  | _ => throw <| IO.userError "acquisition changed the original filesystem error type"
  require (!(← ran.get)) "action ran after acquisition failed"
  require (!(← lockDir.pathExists)) "failed acquisition created a lock"

private def cleanupFailure (root : System.FilePath) (failOperation : Bool) : IO Unit := do
  let lockDir := root / if failOperation then "both-failed" else "cleanup-failed"
  let failure ← failed (← withLock lockDir do
    IO.FS.writeFile (lockDir / "pid") "fixture-owner\n"
    IO.FS.writeFile (lockDir / "unexpected") "preserve these bytes"
    if failOperation then throw injectedError)
  match failOperation, failure with
  | true, (prunePrivate% Beam.Cli.InstallLockFailure.operationAndCleanup) operation cleanup =>
      requireInjected operation
      match renderFailure failure with
      | .userError message =>
          require (message.contains operation.toString) "CLI diagnostic omitted the operation error"
          require (message.contains cleanup.toString) "CLI diagnostic omitted the cleanup error"
      | _ => throw <| IO.userError "combined failure did not reach the CLI diagnostic edge"
  | false, (prunePrivate% Beam.Cli.InstallLockFailure.ioError) _ => pure ()
  | _, _ => throw <| IO.userError "cleanup failure lost one of its typed outcomes"
  require ((← IO.FS.readFile (lockDir / "unexpected")) == "preserve these bytes")
    "cleanup recursively removed an unexpected file"
  require (!(← (lockDir / "pid").pathExists)) "cleanup left its known PID file behind"

end BeamTest.Installation.PruneLockTest

open BeamTest.Installation.PruneLockTest in
def main : IO Unit := IO.FS.withTempDir fun root => do
  successful root
  initializationFailure root false
  initializationFailure root true
  contention root
  acquisitionFailure root
  cleanupFailure root false
  cleanupFailure root true
  IO.println "prune lock ownership, initialization cleanup, and typed failure preservation passed"
