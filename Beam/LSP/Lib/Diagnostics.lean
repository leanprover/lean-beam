/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling

open Lean

/-
Worker diagnostics shared by `Beam.LSP.Todo` and `Beam.LSP.Save`.
-/
namespace Beam.LSP.Lib

/--
Whether a Lean diagnostic belongs on ordinary user-facing surfaces.

Lean uses silent diagnostics for editor-only lifecycle and presentation data such as
`goalsAccomplished`, internal Grind state, and documentation-example output. They are not regular
diagnostics even when their severity is `information`.
-/
def isUserVisibleDiagnostic (diagnostic : Lean.Lsp.DiagnosticWith α) : Bool :=
  diagnostic.isSilent? != some true

def userVisibleDiagnostics (diagnostics : Array (Lean.Lsp.DiagnosticWith α)) :
    Array (Lean.Lsp.DiagnosticWith α) :=
  diagnostics.filter isUserVisibleDiagnostic

def collectCurrentDiagnostics (doc : Lean.Server.FileWorker.EditableDocument) :
    BaseIO (Array Lean.Widget.InteractiveDiagnostic) := do
  let diagnostics ← doc.toEditableDocumentCore.collectCurrentDiagnostics
  pure diagnostics.toArray

end Beam.LSP.Lib
