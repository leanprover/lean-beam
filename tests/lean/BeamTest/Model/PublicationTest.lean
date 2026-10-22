/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import BeamModel.PublicationLaws

open BeamModel.Publication
namespace BeamTest.Model.PublicationTest

def runTests : IO Unit := do
  let success := run {} [.privateWrite, .workerComplete, .traceComplete, .promote]
  unless success.phase == .committed && success.canonicalCommits == 1 do
    throw <| IO.userError "completed private preparation did not publish once"
  let abandoned := run {} [.abandon, .privateWrite, .workerComplete, .traceComplete, .promote]
  unless abandoned.phase == .abandoned && abandoned.privateWrites == 1 &&
      abandoned.canonicalCommits == 0 do
    throw <| IO.userError "late private work regained publication authority"
  let lost := run {} [.workerComplete, .traceComplete, .ownerLost, .promote]
  unless lost.phase == .abandoned && lost.canonicalCommits == 0 do
    throw <| IO.userError "replaced owner promoted a prepared candidate"
  let premature := run {} [.traceComplete, .promote]
  unless premature.canonicalCommits == 0 do
    throw <| IO.userError "missing worker completion allowed promotion"
  IO.println "publication model: passed"

end BeamTest.Model.PublicationTest
