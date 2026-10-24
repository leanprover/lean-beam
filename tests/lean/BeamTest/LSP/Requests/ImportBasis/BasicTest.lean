/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.ImportBasis
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.ImportBasis.BasicTest

private def depAFixture : System.FilePath :=
  "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

private def requireStatus
    (label : String) (expected : Beam.LSP.ImportBasis.Status)
    (result : Beam.LSP.ImportBasis.Result) : ScenarioM Unit := do
  unless result.status == expected && result.changedImports.isEmpty do
    throw <| IO.userError s!"{label}: expected status {(toJson expected).compress}, got {(toJson result).compress}"

/-- A basis captured when the header loads stays current while the import traces are unchanged. -/
def checkImportBasisCapturedAtLoad : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let captureReq ← sendImportBasis doc (capture := true)
  requireStatus "importBasis capture" .current (← awaitResponseAs captureReq)
  let checkReq ← sendImportBasis doc (capture := false)
  requireStatus "importBasis check" .current (← awaitResponseAs checkReq)
  -- The broker captures again after each edit; the basis stays current with unchanged traces.
  syncWhitespacePrefixEdit doc
  let recaptureReq ← sendImportBasis doc (capture := true)
  requireStatus "importBasis recapture" .current (← awaitResponseAs recaptureReq)
  let editedReq ← sendImportBasis doc (capture := false)
  requireStatus "importBasis check after edit" .current (← awaitResponseAs editedReq)
  closeDoc doc

/-- A check never captures: a header loaded without an early capture has an unknown basis. -/
def checkImportBasisWithoutCaptureIsUnknown : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let barrierReq ← sendDiagnosticsBarrier doc
  discard <| awaitReq barrierReq
  let checkReq ← sendImportBasis doc (capture := false)
  requireStatus "importBasis late check" .unknown (← awaitResponseAs checkReq)
  closeDoc doc

/-- A module Beam saved at or after the load point counts as changed, whatever its trace says. -/
def checkImportBasisSavedSinceLoad : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let captureReq ← sendImportBasis doc (capture := true) (eventSeq := 5)
  requireStatus "importBasis capture at sequence 5" .current (← awaitResponseAs captureReq)
  let earlierReq ← sendImportBasis doc (capture := false)
    (savedModules := #[{ module := "BeamTest.Fixtures.Deps.DepB", eventSeq := 4 }])
  requireStatus "importBasis save before load" .current (← awaitResponseAs earlierReq)
  let laterReq ← sendImportBasis doc (capture := false)
    (savedModules := #[{ module := "BeamTest.Fixtures.Deps.DepB", eventSeq := 5 }])
  let later : Beam.LSP.ImportBasis.Result ← awaitResponseAs laterReq
  unless later.status == .changed && later.changedImports == #["BeamTest.Fixtures.Deps.DepB"] do
    throw <| IO.userError s!"importBasis save at load: expected DepB changed, got {(toJson later).compress}"
  closeDoc doc

def checkImportBasisStaleVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let captureReq ← sendImportBasis doc (capture := true)
  discard <| awaitReq captureReq
  let staleReq ← sendImportBasis doc (capture := false) (version? := some 7)
  expectErrorContains staleReq (Json.mkObj [("code", toJson "contentModified")])
  closeDoc doc

def run : ScenarioM Unit := do
  checkImportBasisCapturedAtLoad
  checkImportBasisWithoutCaptureIsUnknown
  checkImportBasisSavedSinceLoad
  checkImportBasisStaleVersion

end BeamTest.LSP.Requests.ImportBasis.BasicTest
