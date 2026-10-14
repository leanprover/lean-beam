/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Protocol
import Beam.LSP.Lib.NativeLib
import BeamTest.Broker.TestUtil
import Lean

open Lean

namespace BeamTest.Broker.SmokeTest

open BeamTest.Broker.TestUtil

def repoRoot : IO System.FilePath := do
  IO.FS.realPath <| System.FilePath.mk "."

def ensurePluginSharedBuilt (root : System.FilePath) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "lake"
    args := #["build", "Beam.LSP:shared"]
    cwd := root.toString
  }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to build Beam.LSP:shared for smoke test\n{out.stderr}"

def pluginPath : IO System.FilePath := do
  let root ← repoRoot
  ensurePluginSharedBuilt root
  IO.FS.realPath <| Beam.LSP.Lib.pluginSharedLibPath (root / ".lake" / "build" / "lib")

def expectStringContains (label haystack needle : String) : IO Unit := do
  unless haystack.contains needle do
    throw <| IO.userError s!"expected {label} to contain '{needle}', got '{haystack}'"

def requireErrorMessage (label : String) (resp : Beam.Broker.Response) : IO String := do
  match resp.error? with
  | some err => pure err.message
  | none => throw <| IO.userError s!"expected {label} to contain an error payload"

def expectClientRequestId (label : String) (actual expected : Option String) : IO Unit := do
  unless actual == expected do
    throw <| IO.userError s!"expected {label} clientRequestId {expected}, got {actual}"

def expectProgressIds
    (label : String)
    (events : Array ProgressEvent)
    (expected : Option String) : IO Unit := do
  for event in events do
    expectClientRequestId label event.clientRequestId? expected

def awaitTask (label : String) (task : Task (Except IO.Error α)) : IO α := do
  match (← IO.wait task) with
  | .ok value => pure value
  | .error err => throw <| IO.userError s!"{label} failed: {err}"

def writeStandaloneErrorFile (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-daemon-error-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "ErrorOnly.lean"
  IO.FS.writeFile path "def brokenVal : Nat := \"broken\"\n"
  pure path

def writeSlowSyncFile (root : System.FilePath) : IO System.FilePath := do
  let dir := root / ".tmp" / s!"beam-daemon-slow-sync-{← IO.monoNanosNow}"
  IO.FS.createDirAll dir
  let path := dir / "SlowSync.lean"
  IO.FS.writeFile path <| String.intercalate "\n" [
    "import Lean",
    "",
    "open Lean Elab Command",
    "",
    "elab \"progress_sleep_cmd\" : command => do",
    "  IO.sleep 1500",
    "",
    "def partialProgressAnchor : Nat := 0",
    "",
    "progress_sleep_cmd",
    "",
    "def partialProgressDone : Nat := partialProgressAnchor + 1",
    ""
  ]
  pure path

end BeamTest.Broker.SmokeTest
