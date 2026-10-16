/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Broker

structure OpStats where
  count : Nat := 0
  successCount : Nat := 0
  errorCount : Nat := 0
  cancelledCount : Nat := 0
  workerExitedCount : Nat := 0
  invalidParamsCount : Nat := 0
  totalLatencyMs : Nat := 0
  maxLatencyMs : Nat := 0
  lastLatencyMs : Nat := 0

/--
Workspace counters retained across Lean session restarts.
Resetting the workspace or dropping and recreating it starts fresh counters.
-/
structure WorkspaceMetrics where
  sessionStarts : Nat := 0
  sessionRestarts : Nat := 0
  requestCount : Nat := 0
  successCount : Nat := 0
  errorCount : Nat := 0
  cancelledCount : Nat := 0
  workerExitedCount : Nat := 0
  invalidParamsCount : Nat := 0
  ops : Std.TreeMap String OpStats := {}

def isCancelledCode (errorCode? : Option String) : Bool :=
  errorCode? == some "requestCancelled"

def isWorkerExitedCode (errorCode? : Option String) : Bool :=
  errorCode? == some "workerExited"

def isInvalidParamsCode (errorCode? : Option String) : Bool :=
  errorCode? == some "invalidParams" || errorCode? == some "-32602"

def OpStats.record (stats : OpStats) (ok : Bool) (errorCode? : Option String) (latencyMs : Nat) : OpStats :=
  {
    count := stats.count + 1
    successCount := stats.successCount + (if ok then 1 else 0)
    errorCount := stats.errorCount + (if ok then 0 else 1)
    cancelledCount := stats.cancelledCount + (if isCancelledCode errorCode? then 1 else 0)
    workerExitedCount := stats.workerExitedCount + (if isWorkerExitedCode errorCode? then 1 else 0)
    invalidParamsCount := stats.invalidParamsCount + (if isInvalidParamsCode errorCode? then 1 else 0)
    totalLatencyMs := stats.totalLatencyMs + latencyMs
    maxLatencyMs := max stats.maxLatencyMs latencyMs
    lastLatencyMs := latencyMs
  }

def avgLatencyMs (count total : Nat) : Nat :=
  if count == 0 then 0 else total / count

def opStatsJson (stats : OpStats) : Json :=
  Json.mkObj [
    ("count", toJson stats.count),
    ("successCount", toJson stats.successCount),
    ("errorCount", toJson stats.errorCount),
    ("cancelledCount", toJson stats.cancelledCount),
    ("workerExitedCount", toJson stats.workerExitedCount),
    ("invalidParamsCount", toJson stats.invalidParamsCount),
    ("avgLatencyMs", toJson (avgLatencyMs stats.count stats.totalLatencyMs)),
    ("maxLatencyMs", toJson stats.maxLatencyMs),
    ("lastLatencyMs", toJson stats.lastLatencyMs)
  ]

def workspaceMetricsJson (metrics : WorkspaceMetrics) : Json :=
  Json.mkObj <|
    [
      ("sessionStarts", toJson metrics.sessionStarts),
      ("sessionRestarts", toJson metrics.sessionRestarts),
      ("requestCount", toJson metrics.requestCount),
      ("successCount", toJson metrics.successCount),
      ("errorCount", toJson metrics.errorCount),
      ("cancelledCount", toJson metrics.cancelledCount),
      ("workerExitedCount", toJson metrics.workerExitedCount),
      ("invalidParamsCount", toJson metrics.invalidParamsCount)
    ] ++
    [("ops", Json.mkObj <| metrics.ops.toList.map fun (op, stats) => (op, opStatsJson stats))]

end Beam.Broker
