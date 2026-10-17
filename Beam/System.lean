/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam

/-- Inspect one exact leaf. Windows junctions count as links; unobservable leaves return false. -/
@[extern "lean_beam_path_is_link"]
private opaque pathIsLinkNative (path : @& String) : IO Bool

def pathIsLink (path : System.FilePath) : IO Bool :=
  pathIsLinkNative path.toString

/-- Wait for a task for at most `timeoutMs`, without cancelling it on timeout. -/
partial def waitTaskWithTimeout
    (task : Task α)
    (timeoutMs : Nat)
    (pollMs : Nat := 50) : IO (Option α) := do
  let rec loop (remainingMs : Nat) : IO (Option α) := do
    if ← IO.hasFinished task then
      return some (← IO.wait task)
    if remainingMs == 0 then
      return none
    let sleepMs := min (max pollMs 1) remainingMs
    IO.sleep sleepMs.toUInt32
    loop (remainingMs - sleepMs)
  loop timeoutMs

/-- POSIX lstat bits, or 0700 only for a private Windows DACL; never follow reparse points. -/
@[extern "lean_beam_lstat_mode"]
private opaque lstatMode (path : @& String) : IO UInt32

def fileModeNoFollow (path : System.FilePath) : IO UInt32 :=
  lstatMode path.toString

@[extern "lean_beam_set_private_dir_rights"]
private opaque setPrivateDirRights (path : @& String) : IO Unit

def privateDirRights : IO.FileRight := {
  user := { read := true, write := true, execution := true }
}

def privateDirMode : UInt32 :=
  privateDirRights.flags

/-- Classification of one exact directory leaf without following a final symbolic link. -/
inductive PrivateDirObservation where
  | absent
  | privateDir
  | symlink
  | nonPrivate (mode : UInt32)
  | notDirectory
  deriving BEq, Repr

def permissionModeText (mode : UInt32) : String :=
  let value := mode.toNat
  s!"0{value / 64}{(value / 8) % 8}{value % 8}"

def PrivateDirObservation.problem : PrivateDirObservation → Option String
  | .privateDir => none
  | .absent => some "the path disappeared during private-directory preparation"
  | .symlink => some "symbolic links are not accepted"
  | .nonPrivate mode =>
      if System.Platform.isWindows then
        some "the Windows DACL must grant full access to the current user and no access to other ordinary accounts"
      else some s!"existing mode is {permissionModeText mode}, expected 0700"
  | .notDirectory => some "the path is not a directory"

/-- Inspect an exact directory leaf without following its final symbolic link. -/
def observePrivateDir (dir : System.FilePath) : IO PrivateDirObservation := do
  try
    let metadata ← dir.symlinkMetadata
    match metadata.type with
    | .dir =>
        let mode ← fileModeNoFollow dir
        if mode == privateDirMode then
          pure .privateDir
        else
          pure <| .nonPrivate mode
    | .symlink => pure .symlink
    | .file | .other => pure .notDirectory
  catch
  | .noFileOrDirectory .. => pure .absent
  | err => throw err

/--
Create a missing private directory leaf, or observe an existing leaf without changing it.

Only the leaf successfully created by this call is changed to mode `0700`. A concurrent or
pre-existing path is returned as observed so the caller can reject it without hidden mutation.
-/
def preparePrivateDir (dir : System.FilePath) : IO PrivateDirObservation := do
  match ← observePrivateDir dir with
  | .privateDir => return .privateDir
  | .absent => pure ()
  | observation => return observation
  if let some parent := dir.parent then
    IO.FS.createDirAll parent
  try
    IO.FS.createDir dir
  catch
  | .alreadyExists .. => return ← observePrivateDir dir
  | err => throw err
  try
    setPrivateDirRights dir.toString
    let observation ← observePrivateDir dir
    unless observation == .privateDir do
      try
        IO.FS.removeDir dir
      catch _ =>
        pure ()
    pure observation
  catch err =>
    try
      IO.FS.removeDir dir
    catch _ =>
      pure ()
    throw err

def requirePrivateDir
    (label : String)
    (dir : System.FilePath)
    (observation : PrivateDirObservation) : IO Unit := do
  match observation.problem with
  | none => pure ()
  | some problem =>
      throw <| IO.userError <|
        s!"unsafe {label} {dir}: {problem}. Select a dedicated directory that is a real " ++
          (if System.Platform.isWindows then "directory with a private Windows DACL"
           else "directory with mode 0700") ++ "; Beam does not change permissions on existing paths"

/-- Create a missing private leaf or validate an existing one without adopting it. -/
def ensurePrivateDir (label : String) (dir : System.FilePath) : IO Unit := do
  requirePrivateDir label dir (← preparePrivateDir dir)

def trimLine (text : String) : String :=
  text.trimAscii.toString

def readCmdTrim (cmd : String) (args : Array String := #[]) (cwd? : Option System.FilePath := none) :
    IO String := do
  let out ← IO.Process.output {
    cmd
    args
    cwd := cwd?.map (·.toString)
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"command failed: {cmd} {String.intercalate " " args.toList}\n{out.stderr}"
  pure <| trimLine out.stdout

def commandAvailable (cmd : String) (args : Array String := #["--help"]) : IO Bool := do
  try
    let child ← IO.Process.spawn {
      cmd := cmd
      args := args
      stdin := .null
      stdout := .null
      stderr := .null
    }
    if (← child.tryWait).isNone then
      try
        child.kill
      catch _ =>
        pure ()
      try
        discard <| child.wait
      catch _ =>
        pure ()
    pure true
  catch _ =>
    pure false

@[extern "lean_beam_utc_timestamp"]
opaque utcTimestamp : IO String

end Beam
