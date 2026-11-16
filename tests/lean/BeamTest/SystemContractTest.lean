/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.System
import Beam.Cli.Args
import Beam.Daemon.Registry
import Beam.Installation.LocalTarget
import Beam.Install.Construction
import Beam.Broker.Publication
import BeamTest.PathBoundaryTest

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def rejected (action : IO α) (message : String) : IO Unit := do
  let failed ← try action *> pure false catch _ => pure true
  require failed message

/-- Admission must fail before removing the old trace, invalidating hashes, or copying a link target. -/
private def rejectedPublication (root : System.FilePath) (leaf : String) : IO Unit := do
  let canonical : Beam.Broker.LeanSaveOutputs := {
    oleanPath := root / leaf, ileanPath := root / s!"{leaf}.ilean",
    cPath := root / s!"{leaf}.c", tracePath := root / s!"{leaf}.trace"
  }
  let stable := #[canonical.ileanPath, canonical.cPath, canonical.tracePath,
    canonical.oleanPath.addExtension "hash", canonical.ileanPath.addExtension "hash",
    canonical.cPath.addExtension "hash"]
  for path in stable do IO.FS.writeFile path "prior bytes"
  let before ← Beam.observeEntry canonical.oleanPath
  let plan ← Beam.Broker.Publication.create canonical
  try
    for path in #[plan.outputs.oleanPath, plan.outputs.ileanPath,
        plan.outputs.cPath, plan.outputs.tracePath] do
      IO.FS.writeFile path "candidate bytes"
    plan.ready
    rejected plan.promote s!"publication admitted a non-file target: {leaf}"
    require ((← Beam.observeEntry canonical.oleanPath) == before)
      "rejected publication changed the target entry"
    for path in stable do
      require ((← IO.FS.readFile path) == "prior bytes") "rejection changed an artifact, trace, or hash"
    require ((← IO.FS.readFile (root / "file")) == "ordinary file")
      "rejection modified a linked file's target"
  finally
    plan.dispose true

/-- POSIX beforeimages retain a non-directory leaf itself, including dangling links and FIFOs. -/
private def posixPublicationBeforeimage (root : System.FilePath) (leaf : String) : IO Unit := do
  let canonical : Beam.Broker.LeanSaveOutputs := {
    oleanPath := root / leaf, ileanPath := root / s!"{leaf}.ilean",
    cPath := root / s!"{leaf}.c", tracePath := root / s!"{leaf}.trace"
  }
  for path in #[canonical.ileanPath, canonical.cPath, canonical.tracePath] do
    IO.FS.writeFile path "prior bytes"
  let before ← Beam.observeEntry canonical.oleanPath
  let plan ← Beam.Broker.Publication.create canonical
  try
    for path in #[plan.outputs.oleanPath, plan.outputs.ileanPath,
        plan.outputs.cPath, plan.outputs.tracePath] do IO.FS.writeFile path "candidate bytes"
    plan.ready
    let rename := fun source target => do
      if source == plan.outputs.cPath then throw <| IO.userError "controlled publication failure"
      IO.FS.rename source target
    rejected (Beam.Broker.Publication.Internal.promote plan rename IO.FS.removeFile)
      "controlled publication failure did not occur"
    require ((← Beam.observeEntry canonical.oleanPath) == before) "rollback lost the original leaf kind"
    require ((← IO.FS.readFile canonical.ileanPath) == "prior bytes") "rollback lost an earlier output"
    require (!(← canonical.tracePath.pathExists)) "rollback restored the old trace"
    require ((← IO.FS.readFile (root / "file")) == "ordinary file") "publication followed the old link"
    require (!(← (root / "missing-file").pathExists)) "publication created a dangling link's target"
  finally
    plan.dispose true

private def concurrentCreation (root : System.FilePath) : IO Unit := do
  for round in [:16] do
    let path := root / s!"concurrent-{round}"
    let tasks ← (List.range 8).mapM fun _ =>
      IO.asTask (prio := Task.Priority.dedicated) <| Beam.preparePrivateDir path
    for task in tasks do
      let observation ← IO.ofExcept (← IO.wait task)
      require (observation == .privateDir) s!"concurrent creator observed a non-private leaf: {repr observation}"

private def inspect (root : System.FilePath) : IO Unit := do
  let missing := root / "absent"
  require ((← Beam.observeEntry missing) == .absent) "missing leaf was not absent"
  require ((← Beam.observeEntry (root / "absent-parent/child")) == .absent)
    "missing ancestors were not absent"
  require ((← Beam.observeEntry (root / "file")) == .file) "ordinary file was not recognized"
  require ((← Beam.observeEntry (root / "target")) == .directory) "directory was not recognized"
  match ← Beam.Daemon.readRegistryAt missing with
  | .absent => pure ()
  | _ => throw <| IO.userError "missing registry did not remain absent"
  let missingMutation ← (Beam.Daemon.requireRegularRegistryLeaf missing).toBaseIO
  match missingMutation with
  | .error (.noFileOrDirectory ..) => pure ()
  | _ => throw <| IO.userError "missing registry mutation lost its typed absence error"
  for path in [root / "target", root / "absent-session"] do
    let parsed ← (Beam.Cli.parseCliOptions {} ["--session-dir", path.toString, "status"]).run
    match parsed with
    | .ok _ => pure ()
    | .error _ => throw <| IO.userError "session selection rejected a real or absent directory"
  for invalidRoot in [root / "absent-parent", root / "file"] do
    match ← Beam.Installation.LocalTarget.resolve invalidRoot none with
    | .error (.io _) => pure ()
    | _ => throw <| IO.userError "missing or unusable selector root authorized fallback"
  for name in ["file-link", "dangling-file"] do
    require ((← Beam.observeEntry (root / name)) == .symlink)
      "file-link observation followed its target"
  for name in ["link", "dangling"] do
    let expected := if System.Platform.isWindows then .junction else .symlink
    require ((← Beam.observeEntry (root / name)) == expected)
      "directory-link observation lost the leaf kind"
  require (← Beam.regularNonSymlinkFile (root / "file")) "ordinary file was rejected"
  for name in ["absent", "target", "file-link", "dangling-file", "link", "dangling"] do
    require (!(← Beam.regularNonSymlinkFile (root / name)))
      s!"non-file entry was admitted as a regular file: {name}"
  for name in ["file-link", "dangling-file", "link", "dangling"] do
    match ← Beam.Daemon.readRegistryAt (root / name) with
    | .invalid (.unsafeLeaf _) => pure ()
    | _ => throw <| IO.userError s!"registry admission followed a link: {name}"
    rejected (Beam.Daemon.requireRegularRegistryLeaf (root / name))
      "registry mutation admitted a linked leaf"
    let parsed ← (Beam.Cli.parseCliOptions {} ["--session-dir", (root / name).toString, "status"]).run
    match parsed with
    | .error _ => pure ()
    | .ok _ => throw <| IO.userError s!"session selection followed a link: {name}"
    if System.Platform.isWindows || name == "link" then rejectedPublication root name
    if !System.Platform.isWindows && (name == "file-link" || name == "dangling-file") then
      posixPublicationBeforeimage root name
  if !System.Platform.isWindows then
    require ((← Beam.observeEntry (root / "fifo")) == .other) "FIFO became a regular file"
    require (!(← Beam.regularNonSymlinkFile (root / "fifo"))) "FIFO was admitted as a file"
    posixPublicationBeforeimage root "fifo"
  require (!(← Beam.pathIsLink missing)) "an absent leaf became a link"
  require ((← Beam.observePrivateDir missing) == .absent) "an absent leaf became another observation"
  require (← Beam.pathIsLink (root / "link")) "a directory link was not observed"
  require ((← Beam.observePrivateDir (root / "link")) == .symlink) "directory observation followed a link"
  require ((← Beam.observePrivateDir (root / "file")) == .notDirectory) "ordinary file became a directory"
  let ordinary ← Beam.fileExecuteBits (root / "file")
  let executable ← Beam.fileExecuteBits (root / "executable")
  if System.Platform.isWindows then
    require (ordinary.isNone && executable.isNone)
      "Windows execution rights were inferred from POSIX mode bits"
  else
    require (ordinary == some false && executable == some true)
      "POSIX execute-bit observation did not distinguish the two regular files"
  let dangling := root / "dangling"
  require (← Beam.pathIsLink dangling) "a dangling link became absent"
  require ((← Beam.observePrivateDir dangling) == .symlink) "a dangling link became absent"
  for path in [root / "link", dangling, root / "file"] do
    let before ← Beam.observePrivateDir path
    require ((← Beam.preparePrivateDir path) == before) "preparation altered an existing leaf"
    require ((← Beam.preparePrivateDirLeaf path) == before) "leaf creation altered an existing leaf"
  let unobservable := root / (if System.Platform.isWindows then "invalid<leaf" else "blocked/child")
  for path in [unobservable,
      System.FilePath.mk ((root / "link").toString ++ String.singleton (Char.ofNat 0))] do
    rejected (Beam.observeEntry path) "entry observation hid a filesystem or invalid-path error"
    try
      Beam.Install.Construction.stageOutput path (root / "unused-staging-output")
      throw <| IO.userError "staging accepted an unobservable input"
    catch
    | .userError _ => throw <| IO.userError "staging erased an input observation error"
    | _ => pure ()
    require (!(← (root / "unused-staging-output").pathExists))
      "rejected staging created an output"
    require (!(← Beam.regularNonSymlinkFile path)) "predicate admitted an observation failure"
    rejected (Beam.pathIsLink path) "link observation hid a filesystem or invalid-path error"
    rejected (Beam.observePrivateDir path) "directory observation hid a filesystem or invalid-path error"
    rejected (Beam.preparePrivateDirLeaf path) "leaf creation hid a filesystem or invalid-path error"
  if !System.Platform.isWindows then
    rejected (Beam.pathIsLink (root / "file/child")) "a non-directory ancestor became absent"
    rejected (Beam.observePrivateDir (root / "file/child")) "a non-directory ancestor became absent"
  let privatePath := root / "private"
  require ((← Beam.preparePrivateDir privatePath) == .privateDir) "private directory creation failed"
  require ((← Beam.preparePrivateDir privatePath) == .privateDir) "existing private directory changed"
  let nonPrivate := root / "non-private"
  let before ← Beam.observePrivateDir nonPrivate
  let expected := if System.Platform.isWindows then .nonPrivate .windowsDacl
    else .nonPrivate (.posixMode 493) -- 0755
  require (before == expected) s!"fixture lost its permission failure: {repr before}"
  require ((← Beam.preparePrivateDir nonPrivate) == before) "preparation adopted or repaired an existing directory"
  require ((← Beam.preparePrivateDirLeaf nonPrivate) == before)
    "leaf creation adopted or repaired an existing directory"
  let missingParent := root / "missing-parent"
  rejected (Beam.preparePrivateDirLeaf (missingParent / "child")) "leaf creation accepted a missing parent"
  require (!(← missingParent.pathExists)) "leaf creation recreated a missing parent"
  if System.Platform.isWindows then
    match ← Beam.observePrivateDir (root / "owner-denied") with
    | .nonPrivate .windowsDacl => pure ()
    | result => throw <| IO.userError s!"a deny ACE was treated as full owner access: {repr result}"

private def foreignOwner (directory : System.FilePath) : IO Unit := do
  let expected := Beam.PrivateDirObservation.nonPrivate .posixOwner
  let observed ← Beam.observePrivateDir directory
  require (observed == expected) s!"foreign ownership was not rejected distinctly: {repr observed}"
  require ((← Beam.preparePrivateDir directory) == expected) "preparation adopted a foreign directory"
  let diagnostic ← try
    Beam.ensurePrivateDir "test directory" directory
    pure ""
  catch error => pure error.toString
  require (diagnostic.contains s!"unsafe test directory {directory}:" &&
      diagnostic.contains "not owned by the current effective user" &&
      diagnostic.contains "Select a dedicated directory")
    s!"foreign-owner rejection lost its path, cause, or recovery advice: {diagnostic}"

def main (args : List String) : IO Unit := do
  let [operation, directory] := args | throw <| IO.userError "expected OPERATION DIRECTORY"
  let root := System.FilePath.mk directory
  match operation with
  | "create-race" => concurrentCreation root
  | "inspect" => inspect root
  | "foreign-owner" => foreignOwner root
  | _ => throw <| IO.userError "unknown system-contract operation"
  IO.println s!"system contract {operation} passed"
