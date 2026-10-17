/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam.ProcessJob

@[extern "lean_beam_process_job_attach"]
private opaque attach (pid : UInt32) : IO USize

@[extern "lean_beam_process_job_close"]
private opaque close (job : USize) : IO Unit

@[extern "lean_beam_process_job_poll"]
private opaque pollNative (pid : UInt32) : IO UInt8

@[extern "lean_beam_process_job_terminate_posix"]
private opaque terminatePosix (pid : UInt32) : IO Unit

inductive State where
  | running
  | exited
  | notChild

/-- Observe without reaping. The caller must retain its unreaped Child throughout this scope. -/
def poll (child : IO.Process.Child cfg) : IO State := do
  match ← pollNative child.pid with
  | 0 => pure .running
  | 1 => pure .exited
  | 2 => pure .notChild
  | _ => throw <| IO.userError "invalid native process-job state"

/-- Request explicit leader/group termination before the one final wait. -/
private def terminate (child : IO.Process.Child cfg) : IO Unit := do
  if System.Platform.isWindows then
    try child.kill
    catch error =>
      -- A child may have exited before assignment failed. Confirm through its retained handle
      -- before accepting a failed TerminateProcess. Windows tryWait does not reap.
      if (← child.tryWait).isNone then throw error
  else
    terminatePosix child.pid

private def terminateAndWait (child : IO.Process.Child cfg) : IO Unit := do
  try terminate child finally discard <| child.wait

private def closeAndWait (child : IO.Process.Child cfg) (job : USize) (owned : Bool) :
    IO Unit := do
  let closeError? : Option IO.Error ← try
    close job
    pure none
  catch error => pure (some error)
  try
    if owned then
      -- Successful Windows job closure already requests termination. A second kill can
      -- fail while termination is pending. Failed closure still needs explicit termination.
      if !System.Platform.isWindows || closeError?.isSome then terminate child
    if let some error := closeError? then throw error
  finally
    if owned then discard <| child.wait

/-- Own assignment, termination and one wait. Lost child ownership forbids PID signalling/reaping. -/
def withChild (child : IO.Process.Child cfg) (stillOwned : IO Bool) (action : IO α) : IO α := do
  let job ← try attach child.pid
    catch error =>
      if ← stillOwned then terminateAndWait child
      throw error
  try action finally closeAndWait child job (← stillOwned)

/-- Child-side owner-pipe EOF. POSIX group termination is guarded by session-leader ownership. -/
@[extern "lean_beam_process_job_parent_lost"]
opaque parentLost : IO Unit

end Beam.ProcessJob
