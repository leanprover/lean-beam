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

-- A filesystem root already has its boundary separator; it must not become `//` or `C:\\`.
#guard Beam.pathRelativeToRoot? filesystemRoot filesystemRoot == some "."

#guard Beam.pathRelativeToRoot? filesystemRoot
  (System.FilePath.mk (filesystemRoot.toString ++ "Main.lean")) == some "Main.lean"

#guard Beam.leanModuleNameForPath? filesystemRoot
  (System.FilePath.mk (filesystemRoot.toString ++ "Foo" ++ separator ++ "Bar.lean")) ==
    some "Foo.Bar"

private def projectRoot := filesystemRoot.toString ++ "beam-root" ++ separator

#guard Beam.pathRelativeToRoot? (System.FilePath.mk projectRoot)
  (System.FilePath.mk (projectRoot ++ "Main.lean")) == some "Main.lean"

#guard Beam.pathRelativeToRoot? (System.FilePath.mk projectRoot)
  (System.FilePath.mk (filesystemRoot.toString ++ "beam-root-other" ++ separator ++ "Main.lean")) == none

end BeamTest.PathBoundaryTest
