/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.DiagnosticsBarrier
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest

private def depAFixture : System.FilePath :=
  "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

def requireDepAResult (label : String) (result : Beam.LSP.DiagnosticsBarrier.Result) :
    ScenarioM Unit := do
  let expectedTextHash := hash (← IO.FS.readFile depAFixture)
  if result.version != 1 then
    throw <| IO.userError s!"{label}: expected version 1, got {result.version}"
  if result.hasFatalSnapshot then
    throw <| IO.userError s!"{label}: unexpected fatal snapshot for a valid file"
  if result.directImports != #["BeamTest.Fixtures.Deps.DepB"] then
    throw <| IO.userError
      s!"{label}: unexpected imports {(toJson result.directImports).compress}"
  if result.saveReadiness.version != 1 then
    throw <| IO.userError
      s!"{label}: expected readiness version 1, got {result.saveReadiness.version}"
  if result.saveReadiness.textHash != expectedTextHash then
    throw <| IO.userError <|
      s!"{label}: expected readiness text hash {expectedTextHash}, " ++
        s!"got {result.saveReadiness.textHash}"
  if !result.saveReadiness.saveReady then
    throw <| IO.userError
      s!"{label}: expected saveReady=true, got {(toJson result.saveReadiness).compress}"
  if result.saveReadiness.saveReadyReason != "ok" then
    throw <| IO.userError
      s!"{label}: expected saveReadyReason=ok, got {result.saveReadiness.saveReadyReason}"

def checkDiagnosticsBarrier : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let barrierReq ← sendDiagnosticsBarrier doc
  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier" result

  closeDoc doc

def checkDiagnosticsBarrierAcceptsSatisfiedVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let barrierReq ← sendDiagnosticsBarrier doc { version? := some 0 }
  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier satisfied version" result

  closeDoc doc

def checkDiagnosticsBarrierWithStandardLspInterference : ScenarioM Unit := do
  let barrierDoc ← openDoc depAFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let barrierReq ← sendDiagnosticsBarrier barrierDoc
  syncWhitespacePrefixEdit editDoc

  let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs barrierReq
  requireDepAResult "diagnosticsBarrier with LSP interference" result

  closeDoc barrierDoc
  closeDoc editDoc

def checkRealFatalSnapshotFlags : ScenarioM Unit := do
  let root ← mkTmpDir "beam-diagnostics-completion"
  try
    for (name, text, hasFatalSnapshot, saveReady) in [
        ("Valid", "import Lean\ndef value : Nat := 1\n", false, true),
        ("Nonfatal", "import Lean\ndef value : Nat := \"not a Nat\"\n", false, false),
        ("Fatal", "import BeamTest.Fixtures.DefinitelyMissing\n", true, false)] do
      let path := root / s!"{name}.lean"
      IO.FS.writeFile path text
      let doc ← openDoc path
      try
        let req ← sendDiagnosticsBarrier doc
        let result : Beam.LSP.DiagnosticsBarrier.Result ← awaitResponseAs req
        unless result.hasFatalSnapshot == hasFatalSnapshot do
          throw <| IO.userError
            s!"{name}: unexpected real barrier fatal-snapshot flag: {(toJson result).compress}"
        unless result.saveReadiness.saveReady == saveReady do
          throw <| IO.userError
            s!"{name}: unexpected real save readiness: {(toJson result).compress}"
      finally
        closeDoc doc
  finally
    IO.FS.removeDirAll root

def run : ScenarioM Unit := do
  checkDiagnosticsBarrier
  checkDiagnosticsBarrierAcceptsSatisfiedVersion
  checkDiagnosticsBarrierWithStandardLspInterference
  checkRealFatalSnapshotFlags

end BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest
