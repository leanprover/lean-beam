/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.LSP.RunAt.Profile

/-- A timed, instrumented Lean scope. Parent indices refer to earlier entries in `spans`.
Ranges, when available, are relative to the submitted text, never the tracked document. -/
structure Span where
  parent? : Option Nat := none
  thread : UInt64
  category : String
  tag : String
  startMs : Float
  durationMs : Float
  range? : Option Lean.Lsp.Range := none
  deriving FromJson, ToJson, Inhabited

/-- Wall-clock evidence from one speculative execution in its already-loaded environment.
Span durations overlap and must not be summed to obtain `elapsedMs`. -/
structure Result where
  elapsedMs : Float
  thresholdMs : Nat := 1
  spans : Array Span := #[]
  truncated : Bool := false
  deriving FromJson, ToJson

def thresholdMs : Nat := 1
def maxSpans : Nat := 1024
def maxVisited : Nat := 8192
def maxDepth : Nat := 128

/-- Retain structured trace data in memory. An explicitly present empty export path is Lean's
retention switch; Beam never calls the frontend's profile file writer or HTTP server. -/
def options (opts : Options) : Options :=
  opts.setBool `trace.profiler true
    |>.set `trace.profiler.threshold thresholdMs
    |>.setBool `trace.profiler.useHeartbeats false
    |>.set `trace.profiler.output ("")
    |>.setBool `trace.profiler.serve false

private def restoreOption [KVMap.Value α] (key : Name) (before after : Options) : Options :=
  match before.get? (α := α) key with
  | some value => after.set key value
  | none => after.erase key

/-- Remove only instrumentation options; retain unrelated options changed by the submitted command. -/
def restoreOptions (before after : Options) : Options :=
  restoreOption (α := Bool) `trace.profiler before after
    |> restoreOption (α := Nat) `trace.profiler.threshold before
    |> restoreOption (α := Bool) `trace.profiler.useHeartbeats before
    |> restoreOption (α := String) `trace.profiler.output before
    |> restoreOption (α := Bool) `trace.profiler.serve before

/-- Align scopes from the outermost scope, allowing the command to open or close a namespace.
New scopes inherit the original active scope's profiling options. -/
def restoreScopes (before after : List Elab.Command.Scope) : List Elab.Command.Scope := Id.run do
  let originals := before.reverse.toArray
  let fallback := before.head?.map (·.opts) |>.getD {}
  let restored := after.reverse.toArray.mapIdx fun i scope =>
    { scope with opts := restoreOptions ((originals[i]?).map (·.opts) |>.getD fallback) scope.opts }
  return restored.toList.reverse

private structure Projection where
  spans : Array Span := #[]
  visited : Nat := 0
  truncated : Bool := false

private def snippetRange? (text : String) (ref : Syntax) : Option Lean.Lsp.Range := do
  -- Bounds alone cannot establish provenance: a custom trace may carry syntax from another file.
  let source ← ref.getSubstring?
  guard (source.str == text)
  let start ← ref.getPos?
  let stop ← ref.getTailPos?
  guard (start <= stop && stop.byteIdx <= text.utf8ByteSize)
  let fileMap := text.toFileMap
  return { start := fileMap.utf8PosToLspPos start, «end» := fileMap.utf8PosToLspPos stop }

private def visit (origin stop : Float) (thread : UInt64) (fuel : Nat)
    (parent? : Option Nat) (range? : Option Lean.Lsp.Range) (msg : MessageData) :
    StateM Projection Unit := do
  let state ← get
  if state.visited >= maxVisited || state.spans.size >= maxSpans then
    modify fun s => { s with truncated := true }
    return
  match fuel with
  | 0 => modify fun s => { s with truncated := true }
  | fuel + 1 =>
    modify fun s => { s with visited := s.visited + 1 }
    match msg with
    | .trace data _ children =>
      let mut parent? := parent?
      -- Exclude untimed nodes and invalid/non-finite intervals. The bounds also prevent traces
      -- inherited from a saved snapshot from being presented as work done by this request.
      if data.startTime >= origin && data.stopTime >= data.startTime && data.stopTime <= stop then
        let index := (← get).spans.size
        let fullCategory := data.cls.toString
        let category := (fullCategory.take 160).toString
        let tag := (data.tag.take 256).toString
        modify fun s => { s with
          truncated := s.truncated || category != fullCategory || tag != data.tag
          spans := s.spans.push {
          parent?, thread
          category, tag
          startMs := (data.startTime - origin) * 1000
          durationMs := (data.stopTime - data.startTime) * 1000
          range?
        } }
        parent? := some index
      for child in children do
        if (← get).visited >= maxVisited || (← get).spans.size >= maxSpans then
          modify fun s => { s with truncated := true }
          break
        -- Nested MessageData does not retain a trustworthy source reference on all supported
        -- Lean versions. Do not copy an enclosing range onto a child.
        visit origin stop thread fuel parent? none child
    | .withContext _ msg | .withNamingContext _ msg | .nest _ msg | .group msg
    | .tagged _ msg | .ofWidget _ msg => visit origin stop thread fuel parent? range? msg
    | .compose left right =>
      visit origin stop thread fuel parent? range? left
      visit origin stop thread fuel parent? range? right
    | _ => pure ()

/-- Project a bounded forest without evaluating lazy labels or pretty-printing expressions.
The limits bound this projection and its response, not Lean's upstream trace allocation. -/
def collect (startNs stopNs : Nat) (states : Array TraceState) (text : String) : Result := Id.run do
  let origin := startNs.toFloat / 1000000000
  let stop := stopNs.toFloat / 1000000000
  let project : StateM Projection Unit := do
    for state in states do
      if (← get).visited >= maxVisited then
        modify fun s => { s with truncated := true }
        return
      modify fun s => { s with visited := s.visited + 1 }
      for trace in state.traces do
        if (← get).visited >= maxVisited || (← get).spans.size >= maxSpans then
          modify fun s => { s with truncated := true }
          return
        visit origin stop state.tid maxDepth none (snippetRange? text trace.ref) trace.msg
  let (_, projection) := project.run {}
  return {
    elapsedMs := (stopNs - startNs).toFloat / 1000000
    thresholdMs
    spans := projection.spans
    truncated := projection.truncated
  }

end Beam.LSP.RunAt.Profile
