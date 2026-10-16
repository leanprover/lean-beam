/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Path

namespace BeamTest.PathBoundaryTest

private def separator := String.singleton System.FilePath.pathSeparator

private def filesystemRoot : System.FilePath :=
  if System.Platform.isWindows then "C:\\" else "/"

-- FilePath.join inserts a separator even at a filesystem root. Keep these fixtures canonical.
private def rooted (name : String) : System.FilePath :=
  System.FilePath.mk (filesystemRoot.toString ++ name)

private def projectRoot := rooted "beam-root"
private def childPath := projectRoot / "src" / "Main.lean"
private def siblingPath := rooted "beam-root-other" / "Main.lean"
private def outsidePath := rooted "other-root" / "Main.lean"

-- Exact roots, descendants, and paths outside the directory boundary.
#guard Beam.pathRelativeToRoot? projectRoot projectRoot == some "."
#guard Beam.pathRelativeToRootOrSelf projectRoot projectRoot == "."

#guard Beam.pathRelativeToRoot? projectRoot childPath == some ("src" ++ separator ++ "Main.lean")
#guard Beam.pathRelativeToRootOrSelf projectRoot childPath == "src" ++ separator ++ "Main.lean"

#guard Beam.pathRelativeToRoot? projectRoot siblingPath == none
#guard Beam.pathRelativeToRootOrSelf projectRoot siblingPath == siblingPath.toString

#guard Beam.pathRelativeToRoot? projectRoot outsidePath == none
#guard Beam.pathRelativeToRootOrSelf projectRoot outsidePath == outsidePath.toString

-- A filesystem root already has its boundary separator; it must not become `//` or `C:\\`.
#guard Beam.pathRelativeToRoot? filesystemRoot filesystemRoot == some "."

#guard Beam.pathRelativeToRoot? filesystemRoot (rooted "Main.lean") == some "Main.lean"

#guard Beam.leanModuleNameForPath? filesystemRoot
  (rooted "Foo" / "Bar.lean") == some "Foo.Bar"

private def trailingRoot := System.FilePath.mk (projectRoot.toString ++ separator)

#guard Beam.pathRelativeToRoot? trailingRoot (projectRoot / "Main.lean") == some "Main.lean"
#guard Beam.pathRelativeToRoot? trailingRoot siblingPath == none

-- Relative and rooted module names share the same native separator handling.
#guard Beam.leanModuleNameFromRelPath? "Main.lean" == some "Main"
#guard Beam.leanModuleNameFromRelPath? ("Foo" ++ separator ++ "Bar" ++ separator ++ "Baz.lean") ==
  some "Foo.Bar.Baz"
#guard Beam.leanModuleNameFromRelPath? ("Foo" ++ separator ++ "Bar.txt") == none
#guard Beam.leanModuleNameForPath? projectRoot (projectRoot / "Foo" / "Bar.lean") == some "Foo.Bar"
#guard Beam.leanModuleNameForPath? projectRoot (projectRoot / "Foo" / "Bar.txt") == none
#guard Beam.leanModuleNameForPath? projectRoot outsidePath == none

-- Dropping the root prefix must count Unicode characters consistently with path splitting.
private def unicodeRoot := rooted "données λ"
#guard Beam.pathRelativeToRoot? unicodeRoot (unicodeRoot / "Málaga.lean") == some "Málaga.lean"
#guard Beam.leanModuleNameForPath? unicodeRoot (unicodeRoot / "Málaga.lean") == some "Málaga"

end BeamTest.PathBoundaryTest
