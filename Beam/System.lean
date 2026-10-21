/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Std.Time.Format

open Lean

namespace Beam

/-- Inspect one exact leaf. Missing leaves return false; other observation failures are errors. -/
@[extern "lean_beam_path_is_link"]
private opaque pathIsLinkNative (path : @& String) : IO Bool

def pathIsLink (path : System.FilePath) : IO Bool :=
  pathIsLinkNative path.toString

/-- POSIX execute-bit inspection only; Windows execution rights are not approximated by mode bits. -/
@[extern "lean_beam_file_execute_bits"]
private opaque fileExecuteBitsNative (path : @& String) : IO (Option Bool)

/-- Inspect the exact regular file without executing it. `none` means unsupported on this platform. -/
def fileExecuteBits (path : System.FilePath) : IO (Option Bool) :=
  fileExecuteBitsNative path.toString

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

/-- Native tags are decoded here; Windows ACL failures never masquerade as POSIX mode bits. -/
@[extern "lean_beam_observe_private_dir"]
private opaque observePrivateDirNative (path : @& String) : IO (UInt8 × UInt32)

@[extern "lean_beam_create_private_dir"]
private opaque createPrivateDir (path : @& String) : IO Unit

inductive PrivateDirIssue where
  | posixMode (mode : UInt32)
  | posixOwner
  | windowsDacl
  deriving BEq, Repr

/-- Classification of an exact directory leaf under Beam's current per-user private-directory policy. -/
inductive PrivateDirObservation where
  | absent
  | privateDir
  | symlink
  | nonPrivate (issue : PrivateDirIssue)
  | notDirectory
  deriving BEq, Repr

def permissionModeText (mode : UInt32) : String :=
  let value := mode.toNat
  s!"0{value / 64}{(value / 8) % 8}{value % 8}"

def PrivateDirObservation.problem : PrivateDirObservation → Option String
  | .privateDir => none
  | .absent => some "the path disappeared during private-directory preparation"
  | .symlink => some "symbolic links are not accepted; Windows reparse points are also rejected"
  | .nonPrivate (.windowsDacl) =>
      some "the Windows DACL must use ordinary allow entries, grant full access to the current user, and grant no access to other ordinary accounts"
  | .nonPrivate (.posixMode mode) =>
      some s!"existing mode is {permissionModeText mode}, expected 0700"
  | .nonPrivate .posixOwner =>
      some "the directory is not owned by the current effective user"
  | .notDirectory => some "the path is not a directory"

/-- Inspect an exact directory leaf without following its final symbolic link. -/
def observePrivateDir (dir : System.FilePath) : IO PrivateDirObservation := do
  let (tag, mode) ← observePrivateDirNative dir.toString
  match tag.toNat with
  | 0 => pure .absent
  | 1 => pure .privateDir
  | 2 => pure .symlink
  | 3 => pure .notDirectory
  | 4 => pure <| .nonPrivate (.posixMode mode)
  | 5 => pure <| .nonPrivate .windowsDacl
  | 6 => pure <| .nonPrivate .posixOwner
  | _ => throw <| IO.userError s!"invalid native private-directory observation: {tag}"

/-- Create only the missing leaf, private from creation; never create parents or repair a leaf. -/
def preparePrivateDirLeaf (dir : System.FilePath) : IO PrivateDirObservation := do
  createPrivateDir dir.toString
  observePrivateDir dir

/--
Create a missing private directory leaf, or observe an existing leaf without changing it.

The new leaf has mode `0700` (subject to umask) or a private Windows DACL at creation.
An accepted POSIX leaf must belong to the current effective user.
A concurrent or pre-existing path is returned as observed without changing ownership or permissions.
Failed observation does not authorize removing a path that may have been replaced.
-/
def preparePrivateDir (dir : System.FilePath) : IO PrivateDirObservation := do
  match ← observePrivateDir dir with
  | .privateDir => return .privateDir
  | .absent => pure ()
  | observation => return observation
  if let some parent := dir.parent then
    IO.FS.createDirAll parent
  preparePrivateDirLeaf dir

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
           else "directory owned by the current effective user with mode 0700") ++
          "; Beam does not change ownership or permissions on existing paths"

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

/-- Stable UTC spelling for timestamps recorded in provenance, sessions and feedback. -/
def formatUtcTimestamp (timestamp : Std.Time.Timestamp) : String :=
  Std.Time.Formats.iso8601.format <| Std.Time.DateTime.ofTimestampWithZone timestamp .UTC

/-- UTC wall-clock time at second precision, independent of the local timezone. -/
def utcTimestamp : IO String :=
  formatUtcTimestamp <$> Std.Time.Timestamp.now

end Beam
