/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.JsonFields
import Beam.Path
import Beam.Broker.Client
import Beam.Broker.Transport

open Lean

namespace Beam.Daemon

open Beam.Broker

def registrySchemaVersion : Nat :=
  5

inductive RegistryLifecycle where
  | live
  | draining
  deriving BEq, Repr

instance : ToJson RegistryLifecycle where
  toJson
    | .live => "live"
    | .draining => "draining"

instance : FromJson RegistryLifecycle where
  fromJson?
    | .str "live" => .ok .live
    | .str "draining" => .ok .draining
    | json => .error s!"expected registry lifecycle 'live' or 'draining', got {json.compress}"

local instance : ToJson UInt16 where
  toJson port := toJson port.toNat

local instance : FromJson UInt16 where
  fromJson? json := do
    let port ← fromJson? (α := Nat) json
    if port < UInt16.size then
      pure port.toUInt16
    else
      throw s!"expected TCP port below {UInt16.size}, got {port}"

/-- One statically configured workspace owned by a CLI session. -/
structure WorkspaceBinding where
  workspaceId : WorkspaceId
  root : String
  leanCmd : String
  plugin : String
  toolchain : String
  bundleId : String
  deriving ToJson, BEq

instance : FromJson WorkspaceBinding where
  fromJson? json := do
    Beam.requireOnlyJsonFields "session workspace"
      #["workspaceId", "root", "leanCmd", "plugin", "toolchain", "bundleId"] json
    pure {
      workspaceId := ← Beam.requiredField json "workspaceId"
      root := ← Beam.requiredField json "root"
      leanCmd := ← Beam.requiredField json "leanCmd"
      plugin := ← Beam.requiredField json "plugin"
      toolchain := ← Beam.requiredField json "toolchain"
      bundleId := ← Beam.requiredField json "bundleId"
    }

/--
The private descriptor for one wrapper-owned CLI session.

Wrapper sessions deliberately own exactly one workspace. Standalone broker and MCP runtimes retain
their independent multi-workspace models.
-/
structure SessionDescriptor where
  schemaVersion : Nat
  lifecycle : RegistryLifecycle
  daemonId : String
  capability : String
  pid : Nat
  ownerPid : Nat
  port : UInt16
  workspace : WorkspaceBinding
  /-- Hash of the complete frozen session configuration. -/
  configHash : String
  daemonBin : String
  /-- Canonical owning root retained from the admitted runtime, independent of component layout. -/
  installationRoot : String
  startedAt : String
  deriving ToJson, BEq

instance : FromJson SessionDescriptor where
  fromJson? json := do
    Beam.requireOnlyJsonFields "session descriptor" #[
      "schemaVersion", "lifecycle", "daemonId", "capability", "pid", "ownerPid", "port",
      "workspace", "configHash", "daemonBin", "installationRoot", "startedAt"
    ] json
    pure {
      schemaVersion := ← Beam.requiredField json "schemaVersion"
      lifecycle := ← Beam.requiredField json "lifecycle"
      daemonId := ← Beam.requiredField json "daemonId"
      capability := ← Beam.requiredField json "capability"
      pid := ← Beam.requiredField json "pid"
      ownerPid := ← Beam.requiredField json "ownerPid"
      port := ← Beam.requiredField json "port"
      workspace := ← Beam.requiredField json "workspace"
      configHash := ← Beam.requiredField json "configHash"
      daemonBin := ← Beam.requiredField json "daemonBin"
      installationRoot := ← Beam.requiredField json "installationRoot"
      startedAt := ← Beam.requiredField json "startedAt"
    }

def SessionDescriptor.identity (entry : SessionDescriptor) : DaemonIdentity := {
  daemonId := entry.daemonId
  configHash := entry.configHash
}

def SessionDescriptor.redactedJson (entry : SessionDescriptor) : Json :=
  (toJson entry).setObjVal! "capability" (toJson "<redacted>")

/-- Whether this single-workspace descriptor belongs to a canonical or equivalent project root. -/
def SessionDescriptor.matchesRoot
    (entry : SessionDescriptor)
    (root : System.FilePath) : IO Bool := do
  Beam.sameFilePath (System.FilePath.mk entry.workspace.root) root

def registryEndpoint (entry : SessionDescriptor) : Transport.Endpoint :=
  .tcp entry.port

def endpointSummary (endpoint : Transport.Endpoint) : String :=
  Transport.endpointDescription endpoint

private structure DaemonProbe where
  root : String
  identity : DaemonIdentity

private def daemonProbeRequestTimeoutMs : Nat :=
  2000

private def daemonProbeOfResponse (resp : Response) : Except BrokerClientFailure DaemonProbe :=
  match resp with
  | .errorResult _ =>
      .error <| .invalidResponse s!"Beam daemon stats probe failed: {(toJson resp).compress}"
  | .successResult result _ => do
    let root ←
      match result.getObjValAs? String "root" with
      | .ok root => pure root
      | .error err => throw <| .invalidResponse s!"invalid Beam daemon stats root: {err}"
    let identity ←
      match result.getObjValAs? DaemonIdentity "daemonIdentity" with
      | .ok identity => pure identity
      | .error err =>
          throw <| .invalidResponse s!"invalid Beam daemon identity: {err}"
    pure { root, identity }

private def daemonProbe
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (server : ServerExpectation)
    (capability? : Option String := none) : IO (Except BrokerClientFailure DaemonProbe) := do
  match ← sendRequestWithStreamTimeoutResult endpoint
      { Request.stats with workspaceId? := some workspaceId, daemonCapability? := capability? }
      daemonProbeRequestTimeoutMs (fun _ => pure ())
      server with
  | .ok resp => pure <| daemonProbeOfResponse resp
  | .error failure => pure <| .error failure

inductive DaemonGenerationStatus where
  | probeFailed (failure : BrokerClientFailure)
  | wrongRoot (daemonRoot : String)
  | wrongGeneration (daemonRoot : String)
  | exact
  deriving Repr

private def daemonGenerationStatusUsing
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity)
    (capability? : Option String)
    (server : ServerExpectation) : IO DaemonGenerationStatus := do
  match ← daemonProbe endpoint workspaceId server capability? with
  | .error failure => pure <| .probeFailed failure
  | .ok probe =>
      unless ← Beam.sameFilePath (System.FilePath.mk probe.root) root do
        return .wrongRoot probe.root
      if probe.identity == identity then
        pure .exact
      else
        pure <| .wrongGeneration probe.root

/-- Classify one wrapper endpoint after proving its expected generation on the same connection. -/
def daemonGenerationStatus
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity)
    (capability : String) : IO DaemonGenerationStatus := do
  daemonGenerationStatusUsing endpoint workspaceId root identity (some capability) (.wrapper identity)

/-- Classify an internal standalone broker, which deliberately has no wrapper greeting. -/
def standaloneDaemonGenerationStatus
    (endpoint : Transport.Endpoint)
    (workspaceId : WorkspaceId)
    (root : System.FilePath)
    (identity : DaemonIdentity) : IO DaemonGenerationStatus := do
  daemonGenerationStatusUsing endpoint workspaceId root identity none .standalone

end Beam.Daemon
