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
  /-- Canonical offsets in nanoseconds from the request origin. JSON preserves both exactly. -/
  startNs : Nat
  stopNs : Nat
  /-- Wall time uncovered by all visited direct same-thread children, before retention. -/
  selfNs : Nat := 0
  range? : Option Lean.Lsp.Range := none
  /-- Lean-rendered header for a selected summary entry. Never retains the message context. -/
  label? : Option String := none
  deriving FromJson, ToJson, Inhabited

def Span.durationNs (span : Span) : Nat := span.stopNs - span.startNs

inductive TruncationReason where
  | retention | visits | depth | identifier | clock
  deriving BEq, FromJson, ToJson, Repr

/-- Wall-clock evidence from one speculative execution in its already-loaded environment.
Span durations overlap and must not be summed to obtain `elapsedNs`. -/
structure Result where
  elapsedNs : Nat
  /-- The collection threshold installed at request start; nested Lean scopes can override it. -/
  initialThresholdMs : Nat := 1
  spans : Array Span := #[]
  truncationReasons : Array TruncationReason := #[]
  deriving FromJson, ToJson

def Result.truncated (result : Result) : Bool := !result.truncationReasons.isEmpty

def initialThresholdMs : Nat := 1
def maxSpans : Nat := 128
def maxVisited : Nat := 16384
def maxDepth : Nat := 256
def maxTopSpans : Nat := 8
def maxSelfSpans : Nat := 5
def maxLabelChars : Nat := 160
private def maxSnippetSourceBytes : Nat := 8192

private def reservedPhaseCategories : Array String :=
  #["Kernel", "Elab.def.maxSharing", "addDecl", "Elab.definition.value", "Elab.lint"]

/-- A maximal single-child path in the retained forest. `inner` is its displayed descendant,
not necessarily its last node: choose the deepest member with at least half the positive outer
duration. This presentation heuristic does not attribute the outer cost to that member. `size`
counts the full structural path, including the tail below the displayed member. -/
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
  topSelf : Array Nat := #[]
  deriving BEq

def select (spans : Array Span) : Selection := Id.run do
  let ranked := (Array.range spans.size).qsort fun i j =>
    spans[i]!.durationNs > spans[j]!.durationNs ||
      (spans[i]!.durationNs == spans[j]!.durationNs && i < j)
  let mut children : Array (Array Nat) := Array.replicate spans.size #[]
  for i in [:spans.size] do
    if let some parent := spans[i]!.parent? then
      if parent < i then
        children := children.modify parent (·.push i)
  -- Only a branch starts new descendant groups. Propagate their largest outer duration up
  -- through every intermediate node, including wrappers within the same group.
  let mut below := Array.replicate spans.size 0
  for offset in [:spans.size] do
    let i := spans.size - 1 - offset
    if let some parent := spans[i]!.parent? then
      if parent < i then
        let largest := if children[parent]!.size == 1 then below[i]!
          else max below[i]! spans[i]!.durationNs
        below := below.modify parent (max largest)
  let mut top : Array Chain := #[]
  for i in ranked do
    if top.size == maxTopSpans then break
    if let some parent := spans[i]!.parent? then
      if parent < i && children[parent]!.size == 1 then continue
    let mut inner := i
    let mut cursor := i
    let mut size := 1
    let outerDuration := spans[i]!.durationNs
    if outerDuration > 0 && 10 * below[i]! >= 9 * outerDuration then continue
    -- Edges go forward, so a path visits at most spans.size nodes.
    for _ in [:spans.size] do
      if children[cursor]!.size != 1 then break
      cursor := children[cursor]![0]!
      size := size + 1
      if outerDuration > 0 && 2 * spans[cursor]!.durationNs >= outerDuration then
        inner := cursor
    top := top.push { outer := i, inner, size }
  let mut phases := #[]
  for category in reservedPhaseCategories.push "Elab.definition.header" do
    if let some index := ranked.find? (fun i => spans[i]!.category == category) then
      phases := phases.push index
  let candidates := (Array.range spans.size).filter fun i => spans[i]!.selfNs > 0 && !phases.contains i
  let bySelf := candidates.qsort fun i j =>
    spans[i]!.selfNs > spans[j]!.selfNs || (spans[i]!.selfNs == spans[j]!.selfNs && i < j)
  return { top, phases, topSelf := bySelf.extract 0 maxSelfSpans }

/-- The number of raw spans represented by top paths, including their intermediate nodes. -/
def Selection.represented (selection : Selection) : Nat :=
  selection.top.foldl (fun count chain => count + chain.size) 0

/-- Render an entry shared by the two views only once. -/
def Selection.indices (selection : Selection) : Array Nat := Id.run do
  let mut indices := #[]
  for chain in selection.top do
    indices := indices.push chain.outer
    if chain.inner != chain.outer then indices := indices.push chain.inner
  return (selection.phases ++ selection.topSelf).foldl (fun indices index =>
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
  truncationReasons : Array TruncationReason := #[]

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

private structure Observation where
  key : List Nat
  span : Span
  -- Temporary original header references; no rendering/evaluation, bounded by valid visits.
  header : MessageData
  deriving Inhabited

private structure Frame where
  thread : UInt64
  fuel : Nat
  heartbeat : Bool := false
  wrap : MessageData → MessageData := id
  parent? : Option Nat := none
  pathRev : List Nat
  range? : Option Lsp.Range := none

private inductive Work where
  | states (index : Nat)
  | roots (stateIndex traceIndex : Nat)
  | children (items : Array MessageData) (next : Nat) (frame : Frame)
  | single (msg : MessageData) (frame : Frame)

private structure Explored where
  observations : Array Observation := #[]
  visited : Nat := 0
  depthStops : Nat := 0
  incompatible : Nat := 0
  clipped : Bool := false
  pendingAtStop : Nat := 0
  deriving Inhabited

private def dispatch (origin stop : Float) (elapsedNs : Nat) (msg : MessageData) (f : Frame)
    (e : Explored) : Explored × Array Work := Id.run do
  if f.fuel == 0 then return ({e with depthStops := e.depthStops + 1}, #[])
  let mut e := {e with visited := e.visited + 1}
  let f := {f with fuel := f.fuel - 1}
  match msg with
  | .trace data header children =>
    let mut f := f
    if f.heartbeat then e := {e with incompatible := e.incompatible + 1}
    else if data.startTime >= origin && data.stopTime >= data.startTime && data.stopTime <= stop then
      let (category, clipped) := boundedNameString data.cls 160
      let tag := (data.tag.take 256).toString
      let index := e.observations.size
      -- Lean records seconds as Floats. At the request stop we already know the exact offset.
      let offsetNs := fun (time : Float) =>
        if time == stop then elapsedNs
        else min elapsedNs (((time - origin) * 1000000000).round.toUInt64.toNat)
      let span : Span := {
        parent? := f.parent?
        thread := f.thread
        category
        tag
        startNs := offsetNs data.startTime
        stopNs := offsetNs data.stopTime
        range? := f.range?
      }
      e := {e with
        observations := e.observations.push {
          key := f.pathRev.reverse
          span
          header := f.wrap header
        }
        clipped := e.clipped || clipped || tag != data.tag
      }
      f := {f with parent? := some index}
    return (e, if children.isEmpty then #[] else #[.children children 0 {f with range? := none}])
  | .withContext context inner =>
    let innerFrame := {f with
      heartbeat := trace.profiler.useHeartbeats.get context.opts
      wrap := fun m => f.wrap (.withContext context m)
      pathRev := 0 :: f.pathRev
    }
    return (e, #[.single inner innerFrame])
  | .withNamingContext context inner =>
    let innerFrame := {f with
      wrap := fun m => f.wrap (.withNamingContext context m)
      pathRev := 0 :: f.pathRev
    }
    return (e, #[.single inner innerFrame])
  | .nest _ inner | .group inner | .tagged _ inner | .ofWidget _ inner | .ofOriginatingSyntax _ inner =>
    return (e, #[.single inner {f with pathRev := 0 :: f.pathRev}])
  | .compose left right => return (e, #[.single left {f with pathRev := 0 :: f.pathRev},
    .single right {f with pathRev := 1 :: f.pathRev}])
  | _ => return (e, #[])

private def Work.level : Work → Nat
  | .states .. | .roots .. => 0
  | .single _ frame | .children _ _ frame => maxDepth - frame.fuel

/-- Visit complete shallow levels before deep descendants. Sequence cursors avoid expanding a
wide array into a work queue. Both retained candidates and pending cursors are bounded by visits.
Context wrappers count as levels, matching the existing depth limit. -/
private def explore (startNs stopNs : Nat) (states : Array TraceState) (text : String) : Explored := Id.run do
  let origin := startNs.toFloat / 1000000000
  let stop := stopNs.toFloat / 1000000000
  let elapsedNs := stopNs - startNs
  let mut levels : Array (List Work) := Array.replicate (maxDepth + 1) []
  if !states.isEmpty then levels := levels.set! 0 [.states 0]
  let mut e : Explored := {}
  for depth in [:maxDepth + 1] do
    for _ in [:3 * maxVisited + 1] do
      if e.visited >= maxVisited then break
      let work :: rest := levels[depth]! | break
      levels := levels.set! depth rest
      let mut tasks := #[]
      match work with
      | .states index =>
        e := {e with visited := e.visited + 1}
        if !states[index]!.traces.isEmpty then tasks := tasks.push (.roots index 0)
        if index + 1 < states.size then tasks := tasks.push (.states (index + 1))
      | .roots si ri =>
        let state := states[si]!
        let item := state.traces[ri]!
        let frame : Frame := {
          thread := state.tid
          fuel := maxDepth
          pathRev := [ri, si]
          range? := snippetRange? text item.ref
        }
        (e, tasks) := dispatch origin stop elapsedNs item.msg frame e
        if ri + 1 < state.traces.size then tasks := tasks.push (.roots si (ri + 1))
      | .children items next frame =>
        (e, tasks) := dispatch origin stop elapsedNs items[next]! {frame with pathRev := next :: frame.pathRev} e
        if next + 1 < items.size then tasks := tasks.push (.children items (next + 1) frame)
      | .single msg frame => (e, tasks) := dispatch origin stop elapsedNs msg frame e
      for task in tasks.reverse do
        levels := levels.modify task.level (task :: ·)
    if e.visited >= maxVisited then break
  return {e with pendingAtStop := levels.foldl (fun n xs => n + xs.length) 0}

private def sourceLT (a b : Observation) : Bool := compare a.key b.key == .lt

/-- Reserve the largest observation of each summary phase, then fill by inclusive duration.
Every admission includes its ancestors inside the same output budget. Equal durations use original
trace-tree order, independent of traversal scheduling. -/
private def retain (e : Explored) (cap : Nat) : Array Nat := Id.run do
  let ranked := (Array.range e.observations.size).qsort fun a b =>
    let x := e.observations[a]!
    let y := e.observations[b]!
    x.span.durationNs > y.span.durationNs ||
      (x.span.durationNs == y.span.durationNs && sourceLT x y)
  let phases := reservedPhaseCategories.filterMap fun category =>
    ranked.find? (fun i => e.observations[i]!.span.category == category)
  let mut selected := #[]
  let mut kept := Array.replicate e.observations.size false
  for i in phases ++ ranked do
    if selected.size == cap then break
    if kept[i]! then continue
    let mut additions := #[i]
    let mut parent := e.observations[i]!.span.parent?
    for _ in [:maxDepth] do
      let some p := parent | break
      if kept[p]! then break
      additions := additions.push p
      parent := e.observations[p]!.span.parent?
    if selected.size + additions.size <= cap then
      for j in additions do
        selected := selected.push j
        kept := kept.set! j true
  return selected.qsort (fun a b => sourceLT e.observations[a]! e.observations[b]!)

/-- Subtract the union once even when siblings overlap, arrive out of order, or cross a
parent endpoint. Children from another thread cannot cover the parent's wall interval. -/
private def uncoveredNs (parent : Span) (intervals : Array (Nat × Nat)) : Nat := Id.run do
  let mut covered := 0
  let mut cursor := parent.startNs
  for (start, stop) in intervals.qsort (fun a b => a.1 < b.1) do
    let stop := min stop parent.stopNs
    covered := covered + (stop - max cursor start)
    cursor := max cursor stop
  return parent.durationNs - covered

private def materialize (explored : Explored) (cap : Nat) : Projection := Id.run do
  let selected := retain explored cap
  let mut indices : Array (Option Nat) := Array.replicate explored.observations.size none
  for i in [:selected.size] do
    indices := indices.set! selected[i]! (some i)
  let mut intervals : Array (Array (Nat × Nat)) := Array.replicate selected.size #[]
  for observation in explored.observations do
    let child := observation.span
    if let some p := child.parent? then
      if let some retained := indices[p]! then
        if child.thread == explored.observations[p]!.span.thread then
          intervals := intervals.modify retained (·.push (child.startNs, child.stopNs))
  let mut reasons : Array TruncationReason := #[]
  if selected.size < explored.observations.size then reasons := reasons.push .retention
  if explored.pendingAtStop > 0 then reasons := reasons.push .visits
  if explored.depthStops > 0 then reasons := reasons.push .depth
  if explored.clipped then reasons := reasons.push .identifier
  if explored.incompatible > 0 then reasons := reasons.push .clock
  let mut result : Projection := {truncationReasons := reasons}
  for i in [:selected.size] do
    let observation := explored.observations[selected[i]!]!
    let parent? := observation.span.parent?.bind (indices[·]!)
    let selfNs := uncoveredNs observation.span intervals[i]!
    result := {result with
      spans := result.spans.push {observation.span with parent?, selfNs}
      headers := result.headers.push observation.header}
  return result

private def project (startNs stopNs : Nat) (states : Array TraceState) (text : String) : Projection :=
  materialize (explore startNs stopNs states text) maxSpans

private def Projection.result (projection : Projection) (startNs stopNs : Nat) : Result := {
    elapsedNs := stopNs - startNs
    initialThresholdMs
    spans := projection.spans
    truncationReasons := projection.truncationReasons
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
