/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import BeamModel.AdmissionLaws

namespace BeamTest.Model.AdmissionTest

open Beam.Broker.DocumentAdmission

private def accepted (result : Except Conflict α) : IO α :=
  IO.ofExcept <| result.mapError fun conflict => IO.userError s!"unexpected {repr conflict}"

private def check (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError label

private def rejects (state : State) (permit : Permit) (conflict : Conflict) : Bool :=
  match state.check permit with | .error actual => actual == conflict | .ok () => false

private def accepts (state : State) (permit : Permit) : Bool :=
  match state.check permit with | .ok () => true | .error _ => false

def runTests : IO Unit := do
  let (state, old) ← accepted <| State.empty.admit "Main"
  let (state, owner) ← accepted <| state.admit "Main"
  let (state, other) ← accepted <| state.admit "Other"
  let state ← accepted <| state.reserve owner
  check "reservation rejects an earlier admission" (rejects state old .closing)
  check "reservation retains its owner" (accepts state owner)
  check "reservation preserves another document" (accepts state other)
  check "reservation rejects new admissions"
    (match state.admit "Main" with | .error .closing => true | _ => false)
  let state := state.release owner
  check "old admission stays invalid after scope exit" (rejects state old .stale)
  let (state, retry) ← accepted <| state.admit "Main"
  check "retry has a fresh identity" (retry != owner && retry != old)
  let state ← accepted <| state.reserve retry
  let state := (state.release owner).release old
  check "old cleanup preserves a retry's ownership" (state.isClosing "Main")
  check "old cleanup preserves another document" (accepts state other)
  let state := state.retire
  check "retirement revokes the closing owner" (rejects state retry .stale)
  check "retirement revokes other outstanding admissions" (rejects state other .stale)
  let (state, replacement) ← accepted <| state.admit "Main"
  let state ← accepted <| state.reserve replacement
  let state := (state.release retry).release other
  check "retired cleanup cannot clear replacement" (state.isClosing "Main")
  let state := state.release replacement
  check "completed scopes retain no path entries" state.entries.isEmpty
  let (state, delayed) ← accepted <| state.admit "Main"
  let (state, closer) ← accepted <| state.admit "Main"
  let state := (state.fence closer).release closer
  check "ordinary close or refresh fences delayed work" (rejects state delayed .stale)
  check "final delayed scope releases its entry" (state.release delayed).entries.isEmpty
  IO.println "document admission: ownership, retry, retirement, and bounded-state schedules passed"

end BeamTest.Model.AdmissionTest
