/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/
import Beam.Broker.Publication

open Lean System Beam.Broker

private def paths (outputs : LeanSaveOutputs) : Array FilePath :=
  #[some outputs.oleanPath, outputs.oleanServerPath?, outputs.oleanPrivatePath?,
    some outputs.ileanPath, outputs.irPath?, outputs.irSigPath?, some outputs.cPath,
    outputs.bcPath?, some outputs.tracePath].filterMap id

private def artifactPaths (outputs : LeanSaveOutputs) : Array FilePath :=
  (paths outputs).filter (· != outputs.tracePath)

private def hashPaths (outputs : LeanSaveOutputs) : Array FilePath :=
  (artifactPaths outputs).map (·.addExtension "hash")

private def writeHashes (outputs : LeanSaveOutputs) : IO Unit := do
  for path in hashPaths outputs do IO.FS.writeFile path ("cached:" ++ path.toString)

private def readHashes (outputs : LeanSaveOutputs) : IO (Array String) :=
  (hashPaths outputs).mapM IO.FS.readFile

private def expectNoHashes (outputs : LeanSaveOutputs) : IO Unit := do
  for path in hashPaths outputs do
    if ← path.pathExists then
      throw <| IO.userError s!"publication retained output hash: {path}"

private def writeFamily (outputs canonical : LeanSaveOutputs) (text : String) : IO Unit := do
  for (path, target) in (paths outputs).zip (paths canonical) do
    IO.FS.writeFile path (text ++ target.fileName.getD "")

private def readFamily (outputs : LeanSaveOutputs) : IO (Array String) :=
  (paths outputs).mapM IO.FS.readFile

private def expectFailure (label : String) (action : IO Unit) : IO Unit := do
  let failed ← try action *> pure false catch _ => pure true
  unless failed do throw <| IO.userError label

private inductive FailureStage where
  | preparing | committing
  deriving BEq

private def checkBeforeReplacement (stage : FailureStage) : IO Unit := IO.FS.withTempDir fun root => do
  let canonical : LeanSaveOutputs := {
    oleanPath := root / "Boundary.olean", ileanPath := root / "Boundary.ilean",
    cPath := root / "Boundary.c", tracePath := root / "Boundary.trace"
  }
  for path in #[canonical.oleanPath, canonical.cPath, canonical.tracePath] do
    IO.FS.writeFile path ("old:" ++ path.fileName.getD "")
  writeHashes canonical
  let priorHashes ← readHashes canonical
  let plan ← Publication.create canonical
  writeFamily plan.outputs canonical "candidate:"
  let faults ← IO.mkRef (0 : Nat)
  let restored ← IO.mkRef (#[] : Array FilePath)
  let failedPath := if stage == .preparing then canonical.cPath else canonical.oleanPath
  let fault : IO.Error := .permissionDenied (some failedPath.toString) 13 "controlled boundary failure"
  let hardLink := fun source target => do
    if stage == .preparing && source == canonical.cPath then
      unless (← IO.FS.readFile (plan.outputs.oleanPath.addExtension "previous")) ==
          "old:Boundary.olean" do
        throw <| IO.userError "backup failure did not follow a real prepared backup"
      faults.modify (· + 1)
      throw fault
    IO.FS.hardLink source target
  let rename := fun source target => do
    if stage == .committing && source == plan.outputs.oleanPath then
      if ← canonical.tracePath.pathExists then
        throw <| IO.userError "first replacement preceded trace invalidation"
      expectNoHashes canonical
      faults.modify (· + 1)
      throw fault
    if source == plan.outputs.tracePath.addExtension "previous" then
      throw <| IO.userError "rollback attempted to restore the old trace"
    if source == plan.outputs.oleanPath.addExtension "previous" ||
        source == plan.outputs.cPath.addExtension "previous" then
      if ← canonical.tracePath.pathExists then
        throw <| IO.userError "artifact restoration preceded trace invalidation"
      IO.FS.rename source target
      restored.modify (·.push target)
    else
      IO.FS.rename source target
  let removeFile := fun path => do
    if stage == .preparing && (paths canonical).contains path then
      throw <| IO.userError "backup preparation failure attempted canonical cleanup"
    IO.FS.removeFile path
  plan.ready
  let outcome ←
    (Publication.Internal.promote plan rename removeFile (hardLink := hardLink)).toBaseIO
  match outcome with
  | .error (.permissionDenied (some filename) 13 _) =>
      unless filename == failedPath.toString do
        throw <| IO.userError "boundary failure lost its original typed error"
  | .error error => throw error
  | .ok () => throw <| IO.userError "controlled boundary failure unexpectedly succeeded"
  unless (← faults.get) == 1 do
    throw <| IO.userError "controlled boundary failure was not reached exactly once"
  let expectedRestore := if stage == .preparing then #[] else #[canonical.cPath, canonical.oleanPath]
  unless (← restored.get) == expectedRestore do
    throw <| IO.userError "rollback did not recover the complete prepared beforeimages in reverse"
  for path in #[canonical.oleanPath, canonical.cPath] do
    unless (← IO.FS.readFile path) == "old:" ++ path.fileName.getD "" do
      throw <| IO.userError "boundary failure changed an original artifact"
  if ← canonical.ileanPath.pathExists then
    throw <| IO.userError "boundary failure created an originally absent output"
  if stage == .preparing then
    unless (← IO.FS.readFile canonical.tracePath) == "old:Boundary.trace" &&
        (← readHashes canonical) == priorHashes do
      throw <| IO.userError "backup preparation failure invalidated the prior checkpoint"
  else
    if ← canonical.tracePath.pathExists then
      throw <| IO.userError "failed canonical commit restored the prior trace"
    expectNoHashes canonical
  unless (← readFamily plan.outputs) ==
      (paths canonical).map (fun path => "candidate:" ++ path.fileName.getD "") do
    throw <| IO.userError "boundary failure consumed a candidate before the first replacement"
  for path in #[plan.outputs.oleanPath, plan.outputs.cPath] do
    if ← (path.addExtension "previous").pathExists then
      throw <| IO.userError "successful boundary recovery retained an artifact backup"
  plan.dispose true
  for candidate in paths plan.outputs do
    let directory := candidate.parent.getD "."
    if (← directory.pathExists) || (← (FilePath.mk (directory.toString ++ ".claim")).pathExists) then
      throw <| IO.userError "successfully recovered boundary attempt was not disposable"

private def checkCommittedCleanupFailure : IO Unit := IO.FS.withTempDir fun root => do
  let canonical : LeanSaveOutputs := {
    oleanPath := root / "Cleanup.olean", ileanPath := root / "Cleanup.ilean",
    cPath := root / "Cleanup.c", tracePath := root / "Cleanup.trace"
  }
  writeFamily canonical canonical "old:"
  let plan ← Publication.create canonical
  writeFamily plan.outputs canonical "new:"
  let backup := plan.outputs.oleanPath.addExtension "previous"
  let faults ← IO.mkRef (0 : Nat)
  let removeFile := fun path => do
    if path == backup then
      faults.modify (· + 1)
      throw <| IO.Error.hardwareFault 5 "controlled committed-backup cleanup failure"
    IO.FS.removeFile path
  plan.ready
  Publication.Internal.promote plan IO.FS.rename removeFile
  unless (← faults.get) == 1 do
    throw <| IO.userError "committed cleanup failpoint was not reached once"
  unless (← readFamily canonical) ==
      (paths canonical).map (fun path => "new:" ++ path.fileName.getD "") do
    throw <| IO.userError "backup cleanup failure changed the committed checkpoint"
  -- Refill consumed candidates so the retry exercises authority, not the file precheck.
  writeFamily plan.outputs canonical "retry:"
  expectFailure "committed cleanup failure regained readiness" plan.ready
  expectFailure "committed cleanup failure regained promotion authority" plan.promote
  unless (← readFamily canonical) ==
      (paths canonical).map (fun path => "new:" ++ path.fileName.getD "") do
    throw <| IO.userError "committed cleanup retry changed canonical output bytes"
  plan.dispose true
  unless (← IO.FS.readFile backup) == "old:Cleanup.olean" do
    throw <| IO.userError "committed cleanup failure lost its retained backup"
  for candidate in paths plan.outputs do
    let directory := candidate.parent.getD "."
    let claim := FilePath.mk (directory.toString ++ ".claim")
    unless (← directory.isDir) && (← claim.symlinkMetadata).type == .file do
      throw <| IO.userError "committed cleanup failure lost its owned recovery paths"

private def checkRollback (failRestore : Bool) : IO Unit := IO.FS.withTempDir fun root => do
  let canonical : LeanSaveOutputs := {
    oleanPath := root / "Rollback.olean", ileanPath := root / "Rollback.ilean",
    cPath := root / "Rollback.c", tracePath := root / "Rollback.trace"
  }
  -- The middle output has no prior artifact; rollback must unlink it rather than restore it.
  for path in #[canonical.oleanPath, canonical.cPath, canonical.tracePath] do
    IO.FS.writeFile path ("old:" ++ path.fileName.getD "")
  writeHashes canonical
  let traceHash := canonical.tracePath.addExtension "hash"
  IO.FS.writeFile traceHash "preserved trace hash"
  let plan ← Publication.create canonical
  writeFamily plan.outputs canonical "new:"
  let cBackup := plan.outputs.cPath.addExtension "previous"
  let traceBackup := plan.outputs.tracePath.addExtension "previous"
  let publicationError : IO.Error :=
    .permissionDenied (some canonical.tracePath.toString) 13 "controlled trace rename failure"
  let restoreError : IO.Error := .hardwareFault 5 "controlled backup restore failure"
  let publicationFaults ← IO.mkRef (0 : Nat)
  let restoreFaults ← IO.mkRef (0 : Nat)
  let continuedRestore ← IO.mkRef false
  let continuedRemoval ← IO.mkRef false
  let rename := fun source target => do
    if source == plan.outputs.tracePath then
      unless target == canonical.tracePath do
        throw <| IO.userError "trace rename targeted an unexpected path"
      unless (← (artifactPaths canonical).mapM IO.FS.readFile) ==
          (artifactPaths canonical).map (fun path => "new:" ++ path.fileName.getD "") do
        throw <| IO.userError "controlled publication failure preceded real artifact replacements"
      for path in artifactPaths plan.outputs do
        if ← path.pathExists then
          throw <| IO.userError "controlled publication failure preceded candidate consumption"
      if ← canonical.tracePath.pathExists then
        throw <| IO.userError "controlled publication failure retained the old trace"
      expectNoHashes canonical
      publicationFaults.modify (· + 1)
      throw publicationError
    if failRestore && source == cBackup then
      unless (← IO.FS.readFile target) == "new:Rollback.c" &&
          (← IO.FS.readFile source) == "old:Rollback.c" do
        throw <| IO.userError "controlled rollback failure did not reach a real backup restore"
      restoreFaults.modify (· + 1)
      throw restoreError
    IO.FS.rename source target
    if source == plan.outputs.oleanPath.addExtension "previous" then
      unless (← restoreFaults.get) == (if failRestore then 1 else 0) do
        throw <| IO.userError "rollback restored an earlier artifact before the controlled failure"
      continuedRestore.set true
  let removeFile := fun path => do
    IO.FS.removeFile path
    if path == canonical.ileanPath then
      unless (← restoreFaults.get) == (if failRestore then 1 else 0) do
        throw <| IO.userError "rollback removed the new output before the controlled failure"
      continuedRemoval.set true
  plan.ready
  let outcome : Except IO.Error Unit ←
    try Publication.Internal.promote plan rename removeFile *> pure (.ok ())
    catch error => pure (.error error)
  match outcome with
  | .error (.permissionDenied (some filename) 13 _) =>
    unless !failRestore && filename == canonical.tracePath.toString do
      throw <| IO.userError "publication lost the rollback failure"
  | .error (.userError _) =>
    unless failRestore do
      throw <| IO.userError "successful rollback lost the typed publication error"
  | _ => throw <| IO.userError "controlled publication failure did not reach the caller"
  unless (← publicationFaults.get) == 1 &&
      (← restoreFaults.get) == (if failRestore then 1 else 0) do
    throw <| IO.userError "controlled publication/rollback failpoints were not each reached once"
  unless (← continuedRestore.get) && (← continuedRemoval.get) do
    throw <| IO.userError "rollback stopped before restoring/removing earlier artifacts"
  unless (← IO.FS.readFile canonical.oleanPath) == "old:Rollback.olean" do
    throw <| IO.userError "rollback did not restore the pre-existing artifact"
  unless (← IO.FS.readFile canonical.cPath) ==
      (if failRestore then "new:Rollback.c" else "old:Rollback.c") do
    throw <| IO.userError "rollback left unexpected bytes at the controlled restore target"
  if ← canonical.ileanPath.pathExists then
    throw <| IO.userError "rollback retained an initially absent output"
  if ← canonical.tracePath.pathExists then
    throw <| IO.userError "rollback republished the old trace"
  expectNoHashes canonical
  unless (← IO.FS.readFile traceHash) == "preserved trace hash" do
    throw <| IO.userError "rollback changed the excluded trace hash"
  -- Refill every consumed candidate so a retry reaches the phase guard, not a file precheck.
  writeFamily plan.outputs canonical "retry:"
  let existing := #[canonical.oleanPath, canonical.cPath]
  let afterRollback ← existing.mapM IO.FS.readFile
  expectFailure "failed publication regained readiness" plan.ready
  expectFailure "failed publication regained promotion authority" plan.promote
  if (← canonical.ileanPath.pathExists) || (← canonical.tracePath.pathExists) then
    throw <| IO.userError "failed publication retry changed the canonical output set"
  unless (← existing.mapM IO.FS.readFile) == afterRollback do
    throw <| IO.userError "failed publication retry changed canonical artifact bytes"
  expectNoHashes canonical
  plan.dispose true
  for candidate in paths plan.outputs do
    let directory := candidate.parent.getD "."
    let claim := FilePath.mk (directory.toString ++ ".claim")
    if failRestore then
      unless (← directory.isDir) && (← claim.symlinkMetadata).type == .file do
        throw <| IO.userError "failed rollback disposal removed retained ownership paths"
    else if (← directory.pathExists) || (← claim.pathExists) then
      throw <| IO.userError "successful rollback was not disposable"
  if failRestore then
    unless (← IO.FS.readFile cBackup) == "old:Rollback.c" &&
        (← IO.FS.readFile traceBackup) == "old:Rollback.trace" do
      throw <| IO.userError "failed rollback disposal removed recovery backups"

def main : IO Unit := IO.FS.withTempDir fun root => do
  let canonical : LeanSaveOutputs := {
    oleanPath := root / "Main.olean",
    oleanServerPath? := some (root / "Main.olean.server"),
    oleanPrivatePath? := some (root / "Main.olean.private"),
    ileanPath := root / "Main.ilean", irPath? := some (root / "Main.ir"),
    irSigPath? := some (root / "Main.ir.sig"), cPath := root / "Main.c",
    bcPath? := some (root / "Main.bc"), tracePath := root / "Main.trace"
  }
  writeFamily canonical canonical "prior:"
  writeHashes canonical
  let prior ← readFamily canonical
  let priorHashes ← readHashes canonical
  let preserved := #[canonical.tracePath.addExtension "hash", root / "Main.ltar.hash",
    root / "Unrelated.olean.hash"]
  for path in preserved do IO.FS.writeFile path ("preserved:" ++ path.toString)
  let preservedHashes ← preserved.mapM IO.FS.readFile
  let abandoned ← Publication.create canonical
  for candidate in paths abandoned.outputs do
    unless candidate.toString.endsWith ".candidate" do
      throw <| IO.userError "private candidate retained an indexable artifact extension"
  abandoned.dispose false
  -- Simulate a genuinely late producer after the broker has returned its failure.
  writeFamily abandoned.outputs canonical "late:"
  expectFailure "abandoned preparation regained authority" abandoned.ready
  expectFailure "abandoned plan promoted late outputs" abandoned.promote
  unless (← readFamily canonical) == prior do
    throw <| IO.userError "late producer changed canonical outputs"
  unless (← readHashes canonical) == priorHashes do
    throw <| IO.userError "abandoned publication invalidated canonical hashes"
  let replacement ← Publication.create canonical
  unless replacement.outputs.oleanPath != abandoned.outputs.oleanPath do
    throw <| IO.userError "publication attempts reused private paths"
  writeFamily replacement.outputs canonical "next:"
  replacement.ready
  replacement.promote
  let committed ← readFamily canonical
  unless committed == (paths canonical).map (fun path => "next:" ++ path.fileName.getD "") do
    throw <| IO.userError "broker did not install the complete artifact/trace family"
  expectNoHashes canonical
  unless (← preserved.mapM IO.FS.readFile) == preservedHashes do
    throw <| IO.userError "publication invalidated trace, unwritten archive, or unrelated hashes"
  expectFailure "committed plan was promoted again" replacement.promote
  replacement.dispose true
  abandoned.dispose true
  writeHashes canonical
  let invalid ← Publication.create canonical
  writeFamily invalid.outputs canonical "invalid:"
  IO.FS.removeFile invalid.outputs.tracePath
  invalid.ready
  expectFailure "missing trace was accepted" invalid.promote
  unless (← readFamily canonical) == committed do
    throw <| IO.userError "precommit failure invalidated the existing checkpoint"
  unless (← readHashes canonical) == priorHashes do
    throw <| IO.userError "precommit failure invalidated canonical hashes"
  invalid.dispose true
  -- A late hash failure must happen before even the first canonical artifact is replaced.
  let blockedHash := (root / "Main.bc").addExtension "hash"
  IO.FS.removeFile blockedHash
  IO.FS.createDir blockedHash
  let blocked ← Publication.create canonical
  writeFamily blocked.outputs canonical "blocked:"
  blocked.ready
  let outcome : Except IO.Error Unit ←
    try blocked.promote *> pure (.ok ()) catch error => pure (.error error)
  match outcome with
  | .ok _ => throw <| IO.userError "hash unlink failure was accepted"
  | .error (.noFileOrDirectory ..) =>
    throw <| IO.userError "hash obstruction unexpectedly reported a missing file"
  | .error _ => pure ()
  unless (← (artifactPaths canonical).mapM IO.FS.readFile) ==
      (artifactPaths canonical).map (fun path => "next:" ++ path.fileName.getD "") do
    throw <| IO.userError "hash unlink failure replaced canonical artifact bytes"
  unless (← readFamily blocked.outputs) ==
      (paths canonical).map (fun path => "blocked:" ++ path.fileName.getD "") do
    throw <| IO.userError "hash unlink failure occurred after a candidate was renamed"
  if ← canonical.tracePath.pathExists then
    throw <| IO.userError "hash unlink failure retained the old trace"
  unless ← blockedHash.isDir do
    throw <| IO.userError "hash obstruction was removed"
  unless (← preserved.mapM IO.FS.readFile) == preservedHashes do
    throw <| IO.userError "hash unlink failure changed unrelated hashes"
  blocked.dispose true
  IO.FS.removeDir blockedHash
  -- Missing output caches are harmless, including after an aborted publication.
  expectNoHashes canonical
  let uncached ← Publication.create canonical
  writeFamily uncached.outputs canonical "uncached:"
  uncached.ready
  uncached.promote
  unless (← readFamily canonical) ==
      (paths canonical).map (fun path => "uncached:" ++ path.fileName.getD "") do
    throw <| IO.userError "missing hashes prevented complete publication"
  expectNoHashes canonical
  unless (← preserved.mapM IO.FS.readFile) == preservedHashes do
    throw <| IO.userError "uncached publication changed unrelated hashes"
  uncached.dispose true
  checkRollback false
  checkRollback true
  checkBeforeReplacement .preparing
  checkBeforeReplacement .committing
  checkCommittedCleanupFailure
  IO.println "publication ownership: passed"
