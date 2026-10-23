/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Broker.LakeHelperMain
import BeamTest.TestHarness
import BeamTest.Broker.SaveOwnerTest
import BeamTest.Broker.PrivatePublicationTest
import BeamTest.Broker.WorkerRecoveryTest

private structure Fixture where
  command : String := "lean"
  plugin? : Option System.FilePath := none
  configHash : String := "fixture"
  args : List String := []

private def extract (fixture : Fixture) : List String → Except String Fixture
  | [] => pure fixture
  | "--lean-cmd" :: command :: rest => extract { fixture with command } rest
  | "--lean-plugin" :: plugin :: rest => extract { fixture with plugin? := some plugin } rest
  | "--config-hash" :: value :: rest =>
      extract { fixture with configHash := value, args := fixture.args ++ ["--config-hash", value] } rest
  | arg :: rest => extract { fixture with args := fixture.args ++ [arg] } rest

/-- Gate real helper work after its ownership handshake; this executable is never shipped. -/
private def gateHelper (args : List String) : IO Unit := do
  let [operation, directory] := args | return
  let some gateDirectory ← IO.getEnv "BEAM_TEST_SAVE_GATE_DIR" | return
  let gateDirectory := System.FilePath.mk gateDirectory
  unless ← (gateDirectory / "enabled").pathExists do return
  unless (← IO.getEnv "BEAM_TEST_SAVE_GATE_OP") == some operation do return
  let ready := Lean.Json.mkObj [
    ("job", Lean.toJson directory)
  ]
  IO.FS.writeFile (gateDirectory / "entered.tmp") ready.compress
  IO.FS.rename (gateDirectory / "entered.tmp") (gateDirectory / "entered")
  let deadline := (← IO.monoMsNow) + 25000
  repeat
    if ← (gateDirectory / "fail").pathExists then
      throw <| IO.userError "controlled save helper failure"
    if ← (gateDirectory / "release").pathExists then return
    if (← IO.monoMsNow) >= deadline then
      throw <| IO.userError "save-finalization helper gate timed out"
    IO.sleep 10

/-- Explicit component fixtures are confined to this non-shipped test executable. -/
def main (args : List String) : IO Unit := do
  let fixture ← IO.ofExcept <| (extract {} args).mapError IO.userError
  let plugin ← fixture.plugin?.mapM Beam.resolveExistingPath
  let plugin ← match plugin with
    | some plugin => pure plugin
    | none => BeamTest.TestHarness.pluginPath
  let description : Beam.Runtime.Description := {
    command := fixture.command, plugin, daemonBin := ← IO.appPath
    toolchain := "library fixture", identity := ⟨(← IO.currentDir), "library fixture"⟩
  }
  match fixture.args with
  | ["worker-recovery-test", root] =>
      BeamTest.Broker.WorkerRecoveryTest.run description (← Beam.resolveExistingPath root)
  | ["private-publication-test", root] =>
      BeamTest.Broker.PrivatePublicationTest.run description (← Beam.resolveExistingPath root)
  | ["save-owner-test", case, root] =>
      BeamTest.Broker.SaveOwnerTest.run description (← Beam.resolveExistingPath root) case
  | "lake-helper" :: helperArgs =>
      Beam.Broker.LakeHelperMain.main (do
        gateHelper helperArgs
        pure fun _ => pure description) helperArgs
  | _ =>
      Beam.Broker.runDaemon (fun root =>
        pure (Beam.Broker.BrokerConfig.ofRuntime root description, fixture.configHash)) fixture.args
