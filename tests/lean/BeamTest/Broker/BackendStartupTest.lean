/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.LakeEnv
import BeamTest.Broker.TestUtil
import Lean

open Lean

namespace BeamTest.Broker.BackendStartupTest

open BeamTest.Broker.TestUtil

private def checkWorkspaceFallbackEnv (root : System.FilePath) : IO Unit := do
  let invalidRoot := root / "invalid-workspace"
  IO.FS.createDirAll invalidRoot
  IO.FS.writeFile (invalidRoot / "lakefile.lean") "this is not a valid Lake configuration\n"
  let noConfigEnv ← Beam.Broker.leanServerLakeEnv root (some "lean")
  let invalidConfigEnv ← Beam.Broker.leanServerLakeEnv invalidRoot (some "lean")
  for serverEnv in #[noConfigEnv, invalidConfigEnv] do
    let some (_, some loaderPath) := serverEnv.env.find? (·.1 == Lake.sharedLibPathEnvVar)
      | throw <| IO.userError s!"expected backend environment variable {Lake.sharedLibPathEnvVar}"
    if loaderPath.isEmpty then
      throw <| IO.userError s!"expected nonempty backend environment variable {Lake.sharedLibPathEnvVar}"
  if noConfigEnv.env.any (·.1 == Lake.invalidConfigEnvVar) then
    throw <| IO.userError "plain Lean fallback unexpectedly marked Lake configuration invalid"
  unless invalidConfigEnv.env.any (·.1 == Lake.invalidConfigEnvVar) do
    throw <| IO.userError "invalid same-version Lake configuration should remain marked invalid"

private def fakeLeanInstallProbe :=
  "if [ \"${1:-}\" = \"--print-prefix\" ]; then exec lean --print-prefix; fi"

private def writeResponseErrorServer (root : System.FilePath) : IO System.FilePath := do
  let script := root / "fake-lean-startup-response-error.sh"
  let body := String.intercalate "\n" [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    fakeLeanInstallProbe,
    "printf '%s\\n' \"$$\" > \"$(dirname \"$0\")/fake-lean.pid\"",
    "frame() {",
    "  local body=\"$1\"",
    "  printf 'Content-Length: %s\\r\\n\\r\\n%s' \"${#body}\" \"$body\"",
    "}",
    "notif='{\"jsonrpc\":\"2.0\",\"method\":\"window/logMessage\",\"params\":{\"type\":4,\"message\":\"early startup message\"}}'",
    "err='{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32603,\"message\":\"initialize failed\"}}'",
    "frame \"$notif\"",
    "frame \"$err\"",
    "sleep 5"
  ] ++ "\n"
  IO.FS.writeFile script body
  let out ← IO.Process.output {
    cmd := "chmod"
    args := #["+x", script.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to chmod fake startup server\n{out.stderr}"
  pure script

private partial def waitForProcessGone (pid : Nat) (tries : Nat := 80) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "/bin/kill"
    args := #["-0", toString pid]
  }
  if out.exitCode != 0 then
    pure ()
  else if tries == 0 then
    throw <| IO.userError s!"failed provisional backend process {pid} remained alive"
  else
    IO.sleep 25
    waitForProcessGone pid (tries - 1)

private def writeAbruptExitServer (root : System.FilePath) : IO System.FilePath := do
  let script := root / "fake-lean-startup-abrupt-exit.sh"
  let body := String.intercalate "\n" [
    "#!/usr/bin/env bash",
    "set -euo pipefail",
    fakeLeanInstallProbe,
    "python3 -c 'import sys; sys.stderr.buffer.write(b\"stderr-prefix-start\\n\" + bytes([0xc3, 0xa9]) * 10000 + b\"\\nAstderr-tail-marker\\n\")'",
    "exit 23"
  ] ++ "\n"
  IO.FS.writeFile script body
  let out ← IO.Process.output {
    cmd := "chmod"
    args := #["+x", script.toString]
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to chmod abrupt-exit startup server\n{out.stderr}"
  pure script

private def checkStartupFailure
    (root fakeServer plugin : System.FilePath)
    (expected : String)
    (checkPidGone := false)
    (forbidden? : Option String := none)
    (maxMessageLength? : Option Nat := none) : IO Unit := do
  let endpoint ← freshTcpEndpoint
  let broker ← spawnLeanBrokerWithPlugin endpoint root plugin (some fakeServer.toString)
  try
    waitForBrokerReadyForRoot endpoint root
    let resp ← runClient endpoint Beam.Broker.Request.ensure
    if resp.ok then
      throw <| IO.userError s!"expected backend startup failure, got success {(toJson resp).compress}"
    let some err := resp.error?
      | throw <| IO.userError s!"expected backend startup error payload, got {(toJson resp).compress}"
    if err.code != "internalError" then
      throw <| IO.userError s!"expected internalError for startup failure, got {(toJson resp).compress}"
    unless err.message.contains "Lean backend failed during startup" do
      throw <| IO.userError s!"expected startup failure phase, got {(toJson resp).compress}"
    unless err.message.contains "backend stderr tail (last 16384 bytes):" do
      throw <| IO.userError s!"expected bounded stderr label, got {(toJson resp).compress}"
    unless err.message.contains expected do
      throw <| IO.userError s!"expected startup failure to mention '{expected}', got {(toJson resp).compress}"
    if let some forbidden := forbidden? then
      if err.message.contains forbidden then
        throw <| IO.userError s!"expected bounded startup failure to omit '{forbidden}', got {(toJson resp).compress}"
    if let some maxMessageLength := maxMessageLength? then
      if err.message.length > maxMessageLength then
        throw <| IO.userError
          s!"expected startup failure at most {maxMessageLength} characters, got {err.message.length}"
    if checkPidGone then
      let pidText ← IO.FS.readFile (root / "fake-lean.pid")
      let some pid := pidText.trimAscii.toString.toNat?
        | throw <| IO.userError s!"invalid fake backend pid '{pidText}'"
      waitForProcessGone pid
  finally
    try
      broker.kill
    catch _ =>
      pure ()
    discard <| broker.tryWait

def main : IO Unit := do
  let root ← mkTempProjectRoot "beam-daemon-startup"
  IO.FS.createDirAll root
  let plugin ← BeamTest.TestHarness.pluginPath
  try
    checkWorkspaceFallbackEnv root
    let responseErrorServer ← writeResponseErrorServer root
    checkStartupFailure root responseErrorServer plugin "initialize failed" (checkPidGone := true)
    let abruptExitServer ← writeAbruptExitServer root
    checkStartupFailure root abruptExitServer plugin "stderr-tail-marker"
      (forbidden? := some "stderr-prefix-start") (maxMessageLength? := some 17000)
  finally
    try
      IO.FS.removeDirAll root
    catch _ =>
      pure ()

end BeamTest.Broker.BackendStartupTest
