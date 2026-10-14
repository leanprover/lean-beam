/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lake.Util.NativeLib
import Init.System.Platform

namespace Beam.Runtime

/-- Lean/Lake's shared-library dependency closure, including the split-library stubs. -/
def sharedLibNames : List String :=
  ["Init_shared", "leanshared_1", "leanshared_2", "leanshared", "Lake_shared"].map
    fun name => Lake.nameToSharedLib name true

/-- Windows loads DLLs beside the executable; Unix uses the executable's relative runtime libdir. -/
def buildSharedLibDir (buildDir : System.FilePath) : System.FilePath :=
  buildDir / if System.Platform.isWindows then "bin" else "lib/lean"

def installedSharedLibDir : String :=
  if System.Platform.isWindows then "libexec" else "lib/lean"

end Beam.Runtime
