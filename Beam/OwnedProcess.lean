/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Std.Sync.Mutex

namespace Beam.OwnedProcess

private opaque ProcessResource : NonemptyType
private abbrev RawProcess := ProcessResource.type
private instance : Nonempty RawProcess := ProcessResource.property

private opaque PipeResource : NonemptyType
private abbrev RawEndpoint := PipeResource.type
private instance : Nonempty RawEndpoint := PipeResource.property

private structure Launch where
  process : RawProcess
  input : RawEndpoint
  output : RawEndpoint
  error : RawEndpoint
  pid : UInt32
  deriving Nonempty

inductive ExitStatus where
  | exited (code : UInt32)
  | signaled (signal : UInt32)
  | windows (code : UInt32)
  deriving Repr, BEq, Inhabited

def ExitStatus.code : ExitStatus → UInt32
  | .exited n | .windows n => n
  | .signaled s => 128 + s

def windowsForceCode : UInt32 := 0xBEA00009

/-- Force records a successful request while the original leader was last observed running.
Collection can remain pending after ownership transfers to the OS or POSIX reaper. -/
structure Completion where
  force : Except IO.Error Bool
  collection : Except IO.Error (Option ExitStatus)
  deriving Inhabited

def Completion.requireExit (r : Completion) : IO ExitStatus := do
  match r.force, r.collection with
  | .error signal, .error collect =>
      throw <| IO.userError s!"{signal}; also failed to collect the leader: {collect}"
  | .error e, _ | _, .error e => throw e
  | .ok _, .ok none => throw <| IO.userError "Beam process collection pending after ownership handoff"
  | .ok _, .ok (some status) => return status

private inductive Owner where
  | active (process : RawProcess)
  | finished (result : Completion)

@[extern "lean_beam_owned_spawn"] private opaque spawnRaw
    (cmd : @& String) (args : @& Array String) (cwd : @& Option String) : IO Launch
@[extern "lean_beam_owned_read"] private opaque readRaw
    (endpoint : @& RawEndpoint) (count : USize) : IO ByteArray
@[extern "lean_beam_owned_write"] private opaque writeRaw
    (endpoint : @& RawEndpoint) (bytes : @& ByteArray) : IO Unit
@[extern "lean_beam_owned_peek"] private opaque peekRaw (process : @& RawProcess) : IO (Option ExitStatus)
@[extern "lean_beam_owned_signal"] private opaque signalRaw
    (process : @& RawProcess) (marker : UInt32) : IO Bool
@[extern "lean_beam_owned_collect"] private opaque collectRaw
    (process : @& RawProcess) (block : Bool) : IO (Option ExitStatus)

private abbrev Endpoint := Std.Mutex (Option RawEndpoint)

private def borrowEndpoint (endpoint : Endpoint) : IO RawEndpoint := endpoint.atomically do
  let some handle ← get | throw <| IO.userError "Beam process pipe is closed"
  return handle

structure Reader where
  private handle : Endpoint
structure Writer where
  private handle : Endpoint

/-- The reader owns the borrowed endpoint throughout the callback and the native read. -/
@[inline] def Internal.readAfterBorrow (r : Reader) (count : USize) (borrowed : IO Unit) :
    IO ByteArray := do
  let endpoint ← borrowEndpoint r.handle
  borrowed
  readRaw endpoint count

def Reader.readSome (r : Reader) (count : USize) : IO ByteArray :=
  Internal.readAfterBorrow r count (pure ())

def Writer.writeAll (w : Writer) (bytes : ByteArray) : IO Unit := do
  writeRaw (← borrowEndpoint w.handle) bytes

def Reader.close (r : Reader) : BaseIO Unit := r.handle.atomically (set (none : Option RawEndpoint))
def Writer.close (w : Writer) : BaseIO Unit := w.handle.atomically (set (none : Option RawEndpoint))

structure Child where
  private process : Std.Mutex Owner
  stdin : Writer
  stdout : Reader
  stderr : Reader
  pid : UInt32

private initialize spawnLock : Std.Mutex Unit ← Std.Mutex.new ()

/-- Windows requires the three child pipe handles to be inheritable during CreateProcessW.
Serialize that interval with ordinary backend launches on SDKs that inherit all marked handles. -/
def withWindowsSpawnLock (launch : IO α) : IO α :=
  if System.Platform.isWindows then spawnLock.atomically launch else launch

/-- Launch a resolved executable in a new POSIX session or a Windows kill-on-close job. -/
def spawn (cmd : String) (args : Array String) (cwd : Option System.FilePath := none) : IO Child := do
  let path : System.FilePath := cmd
  let path ← if path.isAbsolute then pure path else pure ((← IO.currentDir) / path)
  let raw ← withWindowsSpawnLock <| spawnRaw path.toString args (cwd.map (·.toString))
  return ⟨← Std.Mutex.new (.active raw.process), ⟨← Std.Mutex.new (some raw.input)⟩,
    ⟨← Std.Mutex.new (some raw.output)⟩, ⟨← Std.Mutex.new (some raw.error)⟩, raw.pid⟩

/-- Non-consuming observation. The original exit code remains available after collection. -/
def Child.exitCode? (child : Child) : IO (Option UInt32) := child.process.atomically do
  match ← get with
  | .active process => return (← peekRaw process).map ExitStatus.code
  | .finished result =>
      if let .ok (some status) := result.collection then return some status.code
      return some (← result.requireExit).code

private def collectWithin (process : RawProcess) (tries : Nat) : IO (Option ExitStatus) := do
  if let some status ← collectRaw process false then return some status
  match tries with
  | 0 => return none
  | n + 1 => IO.sleep 100; collectWithin process n

/-- Attempt survivor termination before collection, even after leader exit. A failed signal
permits only a nonblocking wait. Dropping the unique raw owner transfers an unsettled POSIX
child to the prestarted reaper, leaving aliases with the same immutable receipt. -/
def Child.settle (child : Child) (polls? : Option Nat := none) : BaseIO Completion :=
  child.process.atomically do
    match ← get with
    | .finished result => return result
    | .active process =>
        let force ← (signalRaw process windowsForceCode).toBaseIO
        let collection ← (match force, polls? with
          | .error _, _ => collectRaw process false
          | .ok _, some tries => collectWithin process tries
          | .ok _, none => collectRaw process true).toBaseIO
        let result := { force, collection : Completion }
        set (.finished result : Owner)
        return result

/-- Require successful owned cleanup and retain the conventional code for diagnostics. -/
def Child.finish (child : Child) : IO UInt32 := do
  return (← (← child.settle).requireExit).code

end Beam.OwnedProcess
