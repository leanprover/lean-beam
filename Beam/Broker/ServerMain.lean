/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Server
import Beam.Broker.LakeHelperMain
import Beam.BuildInfo
import Beam.Installation.Lookup

def main (args : List String) : IO Unit := do
  let bind := do
    let installation ← Beam.Installation.current .daemon
    pure installation.projectRuntime
  match args with
  | ["build-info"] => IO.println Beam.BuildInfo.report.compress
  | "lake-helper" :: helperArgs => Beam.Broker.LakeHelperMain.main bind helperArgs
  | _ =>
      let resolve ← bind
      Beam.Broker.runDaemon (fun root => do
        let runtime ← resolve root
        pure (Beam.Broker.BrokerConfig.ofRuntime root runtime, runtime.configHash root)) args
