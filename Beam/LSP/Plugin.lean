/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Beam.LSP.DiagnosticsBarrier
import Beam.LSP.Goals
import Beam.LSP.ImportBasis
import Beam.LSP.RunAt
import Beam.LSP.Save
import Beam.LSP.Todo

open Lean
open Lean.Server

namespace Beam.LSP

/--
Root plugin module for Beam's Lean LSP extensions.

This module keeps request registration thin. Request implementations and wire types live with the
owning request families under `Beam.LSP.*`.
-/
initialize
  registerLspRequestHandler Beam.LSP.RunAt.method Beam.LSP.RunAt.Params Beam.LSP.RunAt.Result
    Beam.LSP.RunAt.handleRunAt
  registerLspRequestHandler Goals.afterMethod Goals.Params Lib.ProofState
    (fun p => Goals.handle p true)
  registerLspRequestHandler Goals.prevMethod Goals.Params Lib.ProofState
    (fun p => Goals.handle p false)
  registerLspRequestHandler Todo.method Todo.TodoParams Todo.TodoResult Todo.handleTodo
  registerLspRequestHandler Beam.LSP.RunAt.runWithMethod Beam.LSP.RunAt.RunWithParams
    Beam.LSP.RunAt.Result Beam.LSP.RunAt.handleRunWith
  registerLspRequestHandler Beam.LSP.RunAt.releaseHandleMethod Beam.LSP.RunAt.ReleaseHandleParams Json
    Beam.LSP.RunAt.handleReleaseHandle
  registerLspRequestHandler Save.saveArtifactsMethod
    Save.SaveArtifactsParams
    Save.SaveArtifactsCompletion
    Save.handleSaveArtifacts
  registerLspRequestHandler Save.saveReadinessMethod
    Save.SaveReadinessParams
    Save.SaveReadinessResult
    Save.handleSaveReadiness
  registerLspRequestHandler DiagnosticsBarrier.method
    Lean.Lsp.WaitForDiagnosticsParams
    DiagnosticsBarrier.Result
    DiagnosticsBarrier.handle
  registerLspRequestHandler ImportBasis.method
    ImportBasis.Params
    ImportBasis.Result
    ImportBasis.handle

end Beam.LSP
