/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.System
import Std.Sync.Mutex

namespace Beam.ProcessJob

@[extern "lean_beam_process_job_attach"]
private opaque attach (pid : UInt32) : IO USize

@[extern "lean_beam_process_job_close"]
private opaque close (job : USize) : IO Unit

@[extern "lean_beam_process_job_poll_posix"]
private opaque pollPosix (pid : UInt32) : IO UInt8

@[extern "lean_beam_process_job_terminate_posix"]
private opaque terminatePosix (pid : UInt32) : IO Unit

inductive State where
  | running
  | exited
  | notChild
  deriving BEq, Repr

/-- Observe exit without consuming the retained child's identity on either platform. -/
private def poll (child : IO.Process.Child cfg) : IO State := do
  if System.Platform.isWindows then
    -- Windows tryWait observes the original Child handle without closing or reaping it.
    return if (← child.tryWait).isSome then .exited else .running
  -- POSIX tryWait reaps, so retain the non-consuming waitid observation here.
  match ← pollPosix (Beam.processChildPid child) with
  | 0 => pure .running
  | 1 => pure .exited
  | 2 => pure .notChild
  | _ => throw <| IO.userError "invalid native process-job state"

private inductive Ownership where
  | retained
  | lost
  | closed
  deriving BEq

/-- Observation capability for one dynamic child scope; no native handle or PID operations escape. -/
structure Scope where
  private mk ::
  private observe : IO State

/-- Observe without reaping. Lost ownership is permanent; observation after closure is rejected. -/
def Scope.poll (scope : Scope) : IO State := scope.observe

namespace Internal

/-- Request termination while the caller retains the unreaped child spawned with `setsid := true`
(which may not yet have established its session). The caller must own that POSIX process group;
this operation signals both the leader and `-pid`. It does not wait or consume ownership, and does
not depend on `Child.takeStdin` preserving flags. -/
def requestTermination (child : IO.Process.Child cfg) : IO Unit := do
  if System.Platform.isWindows then
    try child.kill
    catch error =>
      -- A child may have exited before assignment failed. Confirm through its retained handle
      -- before accepting a failed TerminateProcess. Windows tryWait does not reap.
      if (← child.tryWait).isNone then throw error
  else
    terminatePosix (Beam.processChildPid child)

end Internal

private def terminateAndWait (child : IO.Process.Child cfg) : IO Unit := do
  try Internal.requestTermination child finally discard <| child.wait

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
      if !System.Platform.isWindows || closeError?.isSome then Internal.requestTermination child
    if let some error := closeError? then throw error
  finally
    if owned then discard <| child.wait

/--
Own assignment, observation, termination, and one final wait. The caller must not wait/kill the child
outside this scope. Native loss of ownership is retained here and forbids further PID operations.
-/
def withChild (child : IO.Process.Child cfg) (action : Scope → IO α) : IO α := do
  let ownership ← Std.Mutex.new Ownership.retained
  let job ← try attach (Beam.processChildPid child)
    catch error =>
      terminateAndWait child
      throw error
  let scope : Scope := ⟨ownership.atomically do
    match ← get with
    | .closed => throw <| IO.userError "process-job scope is closed"
    | .lost => pure .notChild
    | .retained =>
        let state ← poll child
        if state == .notChild then set Ownership.lost
        pure state⟩
  try action scope finally
    ownership.atomically do
      let retained := (← get) == .retained
      set Ownership.closed
      closeAndWait child job retained

/-- Child-side owner-pipe EOF. POSIX group termination is guarded by session-leader ownership. -/
@[extern "lean_beam_process_job_parent_lost"]
opaque parentLost : IO Unit

end Beam.ProcessJob
