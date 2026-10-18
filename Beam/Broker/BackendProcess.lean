/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Std.Sync.Mutex

namespace Beam.Broker

/-- A terminal child observation. A failed wait does not establish ownership of a live PID. -/
inductive BackendExit where
  | exited (code : UInt32)
  | waitFailed (error : IO.Error)

/--
The sole owner of one backend child's wait and kill operations. Session copies share this value;
terminal observations are retained, and no later caller can wait on or signal the child again.
-/
structure BackendProcess where
  private mk ::
  pid : UInt32
  private exit : Std.Mutex (Option BackendExit)
  private tryWait : IO (Option UInt32)
  private kill : IO Unit

/--
Adopt a child's operations once, then use only this owner for observation and termination. Keeping
the operations explicit also permits deterministic lifecycle tests without signalling real PIDs.
-/
def BackendProcess.create
    (pid : UInt32) (tryWait : IO (Option UInt32)) (kill : IO Unit) : BaseIO BackendProcess := do
  pure { pid, tryWait, kill, exit := ← Std.Mutex.new none }

private def BackendProcess.observeLocked (process : BackendProcess) :
    Std.AtomicT (Option BackendExit) IO (Option BackendExit) := do
  if let some exit ← get then
    return some exit
  let exit? ← try
    pure <| (← process.tryWait).map BackendExit.exited
  catch err => pure <| some (.waitFailed err)
  set exit?
  pure exit?

/-- Poll under the ownership lock; only `none` means the child was observed still running. -/
def BackendProcess.observe (process : BackendProcess) : IO (Option BackendExit) :=
  process.exit.atomically process.observeLocked

/-- Wait within a bound, releasing the ownership lock between nonblocking polls. -/
partial def BackendProcess.waitForExit
    (process : BackendProcess) (timeoutMs : Nat) (pollMs : Nat := 50) :
    IO (Option BackendExit) := do
  let rec loop (remainingMs : Nat) : IO (Option BackendExit) := do
    match ← process.observe with
    | some exit => pure (some exit)
    | none =>
        if remainingMs == 0 then
          pure none
        else
          let sleepMs := min (max pollMs 1) remainingMs
          IO.sleep sleepMs.toUInt32
          loop (remainingMs - sleepMs)
  loop timeoutMs

/--
Observe and signal in one critical section: another caller cannot reap between these operations.
The bounded exit wait releases the lock between polls. No pipe I/O runs under this lock.
-/
def BackendProcess.terminate (process : BackendProcess) (timeoutMs : Nat) :
    IO (Option BackendExit) := do
  process.exit.atomically do
    if (← process.observeLocked).isNone then
      try process.kill catch _ => pure ()
  process.waitForExit timeoutMs

end Beam.Broker
