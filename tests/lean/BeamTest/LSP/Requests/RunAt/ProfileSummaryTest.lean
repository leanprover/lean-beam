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
  thread := 0, category, tag := "", startMs := 0, durationMs, parent? }

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
  require (bounded.top.size == 10 && bounded.represented == 20)
    "top budget counts raw spans rather than retained paths"
  require (many.size - bounded.represented == 4 && bounded.represented - bounded.top.size == 10)
    "omitted paths and collapsed members were conflated"
  -- A projection may stop mid-path. Group only retained evidence, without inventing the tail.
  let partialTree := many.extract 0 23
  require ((select partialTree).represented == 20 && partialTree.size - (select partialTree).represented == 3)
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
  require ((← calls.get) == #[1, 1, 0])
    "selected middle header was not rendered exactly once or a tiny leaf header was evaluated"
  require (result.spans[1]!.label? == some "endpoint 1" && result.spans[2]!.label?.isNone)
    "labels did not follow the selected inner member"
  require (!result.truncated && result.spans.size == 3) "grouping altered the raw projection"

def run : IO Unit := do
  checkChains
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
  require (selection.top.map (·.outer) == #[12, 11, 10, 9, 8, 7, 6, 5, 4, 3]) "top spans not ranked by inclusive duration"
  require (selection.phases == #[1, 2]) "phase selection did not select the largest observed span"
  require (selection.indices.size == 12) "phase/top selection omitted or duplicated an index"
  require (pureResult.spans.size - selection.top.size == 3) "top omission count changed"

  let renderStarted ← IO.monoNanosNow
  let (output, result) ← IO.FS.withIsolatedStreams do
    collectWithLabels (pure () : IO Unit) 1000000000 2000000000 states ""
  require ((← IO.monoNanosNow) - renderStarted >= 5000000) "slow header was not awaited"
  require output.isEmpty "label rendering escaped isolated streams"
  require (result.elapsedMs == 1000) "label rendering changed measured elaboration time"
  let observed ← calls.get
  require (observed[0]! == 0 && (observed.extract 1 13).all (· == 1))
    "unselected header evaluated or selected header rendered more than once"
  require result.spans[0]!.label?.isNone "unselected span gained a label"
  require (result.spans[1]!.label? == some "LabelScope: step 1") "renderer lost its naming context"
  require (result.spans[7]!.label?.any (fun s => s.length == maxLabelChars && s.endsWith "…"))
    "Unicode label was not visibly clipped to the output bound"
  require (!result.truncated) "label clipping incorrectly marked the raw projection incomplete"
  require (select result.spans == selection) "label rendering changed the pure selection decision"

  let tied : Array Span := #[
    { thread := 0, category := "Kernel", tag := "", startMs := 0, durationMs := 1 },
    { thread := 0, category := "step", tag := "", startMs := 0, durationMs := 1 }]
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
