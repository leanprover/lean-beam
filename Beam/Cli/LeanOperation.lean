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
    (path : String)
    (version : Nat)
    (line character : Nat)
    (text : String)
    (storeHandle : Bool := false)
    (profile : Bool := false) : Request :=
  ({ path, version, line, character, text, profile? := if profile then some true else none } : Beam.Lean.RunAtInput).toBrokerRequest
    (storeHandle := storeHandle)

def leanRunWithRequest
    (path : String)
    (handle : Handle)
    (text : String)
    (linear : Bool := false)
    (profile : Bool := false) : Request :=
  ({ path, handle, text, profile? := if profile then some true else none } : Beam.Lean.RunWithInput).toBrokerRequest
    (linear := linear)

def leanReleaseRequest (path : String) (handle : Handle) : Request :=
  ({ path, handle } : Beam.Lean.ReleaseInput).toBrokerRequest

def leanHoverRequest
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toHoverBrokerRequest

def leanSignatureHelpRequest
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toSignatureHelpBrokerRequest

def leanDefinitionRequest
    (path : String)
    (version : Nat)
    (line character : Nat) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toDefinitionBrokerRequest

def leanReferencesRequest
    (path : String)
    (version : Nat)
    (line character : Nat)
    (includeDeclaration : Bool := true) : Request :=
  ({
    path
    version
    line
    character
    includeDeclaration? := some includeDeclaration
  } : Beam.Lean.ReferencesInput).toBrokerRequest

def leanDocumentSymbolsRequest
    (path : String)
    (version : Nat) : Request :=
  ({ path, version } : Beam.Lean.DocumentSymbolsInput).toBrokerRequest

def leanWorkspaceSymbolsRequest
    (query : String) : Request :=
  ({ query } : Beam.Lean.WorkspaceSymbolsInput).toBrokerRequest

def leanGoalsRequest
    (path : String)
    (version : Nat)
    (line character : Nat)
    (mode : GoalMode) : Request :=
  ({ path, version, line, character } : Beam.Lean.PositionInput).toGoalsBrokerRequest mode

def leanTodoRequest
    (path : String)
    (version : Nat)
    (startLine startCharacter endLine endCharacter : Nat)
    (kinds? : Option (Array Beam.LSP.Todo.TodoKind))
    (suggest? : Option Beam.LSP.Todo.TodoSuggestMode) : Request :=
  ({
    path
    version
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
