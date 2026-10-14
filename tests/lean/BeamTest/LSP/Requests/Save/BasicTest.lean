/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.Save
import BeamTest.LSP.Requests.Interference
import BeamTest.LSP.Requests.Support

open Lean
open BeamTest.LSP.Scenario
open BeamTest.LSP.Requests.Interference
open BeamTest.LSP.Requests.Support

namespace BeamTest.LSP.Requests.Save.BasicTest

private def depAFixture : String :=
  "tests/lean/BeamTest/Fixtures/Deps/DepA.lean"

private def moduleArtifactsFixture : String :=
  "tests/lean/BeamTest/Fixtures/Save/ModuleArtifacts.lean"

private def requestCancelledJson : Json :=
  Json.mkObj [("code", toJson "requestCancelled")]

private def staleTextHash (text : String) : UInt64 :=
  if hash text == 0 then 1 else 0

private def requireCleanReadiness (label : String)
    (readiness : Beam.LSP.Save.SaveReadinessResult) : ScenarioM Unit := do
  if !readiness.saveReady then
    throw <| IO.userError s!"{label}: expected saveReady = true, got {(toJson readiness).compress}"
  if readiness.saveReadyReason != "ok" then
    throw <| IO.userError s!"{label}: expected reason = ok, got {readiness.saveReadyReason}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"{label}: expected clean file to omit save-blocking evidence, got {(toJson readiness).compress}"

private def requireSavedArtifacts (label : String) (outDir : System.FilePath)
    (saved : Beam.LSP.Save.SaveArtifactsResult) : ScenarioM Unit := do
  if !saved.written then
    throw <| IO.userError s!"{label}: expected written = true"
  if saved.version != 1 then
    throw <| IO.userError s!"{label}: expected version 1, got {saved.version}"
  expectFileExists s!"{label} olean" (outDir / "DepA.olean")
  expectFileExists s!"{label} ilean" (outDir / "DepA.ilean")
  expectFileExists s!"{label} c" (outDir / "DepA.c")

private def expectFileContents
    (label : String) (path : System.FilePath) (expected : String) : ScenarioM Unit := do
  unless (← IO.FS.readBinFile path) == expected.toUTF8 do
    throw <| IO.userError s!"{label}: file contents changed: {path}"

private def readArtifactSet
    (outDir : System.FilePath) (stem : String) : ScenarioM (Array ByteArray) := do
  let olean ← IO.FS.readBinFile (outDir / s!"{stem}.olean")
  let ilean ← IO.FS.readBinFile (outDir / s!"{stem}.ilean")
  let c ← IO.FS.readBinFile (outDir / s!"{stem}.c")
  pure #[olean, ilean, c]

def checkSaveReadinessDecoderRequiresVerdict : ScenarioM Unit := do
  let json := Json.mkObj [
    ("version", toJson 1),
    ("textHash", toJson (0 : UInt64)),
    ("currentDiagnostics", toJson (#[] : Array Lean.Lsp.Diagnostic)),
    ("currentWarningCount", toJson 0),
    ("saveReadyReason", toJson "ok"),
    ("blockingDiagnostics", toJson (#[] : Array Beam.LSP.Save.SaveBlockingDiagnostic)),
    ("blockingCommandMessages", toJson (#[] : Array Beam.LSP.Save.SaveBlockingCommandMessage))
  ]
  match (fromJson? json : Except String Beam.LSP.Save.SaveReadinessResult) with
  | .ok readiness =>
      throw <| IO.userError
        s!"saveReadiness decoder accepted a missing verdict: {(toJson readiness).compress}"
  | .error err =>
      unless err.contains "saveReady" do
        throw <| IO.userError
          s!"saveReadiness decoder rejected a missing verdict without naming saveReady: {err}"

def checkSaveReadinessOk : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  requireCleanReadiness "saveReadiness" readiness

  closeDoc doc

def checkSaveReadinessStaleVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  let staleReadinessVersionReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 0
  }
  expectErrorContains staleReadinessVersionReq (Json.mkObj [("code", toJson "contentModified")])

  closeDoc doc

def checkSaveReadinessStaleHash : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let depAText ← IO.FS.readFile depAFixture

  let staleReadinessHashReq ← sendSaveReadiness doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (staleTextHash depAText)
  }
  expectErrorContains staleReadinessHashReq (Json.mkObj [("code", toJson "contentModified")])

  closeDoc doc

def checkSaveArtifactsStaleVersion : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let outDir ← mkTmpDir "beam-save-request-surface"

  let staleVersionReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 0
    oleanFile := (outDir / "StaleVersion.olean").toString
    ileanFile := (outDir / "StaleVersion.ilean").toString
    cFile := (outDir / "StaleVersion.c").toString
  }
  expectErrorContains staleVersionReq (Json.mkObj [("code", toJson "contentModified")])

  closeDoc doc

def checkSaveArtifactsStaleHash : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let depAText ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-request-surface"

  let staleHashReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (staleTextHash depAText)
    oleanFile := (outDir / "StaleHash.olean").toString
    ileanFile := (outDir / "StaleHash.ilean").toString
    cFile := (outDir / "StaleHash.c").toString
  }
  expectErrorContains staleHashReq (Json.mkObj [("code", toJson "contentModified")])

  closeDoc doc

def checkSaveArtifactsWrite : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let depAText ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-request-surface"

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
  requireSavedArtifacts "saveArtifacts" outDir saved

  closeDoc doc

def checkSaveArtifactsWriteModuleFamily : ScenarioM Unit := do
  let incompletePaths := Json.mkObj [
    ("oleanServerFile", toJson "ModuleArtifacts.olean.server"),
    ("oleanPrivateFile", toJson "ModuleArtifacts.olean.private"),
    ("irFile", toJson "ModuleArtifacts.ir")
  ]
  match (fromJson? incompletePaths : Except String Beam.LSP.Save.ModuleArtifactPaths) with
  | .ok _ => throw <| IO.userError "module artifact paths accepted a missing IR signature"
  | .error err =>
      unless err.contains "irSigFile" do
        throw <| IO.userError s!"missing IR signature path failed without naming irSigFile: {err}"
  let doc ← openDoc moduleArtifactsFixture
  let text ← IO.FS.readFile moduleArtifactsFixture
  let outDir ← mkTmpDir "beam-save-module-family"

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash text)
    oleanFile := (outDir / "ModuleArtifacts.olean").toString
    moduleArtifacts? := some {
      oleanServerFile := (outDir / "ModuleArtifacts.olean.server").toString
      oleanPrivateFile := (outDir / "ModuleArtifacts.olean.private").toString
      irFile := (outDir / "ModuleArtifacts.ir").toString
      irSigFile := (outDir / "ModuleArtifacts.ir.sig").toString
    }
    ileanFile := (outDir / "ModuleArtifacts.ilean").toString
    cFile := (outDir / "ModuleArtifacts.c").toString
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
  if !saved.written then
    throw <| IO.userError "saveArtifacts module family: expected written = true"
  expectFileExists "saveArtifacts module exported olean" (outDir / "ModuleArtifacts.olean")
  expectFileExists "saveArtifacts module server olean" (outDir / "ModuleArtifacts.olean.server")
  expectFileExists "saveArtifacts module private olean" (outDir / "ModuleArtifacts.olean.private")
  expectFileExists "saveArtifacts module IR" (outDir / "ModuleArtifacts.ir")
  expectFileExists "saveArtifacts module IR signature" (outDir / "ModuleArtifacts.ir.sig")
  let paths := #[outDir / "ModuleArtifacts.olean", outDir / "ModuleArtifacts.olean.server",
    outDir / "ModuleArtifacts.olean.private", outDir / "ModuleArtifacts.ir",
    outDir / "ModuleArtifacts.ir.sig", outDir / "ModuleArtifacts.ilean", outDir / "ModuleArtifacts.c"]
  let prior ← paths.mapM (fun path => liftM (IO.FS.readBinFile path))
  let invalidPathReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash text)
    oleanFile := (outDir / "ModuleArtifacts.olean").toString
    moduleArtifacts? := some {
      oleanServerFile := (outDir / "ModuleArtifacts.olean.server").toString
      oleanPrivateFile := (outDir / "ModuleArtifacts.olean.private").toString
      irFile := (outDir / "ModuleArtifacts.ir").toString
      irSigFile := outDir.toString
    }
    ileanFile := (outDir / "ModuleArtifacts.ilean").toString
    cFile := (outDir / "ModuleArtifacts.c").toString
  }
  expectErrorContains invalidPathReq (Json.mkObj [("code", toJson "internalError")])
  unless (← paths.mapM (fun path => liftM (IO.FS.readBinFile path))) == prior do
    throw <| IO.userError "invalid module artifact path changed prior artifacts"
  expectFileExists "saveArtifacts module ilean" (outDir / "ModuleArtifacts.ilean")
  expectFileExists "saveArtifacts module C" (outDir / "ModuleArtifacts.c")
  let entries ← outDir.readDir
  if entries.any (fun entry =>
      entry.fileName.contains ".beam-tmp-" || entry.fileName.contains ".beam-save-tmp-") then
    throw <| IO.userError
      s!"saveArtifacts module family: temporary artifacts leaked: {entries.map (·.fileName)}"

  closeDoc doc

def checkDeferredCompilationReadiness : ScenarioM Unit := do
  for fixture in ["DeferredGlobal", "DeferredScoped"] do
    let doc ← openDoc s!"tests/lean/BeamTest/Fixtures/Save/{fixture}.lean"
    let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs (← sendSaveReadiness doc)
    unless !readiness.saveReady && readiness.saveReadyReason == "deferredCompilation" &&
        readiness.saveReadyMessage?.any (·.contains "lake build") &&
        readiness.currentDiagnostics.isEmpty && !readiness.blockingCommandMessages.isEmpty do
      throw <| IO.userError s!"{fixture}: incorrect deferred readiness: {(toJson readiness).compress}"
    let outDir ← mkTmpDir "beam-save-deferred"
    let paths := #[outDir / "Deferred.olean", outDir / "Deferred.ilean", outDir / "Deferred.c"]
    for path in paths do IO.FS.writeFile path "prior artifact"
    let request ← sendSaveArtifacts doc {
      oleanFile := paths[0]!.toString
      ileanFile := paths[1]!.toString
      cFile := paths[2]!.toString
    }
    expectErrorContains request (Json.mkObj [("code", toJson "invalidParams")])
    for path in paths do expectFileContents "deferred save" path "prior artifact"
    closeDoc doc

def checkSaveArtifactsFailurePreservesPriorArtifacts : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let text ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-atomic-failure"
  let oleanFile := outDir / "DepA.olean"
  let ileanFile := outDir / "DepA.ilean"
  let cFile := outDir / "DepA.c"
  let blockedParent := outDir / "blocked-parent"
  let oldOlean := "prior olean artifact"
  let oldIlean := "prior ilean artifact"
  let oldC := "prior C artifact"
  IO.FS.writeFile oleanFile oldOlean
  IO.FS.writeFile ileanFile oldIlean
  IO.FS.writeFile cFile oldC
  IO.FS.writeFile blockedParent "not a directory"

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash text)
    oleanFile := oleanFile.toString
    ileanFile := ileanFile.toString
    cFile := cFile.toString
    bcFile? := some (blockedParent / "DepA.bc").toString
  }
  expectErrorContains saveReq (Json.mkObj [("code", toJson "internalError")])
  expectFileContents "failed save replaced the prior olean artifact" oleanFile oldOlean
  expectFileContents "failed save replaced the prior ilean artifact" ileanFile oldIlean
  expectFileContents "failed save replaced the prior C artifact" cFile oldC
  let entries ← outDir.readDir
  if entries.any (fun entry =>
      entry.fileName.contains ".beam-tmp-" || entry.fileName.contains ".beam-save-tmp-" ||
        entry.fileName.contains ".beam-backup-") then
    throw <| IO.userError
      s!"failed save leaked staging artifacts: {entries.map (·.fileName)}"

  closeDoc doc

def checkSaveArtifactsCancellationPreservesPriorArtifacts : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/PartialProgress.lean"
  let outDir ← mkTmpDir "beam-save-atomic-cancellation"
  let oleanFile := outDir / "PartialProgress.olean"
  let ileanFile := outDir / "PartialProgress.ilean"
  let cFile := outDir / "PartialProgress.c"
  let oldOlean := "prior olean artifact"
  let oldIlean := "prior ilean artifact"
  let oldC := "prior C artifact"
  IO.FS.writeFile oleanFile oldOlean
  IO.FS.writeFile ileanFile oldIlean
  IO.FS.writeFile cFile oldC

  let saveReq ← sendSaveArtifacts doc {
    oleanFile := oleanFile.toString
    ileanFile := ileanFile.toString
    cFile := cFile.toString
  }
  cancelReq saveReq
  expectErrorContains saveReq requestCancelledJson
  expectFileContents "cancelled save replaced the prior olean artifact" oleanFile oldOlean
  expectFileContents "cancelled save replaced the prior ilean artifact" ileanFile oldIlean
  expectFileContents "cancelled save replaced the prior C artifact" cFile oldC
  let entries ← outDir.readDir
  if entries.any (fun entry =>
      entry.fileName.contains ".beam-save-tmp-" || entry.fileName.contains ".beam-backup-") then
    throw <| IO.userError
      s!"cancelled save leaked staging artifacts: {entries.map (·.fileName)}"

  closeDoc doc

def checkConcurrentSameWorkerSavesPublishWholeSet : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let referenceDir ← mkTmpDir "beam-save-concurrent-reference"
  let sharedDir ← mkTmpDir "beam-save-concurrent-shared"

  let referenceReq ← sendSaveArtifacts doc {
    oleanFile := (referenceDir / "Reference.olean").toString
    ileanFile := (referenceDir / "Reference.ilean").toString
    cFile := (referenceDir / "Reference.c").toString
  }
  let referenceSaved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs referenceReq
  unless referenceSaved.written do
    throw <| IO.userError "concurrent save reference was not written"
  let reference ← readArtifactSet referenceDir "Reference"
  let rotatedReference := #[reference[2]!, reference[0]!, reference[1]!]

  let requests ← (List.range 8).mapM fun index =>
    if index % 2 == 0 then
      sendSaveArtifacts doc {
        oleanFile := (sharedDir / "Shared.olean").toString
        ileanFile := (sharedDir / "Shared.ilean").toString
        cFile := (sharedDir / "Shared.c").toString
      }
    else
      -- Use a distinct whole-set layout while keeping every request in this document's worker.
      sendSaveArtifacts doc {
        oleanFile := (sharedDir / "Shared.ilean").toString
        ileanFile := (sharedDir / "Shared.c").toString
        cFile := (sharedDir / "Shared.olean").toString
      }
  for request in requests do
    let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs request
    unless saved.written do
      throw <| IO.userError "concurrent save request did not report written = true"
  let shared ← readArtifactSet sharedDir "Shared"
  unless shared == reference || shared == rotatedReference do
    throw <| IO.userError "same-worker concurrent saves published a mixed artifact set"
  let entries ← sharedDir.readDir
  if entries.any (fun entry =>
      entry.fileName.contains ".beam-save-tmp-" || entry.fileName.contains ".beam-backup-") then
    throw <| IO.userError
      s!"same-worker concurrent saves leaked staging artifacts: {entries.map (·.fileName)}"

  closeDoc doc

def checkSaveArtifactsRejectsSameDocumentEditRace : ScenarioM Unit := do
  let path := "tests/scenario/docs/PartialProgress.lean"
  let doc ← openDoc path
  let text ← IO.FS.readFile path
  let outDir ← mkTmpDir "beam-save-request-race"

  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash text)
    oleanFile := (outDir / "PartialProgress.olean").toString
    ileanFile := (outDir / "PartialProgress.ilean").toString
    cFile := (outDir / "PartialProgress.c").toString
  }
  changeDoc doc {
    line := 0
    character := 0
    insert := "-- concurrent edit while saveArtifacts is pending\n"
  }

  expectErrorContains saveReq (Json.mkObj [("code", toJson "contentModified")])
  closeDoc doc

def checkSaveReadinessDocumentErrors : ScenarioM Unit := do
  let doc ← openDoc depAFixture

  changeDoc doc {
    line := 8
    character := 18
    delete := "depB"
    insert := "\"oops\""
  }
  syncDoc doc

  let brokenReq ← sendSaveReadiness doc
  let broken : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs brokenReq
  if broken.saveReady then
    throw <| IO.userError s!"broken saveReadiness: expected saveReady = false, got {(toJson broken).compress}"
  if broken.saveReadyReason != "documentErrors" then
    throw <| IO.userError
      s!"broken saveReadiness: expected reason = documentErrors, got {broken.saveReadyReason}"
  if broken.blockingDiagnostics.isEmpty && broken.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"broken saveReadiness: expected save-blocking evidence, got {(toJson broken).compress}"
  unless broken.blockingDiagnostics.all (·.saveBlocking) &&
      broken.blockingCommandMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"broken saveReadiness: expected blocking evidence to carry saveBlocking=true, got {(toJson broken).compress}"

  closeDoc doc

def checkSaveRequestsWithStandardLspInterference : ScenarioM Unit := do
  let saveDoc ← openDoc depAFixture
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let depAText ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-lsp-interference"

  let readinessReq ← sendSaveReadiness saveDoc
  let saveReq ← sendSaveArtifacts saveDoc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }

  syncWhitespacePrefixEdit editDoc

  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  requireCleanReadiness "saveReadiness with LSP interference" readiness

  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs saveReq
  requireSavedArtifacts "saveArtifacts with LSP interference" outDir saved

  closeDoc saveDoc
  closeDoc editDoc

def checkSaveRequestsWithMixedConcurrency : ScenarioM Unit := do
  let saveDoc ← openDoc depAFixture
  let slowDoc ← openDoc "tests/scenario/docs/RunWithMixedConcurrencyProof.lean"
  let goalsDoc ← openDoc "tests/save_olean_project/GoalSmoke.lean"
  let cmdDoc ← openDoc "tests/scenario/docs/CommandB.lean"
  let editDoc ← openDoc "tests/scenario/docs/SimpleProofB.lean"

  let depAText ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-mixed-concurrency"

  let slowReqs ← (List.range 3).mapM fun _ =>
    sendRunAt slowDoc { line := 9, character := 2, text := "mixed_sleep_exact" }
  let readinessReqs ← (List.range 6).mapM fun _ =>
    sendSaveReadiness saveDoc
  let artifactReqs ← (List.range 2).mapM fun i => do
    let artifactDir := outDir / s!"artifact-{i}"
    let req ← sendSaveArtifacts saveDoc {
      expectedVersionOverride? := some 1
      expectedTextHashOverride? := some (hash depAText)
      oleanFile := (artifactDir / "DepA.olean").toString
      ileanFile := (artifactDir / "DepA.ilean").toString
      cFile := (artifactDir / "DepA.c").toString
    }
    pure (artifactDir, req)
  let goalsPrevReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := false }
  let goalsAfterReqs ← (List.range 3).mapM fun _ =>
    sendGoals goalsDoc { line := 1, character := 2, useAfter := true }
  let cmdReqs ← (List.range 6).mapM fun _ =>
    sendRunAt cmdDoc { line := 0, character := 2, text := "#check Nat" }

  syncWhitespacePrefixEdit editDoc

  for req in readinessReqs do
    let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs req
    requireCleanReadiness "saveReadiness mixed concurrency" readiness
  for (artifactDir, req) in artifactReqs do
    let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitResponseAs req
    requireSavedArtifacts "saveArtifacts mixed concurrency" artifactDir saved
  for req in goalsPrevReqs do
    let goalsPrev : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    if goalsPrev.goals.size != 1 then
      throw <| IO.userError
        s!"save mixed concurrency goalsPrev: expected one goal, got {goalsPrev.goals.size}"
    requireSingleGoalTarget "save mixed concurrency goalsPrev" "True" goalsPrev
  for req in goalsAfterReqs do
    let goalsAfter : Beam.LSP.Lib.ProofState ← awaitResponseAs req
    if goalsAfter.goals.size != 0 then
      throw <| IO.userError
        s!"save mixed concurrency goalsAfter: expected solved proof state, got {goalsAfter.goals.size} goals"
  for req in slowReqs do
    discard <| requireRunAtResponseSuccess "save mixed concurrency slow runAt" req
  for req in cmdReqs do
    discard <| requireRunAtResponseSuccess "save mixed concurrency command runAt" req

  closeDoc saveDoc
  closeDoc slowDoc
  closeDoc goalsDoc
  closeDoc cmdDoc
  closeDoc editDoc

def checkReportedOnlyErrorReadiness : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/ReportedOnlyError.lean"
  syncDoc doc

  let readinessReq ← sendSaveReadiness doc
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs readinessReq
  if !readiness.saveReady then
    throw <| IO.userError
      s!"reported-only saveReadiness: expected saveReady = true, got {(toJson readiness).compress}"
  unless readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError
      s!"reported-only saveReadiness: expected no save-blocking evidence, got {(toJson readiness).compress}"

  closeDoc doc

def run : ScenarioM Unit := do
  checkSaveReadinessDecoderRequiresVerdict
  checkSaveReadinessOk
  checkSaveReadinessStaleVersion
  checkSaveReadinessStaleHash
  checkSaveArtifactsStaleVersion
  checkSaveArtifactsStaleHash
  checkSaveArtifactsWrite
  checkSaveArtifactsWriteModuleFamily
  checkDeferredCompilationReadiness
  checkSaveArtifactsFailurePreservesPriorArtifacts
  checkSaveArtifactsCancellationPreservesPriorArtifacts
  checkConcurrentSameWorkerSavesPublishWholeSet
  checkSaveArtifactsRejectsSameDocumentEditRace
  checkSaveReadinessDocumentErrors
  checkSaveRequestsWithStandardLspInterference
  checkSaveRequestsWithMixedConcurrency
  checkReportedOnlyErrorReadiness

end BeamTest.LSP.Requests.Save.BasicTest
