/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Broker.LakeHelper
import Beam.System
import Beam.Transaction
import Std.Sync.Mutex

open Lean System

namespace Beam.Broker.Publication

private inductive Phase where
  | preparing | ready | committing | committed | abandoned
  deriving BEq

private structure Artifact where
  candidate : FilePath
  target : FilePath
  backup : FilePath

/-- One broker-owned publication attempt. Producers receive only `outputs`, never this authority. -/
structure Plan where
  private mk ::
  outputs : LeanSaveOutputs
  private artifacts : Array Artifact
  private directories : Array FilePath
  private claims : Array FilePath
  private phase : Std.Mutex Phase
  private retain : IO.Ref Bool

private def mapOutputs (outputs : LeanSaveOutputs) (f : FilePath → IO FilePath) : IO LeanSaveOutputs := do
  pure {
    oleanPath := ← f outputs.oleanPath
    oleanServerPath? := ← outputs.oleanServerPath?.mapM f
    oleanPrivatePath? := ← outputs.oleanPrivatePath?.mapM f
    ileanPath := ← f outputs.ileanPath
    irPath? := ← outputs.irPath?.mapM f
    irSigPath? := ← outputs.irSigPath?.mapM f
    cPath := ← f outputs.cPath
    bcPath? := ← outputs.bcPath?.mapM f
    -- Trace is always the last canonical member installed.
    tracePath := ← f outputs.tracePath
  }

private def removeOwned (directories claims : Array FilePath) : IO Unit := do
  for directory in directories do
    try IO.FS.removeDirAll directory catch _ => pure ()
  for claim in claims do
    try IO.FS.removeFile claim catch _ => pure ()

/-- Private sibling directories preserve rename locality, including nonstandard Lake output roots.
Exclusive claims are retained with abandoned attempts: a late producer's paths are never reused. -/
def create (canonical : LeanSaveOutputs) : IO Plan := do
  let pid ← IO.Process.getPID
  let stamp ← IO.monoNanosNow
  let artifacts ← IO.mkRef (#[] : Array Artifact)
  let directories ← IO.mkRef (#[] : Array FilePath)
  let claims ← IO.mkRef (#[] : Array FilePath)
  try
    let outputs ← mapOutputs canonical fun target => do
      let prior ← artifacts.get
      if prior.any (·.target == target) then
        throw <| IO.userError s!"duplicate save publication target: {target}"
      let parent := target.parent.getD "."
      IO.FS.createDirAll parent
      let directory := parent / s!".beam-publication-{pid}-{stamp}-{prior.size}"
      let claim := FilePath.mk (directory.toString ++ ".claim")
      IO.FS.withFile claim .writeNew fun _ => pure ()
      claims.modify (·.push claim)
      unless (← Beam.observePrivateDir directory) == .absent do
        throw <| IO.userError s!"save publication directory already exists: {directory}"
      Beam.requirePrivateDir "save publication directory" directory
        (← Beam.preparePrivateDirLeaf directory)
      directories.modify (·.push directory)
      let some name := target.fileName
        | throw <| IO.userError s!"save publication target has no file name: {target}"
      let candidate := directory / name
      artifacts.modify (·.push { candidate, target, backup := FilePath.mk (candidate.toString ++ ".previous") })
      pure candidate
    pure {
      outputs, artifacts := ← artifacts.get, directories := ← directories.get,
      claims := ← claims.get, phase := ← Std.Mutex.new .preparing, retain := ← IO.mkRef false
    }
  catch error =>
    removeOwned (← directories.get) (← claims.get)
    throw error

/-- Only completed worker and trace preparation may make the still-live attempt publishable. -/
def Plan.ready (plan : Plan) : IO Unit := plan.phase.atomically do
  unless (← get) == .preparing do
    throw <| IO.userError "save publication plan is no longer preparing"
  set (Phase.ready)

/-- Abandonment never grants authority. Unsettled producers, failed rollback, and failed cleanup
after commit retain their paths. -/
def Plan.dispose (plan : Plan) (producersSettled : Bool) : IO Unit := do
  let removable ← plan.phase.atomically do
    let phase ← get
    if phase == .committing then return false
    unless phase == .committed do set (Phase.abandoned)
    pure producersSettled
  if removable && !(← plan.retain.get) then
    removeOwned plan.directories plan.claims

namespace Internal

/-- The publication algorithm with its filesystem effects explicit for tests.
Metadata, ownership, and disposal still use the real filesystem. -/
def promote (plan : Plan)
    (rename : FilePath → FilePath → IO Unit) (removeFile : FilePath → IO Unit)
    (hardLink : FilePath → FilePath → IO Unit := IO.FS.hardLink) : IO Unit := do
  for artifact in plan.artifacts do
    unless (← artifact.candidate.symlinkMetadata).type == .file do
      throw <| IO.userError s!"save candidate is not a regular file: {artifact.candidate}"
    if ← artifact.target.isDir then
      throw <| IO.userError s!"save publication target is a directory: {artifact.target}"
  let some trace := plan.artifacts.back?
    | throw <| IO.userError "empty save publication plan"
  let originals ← plan.artifacts.mapM fun artifact => do
    let existed ← match ← artifact.target.symlinkMetadata.toBaseIO with
      | .ok _ => pure true
      | .error (.noFileOrDirectory ..) => pure false
      | .error error => throw error
    pure (artifact, existed)
  let backups := originals.filterMap fun (artifact, existed) =>
    if existed then some artifact else none
  let restore := originals.filter (fun (artifact, _) => artifact.target != trace.target)
  let removeIfPresent := fun path => do
    try removeFile path
    catch
      | .noFileOrDirectory .. => pure ()
      | error => throw error
  plan.phase.atomically do
    unless (← get) == .ready do
      throw <| IO.userError "save publication plan has no promotion authority"
    set (Phase.committing)
  -- Before this phase completes, recovery owns backup names only. A missing backup never
  -- authorizes deleting an original output while preparation is incomplete.
  let preparation ← Beam.Transaction.run
      (rollback := backups.map fun artifact => removeIfPresent artifact.backup) do
    for artifact in backups do hardLink artifact.target artifact.backup
  match preparation with
  | .committed () _ => pure ()
  | .aborted error failures =>
      if !failures.isEmpty then plan.retain.set true
      plan.phase.atomically (set (Phase.abandoned))
      if failures.isEmpty then throw error
      let details := failures.toList.map fun failure =>
        let path := match backups[failure.actionIndex]? with
          | some artifact => artifact.backup.toString
          | none => s!"step {failure.actionIndex}"
        s!"backup cleanup {path}: {failure.error}"
      throw <| IO.userError s!"save backup preparation failed: {error}; cleanup failed: {String.intercalate "; " details}"

  -- Recovery is defined over the complete beforeimages, not a journal of successful renames.
  -- The runner reverses this array, so trace invalidation is attempted before every restoration.
  let rollback := (restore.map fun (artifact, existed) => do
    if existed then
      rename artifact.backup artifact.target
      -- A same-inode rename can leave the backup name intact. Never unlink it before restoration.
      removeIfPresent artifact.backup
    else
      removeIfPresent artifact.target).push (removeIfPresent trace.target)
  let publication ← Beam.Transaction.run
      (rollback := rollback)
      (cleanup := backups.map fun artifact => removeIfPresent artifact.backup) do
    -- Canonical commit boundary. The old trace must be absent before invalidating Lake's
    -- output hash caches, and every mapped cache must be invalidated before any artifact changes.
    removeIfPresent trace.target
    for artifact in plan.artifacts do
      if artifact.target == trace.target then continue
      removeIfPresent (artifact.target.addExtension "hash")
    for artifact in plan.artifacts do
      rename artifact.candidate artifact.target
    plan.phase.atomically (set (Phase.committed))
  match publication with
  | .committed () failures =>
      -- Keep a committed checkpoint successful. Retain failed-cleanup evidence instead of
      -- allowing disposal to erase it; the committed phase distinguishes this from rollback.
      if !failures.isEmpty then plan.retain.set true
  | .aborted error failures =>
      if !failures.isEmpty then plan.retain.set true
      plan.phase.atomically (set (Phase.abandoned))
      if failures.isEmpty then throw error
      let details := failures.toList.map fun failure =>
        let label := match restore[failure.actionIndex]? with
          | some (artifact, _) => s!"recover {artifact.target}"
          | none => s!"trace invalidation {trace.target}"
        s!"{label}: {failure.error}"
      throw <| IO.userError s!"save publication failed: {error}; rollback failed: {String.intercalate "; " details}"

end Internal

/-- The broker calls this under publication ownership and its final basis/cancellation guard.
There are no cancellation checks after the canonical mutation boundary. -/
def Plan.promote (plan : Plan) : IO Unit :=
  Internal.promote plan IO.FS.rename IO.FS.removeFile

end Beam.Broker.Publication
