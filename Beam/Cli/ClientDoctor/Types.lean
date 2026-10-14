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
  purpose : String
  state : Status
  deriving ToJson, Repr

structure ClientReport where
  client : Client
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
  deriving ToJson, Repr

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
