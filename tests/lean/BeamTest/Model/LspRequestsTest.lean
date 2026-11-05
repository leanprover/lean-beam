/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.LspRequests
import BeamModel.BackendProtocol

namespace BeamTest.Model.LspRequestsTest
open BeamModel.LspRequests

private def check (name : String) (ok : Bool) : IO Unit :=
  unless ok do throw <| IO.userError s!"LSP request model: {name}"

def runTests : IO Unit := do
  check "cancel leaves response obligation" <|
    run {} [.request 1, .cancel 1] == some { outstanding := [1] }
  check "late cancellation after response is harmless" <|
    run {} [.request 1, .response 1, .cancel 1] == some {}
  check "out-of-order responses accepted at correlation boundary" <|
    run {} [.request 1, .request 2, .response 2, .response 1] == some {}
  check "duplicate response rejected" <|
    (run {} [.request 1, .response 1, .response 1]).isNone
  check "unknown response rejected" <| (run {} [.response 7]).isNone
  check "duplicate outstanding ID rejected" <|
    (run {} [.request 1, .request 1]).isNone
  check "notifications do not create response obligations" <|
    run {} [.notification, .cancel 99] == some {}
  check "ID reuse after completed response is not lifetime freshness" <|
    run {} [.request 1, .response 1, .request 1] == some { outstanding := [1] }
  let pending : BeamModel.BackendProtocol.State :=
    { incarnation := 7, pending := [⟨7, 1⟩] }
  let crashed := BeamModel.BackendProtocol.step pending .peerCrash
  check "unobserved crash does not discharge local caller obligation" <|
    crashed == (pending, [])
  check "local closure authorizes failure, not an LSP response" <|
    (BeamModel.BackendProtocol.step crashed.1 .closeChannel).2 ==
      [.settle ⟨7, 1⟩ .channelFailure]
  IO.println "LSP request model: 10 correlation, cancellation, and failure-boundary checks passed"

end BeamTest.Model.LspRequestsTest
