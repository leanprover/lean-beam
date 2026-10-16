/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

namespace Beam

/-- Return whether `path` itself is a regular file, without following symbolic links. -/
def regularNonSymlinkFile (path : System.FilePath) : IO Bool := do
  try
    let metadata ← path.symlinkMetadata
    pure (metadata.type == IO.FS.FileType.file)
  catch _ =>
    pure false

/-- Resolve a path that must already exist. -/
def resolveExistingPath (path : System.FilePath) : IO System.FilePath :=
  IO.FS.realPath path

/--
Resolve the existing prefix of `path`, then append its missing suffix.

This gives a path selected before creation the same canonical spelling it will have afterward. In
particular, aliases in an existing ancestor such as macOS `/tmp` are resolved even when the selected
leaf does not exist yet.
-/
partial def resolvePathForCreation (path : System.FilePath) : IO System.FilePath := do
  try
    resolveExistingPath path
  catch
  | .noFileOrDirectory .. =>
      let some parent := path.parent
        | throw <| IO.userError s!"cannot resolve a creation parent for '{path}'"
      let some name := path.fileName
        | throw <| IO.userError s!"cannot resolve a creation leaf for '{path}'"
      -- Resolve before normalizing: lexical normalization would give the wrong meaning to `..`
      -- after an existing symbolic-link ancestor. Normalize only the rebuilt canonical path.
      pure <| ((← resolvePathForCreation parent) / name).normalize
  | err => throw err

/-- Resolve `path`, interpreting relative paths under an already-resolved `root`. -/
def resolvePathAgainstRoot (root path : System.FilePath) : IO System.FilePath :=
  resolveExistingPath <| if path.isAbsolute then path else root / path

/--
Compare two filesystem paths after resolving their canonical spelling.

If either path cannot be resolved, fall back to exact path text equality so callers keep deterministic
behavior for missing paths while handling platform aliases such as macOS `/tmp` and `/private/tmp`
for existing roots.
-/
def sameFilePath (a b : System.FilePath) : IO Bool := do
  try
    pure ((← resolveExistingPath a).toString == (← resolveExistingPath b).toString)
  catch _ =>
    pure (a.toString == b.toString)

/--
Return `path` relative to `root` when the path is exactly the root or is under the root directory.

This is a pure string-level boundary check. Callers that need platform alias or symlink handling
should resolve both paths first with `resolveExistingPath` / `resolvePathAgainstRoot`.
-/
def pathRelativeToRoot? (root path : System.FilePath) : Option String := do
  let rootStr := root.toString
  let pathStr := path.toString
  let separator := String.singleton System.FilePath.pathSeparator
  -- Filesystem roots already end in a separator (for example `/` or `C:\`).
  let rootPrefix := if rootStr.endsWith separator then rootStr else rootStr ++ separator
  if pathStr == rootStr then
    some "."
  else if pathStr.startsWith rootPrefix then
    some <| (pathStr.drop rootPrefix.length).toString
  else
    none

/--
Return `path` relative to `root` when possible, otherwise return the original path spelling.
-/
def pathRelativeToRootOrSelf (root path : System.FilePath) : String :=
  (pathRelativeToRoot? root path).getD path.toString

/--
Return a file URI relative to `root` when possible, otherwise return the original URI spelling.
-/
def pathRelativeToRootOrUri (root : System.FilePath) (uri : Lean.Lsp.DocumentUri) : String :=
  match System.Uri.fileUriToPath? uri with
  | some path => (pathRelativeToRoot? root path).getD uri
  | none => uri

/--
Convert a workspace-relative Lean source path such as `Foo/Bar.lean` to its module name.
-/
def leanModuleNameFromRelPath? (relPath : String) : Option String := do
  guard (relPath.endsWith ".lean")
  let relFile := System.FilePath.mk relPath
  let stem ← relFile.fileStem
  let parts := relFile.components.dropLast
  some <| String.intercalate "." (parts ++ [stem])

/--
Return the Lean module name for `path` when it is a `.lean` file under `root`.
-/
def leanModuleNameForPath? (root path : System.FilePath) : Option String := do
  let relPath ← pathRelativeToRoot? root path
  leanModuleNameFromRelPath? relPath

end Beam
