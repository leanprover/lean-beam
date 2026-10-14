/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.Requests
import Beam.LSP.Lib.Goal
import Beam.LSP.Lib.Request

open Lean
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
Read-only proof-state inspection for Lean LSP positions.

This family owns `$/lean/goalsAfter` and `$/lean/goalsPrev`; it shares only the structured goal
projection with `RunAt` and `Todo`.
-/
namespace Beam.LSP.Goals

/-- JSON-RPC method name for read-only goal inspection after the position. -/
def afterMethod : String := "$/lean/goalsAfter"

/-- JSON-RPC method name for read-only goal inspection before the position. -/
def prevMethod : String := "$/lean/goalsPrev"

/-- Request payload for read-only goal inspection at a file position. -/
structure Params where
  textDocument : Lean.Lsp.VersionedTextDocumentIdentifier
  position : Lean.Lsp.Position
  deriving FromJson, ToJson

instance : Lean.Lsp.FileSource Params where
  fileSource p := p.textDocument.uri

def handle (p : Params) (useAfter : Bool) : RequestM (RequestTask ProofState) := do
  requireDocumentVersion p.textDocument
  validatePosition p.position
  checkRequestCancelled
  let proofTask ← findProofBasisAt p.position
  RequestM.bindRequestTaskCostly proofTask <| fun
    | some basis => do
        checkRequestCancelled
        return RequestTask.pure (← basisProofState basis useAfter)
    | none =>
        throw <| RequestError.invalidParams (noProofBasisFoundMessage p.position)

end Beam.LSP.Goals
