/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Lean

open Lean

namespace BeamTest.Broker.RequestHandleTest

private def checkErrorCode
    (label expectedCode : String)
    (resp : Beam.Broker.Response) : IO Unit := do
  match resp.error? with
  | some err =>
      unless err.code == expectedCode do
        throw <| IO.userError s!"{label} returned {err.code}: {(toJson resp).compress}"
  | none =>
      throw <| IO.userError s!"{label} returned success: {(toJson resp).compress}"

private def checkCancelledResponse (resp : Beam.Broker.Response) : IO Unit :=
  checkErrorCode "cancelled broker request" "requestCancelled" resp

private def checkStaleHandleIsolation
    (server : Beam.Broker.ServerRuntime)
    (req : Beam.Broker.Request) : IO Unit := do
  let staleHandleRef ← IO.mkRef (none : Option Beam.Broker.RequestHandle)
  let completedResp ← server.dispatchRequestWithHandle req (fun handle => do
    staleHandleRef.set (some handle)
    unless ← handle.cancel do
      throw <| IO.userError "completed broker request handle was not cancellable"
    pure true)
  checkCancelledResponse completedResp
  let some staleHandle ← staleHandleRef.get
    | throw <| IO.userError "completed broker request handle was not captured"

  let staleCancelledRef ← IO.mkRef false
  let replacementCancelledRef ← IO.mkRef false
  let replacementResp ← server.dispatchRequestWithHandle req (fun replacement => do
    staleCancelledRef.set (← staleHandle.cancel)
    replacementCancelledRef.set (← replacement.cancel)
    pure true)
  if ← staleCancelledRef.get then
    throw <| IO.userError "stale broker request handle cancelled a replacement with the same ID"
  unless ← replacementCancelledRef.get do
    throw <| IO.userError "replacement broker request handle was not cancellable"
  checkCancelledResponse replacementResp

def checkCancellationAndLifetime : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-request-handle-{← IO.monoNanosNow}"
  IO.FS.createDirAll root
  let root ← Beam.resolveExistingPath root
  let workspaceId : Beam.Broker.WorkspaceId := "request-handle-workspace"
  let server ← Beam.Broker.ServerRuntime.create { root } workspaceId
  let req : Beam.Broker.Request := {
    payload := .runAt {
      path := "Cancelled.lean"
      snapshot := ⟨"test-session", 1⟩
      line := 0
      character := 0
      text := "exact trivial"
    }
    workspaceId? := some workspaceId
    clientRequestId? := some "request-handle-cancel"
  }
  let runOnce : IO Unit := do
    let handleRef ← IO.mkRef (none : Option Beam.Broker.RequestHandle)
    let resp ← server.dispatchRequestWithHandle req (fun handle => do
      handleRef.set (some handle)
      unless ← handle.cancel do
        throw <| IO.userError "new broker request handle was not cancellable"
      pure true)
    checkCancelledResponse resp
    let some handle ← handleRef.get
      | throw <| IO.userError "broker request handle was not captured"
    if ← handle.cancel then
      throw <| IO.userError "broker request handle remained active after its dispatch scope"
  try
    runOnce
    -- Reusing the ID proves that the lexical dispatch scope unregisters the first handle.
    runOnce
    checkStaleHandleIsolation server req

    let anonymousHandleRef ← IO.mkRef (none : Option Beam.Broker.RequestHandle)
    let anonymousResp ← server.dispatchRequestWithHandle
      { req with clientRequestId? := none } (fun handle => do
        anonymousHandleRef.set (some handle)
        unless ← handle.cancel do
          throw <| IO.userError "anonymous broker request handle was not cancellable"
        pure true)
    checkCancelledResponse anonymousResp
    let some anonymousHandle ← anonymousHandleRef.get
      | throw <| IO.userError "anonymous broker request handle was not captured"
    if ← anonymousHandle.cancel then
      throw <| IO.userError "anonymous broker request handle remained active after dispatch"

    let rejectedHandleRef ← IO.mkRef (none : Option Beam.Broker.RequestHandle)
    let rejectedResp ← server.dispatchRequestWithHandle req (fun handle => do
      rejectedHandleRef.set (some handle)
      pure false)
    checkCancelledResponse rejectedResp
    let some rejectedHandle ← rejectedHandleRef.get
      | throw <| IO.userError "rejected broker request handle was not captured"
    if ← rejectedHandle.cancel then
      throw <| IO.userError "rejected broker request handle remained active after its dispatch scope"
    runOnce

    let failedHandleRef ← IO.mkRef (none : Option Beam.Broker.RequestHandle)
    let failedResp ← server.dispatchRequestWithHandle req (fun handle => do
      failedHandleRef.set (some handle)
      throw <| IO.userError "before-dispatch test failure")
    checkErrorCode "failed before-dispatch callback" "internalError" failedResp
    let some failedHandle ← failedHandleRef.get
      | throw <| IO.userError "failed before-dispatch callback handle was not captured"
    if ← failedHandle.cancel then
      throw <| IO.userError "failed before-dispatch callback handle remained active after its dispatch scope"
    runOnce

    let callbackInvoked ← IO.mkRef false
    let invalidReq := {
      Beam.Broker.Request.listWorkspaces with
      workspaceId? := some workspaceId
    }
    let invalidResp ← server.dispatchRequestWithHandle invalidReq (fun _ => do
      callbackInvoked.set true
      pure true)
    checkErrorCode "invalid request before admission" "invalidParams" invalidResp
    if ← callbackInvoked.get then
      throw <| IO.userError "invalid request invoked the before-dispatch callback"

    callbackInvoked.set false
    let mismatchedHandle : Beam.Broker.Handle := {
      workspaceId := "another-workspace"
      backend := .lean
      epoch := 1
      session := "session"
      raw := Json.null
    }
    let mismatchedHandleReq : Beam.Broker.Request := {
      payload := .runWith {
        path := "Cancelled.lean"
        text := "exact trivial"
        handle := mismatchedHandle
      }
      workspaceId? := some workspaceId
    }
    let mismatchedHandleResp ← server.dispatchRequestWithHandle mismatchedHandleReq (fun _ => do
      callbackInvoked.set true
      pure true)
    checkErrorCode "mismatched handle workspace before admission" "invalidParams" mismatchedHandleResp
    if ← callbackInvoked.get then
      throw <| IO.userError "mismatched handle workspace invoked the before-dispatch callback"
  finally
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

#eval checkCancellationAndLifetime

end BeamTest.Broker.RequestHandleTest
