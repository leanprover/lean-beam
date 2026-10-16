/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam.Version

def projectVersion : String :=
  "0.2.0-beta"

def cliName : String :=
  "lean-beam"

def mcpServerName : String :=
  "lean-beam-mcp"

def mcpProtocolVersion : String :=
  "2026-07-28"

def legacyMcpProtocolVersion : String :=
  "2025-11-25"

private def optionalField (key : String) (value? : Option String) : List (String × Json) :=
  match value? with
  | some value => [(key, toJson value)]
  | none => []

private def optionalBoolField (key : String) (value? : Option Bool) : List (String × Json) :=
  match value? with
  | some value => [(key, toJson value)]
  | none => []

structure Identity where
  name : String
  version : String := projectVersion
  mcpProtocol? : Option String := none
  wrapper? : Option String := none
  beamHome? : Option String := none
  beamCli? : Option String := none
  serverBinary? : Option String := none
  runtimePayload? : Option String := none
  manifest? : Option String := none
  sourceCommit? : Option String := none
  bundledLean? : Option String := none
  sourceBranch? : Option String := none
  sourceDirty? : Option Bool := none
  activeRoot? : Option String := none
  runtimeActive? : Option Bool := none
  runtimeCurrent? : Option Bool := none
  runtimeError? : Option String := none

def Identity.asJson (identity : Identity) : Json :=
  Json.mkObj <|
    [
      ("name", toJson identity.name),
      ("version", toJson identity.version)
    ] ++
    optionalField "mcp_protocol" identity.mcpProtocol? ++
    optionalField "wrapper" identity.wrapper? ++
    optionalField "beam_home" identity.beamHome? ++
    optionalField "beam_cli" identity.beamCli? ++
    optionalField "server_binary" identity.serverBinary? ++
    optionalField "runtime_payload" identity.runtimePayload? ++
    optionalField "manifest" identity.manifest? ++
    optionalField "source_commit" identity.sourceCommit? ++
    optionalField "bundled_lean" identity.bundledLean? ++
    optionalField "source_branch" identity.sourceBranch? ++
    optionalBoolField "source_dirty" identity.sourceDirty? ++
    optionalField "active_root" identity.activeRoot? ++
    optionalBoolField "runtime_active" identity.runtimeActive? ++
    optionalBoolField "runtime_current" identity.runtimeCurrent? ++
    optionalField "runtime_error" identity.runtimeError?

def Identity.textLines (identity : Identity) : List String :=
  [s!"{identity.name} {identity.version}"] ++
  (match identity.mcpProtocol? with
  | some protocol => [s!"mcp protocol: {protocol}"]
  | none => []) ++
  (match identity.wrapper? with
  | some wrapper => [s!"wrapper: {wrapper}"]
  | none => []) ++
  (match identity.beamHome? with
  | some home => [s!"beam home: {home}"]
  | none => []) ++
  (match identity.beamCli? with
  | some beamCli => [s!"beam cli: {beamCli}"]
  | none => []) ++
  (match identity.serverBinary? with
  | some serverBinary => [s!"server binary: {serverBinary}"]
  | none => []) ++
  (match identity.beamHome?, identity.runtimePayload? with
  | some _, some payload => [s!"runtime payload: {payload}"]
  | some _, none => [s!"runtime payload: (source tree)"]
  | none, _ => []) ++
  (match identity.beamHome?, identity.manifest? with
  | some _, some manifest => [s!"manifest: {manifest}"]
  | some _, none => [s!"manifest: (none)"]
  | none, _ => []) ++
  (match identity.sourceCommit? with
  | some commit => [s!"source commit: {commit}"]
  | none => []) ++
  (match identity.bundledLean? with
  | some version => [s!"bundled Lean: {version}"]
  | none => []) ++
  (match identity.sourceBranch? with
  | some branch => [s!"source branch: {branch}"]
  | none => []) ++
  (match identity.sourceDirty? with
  | some dirty => [s!"source dirty: {dirty}"]
  | none => []) ++
  (match identity.activeRoot? with
  | some root => [s!"active root: {root}"]
  | none => []) ++
  (match identity.runtimeActive? with
  | some active => [s!"runtime active: {active}"]
  | none => []) ++
  (match identity.runtimeCurrent? with
  | some current => [s!"runtime current: {current}"]
  | none => []) ++
  (match identity.runtimeError? with
  | some error => [s!"runtime error: {error}"]
  | none => [])

def Identity.text (identity : Identity) : String :=
  String.intercalate "\n" identity.textLines

end Beam.Version
