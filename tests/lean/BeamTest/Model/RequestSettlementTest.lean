/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.RequestSettlementLaws

namespace BeamTest.Model.RequestSettlementTest
open BeamModel.RequestSettlement

private def check (name : String) (ok : Bool) : IO Unit :=
  unless ok do throw <| IO.userError s!"request settlement model: {name}"

def runTests : IO Unit := do
  let detached := run {} [.register, .writeSucceeded, .reply (.response 17)]
  check "removal does not imply resolution" <|
    !detached.pending && detached.result.isNone &&
      detached.claims == [(.reader, .response 17)]
  let closed := step detached (.close 40)
  check "close does not steal detached response" <|
    closed.claims == detached.claims && closed.result.isNone
  check "reader completes after close" <|
    (step closed (.resolve .reader)).result == some (.response 17)
  let closeFirst := run {} [.register, .writeSucceeded, .close 40, .reply (.response 17), .resolve .closer]
  check "close wins pending-map removal" <| closeFirst.result == some (.failure 40)
  let writerDetached := run {} [.register, .writeFailed, .close 40, .close 99]
  check "empty map still has writer obligation" <|
    !writerDetached.pending && writerDetached.result.isNone && writerDetached.writer == .detached
  check "writer selects retained channel cause" <|
    (run writerDetached [.chooseWriteFailure 91, .resolve .writer]).result == some (.failure 40)
  let beforeClose := run {} [.register, .writeFailed, .chooseWriteFailure 91, .close 40]
  check "selected write error is not retroactively replaced" <|
    (step beforeClose (.resolve .writer)).result == some (.failure 91)
  let contested := run {} [.register, .reply (.response 17), .writeFailed, .chooseWriteFailure 91]
  check "response and writer can both attempt resolution" <|
    contested.claims.length == 2
  for (first, second, expected) in [
      (.reader, .writer, Outcome.response 17), (.writer, .reader, Outcome.failure 91)] do
    let result := run contested [.resolve first, .resolve second]
    check "first resolution wins in either order" <|
      result.result == some expected && result.claims.isEmpty
  let rejected := run {} [.close 40, .register]
  check "closed registration retains a failure-settlement obligation" <|
    !rejected.pending && rejected.writer == .idle && rejected.result.isNone &&
      rejected.claims == [(.rejectedRegistration, .failure 40)]
  check "rejected registration eventually resolved by its own handler" <|
    (step rejected (.resolve .rejectedRegistration)).result == some (.failure 40)
  check "cancellation and unobserved peer crash preserve detached responsibility" <|
    run detached [.cancel, .peerCrash] == detached
  check "wrong handler cannot resolve the promise" <|
    step detached (.resolve .writer) == detached
  check "server error is a reader outcome preserved through cancellation" <|
    (run {} [.register, .writeSucceeded, .reply (.failure 55), .resolve .reader,
      .cancel, .close 40]).result == some (.failure 55)
  IO.println "request settlement model: 15 ownership, closure, and first-resolution checks passed"

end BeamTest.Model.RequestSettlementTest
