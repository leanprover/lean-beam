/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.RunAt.Profile

open Lean
open Beam.LSP.RunAt.Profile

namespace BeamTest.LSP.Requests.RunAt.ProfileSummaryTest

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def category (i : Nat) : Name :=
  if i < 2 then `Kernel else if i == 2 then `Elab.def.maxSharing else `step

private def span (durationMs : Float) (parent? : Option Nat := none)
    (category : String := "step") : Span := {
  thread := 0, category, tag := "", startNs := 0, stopNs := (durationMs * 1000000).round.toUInt64.toNat, parent? }

private def checkChains : IO Unit := do
  -- Retained paths group wrapper noise, even when an outer scope includes substantial work
  -- absent from its sole child. Branch points and the independent phase view stay visible.
  let spans := #[
    span 547 none "Elab.definition.value", span 346 (some 0), span 345 (some 1),
    span 377 none "Elab.def.maxSharing", span 231, span 230 (some 4) "Kernel",
    span 240, span 80 (some 6), span 50 (some 7), span 1 (some 8), span 100 (some 6)]
  let selected := select spans
  require (selected.top.map (·.outer) == #[0, 3, 6, 4, 10, 7]) "chains not ranked by outer duration"
  require (selected.top.map (·.inner) == #[2, 3, 6, 5, 10, 8])
    "displayed members crossed a retained branch or fell below half the outer duration"
  require (selected.top.map (·.size) == #[3, 1, 1, 2, 1, 3]) "chain member counts are not exact"
  require (selected.represented == spans.size) "grouping lost retained spans"
  require (selected.phases == #[5, 3, 0]) "grouping lost independent phase observations"
  require (!selected.indices.contains 1 && !selected.indices.contains 9)
    "unselected wrapper or tiny leaf labels would still be rendered"
  require (selected.indices.size == 9) "shared endpoints/phases rendered repeatedly"

  -- Live Mathlib ring profiles can continue past ring1 into a tiny synthInstance leaf. Select
  -- the useful middle span while counting the entire structural chain, including that leaf.
  let liveRing := #[span 801.7, span 479.6 (some 0), span 479.3 (some 1), span 1.3 (some 2)]
  let liveSelected := select liveRing
  require (liveSelected.top == #[{ outer := 0, inner := 2, size := 4 }])
    "a tiny leaf displaced the substantial inner span"
  -- The threshold is relative to the outer span, not repeatedly to each preceding child.
  let fading := select #[span 100, span 70 (some 0), span 49 (some 1), span 30 (some 2)]
  require (fading.top == #[{ outer := 0, inner := 1, size := 4 }])
    "pairwise threshold drift selected a small fraction of the outer duration"
  let boundary := select #[span 100, span 50 (some 0), span 50 (some 1), span 49.9 (some 2)]
  require (boundary.top == #[{ outer := 0, inner := 2, size := 4 }])
    "the inclusive half-duration boundary did not select its deepest member"
  let noInner := select #[span 100, span 49.9 (some 0) "Kernel"]
  require (noInner.top == #[{ outer := 0, inner := 0, size := 2 }] && noInner.phases == #[1])
    "a small child was displayed or its independent phase observation was lost"
  let zero := select #[span 0, span 0 (some 0)]
  require (zero.top == #[{ outer := 0, inner := 0, size := 2 }])
    "a zero-duration path invented a useful inner member"

  let mut many : Array Span := #[]
  for i in [:12] do
    many := many.push (span (100 - i).toFloat)
    many := many.push (span 1 (some (2 * i)))
  let bounded := select many
  require (bounded.top.size == 8 && bounded.represented == 16)
    "top budget counts raw spans rather than retained paths"
  require (many.size - bounded.represented == 8 && bounded.represented - bounded.top.size == 8)
    "omitted paths and collapsed members were conflated"
  -- A projection may stop mid-path. Group only retained evidence, without inventing the tail.
  let partialTree := many.extract 0 23
  require ((select partialTree).represented == 16 && partialTree.size - (select partialTree).represented == 7)
    "a partial retained path changed exact omission accounting"

  let calls ← IO.mkRef (Array.replicate 3 0)
  let header := fun i => MessageData.ofLazy (fun _ => do
    calls.modify (·.modify i (· + 1))
    pure <| Dynamic.mk (m!"endpoint {i}")) (fun _ => false)
  let leaf := MessageData.trace { cls := `inner, startTime := 1.3, stopTime := 1.4 } (header 2) #[]
  let mid := MessageData.trace { cls := `wrapper, startTime := 1.2, stopTime := 1.7 } (header 1) #[leaf]
  let root := MessageData.trace { cls := `outer, startTime := 1.1, stopTime := 1.9 } (header 0) #[mid]
  let state : TraceState := {
    tid := 0
    traces := ({} : PersistentArray TraceElem).push { ref := .missing, msg := root } }
  let result ← collectWithLabels (pure () : IO Unit) 1000000000 2000000000 #[state] ""
  require ((← calls.get) == #[1, 1, 1])
    "a shared inclusive/uncovered header or uncovered-only leaf was not rendered exactly once"
  require (result.spans[1]!.label? == some "endpoint 1" && result.spans[2]!.label? == some "endpoint 2")
    "labels did not follow the selected inner member"
  require (!result.truncated && result.spans.size == 3) "grouping altered the raw projection"

private def checkDominance : IO Unit := do
  let tree := fun duration => #[span 100, span duration (some 0), span 1 (some 0)]
  require ((select (tree 90)).top.map (·.outer) == #[1, 2])
    "a descendant covering exactly 90% must suppress its enclosing group"
  require ((select (tree 89.99)).top.map (·.outer) == #[0, 1, 2])
    "a descendant just under 90% must preserve its enclosing group"
  let selection := select #[span 90, span 80 none "Elab.definition.header",
    span 70 none "Elab.definition.header", span 60 none "Elab.lint", span 50 none "Elab.lint"]
  require (selection.phases == #[3, 1] && selection.uncovered.map (·.index) == #[0])
    "all phase-category spans must be skipped, including smaller observations"

private def checkUncovered : IO Unit := do
  -- Children overlap, arrive out of order and cross both parent endpoints. A different
  -- thread's child overlaps the remaining gap and must not cover it.
  let child := fun start stop thread => { span 0 (some 0) with
    startNs := start, stopNs := stop, thread }
  let tree := #[{ span 0 with startNs := 100, stopNs := 200 },
    child 180 210 0, child 80 120 0, child 110 150 0, child 150 180 1]
  require ((select tree).uncovered.any fun u => u.index == 0 && u.uncoveredNs == 30)
    "only the clipped union of same-thread children covers the parent"
  let timed := fun cls start stop children => MessageData.trace
    {cls, startTime := start, stopTime := stop} "" children
  -- Only the root and long fillers fit. Its short children overlap, arrive out of order,
  -- and extend beyond both endpoints. Their union within the root covers 3/4 second.
  let root := timed `target 1.25 2.25 #[
    timed `right 2.0 2.5 #[], timed `left 1.0 1.625 #[], timed `overlap 1.375 1.75 #[]]
  let filler := { ref := Syntax.missing, msg := timed `filler 1.0 1.875 #[] : TraceElem }
  let mut traces := ({} : PersistentArray TraceElem).push {ref := .missing, msg := root}
  for _ in [:maxSpans] do traces := traces.push filler
  let result := collect 1000000000 3000000000 #[{tid := 0, traces}] ""
  require (result.truncationReasons == #[.retention] && result.spans.size == maxSpans)
    "losing visited spans should report only retention"
  require (((select result.spans).uncovered[0]! == ⟨0, 1_000_000_000⟩) && result.spans.all (·.parent?.isNone))
    "omitted child intervals must remain in their returned parent’s balance"

def run : IO Unit := do
  checkChains
  checkDominance
  checkUncovered
  let calls ← IO.mkRef (Array.replicate 13 0)
  let env ← mkEmptyEnvironment
  let context : MessageDataContext := { env, mctx := {}, lctx := {}, opts := {} }
  let mut traces : PersistentArray TraceElem := {}
  for i in [:13] do
    let header := MessageData.ofLazy (fun ctx? => do
      calls.modify (·.modify i (· + 1))
      if i == 12 then IO.sleep 10
      -- A formatter's effects must not corrupt CLI/MCP output, including nested capture.
      discard <| (IO.println "profile label stdout").toBaseIO
      discard <| (IO.eprintln "profile label stderr").toBaseIO
      let scopeName := (ctx?.map (·.currNamespace)).getD .anonymous
      let text := if i == 7 then "".pushn 'λ' 1000 else s!"{scopeName}: step {i}"
      return Dynamic.mk (MessageData.ofFormat (.text text))) (fun _ => false)
    let node := MessageData.trace {
      cls := category i, startTime := 1.1, stopTime := 1.1 + (i + 1).toFloat / 100
    } header #[]
    traces := traces.push {
      ref := .missing
      msg := .withContext context <|
        .withNamingContext { currNamespace := `LabelScope, openDecls := [] } node }
  let states : Array TraceState := #[{ tid := 7, traces }]
  let pureResult := collect 1000000000 2000000000 states ""
  require ((← calls.get).all (· == 0)) "pure profile collector evaluated a header"
  let selection := select pureResult.spans
  require (selection.top.map (·.outer) == #[12, 11, 10, 9, 8, 7, 6, 5]) "top spans not ranked by inclusive duration"
  require (selection.phases == #[1, 2]) "phase selection did not select the largest observed span"
  require (selection.indices.size == 10) "phase/top selection omitted or duplicated an index"
  require (pureResult.spans.size - selection.top.size == 5) "top omission count changed"

  let renderStarted ← IO.monoNanosNow
  let (output, result) ← IO.FS.withIsolatedStreams do
    collectWithLabels (pure () : IO Unit) 1000000000 2000000000 states ""
  require ((← IO.monoNanosNow) - renderStarted >= 5000000) "slow header was not awaited"
  require output.isEmpty "label rendering escaped isolated streams"
  require (result.elapsedNs == 1_000_000_000) "label rendering changed measured elaboration time"
  let observed ← calls.get
  require (observed == #[0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1])
    "unselected header evaluated or selected header rendered more than once"
  require result.spans[0]!.label?.isNone "unselected span gained a label"
  require (result.spans[1]!.label? == some "LabelScope: step 1") "renderer lost its naming context"
  require (result.spans[7]!.label?.any (fun s => s.length == maxLabelChars && s.endsWith "…"))
    "Unicode label was not visibly clipped to the output bound"
  require (!result.truncated) "label clipping incorrectly marked the raw projection incomplete"
  require (select result.spans == selection) "label rendering changed the pure selection decision"

  let tied : Array Span := #[
    { thread := 0, category := "Kernel", tag := "", startNs := 0, stopNs := 1_000_000 },
    { thread := 0, category := "step", tag := "", startNs := 0, stopNs := 1_000_000 }]
  let same := select tied
  require (same.top.map (·.outer) == #[0, 1] && same.phases == #[0] && same.indices == #[0, 1])
    "tie ordering or overlapping view deduplication changed"
  let empty := select #[]
  require (empty.top.isEmpty && empty.phases.isEmpty) "empty evidence invented summary entries"

  calls.set (Array.replicate 13 0)
  let checks ← IO.mkRef 0
  let check : IO Unit := do
    checks.modify (· + 1)
    if (← checks.get) == 3 then throw <| IO.userError "cancelled between labels"
  let mut cancelled := false
  try
    discard <| collectWithLabels check 1000000000 2000000000 states ""
  catch _ => cancelled := true
  require cancelled "label collection ignored cancellation check"
  let stopped ← calls.get
  require (stopped[12]! == 1 && stopped[11]! == 1 && stopped.foldl (· + ·) 0 == 2)
    "cancelled label collection started more formatters or lost settled work"

end BeamTest.LSP.Requests.RunAt.ProfileSummaryTest
