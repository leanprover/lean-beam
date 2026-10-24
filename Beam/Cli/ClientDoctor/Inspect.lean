/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
-/

import Beam.Cli.ClientDoctor.Locations
import Beam.Installation.StandaloneLayout
import Beam.Path
import Beam.System

namespace Beam.Cli.ClientDoctor

open Lean
open Beam.Installation

private def field? (value : Json) (key : String) : Option Json :=
  (value.getObjVal? key).toOption

private def object (value : Json) : Except Unit (Array (String × Json)) :=
  (value.getObj?).map (·.toArray) |>.mapError (fun _ => ())

private def string (value : Json) : Except Unit String :=
  value.getStr? |>.mapError (fun _ => ())

private def strings (value : Json) : Except Unit (Array String) := do
  let values ← value.getArr? |>.mapError (fun _ => ())
  values.mapM string

private def add (report : ClientReport) (area : CheckArea) (code : String) (status : Status)
    (message : String) (source? : Option String := none) (key? : Option String := none)
    (remediation? : Option String := none) : ClientReport :=
  { report with
    mcp := if area == .mcp then report.mcp.observe status else report.mcp
    skill := if area == .skill then report.skill.observe status else report.skill
    findings := report.findings.push { code, status, message, source?, key?, remediation? } }

private inductive FileRead where
  | missing | unreadable | notFile | tooLarge | text (value : String)

/-- Limit reads, accept ordinary symlinked dotfiles, and never open pipes or devices. -/
private def readFile (path : System.FilePath) : IO FileRead := do
  try
    let metadata ← path.metadata
    if metadata.type != .file then return .notFile
    let limit := 1024 * 1024
    if metadata.byteSize.toNat > limit then return .tooLarge
    let handle ← IO.FS.Handle.mk path .read
    let mut bytes := ByteArray.empty
    while bytes.size ≤ limit do
      let next ← handle.read (limit + 1 - bytes.size).toUSize
      if next.isEmpty then break
      bytes := bytes ++ next
    if bytes.size > limit then return .tooLarge
    match String.fromUTF8? bytes with
    | some text => return .text text
    | none => return .unreadable
  catch
  | .noFileOrDirectory .. =>
      -- A dangling symlink is a broken configured file, rather than absent configuration.
      try
        if ← Beam.pathIsLink path then return .unreadable
        let _ ← path.symlinkMetadata
        return .unreadable
      catch
      | .noFileOrDirectory .. => return .missing
      | _ => return .unreadable
  | _ => return .unreadable

private def readProblem (report : ClientReport) (path : String) (role : SourceRole)
    (area : CheckArea) (result : FileRead) (conditional := false) : ClientReport :=
  let state := match result with
    | .missing => Status.notConfigured
    | .notFile => .error
    | _ => .unknown
  let report := { report with
    sources := report.sources.push { path, role, conditional, state }
    discovered := report.discovered || state != .notConfigured }
  match result with
  | .missing => report
  | .tooLarge => add report area "file.tooLarge" .unknown
      "File exceeds the 1 MiB inspection limit." path
  | .notFile => add report area "file.notRegular" .error
      "Expected a regular file; this path is a directory or special file." path
  | _ => add report area "file.unreadable" .unknown
      "File cannot be read as UTF-8, or its symlink target is unavailable." path

private inductive EntryScope where
  | user | project | local
  deriving BEq

private def EntryScope.priority : EntryScope → Nat
  | .user => 0 | .project => 1 | .local => 2

private structure Entry where
  source : String
  key : String
  name : String
  value : Json
  conditional : Bool
  scope : EntryScope := .user
  commandSource? : Option String := none

private def command? (client : Client) (value : Json) : Option String := do
  let command ← field? value "command"
  if client == .opencode then
    ((command.getArr?).toOption.bind (·[0]?)).bind (·.getStr?.toOption)
  else command.getStr?.toOption

private def isMcpExecutable (path : System.FilePath) : Bool :=
  path.fileName == some "lean-beam-mcp" ||
    (System.Platform.isWindows && path.fileName.any (·.toLower == "lean-beam-mcp.exe"))

private def isBeam (client : Client) (name : String) (value : Json) : Bool :=
  name == "lean-beam" || ((command? client value).any fun command =>
    isMcpExecutable (System.FilePath.mk command))

private def namedEntries (client : Client) (source : ConfigSource)
    (keyPrefix : String) (value : Json) (localScope := false) : Except Unit (Array Entry) := do
  let values ← object value
  return values.filterMap fun (name, value) =>
    -- Claude replaces whole entries by name; a later non-Beam entry can shadow an alias.
    if client == .opencode || client == .claude || isBeam client name value then
      some {
        source := source.path.toString
        key := s!"{keyPrefix}.{name}"
        name
        value
        conditional := source.conditional
        scope := if localScope then .local
          else if source.role == .projectConfig then .project else .user
      }
    else none

private def entries (context : Context) (client : Client) (source : ConfigSource)
    (value : Json) : Except Unit (Array Entry) := do
  let _ ← object value
  if source.settingsOnly then return #[]
  match client with
  | .pi => return #[]
  | .codex =>
      match field? value "mcp_servers" with
      | none => return #[]
      | some servers => namedEntries client source "mcp_servers" servers
  | .opencode =>
      match field? value "mcp" with
      | none => return #[]
      | some servers => namedEntries client source "mcp" servers
  | .claude =>
      let mut result := #[]
      if let some servers := field? value "mcpServers" then
        result ← namedEntries client source "mcpServers" servers
      if let some projects := field? value "projects" then
        let _ ← object projects
        if let some project := field? projects context.workspace.toString then
          let _ ← object project
          if let some servers := field? project "mcpServers" then
            result := result ++ (← namedEntries client source "projects.<workspace>.mcpServers" servers true)
      return result
  | .vibe =>
      match field? value "mcp_servers" with
      | none => return #[]
      | some servers =>
          let values ← servers.getArr? |>.mapError (fun _ => ())
          let mut result := #[]
          for entry in values do
            let _ ← object entry
            let name := (field? entry "name").bind (·.getStr?.toOption) |>.getD ""
            if isBeam client name entry then
              result := result.push {
                source := source.path.toString
                key := s!"mcp_servers[{name}]"
                name
                value := entry
                conditional := source.conditional
              }
          return result

private partial def mentionsBeam : Json → Bool
  | .str text => text.contains "lean-beam"
  | .arr values => values.any mentionsBeam
  | .obj values => values.toArray.any fun (key, value) =>
      key.contains "lean-beam" || mentionsBeam value
  | _ => false

private def inspectSettings (context : Context) (client : Client) (source : ConfigSource)
    (value : Json) (report : ClientReport) : ClientReport := Id.run do
  let mut report := report
  let path := source.path.toString
  for key in ["permissions", "permission", "tools", "enabled_tools", "disabled_tools", "skills"] do
    if client == .pi && key == "skills" then continue
    if let some setting := field? value key then
      if mentionsBeam setting then
        report := add report (if key == "skills" then .skill else .mcp) "policy.notEvaluated" .unknown
          "Beam-specific tool or skill policy is present; its effective permissions are not evaluated." path key
  if client == .codex then
    if (field? value "profile").isSome || ((field? value "profiles").any mentionsBeam) then
      report := add report .mcp "config.profile" .unknown
        "Profile selection may change this configuration; profile overrides are not evaluated." path
  if client == .claude then
    if let some projects := (field? value "projects").bind (·.getObj?.toOption) then
      if projects.toArray.any (fun (key, _) => key != context.workspace.toString &&
          (Beam.pathRelativeToRoot? (System.FilePath.mk key) context.workspace).isSome) then
        report := add report .mcp "config.projectContext" .unknown
          "The user config records an ancestor workspace. Local-scope selection may depend on the client's launch context; inspect that workspace with --root."
          path
  return report

private structure ClaudePolicy where
  source : String
  key : String
  names : Array String
  projectOnly : Bool

private def claudePolicies (context : Context) (source : ConfigSource) (value : Json)
    (report : ClientReport) : ClientReport × Array ClaudePolicy := Id.run do
  let mut report := report
  let mut policies := #[]
  let project? := (field? value "projects").bind (field? · context.workspace.toString)
  for (keyPrefix, parent?) in #[("", some value), ("projects.<workspace>.", project?)] do
    if let some parent := parent? then
      for key in ["disabledMcpServers", "disabledMcpjsonServers"] do
        if let some setting := field? parent key then
          match strings setting with
          | .error () =>
              report := add report .mcp "config.policyShape" .unknown
                "A Claude disabled-server setting has an unsupported shape; expected an array of server names."
                source.path.toString (keyPrefix ++ key)
                "Review this setting against the installed client's configuration format."
          | .ok names =>
              policies := policies.push {
                source := source.path.toString
                key := keyPrefix ++ key
                names
                projectOnly := key == "disabledMcpjsonServers" }
  return (report, policies)

/-- Claude precedence is per name, local > project > user, with whole-entry replacement.
    Retain formerly recognized aliases if an override changes their shape or launcher. -/
private def selectClaude (entries : Array Entry) : Array Entry :=
  entries.filter fun entry =>
    (entries.any fun other => other.name == entry.name && isBeam .claude other.name other.value) &&
    !(entries.any fun other => other.name == entry.name && other.scope.priority > entry.scope.priority)

private def inspectRuntime (path : System.FilePath) (entry : Entry)
    (report : ClientReport) : IO ClientReport := do
  let home := (path.parent.getD path).parent.getD path
  let some location := installedRuntimeLocation? home
    | return report
  try
    for path in [location.installRoot / ".lean-beam-install-root", home / "manifest.json"] do
      match ← readFile path with
      | .text _ => pure ()
      | .missing | .notFile =>
          return add report .mcp "runtime.invalid" .error
            "The configured installed runtime has missing or non-regular installation metadata." entry.source entry.key
      | _ =>
          return add report .mcp "runtime.unreadable" .unknown
            "Installed runtime metadata could not be read within the inspection limit." entry.source entry.key
    match ← checkInstallRootMarker location.installRoot with
    | .error _ =>
        return add report .mcp "runtime.invalid" .error
          "The configured installed runtime has an invalid or missing ownership marker." entry.source entry.key
    | .ok () => pure ()
    match ← resolveRuntimeHome home with
    | .invalidInstalled _ | .source _ =>
        return add report .mcp "runtime.invalid" .error
          "The configured installed runtime has invalid installation metadata." entry.source entry.key
    | .installed _ =>
        return add report .mcp "runtime.metadata" .ok
          "The executable has recognized standalone installation metadata; runtime behavior was not tested."
          entry.source entry.key
  catch _ =>
    return add report .mcp "runtime.unreadable" .unknown
      "Installed runtime metadata could not be inspected." entry.source entry.key

private def inspectExecutable (entry : Entry) (command : String)
    (report : ClientReport) : IO ClientReport := do
  if command.isEmpty then
    return add report .mcp "launch.empty" .error
      "The launch command is empty." entry.source entry.key
  if command.contains "$" || command.contains "{" || command.startsWith "~" then
    return add report .mcp "launch.expansion" .unknown
      "The launch command requires client-specific expansion; it was not evaluated." entry.source entry.key
  let path := System.FilePath.mk command
  if !path.isAbsolute then
    let message := if path.components.length > 1 then
      "The command depends on the client's working directory; it was not resolved."
    else "The command depends on the client's PATH; it was not resolved."
    return add report .mcp "launch.relative" .unknown message entry.source entry.key
      "Use an absolute path to the installed lean-beam-mcp wrapper for predictable launches."
  try
    -- Inspect before realPath: Lean can collapse permission and resolution failures into ENOENT.
    let metadata ← path.metadata
    if metadata.type != .file then
      return add report .mcp "launch.notFile" .error
        "The configured executable is not a regular file." entry.source entry.key
    let resolved ← Beam.resolveExistingPath path
    let executeBits ← Beam.fileExecuteBits resolved
    if executeBits == some false then
      return add report .mcp "launch.notExecutable" .error
        "The configured executable has no execute permission bits." entry.source entry.key
    let mut report := add report .mcp "launch.file" .ok
      "The configured executable exists as a regular file; it was not run." entry.source entry.key
    if executeBits.isNone then
      report := add report .mcp "launch.permissions" .unknown
        "Execution permissions are not checked on this platform." entry.source entry.key
    if !isMcpExecutable path then
      return add report .mcp "launch.custom" .unknown
        "A custom launcher is configured; its behavior is not inspected." entry.source entry.key
    inspectRuntime resolved entry report
  catch
  | .noFileOrDirectory .. =>
      return add report .mcp "launch.missing" .error
        "The configured executable or a symlink target does not exist." entry.source entry.key
        "Update the registration to an existing installed lean-beam-mcp wrapper."
  | .invalidArgument .. =>
      return add report .mcp "launch.unresolved" .error
        "The configured executable path cannot be resolved." entry.source entry.key
  | _ =>
      return add report .mcp "launch.unreadable" .unknown
        "The configured executable could not be inspected." entry.source entry.key

private def inspectEntry (client : Client) (entry : Entry)
    (report : ClientReport) (checkLaunch : Bool) : IO ClientReport := do
  let value := entry.value
  let mut report := report
  if !(object value).isOk then
    return add report .mcp "config.entryShape" .unknown
      "A Beam server definition has an unsupported shape; expected a server object."
      entry.source entry.key
      "Review this definition against the installed client's MCP configuration format."
  -- Overrides may legally provide only some fields. Validate launches only after selection.
  if !checkLaunch then
    return add report .mcp "mcp.definition" .ok
      "A Beam definition was found; launch fields are not validated without effective selection."
      entry.source entry.key
  let disabledKey := if client == .vibe then "disabled" else "enabled"
  let disabledValue := client == .vibe
  if field? value disabledKey == some (.bool disabledValue) then
    return add report .mcp "mcp.disabled" .error
      "Beam's MCP registration is explicitly disabled." entry.source entry.key
      "Enable the registration in this client if you intend to use Beam through MCP."
  if client == .opencode && (object value).isOk &&
      (field? value "command").isNone && (field? value "type").isNone &&
      (field? value "enabled").any (·.getBool?.isOk) then
    return add report .mcp "config.partial" .unknown
      "This OpenCode entry only overrides an inherited server; its base definition is outside the inspected files."
      entry.source entry.key
      "Provide the complete local server definition to verify its launch command."
  let decoded : Except Unit (String × Array String) := do
    let _ ← object value
    if let some enabled := field? value disabledKey then
      let _ ← enabled.getBool? |>.mapError (fun _ => ())
    let (command, args) ← if client == .opencode then do
      let some raw := field? value "command" | throw ()
      let values ← strings raw
      let some command := values[0]? | throw ()
      pure (command, values.extract 1 values.size)
    else do
      let some raw := field? value "command" | throw ()
      let command ← string raw
      let args ← match field? value "args" with
        | none => pure #[]
        | some args => strings args
      pure (command, args)
    for key in ["env", "environment"] do
      if let some env := field? value key then
        for (_, setting) in ← object env do
          let _ ← string setting
    let transportKey := match client with | .vibe => "transport" | .codex => "" | _ => "type"
    if let some transport := field? value transportKey then
      let transport ← string transport
      unless transport == (if client == .opencode then "local" else "stdio") do throw ()
    else if client == .opencode || client == .vibe then throw ()
    if (field? value "url").isSome then throw ()
    if let some parallel := field? value "supports_parallel_tool_calls" then
      let _ ← parallel.getBool? |>.mapError (fun _ => ())
    if client == .vibe then
      let some rawName := field? value "name" | throw ()
      let name ← string rawName
      if name.isEmpty then throw ()
    return (command, args)
  match decoded with
  | .error () =>
      return add report .mcp "mcp.invalidEntry" .error
        "Beam's local MCP entry has missing or incorrectly typed launch fields, or a non-stdio transport."
        entry.source entry.key
        (if client == .opencode then "Use type = local and a non-empty command array of strings."
         else if client == .vibe then "Provide name, transport = stdio, and a command string; args must be an array of strings."
         else "Provide a command string for stdio; args must be an array of strings.")
  | .ok (command, args) =>
      report := add report .mcp "mcp.entry" .ok "Beam's local MCP launch fields have valid types." entry.source entry.key
      if client == .codex && field? value "supports_parallel_tool_calls" != some (.bool true) then
        report := add report .mcp "codex.parallelCalls" .warning
          "supports_parallel_tool_calls is not true; Beam's documented Codex adapter recommends it for independent probes."
          entry.source (entry.key ++ ".supports_parallel_tool_calls")
      for key in ["enabled_tools", "disabled_tools", "env", "environment", "cwd"] do
        if (field? value key).any (fun setting => setting != Json.mkObj [] && setting != .arr #[]) then
          report := add report .mcp "launch.overrides" .unknown
            "Tool filters, environment, or working-directory overrides are configured; their effect is not verified."
            entry.source (entry.key ++ "." ++ key)
      if !args.isEmpty then
        report := add report .mcp "launch.arguments" .unknown
          "Additional launch arguments are configured; their behavior is not verified." entry.source entry.key
      inspectExecutable { entry with source := entry.commandSource?.getD entry.source } command report

private def inspectSkill (path : System.FilePath) (report : ClientReport) : IO ClientReport := do
  let result ← readFile path
  match result with
  | .text text =>
      let report := { report with
        discovered := true
        sources := report.sources.push { path := path.toString, role := .leanSkill, state := .ok } }
      if text.trimAscii.isEmpty then
        return add report .skill "skill.empty" .error "The Lean skill file is empty." path.toString
      -- Presence/readability is useful without pretending to implement each client's skill loader.
      return add report .skill "skill.readable" .ok
        "A non-empty Lean skill file is present and readable; client loading and custom skill sources are not verified." path.toString
  | other => return readProblem report path.toString .leanSkill .skill other

/-- Only classify package sources whose cached manifest makes skill discovery unambiguous.
    Unavailable packages and filters remain unknown; never ask npm or Pi to resolve them. -/
private def inspectPiSettings (context : Context) (source : ConfigSource) (value : Json)
    (report : ClientReport) (inspectPackages : Bool) : IO ClientReport := do
  let mut report := report
  for key in ["skills", "packages"] do
    if let some setting := field? value key then
      let .ok values := setting.getArr?
        | return add report .skill "settings.invalid" .error "Skill/package sources must be arrays."
            source.path.toString key
      let mut unresolved := false
      for item in values do
        if key == "skills" then
          unresolved := true
          continue
        -- An explicit empty resource filter disables skill collection for this package.
        if field? item "skills" == some (.arr #[]) && field? item "autoload" != some (.bool false) &&
            ((field? item "source").bind (·.getStr?.toOption)).any (!·.isEmpty) then
          continue
        let some spec := item.getStr?.toOption
          | unresolved := true; continue
        let mut package? : Option System.FilePath := none
        if spec.startsWith "npm:" then
          let raw := (spec.drop 4).toString
          let parts := raw.splitOn "@"
          let name := if raw.startsWith "@" then "@" ++ (parts[1]?.getD "") else parts[0]?.getD ""
          let segments := name.splitOn "/"
          if !name.isEmpty && !segments.any (fun part => part.isEmpty || part == "." || part == "..") &&
              ((name.startsWith "@" && segments.length == 2) || (!name.startsWith "@" && segments.length == 1)) then
            let base := if source.conditional then context.workspace / ".pi"
              else clientHome context .pi
            package? := some (base / "npm" / "node_modules" / name)
        else if spec.startsWith "./" || spec.startsWith "../" || (System.FilePath.mk spec).isAbsolute then
          let path := System.FilePath.mk spec
          package? := some (if path.isAbsolute then path else source.path.parent.getD context.workspace / path)
        let some package := package? | unresolved := true; continue
        if !inspectPackages then unresolved := true; continue
        let manifestPath := package / "package.json"
        let contents ← readFile manifestPath
        let state := match contents with
          | .text _ => Status.ok
          | .missing => .notConfigured
          | _ => .unknown
        report := { report with sources := report.sources.push {
          path := manifestPath.toString, role := .packageManifest, state } }
        match contents with
        | .text text =>
            let .ok manifest := Json.parse text | unresolved := true; continue
            let some pi := field? manifest "pi" | unresolved := true; continue
            let .ok _ := object pi | unresolved := true; continue
            if (field? pi "skills").isSome && field? pi "skills" != some (.arr #[]) then
              unresolved := true
        | _ => unresolved := true
      if unresolved then
        report := add report .skill "skills.customSources" .unknown
          "Additional Pi skill sources or uncached packages need review; package code was not run."
          source.path.toString key
          "Review the skills/packages setting in Pi. Doctor checks standard Lean skill locations only."
      else if !values.isEmpty then
        report := add report .general "pi.packages" .ok
          "Cached package manifests or explicit filters declare no additional skills."
          source.path.toString key
  return report

private partial def mergeObjects (earlier later : Json) : Json :=
  match object earlier, object later with
  | .ok left, .ok right => Json.mkObj <| (right.foldl (fun entries (key, value) =>
      let merged := match entries.find? (·.1 == key) with
        | some (_, previous) => mergeObjects previous value
        | none => value
      (entries.filter (·.1 != key)).push (key, merged)) left).toList
  | _, _ => later

/-- OpenCode merges objects recursively; scalars and command arrays are replaced.
    Keep the command's source when a later layer only changes another field. -/
private def mergeOpenCode (entries : Array Entry) : Array Entry := Id.run do
  let beamNames := (entries.filter fun entry => isBeam .opencode entry.name entry.value).map (·.name)
  let mut result : Array Entry := #[]
  for entry in entries do
    if let some index := result.findIdx? (·.key == entry.key) then
      let some previous := result[index]? | continue
      result := result.set! index { entry with
        value := mergeObjects previous.value entry.value
        commandSource? := if (field? entry.value "command").isSome then some entry.source
          else some (previous.commandSource?.getD previous.source) }
    else result := result.push entry
  -- A malformed override must not erase recognition of an inherited Beam alias.
  return result.filter fun entry => beamNames.contains entry.name

def inspectClient (context : Context) (client : Client) (dirs : Array System.FilePath)
    (configOverride? : Option System.FilePath := none) : IO ClientReport := do
  let mut plan := locations context client dirs
  if let some path := configOverride? then
    let source : ConfigSource := {
      path
      format := if client == .codex || client == .vibe then .toml
        else if client == .opencode then .jsonc else .json
      role := .explicitConfig
      settingsOnly := client == .pi
    }
    plan := { plan with configs := #[source], skills := #[] }
  let mut report : ClientReport := {
    client
    mcp := if client == .pi then .notApplicable else .notConfigured
    skill := if configOverride?.isSome then .outOfScope else .notConfigured }
  let configArea := if client == .pi then CheckArea.skill else .mcp
  if !(clientHome context client).isAbsolute && configOverride?.isNone then
    return add { report with
      discovered := true
      mcp := if client == .pi then .notApplicable else .unverified
      skill := .unverified } .general "location.relative" .error
      "The client home override must be an absolute path. No client files were inspected."
  if client == .claude && (context.env? "CLAUDE_CONFIG_DIR").isSome && configOverride?.isNone then
    report := add { report with discovered := true } .mcp "config.clientHome" .unknown
      "CLAUDE_CONFIG_DIR selects a client home outside the installer's location conventions. Use --config to inspect its MCP config explicitly."
  let mut found : Array Entry := #[]
  let mut policies : Array ClaudePolicy := #[]
  let mut conditional := false
  let mut opencodeProjects := 0
  let mut opencodeDirectories := 0
  for source in plan.configs do
    if !source.path.isAbsolute then
      report := add { report with discovered := true } configArea "location.relative" .unknown
        "A config override is relative; it was not resolved against an assumed client launch directory."
      continue
    match ← readFile source.path with
    | .text text =>
        report := { report with
          discovered := true
          sources := report.sources.push { path := source.path.toString, role := source.role, conditional := source.conditional, state := .ok } }
        match ← parseConfig source.format text with
        | .error () =>
            report := add report configArea "config.syntax" .error
              "Configuration is not valid JSON/TOML for this client; source text is omitted." source.path.toString
        | .ok value =>
            report := inspectSettings context client source value report
            if client == .claude then
              let (updated, collected) := claudePolicies context source value report
              report := updated
              policies := policies ++ collected
            match entries context client source value with
            | .error () =>
                report := add report configArea "config.shape" .unknown
                  (if client == .pi then "Configuration has an unsupported shape; expected a settings object."
                   else "Configuration has an unsupported shape; expected a config object and the client's MCP server container.")
                  source.path.toString none
                  "Review this file against the installed client's configuration format."
            | .ok selected =>
                found := found ++ selected
                if client == .opencode && (field? value "mcp").isSome then
                  if source.role == .projectConfig then
                    opencodeProjects := opencodeProjects + 1
                  if source.role == .projectDirectory then
                    opencodeDirectories := opencodeDirectories + 1
                -- A Vibe project config may replace the server collection even with an empty array.
                conditional := conditional || (source.conditional &&
                  (!selected.isEmpty || (client == .vibe && (field? value "mcp_servers").isSome)))
                if client == .pi then report ← inspectPiSettings context source value report configOverride?.isNone
    | other =>
        report := readProblem report source.path.toString source.role configArea other source.conditional
        if configOverride?.isSome then report := { report with discovered := true }
        if configOverride?.isSome then
          if let .missing := other then
            report := add report configArea "config.missing" .error
              "The explicitly selected config file does not exist." source.path.toString
  if client == .opencode && (context.env? "OPENCODE_CONFIG_CONTENT").isSome then
    report := { report with discovered := true }
    report := add report .mcp "config.inlineOverride" .unknown
      "OPENCODE_CONFIG_CONTENT is set; its value and effects are not inspected."
  if client == .vibe && found.size > 1 && found.any (fun entry =>
      (found.filter (fun other => other.source == entry.source &&
        field? other.value "name" == field? entry.value "name")).size > 1) then
    report := add report .mcp "mcp.duplicate" .error
      "More than one Beam server entry is defined in the same Vibe config."
  if client == .opencode then
    found := mergeOpenCode found
    conditional := !found.isEmpty && (opencodeProjects > 1 || opencodeDirectories > 1)
  let selected := if client == .claude then selectClaude found else found
  let selectionConditional := if client == .claude then
      selected.any fun entry => entry.conditional || (selected.filter (·.name == entry.name)).size > 1
    else conditional
  let checkLaunch := (selected.size == 1 || client == .opencode) && !selectionConditional &&
    !(client == .opencode && (context.env? "OPENCODE_CONFIG_CONTENT").isSome)
  if (selected.size > 1 && client != .opencode && client != .claude) || selectionConditional then
    report := add report .mcp "config.layers" .unknown
      "Multiple Beam definitions or trust/approval-dependent project settings are present. Effective selection/merging is not verified."
  for entry in selected do
    if client == .claude then
      let disabled := policies.filter fun policy => policy.names.contains entry.name &&
        (!policy.projectOnly || entry.scope == .project)
      if !disabled.isEmpty then
        for policy in disabled do
          report := add report .mcp "mcp.disabled" .error
            s!"Beam server {(toJson entry.name).compress} is explicitly disabled for the selected scope."
            policy.source policy.key
            "Remove this server's name from the disabled list if you intend to use it through MCP."
        continue
    let checkEntry := if client == .claude then
        !entry.conditional && (selected.filter (·.name == entry.name)).size == 1
      else checkLaunch
    report ← inspectEntry client entry report checkEntry
  if selected.isEmpty && (report.mcp == .notConfigured || report.mcp == .notApplicable) then
    report := add report .general (if client == .pi then "mcp.notApplicable" else "mcp.notConfigured") .notConfigured
      (if client == .pi then "Beam uses Pi's CLI skill; no native Pi MCP configuration is inspected."
       else "No Beam MCP registration was found in the inspected files. MCP is optional for CLI/skill use.")
  let before := report.findings.size
  for path in plan.skills do report ← inspectSkill path report
  if report.findings.size == before && configOverride?.isNone then
    report := add report .general "skill.notConfigured" .notConfigured
      "No Lean skill was found in the inspected standard locations. Skills are optional for MCP use."
  return report

end Beam.Cli.ClientDoctor
