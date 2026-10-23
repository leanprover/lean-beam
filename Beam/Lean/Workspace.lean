/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.Project
import Beam.Workspace

open Lean

namespace Beam.Lean.Workspace

/-- Resolve roots supplied by API clients. These must already be absolute. -/
def resolveRoot (rootText : String) : IO (Except Beam.Workspace.RootError System.FilePath) := do
  let rootPath := System.FilePath.mk rootText
  if !rootPath.isAbsolute then
    return .error { message := s!"workspace root must be an absolute path: {rootText}" }
  try
    let root ← Beam.resolveExistingPath rootPath
    let metadata ← root.metadata
    if metadata.type != .dir then
      pure <| .error { message := s!"workspace root is not a directory: {root}" }
    else if !(← Beam.Project.hasLeanProject root) then
      pure <| .error {
        message := s!"workspace root is not a Lean/Lake project: expected lean-toolchain, lakefile.toml, or lakefile.lean in {root}"
      }
    else
      pure <| .ok root
  catch
  | .noFileOrDirectory .. =>
    pure <| .error { message := s!"workspace root is missing or inaccessible: {rootPath}" }
  | .permissionDenied .. =>
    pure <| .error { message := s!"permission denied while resolving workspace root: {rootPath}" }
  | error =>
    pure <| .error { message := s!"cannot resolve workspace root {rootPath}: {error}" }

/-- Resolve roots supplied through local CLI flags, where relative paths are current-directory based. -/
def resolveCliRoot (rootText : String) : IO (Except Beam.Workspace.RootError System.FilePath) := do
  let rootPath := System.FilePath.mk rootText
  let rootPath ←
    if rootPath.isAbsolute then
      pure rootPath
    else
      pure <| (← IO.currentDir) / rootPath
  resolveRoot rootPath.toString

end Beam.Lean.Workspace
