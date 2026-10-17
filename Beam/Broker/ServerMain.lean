/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Broker.LakeHelperMain
import Beam.BuildInfo
import Beam.Cli.Installation

def main (args : List String) : IO Unit := do
  let bind := do
    let installation ← Beam.Cli.Installation.current .daemon
    pure installation.runtime.resolve
  match args with
  | ["build-info"] => IO.println (Lean.Json.mkObj [
      ("compiledLeanRevision", Lean.toJson Beam.BuildInfo.compiled.compilerRevision),
      ("loadedLeanRevision", Lean.toJson Lean.githash)
    ]).compress
  | "lake-helper" :: helperArgs => Beam.Broker.LakeHelperMain.main (do
      let resolve ← bind
      pure fun root => return (← resolve root).runtime) helperArgs
  | _ =>
      let resolve ← bind
      Beam.Broker.runDaemon (fun root => do
        let config ← resolve root
        pure (Beam.Broker.BrokerConfig.ofRuntime root config.runtime, config.configHash)) args
