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
  /-- Lean-rendered header for a selected summary entry. Never retains the message context. -/
  label? : Option String := none
  deriving FromJson, ToJson, Inhabited

/-- Wall-clock evidence from one speculative execution in its already-loaded environment.
Span durations overlap and must not be summed to obtain `elapsedMs`. -/
structure Result where
  elapsedMs : Float
  /-- The collection threshold installed at request start; nested Lean scopes can override it. -/
  initialThresholdMs : Nat := 1
  spans : Array Span := #[]
  truncated : Bool := false
  deriving FromJson, ToJson

def initialThresholdMs : Nat := 1
def maxSpans : Nat := 1024
def maxVisited : Nat := 8192
def maxDepth : Nat := 128
def maxTopSpans : Nat := 10
def maxLabelChars : Nat := 160
private def maxSnippetSourceBytes : Nat := 8192

/-- A maximal single-child path in the retained forest. Endpoints keep their own measurements;
one retained child does not imply equal cost or complete coverage of its parent. -/
structure Chain where
  outer : Nat
  inner : Nat
  size : Nat
  deriving BEq

/-- Summary views refer to retained spans. Top entries group paths; a phase entry is the largest
observed span of its category, not a sum or a claim that the entire phase was recorded. -/
structure Selection where
  top : Array Chain := #[]
  phases : Array Nat := #[]
  deriving BEq

def select (spans : Array Span) : Selection := Id.run do
  let ranked := (Array.range spans.size).qsort fun i j =>
    spans[i]!.durationMs > spans[j]!.durationMs ||
      (spans[i]!.durationMs == spans[j]!.durationMs && i < j)
  let mut children : Array (Array Nat) := Array.replicate spans.size #[]
  for i in [:spans.size] do
    if let some parent := spans[i]!.parent? then
      if parent < i then
        children := children.modify parent (·.push i)
  let mut top : Array Chain := #[]
  for i in ranked do
    if top.size == maxTopSpans then break
    if let some parent := spans[i]!.parent? then
      if parent < i && children[parent]!.size == 1 then continue
    let mut inner := i
    let mut size := 1
    -- Edges go forward, so a path visits at most spans.size nodes.
    for _ in [:spans.size] do
      if children[inner]!.size != 1 then break
      inner := children[inner]![0]!
      size := size + 1
    top := top.push { outer := i, inner, size }
  let mut phases := #[]
  for category in #["Kernel", "Elab.def.maxSharing", "addDecl", "Elab.definition.value", "Elab.lint"] do
    if let some index := ranked.find? (fun i => spans[i]!.category == category) then
      phases := phases.push index
  return { top, phases }

/-- The number of raw spans represented by top paths, including their intermediate nodes. -/
def Selection.represented (selection : Selection) : Nat :=
  selection.top.foldl (fun count chain => count + chain.size) 0

/-- Render an entry shared by the two views only once. -/
def Selection.indices (selection : Selection) : Array Nat := Id.run do
  let mut indices := #[]
  for chain in selection.top do
    indices := indices.push chain.outer
    if chain.inner != chain.outer then indices := indices.push chain.inner
  return selection.phases.foldl (fun indices index =>
    if indices.contains index then indices else indices.push index) indices

/-- Retain structured trace data in memory. An explicitly present empty export path is Lean's
retention switch; Beam never calls the frontend's profile file writer or HTTP server. -/
def options (opts : Options) : Options :=
  opts.setBool `trace.profiler true
    |>.set `trace.profiler.threshold initialThresholdMs
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
  /-- Temporary references only, bounded with spans and dropped before publishing a result. -/
  headers : Array MessageData := #[]
  visited : Nat := 0
  truncated : Bool := false

private def boundedNameString (name : Name) (limit : Nat) : String × Bool := Id.run do
  let mut current := name
  let mut parts : Array String := #[]
  let mut remaining := limit
  let mut first := true
  let mut truncated := false
  let mut fuel := limit + 1
  while fuel > 0 do
    fuel := fuel - 1
    match current with
    | .anonymous => break
    | .str parent original =>
      let separatorSize := if first then 0 else 1
      if separatorSize >= remaining then
        truncated := true
        break
      let part := (original.take (remaining - separatorSize)).toString
      if part != original then
        truncated := true
      parts := parts.push part
      remaining := remaining - separatorSize - part.length
      current := parent
      first := false
      if truncated then break
    | .num parent value =>
      let separatorSize := if first then 0 else 1
      if separatorSize >= remaining then
        truncated := true
        break
      -- A maliciously large numeric component should not make label rendering allocate an
      -- unbounded decimal string. Normal profiler categories use ordinary, short names.
      let tooLarge := value > 999999999999999999
      let raw := if tooLarge then "…" else toString value
      let part := (raw.take (remaining - separatorSize)).toString
      if tooLarge || part != raw then
        truncated := true
      parts := parts.push part
      remaining := remaining - separatorSize - part.length
      current := parent
      first := false
      if truncated then break
  let hasRemaining := match current with | .anonymous => false | _ => true
  if hasRemaining then
    truncated := true
  return (String.intercalate "." parts.toList.reverse, truncated)

private def snippetRange? (text : String) (ref : Syntax) : Option Lean.Lsp.Range := do
  -- Bounds alone cannot establish provenance: a custom trace may carry syntax from another file.
  -- Comparing source strings is bounded too; for larger inputs, omit the optional range.
  guard (text.utf8ByteSize <= maxSnippetSourceBytes)
  let source ← ref.getSubstring?
  guard (source.str == text)
  let start ← ref.getPos?
  let stop ← ref.getTailPos?
  guard (start <= stop && stop.byteIdx <= text.utf8ByteSize)
  let fileMap := text.toFileMap
  return { start := fileMap.utf8PosToLspPos start, «end» := fileMap.utf8PosToLspPos stop }

private def visit (origin stop : Float) (thread : UInt64) (fuel : Nat)
    (heartbeatClock : Bool) (wrap : MessageData → MessageData)
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
    | .trace data header children =>
      let mut parent? := parent?
      -- Exclude untimed nodes and invalid intervals. The request-clock bounds also prevent traces
      -- inherited from a saved snapshot from being presented as work done by this request.
      -- TraceData has no clock tag. Lean's message context records the surrounding options;
      -- never reinterpret a known heartbeat-clock node as seconds, even if its numbers happen
      -- to lie in the request interval. A child's own context can restore wall-clock collection.
      if heartbeatClock then
        modify fun s => { s with truncated := true }
      else if data.startTime >= origin && data.stopTime >= data.startTime && data.stopTime <= stop then
        let index := (← get).spans.size
        let (category, categoryTruncated) := boundedNameString data.cls 160
        let tag := (data.tag.take 256).toString
        modify fun s => { s with
          truncated := s.truncated || categoryTruncated || tag != data.tag
          spans := s.spans.push {
            parent?, thread, category, tag
            startMs := (data.startTime - origin) * 1000
            durationMs := (data.stopTime - data.startTime) * 1000
            range?
          }
          headers := s.headers.push (wrap header)
        }
        parent? := some index
      for child in children do
        if (← get).visited >= maxVisited || (← get).spans.size >= maxSpans then
          modify fun s => { s with truncated := true }
          break
        -- Nested MessageData does not retain a trustworthy source reference on all supported
        -- Lean versions. Do not copy an enclosing range onto a child.
        visit origin stop thread fuel heartbeatClock wrap parent? none child
    | .withContext context msg =>
      visit origin stop thread fuel (trace.profiler.useHeartbeats.get context.opts)
        (fun m => wrap (.withContext context m)) parent? range? msg
    | .withNamingContext context msg =>
      visit origin stop thread fuel heartbeatClock
        (fun m => wrap (.withNamingContext context m)) parent? range? msg
    | .nest _ msg | .group msg | .tagged _ msg | .ofWidget _ msg
    | .ofOriginatingSyntax _ msg => visit origin stop thread fuel heartbeatClock wrap parent? range? msg
    | .compose left right =>
      visit origin stop thread fuel heartbeatClock wrap parent? range? left
      visit origin stop thread fuel heartbeatClock wrap parent? range? right
    | _ => pure ()

private def project (startNs stopNs : Nat) (states : Array TraceState) (text : String) : Projection := Id.run do
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
        visit origin stop state.tid maxDepth false id none (snippetRange? text trace.ref) trace.msg
  let (_, projection) := project.run {}
  return projection

private def Projection.result (projection : Projection) (startNs stopNs : Nat) : Result := {
    elapsedMs := (stopNs - startNs).toFloat / 1000000
    initialThresholdMs
    spans := projection.spans
    truncated := projection.truncated
}

/-- Project a bounded forest without evaluating lazy labels or pretty-printing expressions.
The limits bound this projection and its response, not Lean's upstream trace allocation. -/
def collect (startNs stopNs : Nat) (states : Array TraceState) (text : String) : Result :=
  (project startNs stopNs states text).result startNs stopNs

private def renderLabel (header : MessageData) : BaseIO (Option String) := do
  -- Use Lean's context-aware renderer, as its profiler exporter does. A custom label can perform
  -- IO; keep it away from the protocol streams. Clipping bounds output, not rendering work.
  let (_, rendered) ← IO.FS.withIsolatedStreams do
    let label ← header.toString
    let bounded := (label.take (maxLabelChars + 1)).toString
    if bounded.length > maxLabelChars then
      return some ((bounded.take (maxLabelChars - 1)).toString ++ "…")
    return if bounded.isEmpty then none else some bounded
  return rendered

/-- Add Lean-rendered headers only for summary entries, after the measured execution ends.
Cancellation is checked between labels, never by abandoning an active formatter. Only bounded
strings escape; trace headers and their contexts cannot be retained in results or handles. -/
def collectWithLabels {m : Type → Type} [Monad m] [MonadLiftT BaseIO m]
    (checkCancelled : m Unit) (startNs stopNs : Nat) (states : Array TraceState)
    (text : String) : m Result := do
  let projection := project startNs stopNs states text
  let mut result := projection.result startNs stopNs
  for index in (select result.spans).indices do
    checkCancelled
    let label? ← renderLabel projection.headers[index]!
    result := { result with
      spans := result.spans.modify index fun span => { span with label? } }
  checkCancelled
  return result

end Beam.LSP.RunAt.Profile
