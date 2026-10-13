/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Errors
import Beam.Broker.Protocol
import Beam.Broker.StaleDirectDeps
import Beam.Broker.SyncSaveSupport

open Lean
open Lean.Lsp

namespace Beam.Broker

/--
Pure interpretation of the diagnostics/progress barrier used by `sync`, `save`, and `close-save`.

This deliberately does not mean arbitrary Lean operations are semantically ready. It only names the
specific broker contract for operations that wait for a diagnostics/save barrier.
-/
structure SyncBarrierDecision where
  fileProgress? : Option SyncFileProgress := none
  incomplete : Bool := false
  message? : Option String := none
  deriving Inhabited

def decideSyncBarrier
    (uri : DocumentUri)
    (version : Nat)
    (priorProgress? : Option SyncFileProgress)
    (progress? : Option SyncFileProgress)
    (elaborationComplete : Bool)
    (diagnostics : Array Diagnostic) : SyncBarrierDecision :=
  -- Lean sends its final progress notification asynchronously. The completed snapshot returned
  -- by our barrier is authoritative; a delayed busy notification must not reject a valid sync.
  let progress := (effectiveSyncBarrierProgress priorProgress? progress? diagnostics).getD {}
  let fileProgress? := some { progress with
    done := elaborationComplete && !diagnosticsIndicateIncompleteBarrier diagnostics }
  let incomplete := syncBarrierIncomplete? fileProgress? diagnostics
  {
    fileProgress?
    incomplete
    message? :=
      if incomplete then
        some <| syncBarrierIncompleteMessage uri version fileProgress?
      else
        none
  }

def syncBarrierIncompleteFailure
    (uri : DocumentUri)
    (version : Nat)
    (targetPath : String)
    (hints : Array StaleDirectDepHint)
    (diagnostics : Array Diagnostic)
    (fileProgress? : Option SyncFileProgress) : ResponseFailure :=
  (responseFailureFor
    .syncBarrierIncomplete
    (syncBarrierIncompleteMessage uri version fileProgress?)
    (some <| staleSyncErrorData targetPath hints (completionBlockingDiagnostics diagnostics)))
  |>.withOptionalFileProgress fileProgress?

def syncFileSuccessResponse
    (result : SyncFileResult)
    (fileProgress? : Option SyncFileProgress)
    : Response :=
  Response.withOptionalFileProgress
    (Response.success <| toJson result)
    fileProgress?

def syncResultErrorData (syncResult : SyncFileResult) : Json :=
  Json.mkObj [("sync", toJson syncResult)]

end Beam.Broker
