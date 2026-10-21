/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.System
import BeamTest.PathBoundaryTest

private def require (condition : Bool) (message : String) : IO Unit :=
  unless condition do throw <| IO.userError message

private def rejected (action : IO α) (message : String) : IO Unit := do
  let failed ← try action *> pure false catch _ => pure true
  require failed message

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
  require (!(← Beam.pathIsLink missing)) "an absent leaf became a link"
  require ((← Beam.observePrivateDir missing) == .absent) "an absent leaf became another observation"
  require (← Beam.pathIsLink (root / "link")) "a directory link was not observed"
  require ((← Beam.observePrivateDir (root / "link")) == .symlink) "directory observation followed a link"
  require ((← Beam.observePrivateDir (root / "file")) == .notDirectory) "ordinary file became a directory"
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
