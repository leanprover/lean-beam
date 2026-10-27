/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Mcp.Projection

/-!
Execution-admission accounting for the MCP stdio coordinator.

Ordinary requests share one configurable pool. Workspace drops and process observation use that
pool while it has room, then fall back to small fixed reserves of their own, so a saturated
ordinary pool cannot block recovery. Separate reserves keep queued drops from starving observation.
-/

namespace Beam.Mcp.Admission

/-- How a request is admitted, fenced by workspace drops, and protected from cancellation. -/
inductive RequestClass where
  /-- Workspace-bound and protocol work; waits for workspace-drop fences. -/
  | ordinary
  /-- `lean_drop_workspace`: installs a drop fence and is protected once started. -/
  | workspaceControl
  /-- `beam_version`, `beam_stats`, and `ping`: never touch a workspace runtime or its fence. -/
  | observation
  deriving BEq, Repr

def classify (method : String) (tool? : Option ToolName) : RequestClass :=
  match method, tool? with
  | "tools/call", some .leanDropWorkspace => .workspaceControl
  | "tools/call", some .beamVersion | "tools/call", some .beamStats => .observation
  | "ping", _ => .observation
  | _, _ => .ordinary

/-- The capacity an admitted request is charged to, and later released from. -/
inductive Pool where
  | ordinary
  | controlReserve
  | observationReserve
  deriving BEq, Repr

def Pool.isReserve : Pool → Bool
  | .ordinary => false
  | .controlReserve | .observationReserve => true

/-- Pools a class may use, in order of preference. -/
def RequestClass.pools : RequestClass → List Pool
  | .ordinary => [.ordinary]
  | .workspaceControl => [.ordinary, .controlReserve]
  | .observation => [.ordinary, .observationReserve]

def defaultOrdinaryLimit : Nat := 32
def maxOrdinaryLimit : Nat := 1024

structure Limits where
  ordinary : Nat := defaultOrdinaryLimit
  controlReserve : Nat := 2
  observationReserve : Nat := 2
  deriving Repr

def Limits.capacity (limits : Limits) : Pool → Nat
  | .ordinary => limits.ordinary
  | .controlReserve => limits.controlReserve
  | .observationReserve => limits.observationReserve

/-- Unfinished admissions per pool. Each is released exactly once, after execution settles. -/
structure Ledger where
  ordinary : Nat := 0
  controlReserve : Nat := 0
  observationReserve : Nat := 0
  deriving BEq, Repr

def Ledger.inUse (ledger : Ledger) : Pool → Nat
  | .ordinary => ledger.ordinary
  | .controlReserve => ledger.controlReserve
  | .observationReserve => ledger.observationReserve

private def Ledger.update (ledger : Ledger) (pool : Pool) (f : Nat → Nat) : Ledger :=
  match pool with
  | .ordinary => { ledger with ordinary := f ledger.ordinary }
  | .controlReserve => { ledger with controlReserve := f ledger.controlReserve }
  | .observationReserve => { ledger with observationReserve := f ledger.observationReserve }

def Ledger.hasRoom (ledger : Ledger) (limits : Limits) (pool : Pool) : Bool :=
  ledger.inUse pool < limits.capacity pool

/-- Pools with room for this class, in order of preference. Empty means the request is busy. -/
def Ledger.candidates (ledger : Ledger) (limits : Limits) (cls : RequestClass) : List Pool :=
  cls.pools.filter (ledger.hasRoom limits)

/-- Charge one admission to `pool`, or `none` when it has no room. -/
def Ledger.acquire? (ledger : Ledger) (limits : Limits) (pool : Pool) : Option Ledger :=
  if ledger.hasRoom limits pool then some (ledger.update pool (· + 1)) else none

def Ledger.release (ledger : Ledger) (pool : Pool) : Ledger :=
  ledger.update pool (· - 1)

/-- Parse the startup `--max-unfinished-requests` value. -/
def parseOrdinaryLimit (text : String) : Except String Nat := do
  let invalid := s!"--max-unfinished-requests expects an integer from 1 to {maxOrdinaryLimit}, got '{text}'"
  if text.isEmpty || !text.all Char.isDigit then throw invalid
  -- Digit strings are arbitrary precision; bound the length before the value.
  if text.length > (toString maxOrdinaryLimit).length + 8 then throw invalid
  let some value := text.toNat? | throw invalid
  if value == 0 || value > maxOrdinaryLimit then throw invalid
  pure value

end Beam.Mcp.Admission
