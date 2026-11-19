/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.DiagnosticsBarrier
import Beam.Broker.SyncSaveSupport
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

private def requireMatchingCompletion (label : String)
    (pulled : Array Lean.Lsp.Diagnostic) (published : Array Lean.Lsp.Diagnostic) : ScenarioM Unit := do
  let published := Beam.LSP.Lib.userVisibleDiagnostics published
  unless pulled.any Beam.Broker.isIncompleteBarrierDiagnostic ==
      published.any Beam.Broker.isIncompleteBarrierDiagnostic do
    throw <| IO.userError
      s!"{label}: pull/publication completion mismatch\npulled: {toJson pulled}\npublished: {toJson published}"

def checkPulledDiagnosticSnapshots : ScenarioM Unit := do
  let root ← mkTmpDir "beam-diagnostic-snapshots"
  try
    for (name, text, errors, warnings) in [
        ("Empty", "", 0, 0),
        ("Clean", "def value : Nat := 1\n", 0, 0),
        ("Error", "def value : Nat := \"not a Nat\"\n", 1, 0),
        ("Warning", "example : True := by sorry\n", 0, 1),
        ("Header", "import BeamTest.Fixtures.DefinitelyMissing\n", 1, 0),
        ("Consumed", "import Lean\n/-- error: snapshot consumed -/\n#guard_msgs in\nrun_cmd Lean.logError \"snapshot consumed\"\n", 0, 0)] do
      let path := root / s!"{name}.lean"
      IO.FS.writeFile path text
      let doc ← openDoc path
      try
        for attempt in [0, 1] do
          let (result, published?) ← collectDiagnosticsBarrier doc
          let diagnostics := result.saveReadiness.currentDiagnostics
          unless result.version == 1 && result.saveReadiness.version == 1 &&
              result.saveReadiness.textHash == hash text do
            throw <| IO.userError s!"{name}: diagnostics lost accepted source identity"
          unless (diagnostics.filter (·.severity? == some .error)).size == errors &&
              (diagnostics.filter (·.severity? == some .warning)).size == warnings do
            throw <| IO.userError s!"{name}: unexpected pulled diagnostics {toJson diagnostics}"
          if attempt == 0 && published?.isNone then
            throw <| IO.userError s!"{name}: initial publication comparison was not exercised"
          if name == "Header" && !diagnostics.any Beam.Broker.isIncompleteBarrierDiagnostic then
            throw <| IO.userError s!"Header: expected Lake setup failure evidence: {toJson diagnostics}"
          if let some published := published? then
            requireMatchingCompletion s!"{name} attempt {attempt}" diagnostics published.diagnostics
      finally
        closeDoc doc
  finally
    IO.FS.removeDirAll root

def checkPulledDiagnosticsAfterEdit : ScenarioM Unit := do
  let root ← mkTmpDir "beam-diagnostic-clear"
  let path := root / "Clear.lean"
  IO.FS.writeFile path "def value : Nat := \"not a Nat\"\n"
  try
    let doc ← openDoc path
    try
      let (before, _) ← collectDiagnosticsBarrier doc
      unless before.saveReadiness.currentDiagnostics.any (·.severity? == some .error) do
        throw <| IO.userError "clear fixture did not begin with an error"
      let clean := "def value : Nat := 1\n"
      changeDoc doc {
        line := 0
        character := 0
        endLine? := some 1
        endCharacter? := some 0
        insert := clean
      }
      for attempt in [0, 1] do
        let (after, published?) ← collectDiagnosticsBarrier doc
        unless after.version == 2 && after.saveReadiness.version == 2 &&
            after.saveReadiness.textHash == hash clean && after.saveReadiness.saveReady &&
            after.saveReadiness.currentDiagnostics.isEmpty do
          throw <| IO.userError s!"cleared diagnostic survived the accepted edit: {toJson after}"
        if attempt == 0 && published?.isNone then
          throw <| IO.userError "cleared publication comparison was not exercised"
        if let some published := published? then
          requireMatchingCompletion "cleared file" after.saveReadiness.currentDiagnostics published.diagnostics
    finally
      closeDoc doc
  finally
    IO.FS.removeDirAll root

private partial def awaitStalePublication (doc : DocHandle) (dependency : String)
    (deadline : Nat) : ScenarioM Lean.Lsp.PublishDiagnosticsParams := do
  notifyWatchedFileChanged s!"tests/lean/BeamTest/Fixtures/Deps/{dependency}.lean"
  let (_, published?) ← collectDiagnosticsBarrier doc
  if let some published := published? then
    if published.diagnostics.any Beam.Broker.isIncompleteBarrierDiagnostic then
      return published
  if (← IO.monoMsNow) >= deadline then
    throw <| IO.userError s!"{dependency}: dependency invalidation was not published"
  IO.sleep 20
  awaitStalePublication doc dependency deadline

def checkPulledStickyDiagnostics : ScenarioM Unit := do
  let root ← mkTmpDir "beam-diagnostic-sticky"
  let text ← IO.FS.readFile depAFixture
  try
    for dependency in ["DepB", "DepC"] do
      let path := root / s!"{dependency}Importer.lean"
      IO.FS.writeFile path text
      let doc ← openDoc path
      try
        let (before, _) ← collectDiagnosticsBarrier doc
        unless before.saveReadiness.currentDiagnostics.isEmpty do
          throw <| IO.userError "sticky fixture did not begin with clean diagnostics"
        -- Import-graph initialization has its own task. Observe the invalidation before
        -- testing the next pull; the diagnostics barrier does not wait for that task.
        let published ← awaitStalePublication doc dependency ((← IO.monoMsNow) + 20000)
        let (after, _) ← collectDiagnosticsBarrier doc
        let diagnostics := after.saveReadiness.currentDiagnostics
        unless after.version == before.version &&
            after.saveReadiness.textHash == before.saveReadiness.textHash &&
            !after.hasFatalSnapshot && after.saveReadiness.saveReady &&
            diagnostics.any Beam.Broker.isIncompleteBarrierDiagnostic do
          throw <| IO.userError s!"{dependency}: sticky invalidation missing from pull: {toJson after}"
        requireMatchingCompletion dependency diagnostics published.diagnostics
        let (unchanged, _) ← collectDiagnosticsBarrier doc
        unless unchanged.saveReadiness.currentDiagnostics.any Beam.Broker.isIncompleteBarrierDiagnostic do
          throw <| IO.userError "unchanged pull lost sticky invalidation"
      finally
        closeDoc doc
  finally
    IO.FS.removeDirAll root

def run : ScenarioM Unit := do
  checkDiagnosticsBarrier
  checkDiagnosticsBarrierAcceptsSatisfiedVersion
  checkDiagnosticsBarrierWithStandardLspInterference
  checkRealFatalSnapshotFlags
  checkPulledDiagnosticSnapshots
  checkPulledDiagnosticsAfterEdit
  checkPulledStickyDiagnostics

end BeamTest.LSP.Requests.DiagnosticsBarrier.BasicTest
