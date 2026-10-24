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

private def awaitSavedArtifacts (req : ReqHandle) : ScenarioM Beam.LSP.Save.SaveArtifactsResult := do
  let completion : Beam.LSP.Save.SaveArtifactsCompletion ← awaitResponseAs req
  match completion with
  | .success result => pure result
  | .failure code message =>
      throw <| IO.userError s!"save handler failed with {(toJson code).compress}: {message}"

private def expectSaveFailure (req : ReqHandle) (code : Lean.JsonRpc.ErrorCode)
    (allowRoutingError : Bool := false) : ScenarioM Unit := do
  let outcome ← awaitReq req
  if allowRoutingError && outcome.errorCode?.isSome then
    expectErrorContains req (Json.mkObj [("code", toJson (BeamTest.TestHarness.errorCodeName code))])
    return
  let completion : Beam.LSP.Save.SaveArtifactsCompletion ← awaitResponseAs req
  match completion with
  | .success _ => throw <| IO.userError "save handler unexpectedly succeeded"
  | .failure actual _ =>
      unless actual == code do
        throw <| IO.userError s!"save handler returned {(toJson actual).compress}, expected {(toJson code).compress}"

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
  expectSaveFailure staleVersionReq .contentModified

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
  expectSaveFailure staleHashReq .contentModified

  closeDoc doc

def checkSaveArtifactsWrite : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let depAText ← IO.FS.readFile depAFixture
  let outDir ← mkTmpDir "beam-save-request-surface"

  let bcFile? := if Lean.Internal.hasLLVMBackend () then some (outDir / "DepA.bc") else none
  if bcFile?.isNone then
    IO.eprintln "saveArtifacts ordinary bitcode: unsupported (toolchain has no LLVM backend)"
  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash depAText)
    oleanFile := (outDir / "DepA.olean").toString
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
    bcFile? := bcFile?.map (·.toString)
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitSavedArtifacts saveReq
  requireSavedArtifacts "saveArtifacts" outDir saved
  if let some bcFile := bcFile? then expectFileExists "saveArtifacts ordinary bitcode" bcFile

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

  -- The broker supplies each companion in its own private directory. Exercise that layout.
  let paths := #[outDir / "module" / "ModuleArtifacts.olean",
    outDir / "server" / "ModuleArtifacts.olean.server",
    outDir / "private" / "ModuleArtifacts.olean.private", outDir / "ir" / "ModuleArtifacts.ir",
    outDir / "signature" / "ModuleArtifacts.ir.sig", outDir / "ilean" / "ModuleArtifacts.ilean",
    outDir / "c" / "ModuleArtifacts.c"]
  let bcFile? := if Lean.Internal.hasLLVMBackend () then some (outDir / "bc" / "ModuleArtifacts.bc")
    else none
  if bcFile?.isNone then
    IO.eprintln "saveArtifacts module bitcode: unsupported (toolchain has no LLVM backend)"
  let saveReq ← sendSaveArtifacts doc {
    expectedVersionOverride? := some 1
    expectedTextHashOverride? := some (hash text)
    oleanFile := paths[0]!.toString
    moduleArtifacts? := some {
      oleanServerFile := paths[1]!.toString
      oleanPrivateFile := paths[2]!.toString
      irFile := paths[3]!.toString
      irSigFile := paths[4]!.toString
    }
    ileanFile := paths[5]!.toString
    cFile := paths[6]!.toString
    bcFile? := bcFile?.map (·.toString)
  }
  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitSavedArtifacts saveReq
  unless saved.written && saved.version == 1 && saved.textHash == hash text do
    throw <| IO.userError "saveArtifacts module family returned the wrong completion"
  for path in paths do expectFileExists "saveArtifacts module family" path
  if let some bcFile := bcFile? then expectFileExists "saveArtifacts module bitcode" bcFile
  let entries ← (outDir / "module").readDir
  if entries.any (·.fileName.startsWith ".beam-save-tmp-") then
    throw <| IO.userError "module filename adapter left temporary files"

  closeDoc doc

def checkDeferredCompilationReadiness : ScenarioM Unit := do
  for fixture in ["DeferredGlobal", "DeferredScoped"] do
    let doc ← openDoc s!"tests/lean/BeamTest/Fixtures/Save/{fixture}.lean"
    let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs (← sendSaveReadiness doc)
    unless !readiness.saveReady && readiness.saveReadyReason == "deferredCompilation" &&
        readiness.saveReadyMessage?.any (·.contains "lake build") &&
        readiness.currentDiagnostics.isEmpty && readiness.blockingDiagnostics.isEmpty &&
        readiness.blockingCommandMessages.size == 1 do
      throw <| IO.userError s!"{fixture}: incorrect deferred readiness: {(toJson readiness).compress}"
    let outDir ← mkTmpDir "beam-save-deferred"
    let paths := #[outDir / "Deferred.olean", outDir / "Deferred.ilean", outDir / "Deferred.c"]
    for path in paths do IO.FS.writeFile path "prior artifact"
    let request ← sendSaveArtifacts doc {
      oleanFile := paths[0]!.toString
      ileanFile := paths[1]!.toString
      cFile := paths[2]!.toString
    }
    expectSaveFailure request .invalidParams
    for path in paths do expectFileContents "deferred save" path "prior artifact"
    closeDoc doc

def checkSaveArtifactsPartialPrivateFailure : ScenarioM Unit := do
  let doc ← openDoc moduleArtifactsFixture
  let outDir ← mkTmpDir "beam-save-private-failure"
  let paths := #[outDir / "ModuleArtifacts.olean", outDir / "ModuleArtifacts.olean.server",
    outDir / "ModuleArtifacts.olean.private", outDir / "ModuleArtifacts.ir",
    outDir / "ModuleArtifacts.ir.sig", outDir / "ModuleArtifacts.ilean"]
  let blockedParent := outDir / "blocked-parent"
  IO.FS.writeFile blockedParent "not a directory"
  let cFile := blockedParent / "ModuleArtifacts.c"
  let request ← sendSaveArtifacts doc {
    oleanFile := paths[0]!.toString
    moduleArtifacts? := some {
      oleanServerFile := paths[1]!.toString
      oleanPrivateFile := paths[2]!.toString
      irFile := paths[3]!.toString
      irSigFile := paths[4]!.toString
    }
    ileanFile := paths[5]!.toString
    cFile := cFile.toString
  }
  expectSaveFailure request .internalError
  -- Failure may leave private outputs; only the broker can publish a canonical checkpoint.
  for path in paths do
    expectFileExists "partial private output" path
    if (← IO.FS.readBinFile path).isEmpty then
      throw <| IO.userError s!"private preparation did not finish the earlier output: {path}"
  expectFileContents "blocked private parent" blockedParent "not a directory"
  let entries ← outDir.readDir
  if entries.any (·.fileName.startsWith ".beam-save-tmp-") then
    throw <| IO.userError "failed private preparation left module adapter scratch files"
  closeDoc doc

def checkSaveArtifactsInvalidShape : ScenarioM Unit := do
  let outDir ← mkTmpDir "beam-save-private-shape"
  let ordinary ← openDoc depAFixture
  let duplicate ← sendSaveArtifacts ordinary {
    oleanFile := (outDir / "duplicate").toString
    ileanFile := (outDir / "duplicate").toString
    cFile := (outDir / "DepA.c").toString
  }
  expectSaveFailure duplicate .internalError
  let extraCompanions ← sendSaveArtifacts ordinary {
    oleanFile := (outDir / "DepA.olean").toString
    moduleArtifacts? := some {
      oleanServerFile := (outDir / "DepA.olean.server").toString
      oleanPrivateFile := (outDir / "DepA.olean.private").toString
      irFile := (outDir / "DepA.ir").toString
      irSigFile := (outDir / "DepA.ir.sig").toString
    }
    ileanFile := (outDir / "DepA.ilean").toString
    cFile := (outDir / "DepA.c").toString
  }
  expectSaveFailure extraCompanions .internalError
  closeDoc ordinary
  let moduleDoc ← openDoc moduleArtifactsFixture
  let missingCompanions ← sendSaveArtifacts moduleDoc {
    oleanFile := (outDir / "ModuleArtifacts.olean").toString
    ileanFile := (outDir / "ModuleArtifacts.ilean").toString
    cFile := (outDir / "ModuleArtifacts.c").toString
  }
  expectSaveFailure missingCompanions .internalError
  unless (← outDir.readDir).isEmpty do
    throw <| IO.userError "invalid private output shape wrote artifact files"
  closeDoc moduleDoc

def checkSaveArtifactsCancellation : ScenarioM Unit := do
  let doc ← openDoc "tests/scenario/docs/PartialProgress.lean"
  let outDir ← mkTmpDir "beam-save-private-cancellation"
  let request ← sendSaveArtifacts doc {
    oleanFile := (outDir / "PartialProgress.olean").toString
    ileanFile := (outDir / "PartialProgress.ilean").toString
    cFile := (outDir / "PartialProgress.c").toString
  }
  cancelReq request
  expectErrorContains request (Json.mkObj [("code", toJson "requestCancelled")])
  -- Cancellation may leave private files; the request makes no rollback guarantee.
  closeDoc doc

def checkConcurrentDisjointPrivateSaves : ScenarioM Unit := do
  let doc ← openDoc depAFixture
  let outDir ← mkTmpDir "beam-save-disjoint-attempts"
  let requests ← (List.range 4).mapM fun index => do
    let directory := outDir / s!"attempt-{index}"
    let request ← sendSaveArtifacts doc {
      oleanFile := (directory / "DepA.olean").toString
      ileanFile := (directory / "DepA.ilean").toString
      cFile := (directory / "DepA.c").toString
    }
    pure (directory, request)
  for (directory, request) in requests do
    let saved ← awaitSavedArtifacts request
    requireSavedArtifacts "disjoint private save" directory saved
  let reference ← readArtifactSet (outDir / "attempt-0") "DepA"
  for (directory, _) in requests do
    unless (← readArtifactSet directory "DepA") == reference do
      throw <| IO.userError "disjoint private attempts produced different artifact families"
    unless (← directory.readDir).size == 3 do
      throw <| IO.userError "disjoint private attempt left unexpected files"
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

  expectSaveFailure saveReq .contentModified (allowRoutingError := true)
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
  if broken.blockingDiagnostics.isEmpty || !broken.blockingCommandMessages.isEmpty then
    throw <| IO.userError
      s!"broken saveReadiness: expected located evidence without command-message copies, got {(toJson broken).compress}"
  unless broken.blockingDiagnostics.all (·.saveBlocking) &&
      broken.blockingCommandMessages.all (·.saveBlocking) do
    throw <| IO.userError
      s!"broken saveReadiness: expected blocking evidence to carry saveBlocking=true, got {(toJson broken).compress}"

  closeDoc doc

def checkRepeatedReadinessErrors : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Save/RepeatedErrors.lean"
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs (← sendSaveReadiness doc)
  unless !readiness.saveReady && readiness.saveReadyReason == "documentErrors" &&
      readiness.blockingDiagnostics.size == 2 && readiness.blockingCommandMessages.isEmpty do
    throw <| IO.userError s!"repeated errors lost or duplicated: {(toJson readiness).compress}"
  let some first := readiness.blockingDiagnostics[0]?
    | throw <| IO.userError "missing first blocking diagnostic"
  let some second := readiness.blockingDiagnostics[1]?
    | throw <| IO.userError "missing second blocking diagnostic"
  unless first.message == second.message && first.range.start.line != second.range.start.line &&
      first.saveBlocking && second.saveBlocking do
    throw <| IO.userError s!"identical errors must retain their distinct locations: {(toJson readiness).compress}"
  closeDoc doc

def checkReadinessWithoutFinalState : ScenarioM Unit := do
  let doc ← openDoc "tests/lean/BeamTest/Fixtures/Save/MissingImport.lean"
  let readiness : Beam.LSP.Save.SaveReadinessResult ← awaitResponseAs (← sendSaveReadiness doc)
  unless !readiness.saveReady &&
      readiness.saveReadyReason == "documentDidNotElaborateSuccessfully" &&
      !readiness.blockingDiagnostics.isEmpty && readiness.blockingCommandMessages.isEmpty &&
      readiness.blockingDiagnostics.all (·.saveBlocking) do
    throw <| IO.userError s!"missing final state must retain located errors: {(toJson readiness).compress}"
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

  let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitSavedArtifacts saveReq
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
    let saved : Beam.LSP.Save.SaveArtifactsResult ← awaitSavedArtifacts req
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
  checkSaveArtifactsPartialPrivateFailure
  checkSaveArtifactsInvalidShape
  checkSaveArtifactsCancellation
  checkConcurrentDisjointPrivateSaves
  checkSaveArtifactsRejectsSameDocumentEditRace
  checkSaveReadinessDocumentErrors
  checkRepeatedReadinessErrors
  checkReadinessWithoutFinalState
  checkSaveRequestsWithStandardLspInterference
  checkSaveRequestsWithMixedConcurrency
  checkReportedOnlyErrorReadiness

end BeamTest.LSP.Requests.Save.BasicTest
