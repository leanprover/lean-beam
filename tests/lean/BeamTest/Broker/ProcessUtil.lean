/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path
import Beam.Broker.Client
import Beam.Broker.Protocol
import Beam.Broker.Transport
import BeamTest.Broker.ClientUtil
import BeamTest.TestHarness

namespace BeamTest.Broker.TestUtil

abbrev nullBrokerStdio : IO.Process.StdioConfig where
  stdin := .null
  stdout := .null
  stderr := .null

def daemonExe : IO System.FilePath := do
  pure <| (← IO.appPath).parent.getD (System.FilePath.mk ".") / "beam-daemon"

private def testPortBase : Nat :=
  49152

private def testPortSpan : Nat :=
  UInt16.size - testPortBase

private def testPortStride : Nat :=
  7919

private def testPortCandidate (seed attempt : Nat) : UInt16 :=
  (testPortBase + ((seed + attempt * testPortStride) % testPortSpan)).toUInt16

private def endpointAcceptsConnection (endpoint : Beam.Broker.Endpoint) : IO Bool := do
  try
    let conn ← Beam.Broker.Transport.connect endpoint
    Beam.Broker.Transport.closeConnection conn
    pure true
  catch _ =>
    pure false

/--
Pick a test TCP port that is not accepting connections right now.

This is still subject to the usual close-before-spawn race, but it avoids the timestamp-derived
ports colliding with long-running local Beam daemons.
-/
partial def freshTcpPort (tries : Nat := 200) : IO UInt16 := do
  let seed ← IO.monoNanosNow
  let rec loop (attempt remaining : Nat) : IO UInt16 := do
    if remaining == 0 then
      throw <| IO.userError s!"could not find an unused local TCP port after {tries} attempts"
    let port := testPortCandidate seed attempt
    let endpoint : Beam.Broker.Endpoint := .tcp port
    if ← endpointAcceptsConnection endpoint then
      loop (attempt + 1) (remaining - 1)
    else
      pure port
  loop 0 tries

def freshTcpEndpoint : IO Beam.Broker.Endpoint := do
  pure (.tcp (← freshTcpPort))

private structure ProcessInfo where
  pid : Nat
  ppid : Nat
  state : String
  cmd : String

private def isZombie (proc : ProcessInfo) : Bool :=
  proc.state.contains "Z"

private def listProcesses : IO (Array ProcessInfo) := do
  let out ← IO.Process.output {
    cmd := "ps"
    args := #["-eo", "pid=,ppid=,state=,args="]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to list processes\n{out.stderr}"
  let mut procs := #[]
  for rawLine in out.stdout.split (· == '\n') do
    let parts : List String :=
      (rawLine.trimAscii.toString.split (· == ' ') |>.filterMap fun part =>
        let part := part.trimAscii.toString
        if part.isEmpty then none else some part).toList
    match parts with
    | pidText :: ppidText :: stateText :: cmdParts =>
        match pidText.toNat?, ppidText.toNat? with
        | some pid, some ppid =>
            procs := procs.push {
              pid
              ppid
              state := stateText
              cmd := String.intercalate " " cmdParts
            }
        | _, _ =>
            pure ()
    | _ =>
        pure ()
  pure procs

private def requireUniquePid (label : String) (candidates : Array ProcessInfo) : IO Nat := do
  match candidates.toList with
  | [proc] =>
      pure proc.pid
  | [] =>
      throw <| IO.userError s!"expected one {label} process, found none"
  | _ =>
      throw <| IO.userError s!"expected one {label} process, found {candidates.size}"

private partial def waitForPidGone (pid : Nat) (tries : Nat := 40) : IO Unit := do
  if tries == 0 then
    throw <| IO.userError s!"timed out waiting for pid {pid} to exit"
  let procs ← listProcesses
  if procs.any (fun proc => proc.pid == pid && !isZombie proc) then
    IO.sleep 100
    waitForPidGone pid (tries - 1)
  else
    pure ()

def killLeanServerForEndpoint
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath) : IO Unit := do
  let port ←
    match endpoint with
    | .tcp port => pure port
  let procs ← listProcesses
  let brokerPid ← requireUniquePid "broker daemon" <| procs.filter fun proc =>
    proc.cmd.contains "beam-daemon" &&
      proc.cmd.contains s!"--port {port.toNat}" &&
      proc.cmd.contains s!"--root {root.toString}"
  let serverPid ← requireUniquePid "Lean server" <| procs.filter fun proc =>
    proc.ppid == brokerPid && proc.cmd.contains "--server"
  let out ← IO.Process.output {
    cmd := "kill"
    args := #["-9", toString serverPid]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to kill Lean server pid {serverPid}\n{out.stderr}"
  waitForPidGone serverPid

def spawnLeanBrokerWithPlugin
    (endpoint : Beam.Broker.Endpoint)
    (root leanPlugin : System.FilePath)
    (leanCmd : String := "lean")
    (identity? : Option Beam.Broker.DaemonIdentity := none) : IO (IO.Process.Child nullBrokerStdio) := do
  let port :=
    match endpoint with
    | .tcp port => port
  IO.Process.spawn {
    toStdioConfig := nullBrokerStdio
    cmd := (← daemonExe).toString
    args := #[
      "--port", toString port.toNat,
      "--root", root.toString,
      "--workspace-id", testWorkspaceId,
      "--lean-cmd", leanCmd,
      "--lean-plugin", leanPlugin.toString
    ] ++ match identity? with
      | some identity => #[
          "--daemon-id", identity.daemonId,
          "--config-hash", identity.configHash
        ]
      | none => #[]
    setsid := true
  }

def spawnLeanBroker
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (leanCmd : String := "lean")
    (identity? : Option Beam.Broker.DaemonIdentity := none) : IO (IO.Process.Child nullBrokerStdio) := do
  spawnLeanBrokerWithPlugin endpoint root (← BeamTest.TestHarness.pluginPath) leanCmd identity?

partial def waitForBrokerReady
    (endpoint : Beam.Broker.Endpoint)
    (tries : Nat := 50) : IO Unit := do
  try
    let conn ← Beam.Broker.Transport.connect endpoint
    Beam.Broker.Transport.closeConnection conn
  catch _ =>
    if tries == 0 then
      throw <| IO.userError s!"timed out waiting for Beam daemon at {Beam.Broker.Transport.endpointDescription endpoint}"
    IO.sleep 100
    waitForBrokerReady endpoint (tries - 1)

private def statsRoot? (resp : Beam.Broker.Response) : Option String := do
  let result ← resp.result?
  result.getObjValAs? String "root" |>.toOption

private def brokerRoot? (endpoint : Beam.Broker.Endpoint) : IO (Option String) := do
  try
    let result ← Beam.Broker.sendRequestWithCallbacksTimeoutResult endpoint {
      Beam.Broker.Request.stats with
      workspaceId? := some testWorkspaceId
    } testBrokerRequestTimeoutMs (server := .standalone)
    match result with
    | .ok resp =>
        if resp.ok then pure (statsRoot? resp) else pure none
    | .error _ => pure none
  catch _ =>
    pure none

partial def waitForBrokerReadyForRoot
    (endpoint : Beam.Broker.Endpoint)
    (root : System.FilePath)
    (tries : Nat := 50) : IO Unit := do
  match ← brokerRoot? endpoint with
  | some daemonRoot =>
      if ← Beam.sameFilePath (System.FilePath.mk daemonRoot) root then
        pure ()
      else
        throw <| IO.userError
          s!"test endpoint {Beam.Broker.Transport.endpointDescription endpoint} already serves Beam root {daemonRoot}, not {root}"
  | none =>
      if tries == 0 then
        throw <| IO.userError
          s!"timed out waiting for Beam daemon at {Beam.Broker.Transport.endpointDescription endpoint}"
      IO.sleep 100
      waitForBrokerReadyForRoot endpoint root (tries - 1)

end BeamTest.Broker.TestUtil
