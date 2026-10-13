/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Data.Lsp.Extra
import Lean.Server.References
import Lean.Server.Requests
import Beam.LSP.Save

open Lean
open Lean.Server
open Lean.Server.RequestM

namespace Beam.LSP.DiagnosticsBarrier

/--
Internal Beam diagnostics barrier. This mirrors Lean's `textDocument/waitForDiagnostics`, but
returns small Beam-owned metadata from the accepted document snapshot.
-/
def method : String := "$/beam/waitForDiagnostics"

structure Result where
  version : Nat
  elaborationComplete : Bool
  directImports : Array String := #[]
  saveReadiness : Save.SaveReadinessResult
  deriving FromJson, ToJson

private def importsOfHeader (header : Lean.Elab.HeaderSyntax) : Array String :=
  (Lean.Server.collectImports header).foldl (init := #[]) fun acc info =>
    if acc.contains info.module then
      acc
    else
      acc.push info.module

partial def waitForDocumentVersion (version : Nat) : RequestM Lean.Server.FileWorker.EditableDocument := do
  let doc ← readDoc
  if version ≤ doc.meta.version then
    return doc
  else
    IO.sleep 50
    waitForDocumentVersion version

def resultOfDocument
    (doc : Lean.Server.FileWorker.EditableDocument)
    (saveReadiness : Save.SaveReadinessResult) : Result := {
  version := doc.meta.version
  elaborationComplete := !(Lean.Language.toSnapshotTree doc.initSnap).getAll.any (·.isFatal)
  directImports := importsOfHeader ⟨doc.initSnap.stx⟩
  saveReadiness
}

def handle (p : Lean.Lsp.WaitForDiagnosticsParams) : RequestM (RequestTask Result) := do
  let t ← RequestM.asTask <| waitForDocumentVersion p.version
  RequestM.bindTaskCheap t fun doc? => do
    let doc ← liftExcept doc?
    -- Match `textDocument/waitForDiagnostics`: wait on both the reporter and `cmdSnaps` so
    -- request handlers using `IO.hasFinished` on `doc.cmdSnaps` have completed.
    let t := doc.reporter.bindCheap (fun _ => doc.cmdSnaps.waitAll)
    RequestM.mapTaskCostly t fun _ => do
      let (saveReadiness, _, _, _) ← Save.collectSaveReadiness doc
      pure <| resultOfDocument doc saveReadiness

end Beam.LSP.DiagnosticsBarrier
