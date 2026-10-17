/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Broker.LakeHelperMain
import BeamTest.TestHarness

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

/-- Explicit component fixtures are confined to this non-shipped test executable. -/
def main (args : List String) : IO Unit := do
  let fixture ← IO.ofExcept <| (extract {} args).mapError IO.userError
  let plugin ← fixture.plugin?.mapM Beam.resolveExistingPath
  let plugin ← match plugin with
    | some plugin => pure plugin
    | none => BeamTest.TestHarness.pluginPath
  let description : Beam.Runtime.Description := {
    command := fixture.command, plugin, daemonBin := ← IO.appPath
    toolchain := "library fixture", identity := ⟨"library fixture"⟩
  }
  match fixture.args with
  | "lake-helper" :: helperArgs =>
      Beam.Broker.LakeHelperMain.main (pure fun _ => pure description) helperArgs
  | _ =>
      Beam.Broker.runDaemon (fun root =>
        pure (Beam.Broker.BrokerConfig.ofRuntime root description, fixture.configHash)) fixture.args
