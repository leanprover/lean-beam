/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Broker.Protocol
import Beam.Broker.Transport

open Lean

namespace Beam.Daemon

def startupReadySchemaVersion : Nat :=
  1

def maxStartupReadyBytes : Nat :=
  16 * 1024

/-- One typed message emitted after a wrapper daemon has bound its OS-assigned listener. -/
structure StartupReady where
  schemaVersion : Nat
  port : Nat
  identity : Beam.Broker.DaemonIdentity
  deriving FromJson, ToJson

def StartupReady.ofEndpoint
    (endpoint : Beam.Broker.Transport.Endpoint)
    (identity : Beam.Broker.DaemonIdentity) : StartupReady :=
  match endpoint with
  | .tcp port => { schemaVersion := startupReadySchemaVersion, port := port.toNat, identity }

def StartupReady.encodeLine (ready : StartupReady) : String :=
  (toJson ready).compress

def StartupReady.decodeLine
    (expectedIdentity : Beam.Broker.DaemonIdentity)
    (line : String) : Except String Beam.Broker.Transport.Endpoint := do
  let json ← Json.parse line
  let ready ← fromJson? (α := StartupReady) json
  unless ready.schemaVersion == startupReadySchemaVersion do
    throw s!"unsupported Beam daemon readiness schema {ready.schemaVersion}"
  unless ready.identity == expectedIdentity do
    throw "Beam daemon readiness identity does not match the spawned generation"
  unless ready.port > 0 && ready.port < UInt16.size do
    throw s!"Beam daemon readiness port {ready.port} is outside 1-65535"
  pure <| .tcp ready.port.toUInt16

def StartupReady.readLineWith (read : USize → IO ByteArray) : IO String := do
  let mut bytes := ByteArray.empty
  repeat
    if bytes.size >= maxStartupReadyBytes then
      throw <| IO.userError s!"Beam daemon readiness exceeds {maxStartupReadyBytes} bytes"
    let chunk ← read 1
    if chunk.isEmpty then
      throw <| IO.userError "Beam daemon closed its readiness pipe before reporting readiness"
    if chunk[0]! == '\n'.toUInt8 then
      break
    bytes := bytes ++ chunk
  let some line := String.fromUTF8? bytes
    | throw <| IO.userError "Beam daemon readiness is not valid UTF-8"
  pure line

def StartupReady.readLine (source : IO.FS.Handle) : IO String := readLineWith source.read

end Beam.Daemon
