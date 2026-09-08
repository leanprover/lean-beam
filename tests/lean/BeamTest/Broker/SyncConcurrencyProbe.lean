/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import BeamTest.Broker.ProcessUtil
import BeamTest.Broker.SmokeUtil

open Lean

namespace BeamTest.Broker.SyncConcurrencyProbe

open BeamTest.Broker.TestUtil
open BeamTest.Broker.SmokeTest

private abbrev tracedBrokerStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .piped

private def spawnTracedLeanBrokerWithPlugin
    (endpoint : Beam.Broker.Endpoint)
    (root leanPlugin : System.FilePath)
    (leanCmd : String := "lean") : IO (IO.Process.Child tracedBrokerStdio) := do
  let port :=
    match endpoint with
    | .tcp port => port
  IO.Process.spawn {
    toStdioConfig := tracedBrokerStdio
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--workspace-id", testWorkspaceId,
      "--lean-cmd", leanCmd,
      "--lean-plugin", leanPlugin.toString
    ]
    env := #[("LEAN_BEAM_BROKER_TRACE", some "1")]
    setsid := true
  }

private def writeConcurrencySlowSyncFile (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-sync-concurrency-probe-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "SlowSync.lean"
  IO.FS.writeFile path <| String.intercalate "\n" [
    "import Lean",
    "",
    "open Lean Elab Command",
    "",
    "elab \"concurrency_probe_sleep\" : command => do",
    "  IO.sleep 3000",
    "",
    "def concurrencyProbeStart : Nat := 0",
    "",
    "concurrency_probe_sleep",
    "",
    "def concurrencyProbeDone : Nat := concurrencyProbeStart + 1",
    ""
  ]
  pure path

private def writeValidStressSyncFiles (root : System.FilePath) (count : Nat) : IO (Array System.FilePath) := do
  let dir := root / ".tmp" / s!"beam-sync-stress-probe-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let mut paths := #[]
  for i in [0:count] do
    let path := dir / s!"Stress{i}.lean"
    IO.FS.writeFile path <| String.intercalate "\n" [
      "import Lean",
      "",
      "open Lean Elab Command",
      "",
      s!"elab \"stress_probe_sleep_{i}\" : command => do",
      "  IO.sleep 1000",
      "",
      s!"def stressProbeStart{i} : Nat := {i}",
      "",
      s!"stress_probe_sleep_{i}",
      "",
      s!"def stressProbeDone{i} : Nat := stressProbeStart{i} + 1",
      ""
    ]
    paths := paths.push path
  pure paths

private def writeInvalidStressSyncFiles (root : System.FilePath) (count : Nat) : IO (Array System.FilePath) := do
  let dir := root / ".tmp" / s!"beam-sync-invalid-stress-probe-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let mut paths := #[]
  for i in [0:count] do
    let path := dir / s!"InvalidStress{i}.lean"
    IO.FS.writeFile path <| String.intercalate "\n" [
      "import Lean",
      "",
      "open Lean Elab Command",
      "",
      s!"elab \"invalid_stress_probe_sleep_{i}\" : command => do",
      "  IO.sleep 500",
      "",
      s!"invalid_stress_probe_sleep_{i}",
      "",
      s!"def invalidStressNat{i} : Nat := \"not a nat\"",
      s!"def invalidStressBool{i} : Bool := {i}",
      s!"theorem invalidStressProof{i} : False := by",
      "  exact trivial",
      ""
    ]
    paths := paths.push path
  pure paths

private def syncRequest
    (path : String)
    (clientRequestId : String) : Beam.Broker.Request := {
  payload := .syncFile {
    path := path
  }
  clientRequestId? := some clientRequestId
}

private def requireSyncOk (label : String) (resp : Beam.Broker.Response) : IO Unit := do
  discard <| requireSyncFileResult label (← expectOk resp)

private structure SyncOutcome where
  label : String
  ok : Bool
  code? : Option String := none
  saveReady? : Option Bool := none
  errorCount? : Option Nat := none
  detail : String

private def runSyncOutcome
    (endpoint : Beam.Broker.Endpoint)
    (path : String)
    (clientRequestId : String) : IO SyncOutcome := do
  let started ← IO.monoNanosNow
  try
    let resp ← runClient endpoint (syncRequest path clientRequestId)
    let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
    if resp.ok then
      match resp.result? with
      | some payload =>
          match fromJson? (α := Beam.Broker.SyncFileResult) payload with
          | .ok result =>
              pure {
                label := clientRequestId
                ok := true
                saveReady? := some result.readiness.saveReady
                errorCount? := some result.readiness.blockingErrorCount
                detail := s!"ok snapshot={result.snapshot} saveReady={result.readiness.saveReady} elapsedMs={elapsedMs}"
              }
          | .error err =>
              pure {
                label := clientRequestId
                ok := false
                code? := some "invalidSyncPayload"
                detail := s!"ok response had invalid sync payload: {err}; response={(toJson resp).compress}"
              }
      | none =>
          pure {
            label := clientRequestId
            ok := false
            code? := some "missingResult"
            detail := s!"ok response omitted result; response={(toJson resp).compress}"
          }
    else
      let code := resp.error?.map (·.code) |>.getD "<missing>"
      let message := resp.error?.map (·.message) |>.getD "<missing>"
      pure {
        label := clientRequestId
        ok := false
        code? := some code
        detail := s!"error code={code} message={message} elapsedMs={elapsedMs}"
      }
  catch err =>
    let elapsedMs := ((← IO.monoNanosNow) - started) / 1000000
    pure {
      label := clientRequestId
      ok := false
      code? := some "transportException"
      detail := s!"transport exception after {elapsedMs}ms: {err}"
    }

private def runStressRound
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (round : Nat)
    (paths : Array System.FilePath) : IO (Array SyncOutcome) := do
  let mut tasks := #[]
  for i in [0:paths.size] do
    let path := paths[i]!
    let relPath := Beam.pathRelativeToRootOrSelf root path
    let requestId := s!"stress-r{round}-sync-{i}"
    let task ← IO.asTask (prio := Task.Priority.dedicated) <|
      runSyncOutcome endpoint relPath requestId
    tasks := tasks.push task
  let mut outcomes := #[]
  for task in tasks do
    outcomes := outcomes.push (← awaitTask "stress sync" task)
  pure outcomes

private def stressFailureLines
    (label : String)
    (outcomes : Array SyncOutcome)
    (bad : SyncOutcome → Bool) : List String :=
  let failures := outcomes.filter bad
  (s!"{label}: observed {failures.size} failures out of {outcomes.size} concurrent sync requests") ::
    (failures.map (fun failure => s!"  {failure.label}: {failure.detail}")).toList

private def requireValidStressOutcomes
    (label : String)
    (outcomes : Array SyncOutcome) : IO Unit := do
  let bad := fun outcome =>
    !outcome.ok || outcome.saveReady? != some true || outcome.errorCount? != some 0
  unless (outcomes.filter bad).isEmpty do
    throw <| IO.userError <| String.intercalate "\n" <| stressFailureLines label outcomes bad

private def requireInvalidStressOutcomes
    (label : String)
    (outcomes : Array SyncOutcome) : IO Unit := do
  let bad := fun outcome =>
    !outcome.ok || outcome.saveReady? != some false || outcome.errorCount?.getD 0 == 0
  unless (outcomes.filter bad).isEmpty do
    throw <| IO.userError <| String.intercalate "\n" <| stressFailureLines label outcomes bad

private def runStressProbeWith
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (label : String)
    (paths : Array System.FilePath)
    (check : String → Array SyncOutcome → IO Unit) : IO Unit := do
  let mut allOutcomes := #[]
  for round in [0:4] do
    let outcomes ← runStressRound endpoint root round paths
    allOutcomes := allOutcomes ++ outcomes
  check label allOutcomes

private def runStressProbe
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  runStressProbeWith endpoint root
    "valid sync stress"
    (← writeValidStressSyncFiles root 12)
    requireValidStressOutcomes
  runStressProbeWith endpoint root
    "invalid sync stress"
    (← writeInvalidStressSyncFiles root 12)
    requireInvalidStressOutcomes

private partial def waitUntilTraceContains
    (traceRef : IO.Ref String)
    (needle : String)
    (tries : Nat := 100) : IO Unit := do
  if (← traceRef.get).contains needle then
    pure ()
  else if tries == 0 then
    throw <| IO.userError s!"timed out waiting for broker trace line containing '{needle}'"
  else
    IO.sleep 50
    waitUntilTraceContains traceRef needle (tries - 1)

private partial def drainTrace
    (stream : IO.FS.Stream)
    (traceRef : IO.Ref String) : IO Unit := do
  let chunk ← stream.getLine
  if chunk.isEmpty then
    pure ()
  else
    traceRef.modify (· ++ chunk)
    drainTrace stream traceRef

private def writeSameFileSupersessionSlow (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-sync-supersession-probe-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "SameFile.lean"
  IO.FS.writeFile path <| String.intercalate "\n" [
    "import Lean",
    "",
    "open Lean Elab Command",
    "",
    "elab \"same_file_supersession_sleep\" : command => do",
    "  IO.sleep 3000",
    "",
    "same_file_supersession_sleep",
    "",
    "def sameFileSupersessionValue : Nat := 1",
    ""
  ]
  pure path

private def writeSameFileSupersessionFast (path : System.FilePath) : IO Unit := do
  IO.FS.writeFile path <| String.intercalate "\n" [
    "def sameFileSupersessionValue : Nat := 2",
    ""
  ]

private def runSameFileSupersessionProbe
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (traceRef : IO.Ref String) : IO Unit := do
  let path ← writeSameFileSupersessionSlow root
  let relPath := Beam.pathRelativeToRootOrSelf root path
  let oldTask ← IO.asTask (prio := Task.Priority.dedicated) <|
    runSyncOutcome endpoint relPath "same-file-old"
  waitUntilTraceContains traceRef "sync_file await barrier clientRequestId=same-file-old"
  writeSameFileSupersessionFast path
  let newOutcome ← runSyncOutcome endpoint relPath "same-file-new"
  let oldOutcome ← awaitTask "same-file old sync" oldTask
  unless newOutcome.ok do
    throw <| IO.userError s!"newer same-file sync should succeed, got {newOutcome.detail}"
  -- Current behavior reports `contentModified` for the older in-flight sync. A future
  -- same-file supersession path may report cancellation instead; either is a typed stale outcome.
  unless oldOutcome.code? == some "contentModified" || oldOutcome.code? == some "requestCancelled" do
    throw <| IO.userError <| String.intercalate "\n" [
      "older same-file sync should finish with a typed stale/cancelled response",
      s!"newer sync result: {newOutcome.detail}",
      s!"older sync result: {oldOutcome.detail}"
    ]

private def lineIndex? (lines : Array String) (needle : String) : Option Nat := Id.run do
  for h : i in [0:lines.size] do
    if lines[i].contains needle then
      return some i
  none

private def requireLineIndex (lines : Array String) (needle : String) : IO Nat := do
  match lineIndex? lines needle with
  | some index => pure index
  | none =>
      throw <| IO.userError s!"missing broker trace line containing '{needle}'\ntrace:\n{String.intercalate "\n" lines.toList}"

private def checkOptionalOverlapTrace (trace : String) : IO Unit := do
  let lines := (trace.split (· == '\n')).map (·.trimAscii.toString) |>.filter (!·.isEmpty) |>.toArray
  discard <| requireLineIndex lines "sync_file await barrier clientRequestId=probe-slow"
  discard <| requireLineIndex lines "sync_file barrier completed clientRequestId=probe-slow"

def main : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let root ← BeamTest.Broker.SmokeTest.repoRoot
  let traceRef ← IO.mkRef ""
  let broker ← spawnTracedLeanBrokerWithPlugin endpoint root
    (← BeamTest.Broker.SmokeTest.pluginPath)
    (← BeamTest.Broker.SmokeTest.leanCmd)
  let traceTask ← IO.asTask (prio := Task.Priority.dedicated) do
    try
      drainTrace (IO.FS.Stream.ofHandle broker.stderr) traceRef
    catch _ =>
      pure ()
  try
    waitForBrokerReadyForRoot endpoint root
    discard <| expectOk (← runClient endpoint Beam.Broker.Request.ensure)
    let fastPath := "tests/scenario/docs/CommandA.lean"
    requireSyncOk "warm fast sync" <| ← runClient endpoint (syncRequest fastPath "probe-warm")

    let slowPath ← writeConcurrencySlowSyncFile root
    let slowTask ← IO.asTask (prio := Task.Priority.dedicated) <|
      runClient endpoint (syncRequest slowPath.toString "probe-slow")
    waitUntilTraceContains traceRef "sync_file await barrier clientRequestId=probe-slow"

    let fastResp ← runClient endpoint (syncRequest fastPath "probe-fast")
    requireSyncOk "fast sync during slow sync" fastResp
    let slowResp ← awaitTask "slow sync" slowTask
    requireSyncOk "slow sync" slowResp

    runStressProbe endpoint root
    runSameFileSupersessionProbe endpoint root traceRef

    let shutdownResp ← runClient endpoint Beam.Broker.Request.shutdown
    discard <| expectOk shutdownResp
    IO.sleep 100
    checkOptionalOverlapTrace (← traceRef.get)
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| IO.wait traceTask

end BeamTest.Broker.SyncConcurrencyProbe

def main := BeamTest.Broker.SyncConcurrencyProbe.main
