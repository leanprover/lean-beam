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

def run : IO Unit := do
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
  require (selection.top == #[12, 11, 10, 9, 8, 7, 6, 5, 4, 3]) "top spans not ranked by inclusive duration"
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
  require result.truncated "label clipping was not reflected in partial-evidence flag"

  let tied : Array Span := #[
    { thread := 0, category := "Kernel", tag := "", startMs := 0, durationMs := 1 },
    { thread := 0, category := "step", tag := "", startMs := 0, durationMs := 1 }]
  let same := select tied
  require (same.top == #[0, 1] && same.phases == #[0] && same.indices == #[0, 1])
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
