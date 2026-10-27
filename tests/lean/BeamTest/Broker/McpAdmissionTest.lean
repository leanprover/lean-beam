/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Mcp.Options
import BeamTest.Broker.JsonAssert

open Beam.Mcp
open Beam.Mcp.Admission
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.McpAdmissionTest

private def checkClassification : IO Unit := do
  require "drop is workspace control"
    (classify "tools/call" (some .leanDropWorkspace) == .workspaceControl)
  require "beam_version is observation" (classify "tools/call" (some .beamVersion) == .observation)
  require "beam_stats is observation" (classify "tools/call" (some .beamStats) == .observation)
  require "ping is observation" (classify "ping" none == .observation)
  require "feedback is ordinary" (classify "tools/call" (some .beamFeedbackReport) == .ordinary)
  require "an unparsed tool call is ordinary" (classify "tools/call" none == .ordinary)
  require "tools/list is ordinary" (classify "tools/list" none == .ordinary)
  require "a drop name outside tools/call is ordinary"
    (classify "tools/list" (some .leanDropWorkspace) == .ordinary)

/-- Admit through the first candidate pool, as the coordinator does when output has room. -/
private def admit (limits : Limits) (ledger : Ledger) (cls : RequestClass) : Option (Pool × Ledger) := do
  let pool ← (ledger.candidates limits cls).head?
  let ledger ← ledger.acquire? limits pool
  pure (pool, ledger)

private def admitAll (limits : Limits) (ledger : Ledger) (cls : RequestClass) (n : Nat) :
    IO (Ledger × Array Pool) := do
  let mut ledger := ledger
  let mut pools := #[]
  for _ in [0:n] do
    let some (pool, next) := admit limits ledger cls
      | throw <| IO.userError s!"admission unexpectedly busy for {repr cls} at {repr ledger}"
    ledger := next
    pools := pools.push pool
  pure (ledger, pools)

private def checkSaturationRecovery (ordinary : Nat) : IO Unit := do
  let limits : Limits := { ordinary }
  let (saturated, _) ← admitAll limits {} .ordinary ordinary
  require s!"ordinary pool of {ordinary} is exhausted" (admit limits saturated .ordinary).isNone
  -- Cancelled-but-unsettled ordinary work keeps its charge; recovery uses reserves.
  let some (dropPool, afterDrop) := admit limits saturated .workspaceControl
    | throw <| IO.userError "drop was busy under ordinary saturation"
  require "drop spills into the control reserve" (dropPool == .controlReserve)
  let (afterDrops, _) ← admitAll limits afterDrop .workspaceControl 1
  require "control reserve is bounded" (admit limits afterDrops .workspaceControl).isNone
  -- Queued drops cannot consume observation capacity.
  let (observed, observationPools) ← admitAll limits afterDrops .observation 2
  require "observation spills into its own reserve"
    (observationPools.all (· == .observationReserve))
  require "observation reserve is bounded" (admit limits observed .observation).isNone
  require "reserves never admit ordinary work" (admit limits observed .ordinary).isNone
  -- Releases return capacity to the charged pool exactly once.
  let released := observed.release .observationReserve
  require "released observation capacity is reusable"
    ((admit limits released .observation).map (·.1) == some .observationReserve)
  let settled := released.release .ordinary
  require "a settled ordinary admission frees ordinary capacity"
    ((admit limits settled .ordinary).map (·.1) == some .ordinary)
  require "with ordinary room, drops prefer the ordinary pool"
    ((admit limits settled .workspaceControl).map (·.1) == some .ordinary)

private def checkReleaseAccounting : IO Unit := do
  let limits : Limits := { ordinary := 2 }
  let (ledger, pools) ← admitAll limits {} .observation 4
  require "observation uses ordinary capacity first"
    (pools == #[.ordinary, .ordinary, .observationReserve, .observationReserve])
  let ledger := pools.foldl Ledger.release ledger
  require "releasing every charge empties the ledger" (ledger == {})

private def checkLimitParsing : IO Unit := do
  require "default limit" ((parseOptions {} []).toOption.map (·.maxUnfinishedRequests) == some 32)
  for (text, value) in [("1", 1), ("2", 2), ("32", 32), ("1024", 1024), ("0007", 7)] do
    require s!"accepts {text}"
      ((parseOptions {} ["--max-unfinished-requests", text]).toOption.map
        (·.maxUnfinishedRequests) == some value)
  for text in ["0", "-1", "+3", "1025", "18446744073709551617", "3.5", "", " 4", "four"] do
    require s!"rejects {text.quote}"
      (!(parseOptions {} ["--max-unfinished-requests", text]).isOk)
  require "rejects a missing value" (!(parseOptions {} ["--max-unfinished-requests"]).isOk)
  require "rejects the equals spelling" (!(parseOptions {} ["--max-unfinished-requests=4"]).isOk)
  match parseOptions {} ["--max-unfinished-requests", "0"] with
  | .error message =>
      require "rejection names the flag and range"
        ((message.splitOn "--max-unfinished-requests expects an integer from 1 to 1024").length > 1)
  | .ok _ => throw <| IO.userError "zero limit was accepted"

def run : IO Unit := do
  checkClassification
  checkSaturationRecovery 1
  checkSaturationRecovery 2
  checkSaturationRecovery 32
  checkReleaseAccounting
  checkLimitParsing

end BeamTest.Broker.McpAdmissionTest
