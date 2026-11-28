/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.System
import Beam.OwnedProcess
import Std.Sync.Mutex

namespace Beam.ProcessJob

inductive State where
  | running
  | exited
  deriving BEq, Repr

/-- Observation capability for one dynamic child scope; no native handle or PID operations escape. -/
structure Scope where
  private mk ::
  private observe : IO State

/-- Observe without reaping. Observation after closure is rejected. -/
def Scope.poll (scope : Scope) : IO State := scope.observe

/-- The operation and its owned teardown are independent outcomes. Neither erases the other. -/
structure Completion (α : Type) where
  operation : Except IO.Error α
  cleanup : Except IO.Error Unit

namespace Internal

/-- Serialize scope closure with outstanding polls and retain both completion outcomes. -/
def runScope (observe : IO State) (finalize : IO Unit)
    (action : Scope → IO α) : BaseIO (Completion α) := do
  let observer ← Std.Mutex.new (some observe)
  let scope : Scope := ⟨observer.atomically do
    let some poll ← get | throw <| IO.userError "process-job scope is closed"
    poll⟩
  let operation ← (action scope).toBaseIO
  let cleanup ← observer.atomically do
    set (none : Option (IO State))
    finalize.toBaseIO
  return { operation, cleanup }

end Internal

/-- Scope observation and finalization share the capability acquired by the native launcher. -/
def withChild (child : Beam.OwnedProcess.Child) (action : Scope → IO α) :
    BaseIO (Completion α) :=
  Internal.runScope (do return if (← child.exitCode?).isSome then .exited else .running)
    (discard child.finish) action

/-- Child-side owner-pipe EOF. POSIX group termination is guarded by session-leader ownership. -/
@[extern "lean_beam_process_job_parent_lost"]
opaque parentLost : IO Unit

end Beam.ProcessJob
