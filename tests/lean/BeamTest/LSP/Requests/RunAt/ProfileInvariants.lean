/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/
import Beam.Output

open Lean

namespace BeamTest.LSP.Requests.RunAt.ProfileInvariants

private def checkEntry (spans : Array Json) (entry : Json) : Except String Nat := do
  let i ← entry.getObjValAs? Nat "span"
  let some span := spans[i]? | throw "summary index outside span array"
  unless (← entry.getObjVal? "category") == (← span.getObjVal? "category") &&
      (← entry.getObjValAs? Float "duration_ms") == (← span.getObjValAs? Float "duration_ms") do
    throw "summary disagrees with its span"
  if let .ok label := entry.getObjVal? "label" then
    unless (← label.getStr?).length <= 160 do throw "label exceeds 160 characters"
  return i

/-- Check the public profile as a client receives it, including the rounded span forest. -/
def check (profile : Json) : Except String Unit := do
  let spans ← profile.getObjValAs? (Array Json) "spans"
  let mut parents : Array (Option Nat) := #[]
  for s in spans do
    let start ← s.getObjValAs? Float "start_ms"
    let duration ← s.getObjValAs? Float "duration_ms"
    unless start >= 0 && duration >= 0 do throw "negative span time"
    let thread ← s.getObjValAs? Nat "thread"
    let parent ← (s.getObjVal? "parent").toOption.mapM Json.getNat?
    if let some p := parent then
      unless p < parents.size do throw "parent must precede child"
      if (s.getObjVal? "range").isOk then throw "range on child span"
      let outer := spans[p]!
      if thread == (← outer.getObjValAs? Nat "thread") then
        let t ← outer.getObjValAs? Float "start_ms"
        let d ← outer.getObjValAs? Float "duration_ms"
        unless start >= t - 0.05 && start + duration <= t + d + 0.05 do
          throw "child escapes same-thread parent"
    parents := parents.push parent
  let summary ← profile.getObjVal? "summary"
  let top ← summary.getObjValAs? (Array Json) "top_spans"
  unless top.size <= 10 do throw "too many top spans"
  for entry in top do
    let outer ← checkEntry spans entry
    if let .ok inner := entry.getObjVal? "inner_span" then
      let i ← checkEntry spans inner
      let mut p := parents[i]!
      while let some j := p do
        if j <= outer then break
        p := parents[j]!
      unless p == some outer do throw "inner span is not a descendant"
  for entry in (← summary.getObjValAs? (Array Json) "phase_spans") do
    discard <| checkEntry spans entry
  let collapsed ← summary.getObjValAs? Nat "collapsed_spans"
  let omitted ← summary.getObjValAs? Nat "omitted_from_top"
  unless top.size + collapsed + omitted == spans.size do throw "span count mismatch"

def project (profile : Beam.LSP.RunAt.Profile.Result) : IO Json := do
  let result : Beam.LSP.RunAt.Result := { success := true, profile? := some profile }
  let .ok json := Beam.Output.projectResult (.broker .runAt) (toJson result)
    | throw <| IO.userError "profile projection failed"
  IO.ofExcept (json.getObjVal? "profile")

def checkResult (profile : Beam.LSP.RunAt.Profile.Result) : IO Unit := do
  let value ← project profile
  IO.ofExcept (check value)

/-- Each edit to this small forest must fail at the intended check. -/
def checkMalformed : IO Unit := do
  let root := Json.mkObj [("thread", toJson 0), ("start_ms", toJson 0), ("duration_ms", toJson 1),
    ("category", toJson "step")]
  let child := root.setObjVal! "parent" (toJson 0)
  let entry := Json.mkObj [("span", toJson 0), ("category", toJson "step"), ("duration_ms", toJson 1)]
  let mk := fun (spans top : Array Json) (omitted : Nat) => Json.mkObj [
    ("spans", Json.arr spans), ("summary", Json.mkObj [("top_spans", Json.arr top),
      ("phase_spans", Json.arr #[]), ("collapsed_spans", toJson 0), ("omitted_from_top", toJson omitted)])]
  let bad := fun (value : Json) (expected : String) => do
    match check value with
    | .error msg => unless msg == expected do throw <| IO.userError s!"expected {expected}, got {msg}"
    | .ok _ => throw <| IO.userError s!"missing error: {expected}"
  IO.ofExcept (check (mk #[root, child] #[entry] 1))
  let escape := child.setObjVal! "duration_ms" (toJson 2)
  IO.ofExcept (check (mk #[root, escape.setObjVal! "thread" (toJson 1)] #[entry] 1))
  bad (mk #[child, root] #[entry] 1) "parent must precede child"
  bad (mk #[root, escape] #[entry] 1) "child escapes same-thread parent"
  bad (mk #[root, child.setObjVal! "range" (Json.mkObj [])] #[entry] 1) "range on child span"
  bad (mk #[root] #[entry.setObjVal! "duration_ms" (toJson 2)] 0) "summary disagrees with its span"
  let inner := entry.setObjVal! "span" (toJson 1)
  bad (mk #[root, root] #[entry.setObjVal! "inner_span" inner] 1) "inner span is not a descendant"
  bad (mk #[root] #[entry] 1) "span count mismatch"
  bad (mk #[root] #[inner] 0) "summary index outside span array"
  bad (mk #[root] #[entry.setObjVal! "label" (toJson ("".pushn 'a' 161))] 0) "label exceeds 160 characters"
  bad (mk #[root] (Array.replicate 11 entry) 0) "too many top spans"
  bad (mk #[root.setObjVal! "start_ms" (toJson (-1 : Int))] #[entry] 0) "negative span time"

end BeamTest.LSP.Requests.RunAt.ProfileInvariants
