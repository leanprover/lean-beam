/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Cli.Args
import Beam.Cli.ClientDoctor.Inspect

namespace Beam.Cli.ClientDoctor

open Lean

def usage : String :=
  "usage: lean-beam [--root PATH] doctor clients [codex|claude|pi|opencode|vibe] [--config PATH] [--json | --verbose]"

structure Options where
  client? : Option Client := none
  config? : Option System.FilePath := none
  json : Bool := false
  verbose : Bool := false

def parseOptions (args : List String) : Except String Options := do
  let rec parse (args : List String) (options : Options) : Except String Options := do
    match args with
    | [] =>
        if options.config?.isSome && options.client?.isNone then
          throw "--config requires an explicit client."
        if options.json && options.verbose then throw "Choose --json or --verbose."
        return options
    | "--json" :: rest =>
        if options.json then throw "--json was specified more than once."
        parse rest { options with json := true }
    | "--verbose" :: rest =>
        if options.verbose then throw "--verbose was specified more than once."
        parse rest { options with verbose := true }
    | "--config" :: path :: rest =>
        if options.config?.isSome then throw "--config was specified more than once."
        parse rest { options with config? := some (System.FilePath.mk path) }
    | arg :: rest =>
        let some client := Client.parse? arg | throw usage
        if options.client?.isSome then throw "Select at most one client."
        parse rest { options with client? := some client }
  parse args {}

def captureContext (opts : CliOptions) : IO Context := do
  let workspace ← IO.FS.realPath (opts.explicitRoot?.getD (← IO.currentDir))
  unless (← workspace.metadata).type == .dir do
    throw <| IO.userError "The inspection workspace must be a directory."
  let some userHome ← IO.getEnv "HOME"
    | throw <| IO.userError "HOME is required for client discovery."
  unless (System.FilePath.mk userHome).isAbsolute do
    throw <| IO.userError "HOME must be an absolute path."
  let mut variables := #[]
  for name in ["CODEX_HOME", "CLAUDE_HOME", "CLAUDE_CONFIG_DIR", "BEAM_CLAUDE_MCP_CONFIG", "PI_CODING_AGENT_DIR",
      "XDG_CONFIG_HOME", "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_CONFIG_CONTENT", "VIBE_HOME"] do
    if let some value ← IO.getEnv name then variables := variables.push (name, value)
  return { workspace, userHome := System.FilePath.mk userHome, variables }

/-- Keep unexpected parser/filesystem failures local to one client and redact exception text. -/
def inspectSafely (client : Client) (explicitConfig : Bool)
    (action : IO ClientReport) : IO ClientReport := do
  try action
  catch _ =>
    return {
      client
      discovered := true
      mcp := if client == .pi then .notApplicable else .unverified
      skill := if explicitConfig then .outOfScope else .unverified
      findings := #[{
        code := "inspection.failed"
        status := .unknown
        message := "Inspection of this client could not complete; configuration contents and exception text are omitted."
        remediation? := some "Review this client's configuration and retry."
      }] }

def inspect (context : Context) (options : Options) : IO Report := do
  let dirs ← workspaceDirectories context
  let mut clients := #[]
  for client in options.client?.map (#[·]) |>.getD Client.all do
    let report ← inspectSafely client options.config?.isSome
      (inspectClient context client dirs options.config?)
    if options.client?.isSome || report.discovered then clients := clients.push report
  return {
    workspace := context.workspace.toString
    scope := if options.config?.isSome then "explicitConfigFile" else "userAndWorkspaceFiles"
    clients
    limitations := #[
      "Checks the listed user/workspace files only. Running clients, launch flags, system/cloud/managed policy, and loaded tools are not inspected.",
      "Skill checks establish presence and readability, not client discovery or loading.",
      "OpenCode local files are merged in order. Other ambiguous layers and trust/approval state are reported as unknown.",
      "Configured commands are never executed; no files are written and no sessions are started."
    ] }

private def quoted (text : String) : String := (toJson text).compress

private def renderVerbose (report : Report) : String := Id.run do
  let mut lines := #[s!"Client configuration inspection: {quoted report.workspace}"]
  if report.clients.isEmpty then lines := lines.push "No client configuration or Lean skills found in the inspected locations."
  for client in report.clients do
    lines := lines.push s!"\n{client.client.name}:"
    for source in client.sources do
      if source.role != .leanSkill || source.state != .notConfigured then
        lines := lines.push s!"  source [{source.state.name}] {quoted source.path} ({source.purpose})"
    for finding in client.findings do
      lines := lines.push s!"  {finding.status.name} [{finding.code}] {finding.message}"
      if let some source := finding.source? then
        lines := lines.push s!"    source: {quoted source}"
      if let some key := finding.key? then lines := lines.push s!"    key: {quoted key}"
      if let some action := finding.remediation? then lines := lines.push s!"    action: {action}"
  lines := lines.push "\nScope:"
  for limitation in report.limitations do lines := lines.push s!"  {limitation}"
  return String.intercalate "\n" lines.toList

/-- A compact summary of static checks, with details only for actionable findings. -/
def renderText (report : Report) : String := Id.run do
  let mut lines := #["Beam client configuration", ""]
  if report.clients.isEmpty then
    lines := lines.push "No client configuration or Lean skills found."
  let mut errors := 0
  let mut unknowns := 0
  let mut warnings := 0
  for client in report.clients do
    let issues := client.findings.filter fun finding =>
      finding.status == .error || finding.status == .unknown || finding.status == .warning
    let label := if issues.any (·.status == .error) then "needs attention"
      else if issues.any (·.status == .unknown) then "partly checked"
      else if issues.any (·.status == .warning) then "check recommendation"
      else if client.skill == .notConfigured &&
          (client.mcp == .notConfigured || client.mcp == .notApplicable) then "not configured"
      else "checked"
    let mcp := match client.mcp with
      | .notApplicable => "MCP not applicable"
      | .notConfigured => "MCP not configured (optional)"
      | .checked => "MCP config checked"
      | .unverified => "MCP config unverified"
      | .error => "MCP config needs attention"
      | .outOfScope => "MCP outside selected scope"
    let skill := match client.skill with
      | .checked => "Lean skill found"
      | .notConfigured => "Lean skill not found"
      | .unverified => "Lean skill inspection incomplete"
      | .error => "Lean skill needs attention"
      | .outOfScope => "skills outside selected scope"
      | .notApplicable => "Lean skill not applicable"
    lines := lines.push s!"{client.client.name}: {label} — {mcp}; {skill}"
    for finding in issues do
      let kind := match finding.status with
        | .error => "Error"
        | .unknown => "Unverified"
        | _ => "Recommendation"
      if finding.status == .error then errors := errors + 1
      else if finding.status == .unknown then unknowns := unknowns + 1
      else warnings := warnings + 1
      lines := lines.push s!"  {kind}: {finding.message}"
      if let some source := finding.source? then lines := lines.push s!"    In {quoted source}"
      if let some action := finding.remediation? then lines := lines.push s!"    {action}"
  lines := lines.push s!"\n{errors} errors, {unknowns} unverified checks, {warnings} recommendations."
  lines := lines.push "Read-only checks; running clients and loaded tools were not tested."
  lines := lines.push "Use --verbose for inspected paths and individual checks."
  return String.intercalate "\n" lines.toList

def command (opts : CliOptions) (args : List String) : IO UInt32 := do
  if args == ["--help"] then IO.println usage; return 0
  match parseOptions args with
  | .error message => IO.eprintln message; return 2
  | .ok options =>
      if opts.explicitControlDir?.isSome then
        IO.eprintln "doctor clients does not use --session-dir."
        return 2
      try
        let context ← captureContext opts
        let cwd ← IO.currentDir
        let config? := options.config?.map fun path =>
          if path.isAbsolute then path else cwd / path
        let report ← inspect context { options with config? }
        IO.println <| if options.json then (toJson report).compress
          else if options.verbose then renderVerbose report else renderText report
        return report.exitCode
      catch _ =>
        -- IO/parser exceptions may contain config fragments or environment values.
        IO.eprintln "Client inspection could not complete. Check HOME and the workspace directory."
        return 2

end Beam.Cli.ClientDoctor
