/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.Save
import BeamTest.TransactionTest

open Lean System

namespace BeamTest.LSP.SavePublicationTest

-- Follow McpDropFailureTest: keep the publisher private and type-check every fixture access.
local macro "savePrivate% " name:ident : term =>
  `(@$(mkIdent (mkPrivateNameCore `Beam.LSP.Save name.getId)))

private abbrev Artifact := (savePrivate% Beam.LSP.Save.StagedArtifact)

private def staged (artifact : Artifact) : FilePath :=
  (savePrivate% Beam.LSP.Save.StagedArtifact.staged) artifact

private def target (artifact : Artifact) : FilePath :=
  (savePrivate% Beam.LSP.Save.StagedArtifact.target) artifact

private def backup (artifact : Artifact) : FilePath :=
  (savePrivate% Beam.LSP.Save.StagedArtifact.backup) artifact

private def require (label : String) (condition : Bool) : IO Unit :=
  unless condition do throw <| IO.userError label

private inductive Operation where
  | backup (index : Nat)
  | install (index : Nat)
  | restore (index : Nat)
  deriving BEq, Repr, ToJson

private def injectedMessage (operation : Operation) : String :=
  s!"injected worker publication failure: {reprStr operation}"

private def backupOperation (artifacts : Array Artifact) (source destination : FilePath) :
    IO Operation := do
  for (artifact, index) in artifacts.toList.zipIdx do
    if source == target artifact && destination == backup artifact then return .backup index
  throw <| IO.userError "unexpected hard-link operation in publication fixture"

private def renameOperation (artifacts : Array Artifact) (source destination : FilePath) :
    IO Operation := do
  for (artifact, index) in artifacts.toList.zipIdx do
    if destination == target artifact then
      if source == staged artifact then return .install index
      if source == backup artifact then return .restore index
  throw <| IO.userError "unexpected rename operation in publication fixture"

private def oldContents : Array (Option String) :=
  #[some "old 0", none, some "old 2", some "old 3"]

private def noBackups : Array (Option String) := #[none, none, none, none]

private inductive Failure where
  | none
  | operations (faults : Array Operation)
  | hashDirectory (index : Nat)

private structure Case where
  name : String
  failure : Failure := .none
  requiredCompleted : Array Operation
  expectedTargets : Array (Option String) := oldContents
  expectedBackups : Array (Option String) := noBackups
  expectedRollback : Array Operation := #[]
  noCompletedInstalls : Bool := false
  noCompletedRestores : Bool := false

private def contents? (path : FilePath) : IO (Option String) := do
  if ← path.pathExists then return some (← IO.FS.readFile path)
  pure none

private def runCase (base : FilePath) (test : Case) : IO Unit := do
  let root := base / test.name
  IO.FS.createDirAll root
  let artifacts := (List.range 4).toArray.map fun index =>
    (savePrivate% Beam.LSP.Save.StagedArtifact.mk)
      (root / s!"staged-{index}") (root / s!"target-{index}") (root / s!"backup-{index}")
  for (artifact, index) in artifacts.toList.zipIdx do
    IO.FS.writeFile (staged artifact) s!"new {index}"
    if let some old := oldContents[index]! then IO.FS.writeFile (target artifact) old
  let hashObstruction? := match test.failure with
    | .hashDirectory index => some ((root / s!"target-{index}").addExtension "hash")
    | _ => none
  if let .hashDirectory barrierIndex := test.failure then
    for (artifact, index) in artifacts.toList.zipIdx do
      if index < barrierIndex then
        IO.FS.writeFile ((target artifact).addExtension "hash") s!"cached hash {index}"
    if let some path := hashObstruction? then IO.FS.createDir path
  let faults := match test.failure with
    | .operations faults => faults
    | _ => #[]

  let completed ← IO.mkRef (#[] : Array Operation)
  let hits ← IO.mkRef (#[] : Array Operation)
  let perform := fun operation (action : IO Unit) => do
    if faults.contains operation then
      hits.modify (·.push operation)
      -- Fail before the syscall. A successful real mutation is always recorded as completed.
      throw <| IO.userError (injectedMessage operation)
    action
    completed.modify (·.push operation)
  let hardLink := fun source destination => do
    perform (← backupOperation artifacts source destination) (IO.FS.hardLink source destination)
  let rename := fun source destination => do
    perform (← renameOperation artifacts source destination) (IO.FS.rename source destination)
  let outcome ← (do
    try
      (savePrivate% Beam.LSP.Save.publishStagedArtifacts) artifacts hardLink rename
    finally
      -- Match the worker's staging cleanup, including when rollback itself fails.
      (savePrivate% Beam.LSP.Save.cleanupStagedArtifacts) artifacts).toBaseIO

  let completed ← completed.get
  let hits ← hits.get
  let actualTargets ← artifacts.mapM (fun artifact => contents? (target artifact))
  let actualBackups ← artifacts.mapM (fun artifact => contents? (backup artifact))
  let remainingStaging ← artifacts.mapM (fun artifact => (staged artifact).pathExists)
  let remainingHashes ← artifacts.mapM (fun artifact =>
    ((target artifact).addExtension "hash").pathExists)
  let hashObstructionRemains ← match hashObstruction? with
    | some path => path.isDir
    | none => pure false
  let error? := match outcome with
    | .ok _ => none
    | .error error => some error.toString
  -- Keep actual filesystem evidence before assertions; --keep retains it for RED/GREEN audits.
  let report := Json.mkObj [
    ("case", toJson test.name), ("targets", toJson actualTargets),
    ("backups", toJson actualBackups), ("remainingStaging", toJson remainingStaging),
    ("completed", toJson completed), ("faultsHit", toJson hits),
    ("remainingHashes", toJson remainingHashes),
    ("hashObstructionRemains", toJson hashObstructionRemains),
    ("error", toJson error?)
  ]
  IO.FS.writeFile (root / "result.json") (report.pretty ++ "\n")
  IO.println report.compress

  require s!"{test.name}: intended fault was not reached" (hits == faults)
  for operation in test.requiredCompleted do
    require s!"{test.name}: missing completed prefix {reprStr operation}"
      (completed.contains operation)
  match test.failure with
  | .none =>
      match outcome with
      | .ok _ => pure ()
      | .error error => throw error
  | .operations faults =>
      match outcome with
      | .ok _ => throw <| IO.userError s!"{test.name}: publication unexpectedly succeeded"
      | .error (.userError message) =>
          for operation in faults do
            require s!"{test.name}: lost failure diagnostic for {reprStr operation}"
              (message.contains (injectedMessage operation))
      | .error error => throw error
  | .hashDirectory barrierIndex =>
      require s!"{test.name}: hash obstruction changed" hashObstructionRemains
      for index in [:barrierIndex] do
        require s!"{test.name}: preceding hash {index} was not invalidated" (!remainingHashes[index]!)
      match outcome with
      | .ok _ => throw <| IO.userError s!"{test.name}: publication ignored the hash obstruction"
      | .error (.userError message) =>
          throw <| IO.userError s!"{test.name}: expected a filesystem error, got: {message}"
      | .error (.noFileOrDirectory ..) =>
          throw <| IO.userError s!"{test.name}: existing hash directory reported absent"
      | .error _ => pure ()
  for index in [:artifacts.size] do
    require s!"{test.name}: target {index} expected {reprStr (test.expectedTargets[index]!)}, got {reprStr (actualTargets[index]!)}"
      (actualTargets[index]! == test.expectedTargets[index]!)
    require s!"{test.name}: incorrect recovery backup {index}"
      (actualBackups[index]! == test.expectedBackups[index]!)
  require s!"{test.name}: worker staging cleanup left files" (remainingStaging.all (fun remains => !remains))
  for operation in test.expectedRollback do
    require s!"{test.name}: rollback did not continue through {reprStr operation}"
      (completed.contains operation)
  if test.noCompletedInstalls then
    require s!"{test.name}: failure unexpectedly installed an output" <|
      !completed.any fun operation => match operation with
        | .install _ => true
        | _ => false
  if test.noCompletedRestores then
    require s!"{test.name}: backup preparation failure attempted canonical recovery" <|
      !completed.any fun operation => match operation with
        | .restore _ => true
        | _ => false
  IO.println s!"worker publication: {test.name} passed"

private def run (base : FilePath) : IO Unit := do
  -- Start with a genuine partial replacement, so the old journal must fail on restored bytes.
  runCase base {
    name := "partial-install", failure := .operations #[.install 3]
    requiredCompleted := #[.backup 0, .backup 2, .backup 3, .install 0, .install 1, .install 2]
    expectedRollback := #[.restore 3, .restore 2, .restore 0]
  }
  runCase base {
    name := "partial-backup", failure := .operations #[.backup 2]
    requiredCompleted := #[.backup 0], noCompletedInstalls := true, noCompletedRestores := true
  }
  runCase base {
    name := "before-first-install", failure := .operations #[.install 0]
    requiredCompleted := #[.backup 0, .backup 2, .backup 3], noCompletedInstalls := true
    expectedRollback := #[.restore 3, .restore 2, .restore 0]
  }
  runCase base {
    name := "failed-restore", failure := .operations #[.install 3, .restore 2]
    requiredCompleted := #[.backup 0, .backup 2, .backup 3, .install 0, .install 1, .install 2]
    expectedTargets := #[some "old 0", none, some "new 2", some "old 3"]
    expectedBackups := #[none, none, some "old 2", none]
    expectedRollback := #[.restore 0]
  }
  runCase base {
    name := "success"
    requiredCompleted := #[.backup 0, .backup 2, .backup 3,
      .install 0, .install 1, .install 2, .install 3]
    expectedTargets := #[some "new 0", some "new 1", some "new 2", some "new 3"]
  }
  runCase base {
    -- Obstruct the last hash: even after earlier invalidations, no output may be replaced.
    name := "hash-removal", failure := .hashDirectory 3
    requiredCompleted := #[.backup 0, .backup 2, .backup 3], noCompletedInstalls := true
    expectedRollback := #[.restore 3, .restore 2, .restore 0]
  }
  BeamTest.TransactionTest.run

/-- Non-shipped real-filesystem regression for the worker's private publication algorithm. -/
def main (args : List String) : IO Unit := do
  match args with
  | [] => IO.FS.withTempDir run
  | ["--keep", path] =>
      let root := FilePath.mk path
      require "publication fixture retention path already exists" (!(← root.pathExists))
      IO.FS.createDirAll root
      run root
  | _ => throw <| IO.userError "usage: beam-save-publication-test [--keep NEW-DIRECTORY]"

end BeamTest.LSP.SavePublicationTest
