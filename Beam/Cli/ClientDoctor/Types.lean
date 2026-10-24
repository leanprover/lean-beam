/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Lean

namespace Beam.Cli.ClientDoctor

open Lean

inductive Client where
  | codex | claude | pi | opencode | vibe
  deriving BEq, Repr, Inhabited

def Client.name : Client → String
  | .codex => "codex"
  | .claude => "claude"
  | .pi => "pi"
  | .opencode => "opencode"
  | .vibe => "vibe"

def Client.all : Array Client := #[.codex, .claude, .pi, .opencode, .vibe]

def Client.parse? (name : String) : Option Client :=
  Client.all.find? (·.name == name)

instance : ToJson Client := ⟨fun client => toJson client.name⟩

inductive Status where
  | ok | warning | error | unknown | notConfigured
  deriving BEq, Repr, Inhabited

def Status.name : Status → String
  | .ok => "ok"
  | .warning => "warning"
  | .error => "error"
  | .unknown => "unknown"
  | .notConfigured => "notConfigured"

instance : ToJson Status := ⟨fun status => toJson status.name⟩

/-- Configuration selection uses roles, independently of their display labels. -/
inductive SourceRole where
  | userConfig | userSettings | projectConfig | projectSettings | localSettings
  | projectDirectory | pathOverride | directoryOverride | explicitConfig | leanSkill | packageManifest
  deriving BEq, Repr, Inhabited

def SourceRole.description : SourceRole → String
  | .userConfig => "user configuration"
  | .userSettings => "user settings"
  | .projectConfig => "project configuration"
  | .projectSettings => "project settings"
  | .localSettings => "local settings"
  | .projectDirectory => "project .opencode configuration"
  | .pathOverride => "OPENCODE_CONFIG override"
  | .directoryOverride => "OPENCODE_CONFIG_DIR configuration"
  | .explicitConfig => "explicit config file"
  | .leanSkill => "Lean skill"
  | .packageManifest => "Pi package manifest"

/-- Integration state is recorded during inspection, rather than inferred from finding codes. -/
inductive IntegrationState where
  | notConfigured | notApplicable | outOfScope | checked | unverified | error
  deriving BEq, Repr, Inhabited

def IntegrationState.name : IntegrationState → String
  | .notConfigured => "notConfigured"
  | .notApplicable => "notApplicable"
  | .outOfScope => "outOfScope"
  | .checked => "checked"
  | .unverified => "unverified"
  | .error => "error"

instance : ToJson IntegrationState := ⟨fun state => toJson state.name⟩

/-- A successful check cannot erase a failed or incomplete check in another source. -/
def IntegrationState.observe (state : IntegrationState) (status : Status) : IntegrationState :=
  match state, status with
  | .outOfScope, _ | .notApplicable, _ => state
  | .error, _ | _, .error => .error
  | .unverified, _ | _, .unknown => .unverified
  | _, .ok | _, .warning => .checked
  | _, .notConfigured => state

inductive CheckArea where
  | general | mcp | skill
  deriving BEq, Repr

structure Finding where
  code : String
  status : Status
  message : String
  source? : Option String := none
  key? : Option String := none
  remediation? : Option String := none
  deriving ToJson, Repr

structure Source where
  path : String
  role : SourceRole
  conditional : Bool := false
  state : Status
  deriving Repr

def Source.purpose (source : Source) : String :=
  source.role.description ++ (if source.conditional then " (trust/approval-dependent)" else "")

instance : ToJson Source := ⟨fun source => Json.mkObj [
  ("path", toJson source.path), ("purpose", toJson source.purpose), ("state", toJson source.state)]⟩

structure ClientReport where
  client : Client
  mcp : IntegrationState := .notConfigured
  skill : IntegrationState := .notConfigured
  sources : Array Source := #[]
  findings : Array Finding := #[]
  /-- Discovery is separate from correctness: a malformed config still discovers a client. -/
  discovered : Bool := false
  deriving ToJson, Repr

structure Report where
  workspace : String
  scope : String := "userAndWorkspaceFiles"
  clients : Array ClientReport
  limitations : Array String := #[]
  deriving Repr

/-- Completed inspections have a fixed discriminator, distinct from CLI usage/setup failures. -/
instance : ToJson Report := ⟨fun report => Json.mkObj [
  ("kind", toJson "clientInspection"),
  ("workspace", toJson report.workspace),
  ("scope", toJson report.scope),
  ("clients", toJson report.clients),
  ("limitations", toJson report.limitations)]⟩

/-- Errors take precedence over incomplete inspection. Absence is not a broken optional setup. -/
def Report.exitCode (report : Report) : UInt32 :=
  if report.clients.any (·.findings.any (·.status == .error)) then 1
  else if report.clients.any (·.findings.any (·.status == .unknown)) then 2
  else 0

/-- Capture only variables with a documented role in local discovery; never serialize values. -/
structure Context where
  workspace : System.FilePath
  userHome : System.FilePath
  variables : Array (String × String) := #[]

def Context.env? (context : Context) (name : String) : Option String :=
  (context.variables.find? (·.1 == name)).map (·.2)

def Context.location (context : Context) (envName : String)
    (fallback : System.FilePath) : System.FilePath :=
  (context.env? envName).filter (!·.isEmpty) |>.map System.FilePath.mk |>.getD fallback

end Beam.Cli.ClientDoctor
