/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Mcp.Options
import Beam.Broker.Config
import Beam.Mcp.Protocol
import Beam.Mcp.SetupError
import Beam.Path

open Lean

namespace Beam.Mcp.Runtime

private structure LeanRuntimeConfig where
  leanCmd : String
  leanPlugin : System.FilePath
  leanLakeHelper : System.FilePath

private def inferLakeHelper (leanPlugin : System.FilePath) : IO (Except String System.FilePath) := do
  let some pluginDir := leanPlugin.parent
    | return .error s!"--lean-plugin has no parent directory: {leanPlugin}"
  let buildHelper? := pluginDir.parent.map fun buildDir => buildDir / "bin" / "beam-daemon"
  let candidates := #[some (pluginDir / "beam-daemon"), buildHelper?].filterMap id
  for candidate in candidates do
    if ← candidate.pathExists then
      return .ok (← Beam.resolveExistingPath candidate)
  pure <| .error <|
    s!"could not locate the target Lake helper for --lean-plugin {leanPlugin}; expected " ++
      String.intercalate " or " (candidates.map (·.toString)).toList

private def processOutputSummary (stdout stderr : String) : String :=
  let stderr := stderr.trimAscii.toString
  let stdout := stdout.trimAscii.toString
  if !stderr.isEmpty then
    stderr
  else if !stdout.isEmpty then
    stdout
  else
    "(no output)"

private def parseCliMcpConfig (text : String) : Except String LeanRuntimeConfig := do
  let json ← Json.parse text
  let leanCmd ← json.getObjValAs? String "lean_cmd"
  let leanPluginText ← json.getObjValAs? String "lean_plugin"
  let leanLakeHelperText ← json.getObjValAs? String "lean_lake_helper"
  pure {
    leanCmd
    leanPlugin := System.FilePath.mk leanPluginText
    leanLakeHelper := System.FilePath.mk leanLakeHelperText
  }

private def resolveFromBeamCli (beamCli : String) (root : System.FilePath) : IO (Except String LeanRuntimeConfig) := do
  let out ← IO.Process.output {
    cmd := beamCli
    args := #["--root", root.toString, "mcp-config"]
  }
  if out.exitCode != 0 then
    pure <| .error s!"{beamCli} --root {root} mcp-config failed: {processOutputSummary out.stdout out.stderr}"
  else
    match parseCliMcpConfig out.stdout with
    | .error err => pure <| .error s!"{beamCli} mcp-config returned invalid JSON: {err}"
    | .ok config => do
        try
          let plugin ← Beam.resolveExistingPath config.leanPlugin
          let lakeHelper ← Beam.resolveExistingPath config.leanLakeHelper
          pure <| .ok { config with leanPlugin := plugin, leanLakeHelper := lakeHelper }
        catch e =>
          pure <| .error s!"{beamCli} mcp-config returned an unusable runtime path: {e}"

private def resolveLeanRuntime (opts : LaunchOptions) (root : System.FilePath) : IO (Except RpcError LeanRuntimeConfig) := do
  match opts.beamCli?, opts.leanCmd?, opts.leanPlugin? with
  | none, some leanCmd, some leanPluginText =>
      let leanPlugin ←
        try
          Beam.resolveExistingPath <| System.FilePath.mk leanPluginText
        catch e =>
          return .error <| runtimeSetupError <| leanPluginSetupError e.toString
      match ← inferLakeHelper leanPlugin with
      | .ok leanLakeHelper =>
          pure <| .ok { leanCmd, leanPlugin, leanLakeHelper }
      | .error err =>
          pure <| .error <| runtimeSetupError err
  | some beamCli, none, none =>
      match ← resolveFromBeamCli beamCli root with
      | .error err => pure <| .error <| runtimeSetupError err
      | .ok resolved => pure <| .ok resolved
  | none, none, none =>
      pure <| .error <| runtimeSetupError runtimeSetupGuidance
  | _, _, _ =>
      pure <| .error <| runtimeSetupError <|
        "choose exactly one Lean runtime source: --beam-cli PATH, or " ++
          "--lean-cmd CMD with --lean-plugin PATH"

def mkBrokerConfig (opts : LaunchOptions) (root : System.FilePath) : IO (Except RpcError Beam.Broker.BrokerConfig) := do
  let root ←
    try
      Beam.resolveExistingPath root
    catch e =>
      return .error <| runtimeSetupError <| projectRootSetupError e.toString
  let runtime ← resolveLeanRuntime opts root
  match runtime with
  | .error err => pure <| .error err
  | .ok runtime =>
      pure <| .ok {
        root := root
        lean? := some {
          command := runtime.leanCmd
          plugin := runtime.leanPlugin
          lakeHelper? := some runtime.leanLakeHelper
        }
      }

end Beam.Mcp.Runtime
