/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Lean.Operation

open Lean

namespace Beam.Cli

open Beam.Broker

def leanRunAtRequest
    (position : Beam.Lean.PositionInput)
    (text : String)
    (storeHandle : Bool := false) : Request :=
  ({ toPositionInput := position, text } : Beam.Lean.RunAtInput).toBrokerRequest
    (storeHandle := storeHandle)

def leanRunWithRequest
    (path : String)
    (handle : Handle)
    (text : String)
    (linear : Bool := false) : Request :=
  ({ path, handle, text } : Beam.Lean.RunWithInput).toBrokerRequest
    (linear := linear)

def leanReleaseRequest (path : String) (handle : Handle) : Request :=
  ({ path, handle } : Beam.Lean.ReleaseInput).toBrokerRequest

def leanHoverRequest (position : Beam.Lean.PositionInput) : Request :=
  position.toHoverBrokerRequest

def leanSignatureHelpRequest (position : Beam.Lean.PositionInput) : Request :=
  position.toSignatureHelpBrokerRequest

def leanDefinitionRequest (position : Beam.Lean.PositionInput) : Request :=
  position.toDefinitionBrokerRequest

def leanReferencesRequest
    (position : Beam.Lean.PositionInput)
    (includeDeclaration : Bool := true) : Request :=
  ({
    toPositionInput := position
    includeDeclaration? := some includeDeclaration
  } : Beam.Lean.ReferencesInput).toBrokerRequest

def leanDocumentSymbolsRequest (document : Beam.Lean.DocumentInput) : Request :=
  document.toDocumentSymbolsBrokerRequest

def leanWorkspaceSymbolsRequest
    (query : String) : Request :=
  ({ query } : Beam.Lean.WorkspaceSymbolsInput).toBrokerRequest

def leanGoalsRequest
    (position : Beam.Lean.PositionInput)
    (mode : GoalMode) : Request :=
  position.toGoalsBrokerRequest mode

def leanTodoRequest
    (path : String)
    (snapshot : SnapshotRef)
    (startLine startCharacter endLine endCharacter : Nat)
    (kinds? : Option (Array Beam.LSP.Todo.TodoKind))
    (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) : Request :=
  ({
    path
    snapshot
    startLine
    startCharacter
    endLine
    endCharacter
    kinds?
    suggest?
  } : Beam.Lean.TodoInput).toBrokerRequest

def leanCloseRequest (path : String) : Request :=
  ({ path } : Beam.Lean.PathInput).toCloseBrokerRequest

def leanUpdateRequest (path : String) : Request :=
  ({ path } : Beam.Lean.PathInput).toUpdateBrokerRequest

def leanSyncRequest
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SyncInput).toSyncBrokerRequest

def leanRefreshRequest
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SyncInput).toRefreshBrokerRequest

def leanSaveRequest
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SaveInput).toSaveBrokerRequest

def leanCloseSaveRequest
    (path : String)
    (diagnosticScope : DiagnosticScope) : Request :=
  ({ path, diagnosticScope? := some diagnosticScope } : Beam.Lean.SaveInput).toCloseSaveBrokerRequest

end Beam.Cli
