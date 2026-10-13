/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Compiler
import Lean.Elab.Term
import Lean.Shell
import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests
import Beam.LSP.Lib.DiagnosticsCompat
import Beam.LSP.Lib.Request

open Lean
open Lean.Elab
open Lean.Server
open Lean.Server.RequestM
open Beam.LSP.Lib

/-
Internal save/readiness LSP extensions used by the Beam broker.

This family owns the worker-side artifact serialization and readiness checks; it shares only
request cancellation/version helpers and diagnostics compatibility.
-/
namespace Beam.LSP.Save

/--
Internal broker-only request for saving the current elaborated document state to
the Lake artifact locations expected by the workspace.

This underpins the supported `save after sync` path. It is not part of the public
`runAt` API.
-/
def saveArtifactsMethod : String := "$/beam/saveArtifacts"

/--
Internal broker-only request for checking whether the current elaborated document
state is ready for artifact save.

Broker sync/save paths consume this metadata from `$/beam/waitForDiagnostics`; this request remains
a direct request-surface check for the current worker snapshot. It is not part of the public `runAt`
API.
-/
def saveReadinessMethod : String := "$/beam/saveReadiness"

/-- Canonical Lake companion outputs required when saving a `module` environment. -/
structure ModuleArtifactPaths where
  oleanServerFile : String
  oleanPrivateFile : String
  irFile : String
  irSigFile? : Option String := none
  deriving FromJson, Repr, ToJson

/-- Internal request payload for artifact serialization from the current worker snapshot. -/
structure SaveArtifactsParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  expectedVersion : Nat
  expectedTextHash : UInt64
  oleanFile : String
  moduleArtifacts? : Option ModuleArtifactPaths := none
  ileanFile : String
  cFile : String
  bcFile? : Option String := none
  deriving FromJson, ToJson

-- Keep this indirection while v4.28 stays supported; re-check these request types when the
-- compatibility target is dropped.
instance : Lean.Lsp.FileSource SaveArtifactsParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Internal request payload for save-readiness checks from the current worker snapshot. -/
structure SaveReadinessParams where
  textDocument : Lean.Lsp.TextDocumentIdentifier
  expectedVersion : Nat
  expectedTextHash : UInt64
  deriving FromJson, ToJson

-- Keep this indirection while v4.28 stays supported; re-check these request types when the
-- compatibility target is dropped.
instance : Lean.Lsp.FileSource SaveReadinessParams where
  fileSource p := Lean.Lsp.fileSource p.textDocument

/-- Internal success payload for artifact serialization. -/
structure SaveArtifactsResult where
  written : Bool := true
  version : Nat
  textHash : UInt64
  deriving FromJson, ToJson

/-- Diagnostic-shaped evidence for an error that participates in save-readiness. -/
structure SaveBlockingDiagnostic where
  range : Lean.Lsp.Range
  severity? : Option Lean.Lsp.DiagnosticSeverity := some .error
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving FromJson, ToJson

/-- Frontend command-message evidence for an error that participates in save-readiness. -/
structure SaveBlockingCommandMessage where
  message : String
  saveBlocking : Bool := true
  completionBlocking : Bool := false
  deriving FromJson, ToJson

private def optionalField? [FromJson α] (json : Json) (field : String) : Except String (Option α) := do
  match json.getObjVal? field with
  | .ok value =>
      match fromJson? value with
      | .ok decoded => pure (some decoded)
      | .error err => throw s!"invalid '{field}': {err}"
  | .error _ =>
      pure none

private def requiredField [FromJson α] (json : Json) (field : String) : Except String α := do
  let value ←
    match json.getObjVal? field with
    | .ok value => pure value
    | .error _ => throw s!"missing required '{field}'"
  match fromJson? value with
  | .ok decoded => pure decoded
  | .error err => throw s!"invalid '{field}': {err}"

/-- Internal success payload for save-readiness checks. -/
structure SaveReadinessResult where
  version : Nat
  textHash : UInt64 := 0
  /-- Current worker snapshot diagnostics for reporting, not the save-readiness verdict. -/
  currentDiagnostics : Array Lean.Lsp.Diagnostic := #[]
  currentWarningCount : Nat := 0
  saveReady : Bool := true
  saveReadyReason : String := "ok"
  saveReadyMessage? : Option String := none
  blockingDiagnostics : Array SaveBlockingDiagnostic := #[]
  blockingCommandMessages : Array SaveBlockingCommandMessage := #[]
  deriving ToJson

instance : FromJson SaveReadinessResult where
  fromJson? json := do
    let version ← requiredField (α := Nat) json "version"
    let textHash ← requiredField (α := UInt64) json "textHash"
    let currentDiagnostics ←
      requiredField (α := Array Lean.Lsp.Diagnostic) json "currentDiagnostics"
    let currentWarningCount ← requiredField (α := Nat) json "currentWarningCount"
    let saveReady ← requiredField (α := Bool) json "saveReady"
    let saveReadyReason ← requiredField (α := String) json "saveReadyReason"
    let saveReadyMessage? ← optionalField? (α := String) json "saveReadyMessage"
    let blockingDiagnostics ←
      requiredField (α := Array SaveBlockingDiagnostic) json "blockingDiagnostics"
    let blockingCommandMessages ←
      requiredField (α := Array SaveBlockingCommandMessage) json "blockingCommandMessages"
    pure {
      version
      textHash
      currentDiagnostics
      currentWarningCount
      saveReady
      saveReadyReason
      saveReadyMessage?
      blockingDiagnostics
      blockingCommandMessages
    }

private def oldIREmitCName : Name :=
  .str (.str (.str .anonymous "Lean") "IR") "emitC"

-- Lean v4.30 moved C emission from `Lean.IR.emitC` to `Lean.Compiler.LCNF.emitC`.
-- Select the available API at elaboration time so one source tree still builds on v4.28-v4.35.
elab "emitCForSavedModule(" env:term ", " modName:term ")" : term => do
  if (← getEnv).contains oldIREmitCName then
    Lean.Elab.Term.elabTerm (← `(term| IO.ofExcept <| Lean.IR.emitC $env $modName)) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (Lean.Compiler.LCNF.emitC $modName).toIO'
        { fileName := "", fileMap := default }
        { env := $env })) none

def mkFilePath (path : String) : System.FilePath :=
  System.FilePath.mk path

def ensureParentDir (path : System.FilePath) : IO Unit := do
  if let some parent := path.parent then
    IO.FS.createDirAll parent

private def removeFileIfExists (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    IO.FS.removeFile path

private def withTempSiblingDir
    (path : System.FilePath)
    (useDir : System.FilePath → IO α) : IO α := do
  ensureParentDir path
  let parent := path.parent.getD (System.FilePath.mk ".")
  let pid ← IO.Process.getPID
  let tmpDir := parent / s!".beam-save-tmp-{pid}-{← IO.monoNanosNow}"
  IO.FS.createDirAll tmpDir
  try
    useDir tmpDir
  finally
    if ← tmpDir.pathExists then
      IO.FS.removeDirAll tmpDir

private structure StagedArtifact where
  staged : System.FilePath
  target : System.FilePath
  backup : System.FilePath

private initialize artifactPublicationMutex : Std.Mutex Unit ← Std.Mutex.new ()

private def prepareStagedArtifacts
    (targets : Array System.FilePath) : IO (Array StagedArtifact) := do
  let pid ← IO.Process.getPID
  let stamp ← IO.monoNanosNow
  let mut seenTargets : Array String := #[]
  let mut artifacts : Array StagedArtifact := #[]
  let mut index := 0
  for target in targets do
    let targetString := target.toString
    if seenTargets.contains targetString then
      throw <| IO.userError s!"duplicate artifact output path: {target}"
    seenTargets := seenTargets.push targetString
    ensureParentDir target
    if ← target.isDir then
      throw <| IO.userError s!"artifact output path is a directory: {target}"
    let staged := System.FilePath.mk s!"{targetString}.beam-save-tmp-{pid}-{stamp}-{index}"
    let backup := System.FilePath.mk s!"{targetString}.beam-backup-{pid}-{stamp}-{index}"
    if ← staged.pathExists then
      throw <| IO.userError s!"artifact staging path already exists: {staged}"
    if ← backup.pathExists then
      throw <| IO.userError s!"artifact backup path already exists: {backup}"
    artifacts := artifacts.push { staged, target, backup }
    index := index + 1
  pure artifacts

private def cleanupStagedArtifacts (artifacts : Array StagedArtifact) : IO Unit := do
  for artifact in artifacts do
    try
      removeFileIfExists artifact.staged
    catch _ =>
      pure ()

private def stagedArtifactAt
    (artifacts : Array StagedArtifact) (index : Nat) (kind : String) : IO StagedArtifact := do
  let some artifact := artifacts[index]?
    | throw <| IO.userError s!"internal {kind} artifact staging mismatch"
  pure artifact

private def publishStagedArtifacts (artifacts : Array StagedArtifact) : IO Unit := do
  -- Complete all checks that can be done without touching canonical outputs before the commit.
  for artifact in artifacts do
    unless ← artifact.staged.pathExists do
      throw <| IO.userError s!"missing staged artifact: {artifact.staged}"
    if ← artifact.target.isDir then
      throw <| IO.userError s!"artifact output path is a directory: {artifact.target}"
    ensureParentDir artifact.target

  let mut backedUp : Array StagedArtifact := #[]
  let mut installed : Array StagedArtifact := #[]
  try
    -- Hard-link each prior artifact before publication. The canonical paths remain readable, and
    -- every subsequent rename replaces one file atomically while retaining rollback data.
    for artifact in artifacts do
      if ← artifact.target.pathExists then
        IO.FS.hardLink artifact.target artifact.backup
        backedUp := backedUp.push artifact
    for artifact in artifacts do
      IO.FS.rename artifact.staged artifact.target
      installed := installed.push artifact
  catch publishError =>
    let mut rollbackErrors : Array String := #[]
    for artifact in installed.toList.reverse do
      try
        if ← artifact.backup.pathExists then
          IO.FS.rename artifact.backup artifact.target
        else
          removeFileIfExists artifact.target
      catch rollbackError =>
        rollbackErrors := rollbackErrors.push
          s!"could not restore {artifact.target}: {rollbackError}"
    for artifact in backedUp.toList.reverse do
      try
        let wasInstalled := installed.any fun installedArtifact =>
          installedArtifact.target.toString == artifact.target.toString
        if !wasInstalled && (← artifact.backup.pathExists) then
          removeFileIfExists artifact.backup
      catch rollbackError =>
        rollbackErrors := rollbackErrors.push
          s!"could not clean rollback link for {artifact.target}: {rollbackError}"
    if rollbackErrors.isEmpty then
      throw publishError
    throw <| IO.userError <|
      s!"artifact publication failed: {publishError}; rollback also failed: " ++
        String.intercalate "; " rollbackErrors.toList

  -- Publication has committed. Backup cleanup must not turn a successful, complete save into a
  -- reported failure whose trace is omitted.
  for artifact in backedUp do
    try
      removeFileIfExists artifact.backup
    catch _ =>
      pure ()

private structure ModuleArtifactTargets where
  oleanServerFile : System.FilePath
  oleanPrivateFile : System.FilePath
  irFile : System.FilePath
  irSigFile? : Option System.FilePath := none

private def moduleArtifactFiles
    (env : Environment)
    (oleanFile : System.FilePath)
    (moduleTargets? : Option ModuleArtifactTargets) : IO (Array System.FilePath) := do
  let mut files := #[oleanFile]
  if env.header.isModule then
    let some targets := moduleTargets?
      | throw <| IO.userError
          "module artifact save requires oleanServerFile, oleanPrivateFile, and irFile"
    files := files.push targets.oleanServerFile
    files := files.push targets.oleanPrivateFile
    files := files.push targets.irFile
    if let some irSigFile := targets.irSigFile? then
      files := files.push irSigFile
  else
    unless moduleTargets?.isNone do
      throw <| IO.userError
        "non-module artifact save must not provide module companion output paths"
  pure files

private def stageModuleArtifacts
    (env : Environment)
    (oleanFile : System.FilePath)
    (hasIRSignature : Bool)
    (moduleArtifacts : Array StagedArtifact) : IO Unit := do
  withTempSiblingDir oleanFile fun tmpDir => do
    let some fileName := oleanFile.fileName
      | throw <| IO.userError s!"module artifact path has no file name: {oleanFile}"
    let stagedOlean := tmpDir / fileName
    Lean.writeModule env stagedOlean
    let stagedIRSignature := stagedOlean.withExtension "ir.sig"
    if env.header.isModule && (← stagedIRSignature.pathExists) != hasIRSignature then
      throw <| IO.userError
        "module IR signature output path does not match this Lean build's artifact family"
    let mut generated :=
      if env.header.isModule then
        #[stagedOlean, stagedOlean.addExtension "server", stagedOlean.addExtension "private",
          stagedOlean.withExtension "ir"]
      else
        #[stagedOlean]
    if hasIRSignature then
      generated := generated.push stagedIRSignature
    unless generated.size == moduleArtifacts.size do
      throw <| IO.userError "internal module artifact staging mismatch"
    for path in generated do
      unless ← path.pathExists do
        throw <| IO.userError s!"Lean did not write expected staged module artifact: {path}"
    for (path, artifact) in generated.zip moduleArtifacts do
      IO.FS.writeBinFile artifact.staged (← IO.FS.readBinFile path)

private def writeIlean
    (doc : DocumentMeta)
    (headerStx : Syntax)
    (mainModule : Name)
    (trees : Array Elab.InfoTree)
    (ileanFile : System.FilePath) : IO Unit := do
  let references := Lean.Server.findModuleRefs doc.text trees (localVars := false)
  let (moduleRefs, decls) ← references.toLspModuleRefs
  let ilean : Lean.Server.Ilean := {
    module := mainModule
    directImports := Lean.Server.collectImports ⟨headerStx⟩
    references := moduleRefs
    decls
  }
  IO.FS.writeFile ileanFile (Json.compress <| toJson ilean)

def singleLineText (text : String) : String :=
  let parts := text.splitOn "\n"
  let parts := parts.filterMap fun part =>
    let trimmed := part.trimAscii.toString
    if trimmed.isEmpty then none else some trimmed
  String.intercalate " " parts

def formatErrorDiagnostic (diagnostic : Lean.Widget.InteractiveDiagnostic) : String :=
  let line := diagnostic.range.start.line + 1
  let character := diagnostic.range.start.character + 1
  s!"{line}:{character}: {singleLineText diagnostic.message.stripTags}"

def summarizeErrorItems (items : Array String) (maxItems : Nat := 3) : String :=
  let limit := Nat.min maxItems items.size
  let shown := items.extract 0 limit
  let extra := items.size - shown.size
  let suffix := if extra > 0 then s!" (and {extra} more)" else ""
  s!"{String.intercalate " | " shown.toList}{suffix}"

def saveArtifactsErrorMessage
    (diagnosticErrors : Array Lean.Widget.InteractiveDiagnostic)
    (commandErrors : Array String) : String :=
  let detailParts : List String :=
    if !commandErrors.isEmpty then
      [s!"commandMessages: {summarizeErrorItems commandErrors}"]
    else
      [
        if !diagnosticErrors.isEmpty then
          some s!"diagnostics: {summarizeErrorItems (diagnosticErrors.map formatErrorDiagnostic)}"
        else
          none
      ].filterMap id
  if detailParts.isEmpty then
    "cannot save artifacts for a document with errors"
  else
    s!"cannot save artifacts for a document with errors; {String.intercalate "; " detailParts}"

def saveReadinessDocumentErrorsReason : String :=
  "documentErrors"

def saveReadinessNotElaboratedReason : String :=
  "documentDidNotElaborateSuccessfully"

private def currentDocumentTextHash (doc : Lean.Server.FileWorker.EditableDocument) : UInt64 :=
  hash doc.meta.text.source

private def checkExpectedDocument
    (doc : Lean.Server.FileWorker.EditableDocument)
    (expectedVersion : Nat)
    (expectedTextHash : UInt64) : RequestM Unit := do
  unless doc.meta.version == expectedVersion do
    throw {
      RequestError.fileChanged with
      message :=
        s!"document version changed before artifact save: " ++
          s!"expected {expectedVersion}, got {doc.meta.version}"
    }
  let currentTextHash := currentDocumentTextHash doc
  unless currentTextHash == expectedTextHash do
    throw {
      RequestError.fileChanged with
      message :=
        s!"document text changed before artifact save: " ++
          s!"expected hash {expectedTextHash}, got {currentTextHash}"
    }

private def snapshotTreeMessageLog (snaps : Array Lean.Language.Snapshot) : MessageLog :=
  snaps.foldl (fun log snap => log ++ snap.diagnostics.msgLog) MessageLog.empty

private def messageSeverityCount (severity : MessageSeverity) (messages : Array Lean.Message) : Nat :=
  messages.foldl (init := 0) fun count msg =>
    if msg.severity == severity then count + 1 else count

private def commandErrorMessages (messages : Array Lean.Message) : RequestM (Array String) := do
  let mut commandErrors : Array String := #[]
  for msg in messages do
    if msg.severity == MessageSeverity.error then
      commandErrors := commandErrors.push (singleLineText (← msg.data.toString))
  pure commandErrors

private def saveBlockingDiagnosticOfInteractive
    (diagnostic : Lean.Widget.InteractiveDiagnostic) : SaveBlockingDiagnostic :=
  let plain := Lean.Widget.InteractiveDiagnostic.toDiagnostic diagnostic
  {
    range := diagnostic.fullRange
    severity? := plain.severity?
    message := singleLineText plain.message
    saveBlocking := true
    completionBlocking := false
  }

private def currentDiagnosticOfInteractive
    (diagnostic : Lean.Widget.InteractiveDiagnostic) : Lean.Lsp.Diagnostic :=
  let plain := Lean.Widget.InteractiveDiagnostic.toDiagnostic diagnostic
  { plain with fullRange? := some diagnostic.fullRange }

private def saveBlockingDiagnosticsOfMessages
    (doc : Lean.Server.FileWorker.EditableDocument)
    (messages : Array Lean.Message) : RequestM (Array SaveBlockingDiagnostic) := do
  let mut blockingDiagnostics := #[]
  for msg in messages do
    if msg.severity == MessageSeverity.error then
      let diagnostic ← Lean.Widget.msgToInteractiveDiagnostic doc.meta.text msg false
      blockingDiagnostics := blockingDiagnostics.push (saveBlockingDiagnosticOfInteractive diagnostic)
  pure blockingDiagnostics

private def saveBlockingDiagnosticsOfInteractive
    (diagnostics : Array Lean.Widget.InteractiveDiagnostic) :
    Array SaveBlockingDiagnostic :=
  diagnostics.map saveBlockingDiagnosticOfInteractive

private def saveBlockingCommandMessages
    (messages : Array String) : Array SaveBlockingCommandMessage :=
  messages.map fun message => {
    message
    saveBlocking := true
    completionBlocking := false
  }

-- The option can be scoped to a declaration and reset by EOF while compilation remains pending.
-- Older supported Lean versions have no postponed-compilation extension.
elab "hasPostponedCompilation(" env:term ")" : term => do
  if (← getEnv).contains `Lean.Compiler.LCNF.postponedCompileDeclsExt then
    Lean.Elab.Term.elabTerm (← `(term|
      !(Lean.Compiler.LCNF.postponedCompileDeclsExt.getState $env).isEmpty)) none
  else
    Lean.Elab.Term.elabTerm (← `(term| (let _ := $env; false))) none

def saveReadinessDeferredCompilationReason : String := "deferredCompilation"

private def deferredCompilationMessage? (state : Elab.Command.State) : Option String :=
  if state.scopes.head!.opts.getBool `compiler.postponeCompile false ||
      hasPostponedCompilation(state.env) then
    some "Beam cannot save deferred compilation from compiler.postponeCompile; use lake build instead."
  else
    none

def collectSaveReadiness
    (doc : Lean.Server.FileWorker.EditableDocument) :
    RequestM
      (SaveReadinessResult ×
        Option Elab.Command.State ×
        Array Lean.Widget.InteractiveDiagnostic ×
        Array String) := do
  let diagnostics := Beam.LSP.Lib.userVisibleDiagnostics (← collectCurrentDiagnosticsCompat(doc))
  let diagnosticErrors := diagnostics.filter (fun diag => diag.severity? == some .error)
  let diagnosticWarnings := diagnostics.filter (fun diag => diag.severity? == some .warning)
  -- Mirror Lean batch/Lake's current save-blocking message gate for the snapshot tree.
  let frontendLog := snapshotTreeMessageLog <| Lean.Language.toSnapshotTree doc.initSnap |>.getAll
  let frontendMessages := frontendLog.unreported.toArray
  let frontendErrorCount := messageSeverityCount MessageSeverity.error frontendMessages
  let frontendWarningCount := messageSeverityCount MessageSeverity.warning frontendMessages
  let commandErrors ← commandErrorMessages frontendMessages
  let frontendBlockingDiagnostics ← saveBlockingDiagnosticsOfMessages doc frontendMessages
  let frontendBlockingCommandMessages := saveBlockingCommandMessages commandErrors
  let textHash := currentDocumentTextHash doc
  let fallbackBlockingDiagnostics :=
    if frontendErrorCount == 0 then
      saveBlockingDiagnosticsOfInteractive diagnosticErrors
    else
      frontendBlockingDiagnostics
  let fallbackBlockingCommandMessages :=
    if frontendErrorCount == 0 then #[] else frontendBlockingCommandMessages
  let some cmdState := Lean.Language.Lean.waitForFinalCmdState? doc.initSnap
    | return ({
      version := doc.meta.version
      textHash
      currentDiagnostics := diagnostics.map currentDiagnosticOfInteractive
      currentWarningCount :=
        if frontendWarningCount == 0 then diagnosticWarnings.size else frontendWarningCount
      saveReady := false
      saveReadyReason := saveReadinessNotElaboratedReason
      saveReadyMessage? := some (saveArtifactsErrorMessage diagnosticErrors commandErrors)
      blockingDiagnostics := fallbackBlockingDiagnostics
      blockingCommandMessages := fallbackBlockingCommandMessages
      : SaveReadinessResult
    }, none, diagnosticErrors, commandErrors)
  let deferredMessage? := deferredCompilationMessage? cmdState
  let saveReady := frontendErrorCount == 0 && deferredMessage?.isNone
  let readiness : SaveReadinessResult := {
    version := doc.meta.version
    textHash
    currentDiagnostics := diagnostics.map currentDiagnosticOfInteractive
    currentWarningCount :=
      if frontendWarningCount == 0 then diagnosticWarnings.size else frontendWarningCount
    saveReady := saveReady
    saveReadyReason :=
      if frontendErrorCount != 0 then saveReadinessDocumentErrorsReason
      else if deferredMessage?.isSome then saveReadinessDeferredCompilationReason
      else "ok"
    saveReadyMessage? :=
      if frontendErrorCount != 0 then some (saveArtifactsErrorMessage diagnosticErrors commandErrors)
      else deferredMessage?
    blockingDiagnostics := if saveReady then #[] else frontendBlockingDiagnostics
    blockingCommandMessages := frontendBlockingCommandMessages ++
      saveBlockingCommandMessages deferredMessage?.toArray
  }
  pure (readiness, some cmdState, diagnosticErrors, commandErrors)

def saveCurrentArtifacts
    (doc : Lean.Server.FileWorker.EditableDocument)
    (snaps : List Snapshots.Snapshot)
    (p : SaveArtifactsParams) : RequestM SaveArtifactsResult := do
  checkRequestCancelled
  checkExpectedDocument doc p.expectedVersion p.expectedTextHash
  let (readiness, cmdState?, diagnosticErrors, commandErrors) ← collectSaveReadiness doc
  unless readiness.saveReady do
    throw <| RequestError.invalidParams <| readiness.saveReadyMessage?.getD
      (saveArtifactsErrorMessage diagnosticErrors commandErrors)
  let some cmdState := cmdState?
    | throw <| RequestError.invalidParams "document did not elaborate successfully"
  let env := cmdState.env
  let mainModule := env.mainModule
  let oleanFile := mkFilePath p.oleanFile
  let moduleTargets? := p.moduleArtifacts?.map fun paths => ({
    oleanServerFile := mkFilePath paths.oleanServerFile
    oleanPrivateFile := mkFilePath paths.oleanPrivateFile
    irFile := mkFilePath paths.irFile
    irSigFile? := paths.irSigFile?.map mkFilePath
  } : ModuleArtifactTargets)
  let ileanFile := mkFilePath p.ileanFile
  let cFile := mkFilePath p.cFile
  let moduleFiles ← moduleArtifactFiles env oleanFile moduleTargets?
  let mut targetFiles := moduleFiles.push ileanFile |>.push cFile
  if let some bcFile := p.bcFile?.map mkFilePath then
    targetFiles := targetFiles.push bcFile
  let stagedArtifacts ← prepareStagedArtifacts targetFiles
  let trees := snaps.toArray.map (·.infoTree)
  try
    let moduleArtifacts := stagedArtifacts.extract 0 moduleFiles.size
    stageModuleArtifacts env oleanFile
      (moduleTargets?.any fun targets => targets.irSigFile?.isSome) moduleArtifacts
    let ileanArtifact ← stagedArtifactAt stagedArtifacts moduleFiles.size "ilean"
    writeIlean doc.meta doc.initSnap.stx mainModule trees ileanArtifact.staged
    let cOutput ← emitCForSavedModule(env, mainModule)
    let cArtifact ← stagedArtifactAt stagedArtifacts (moduleFiles.size + 1) "C"
    IO.FS.writeFile cArtifact.staged cOutput
    if p.bcFile?.isSome then
      let bcArtifact ← stagedArtifactAt stagedArtifacts (moduleFiles.size + 2) "LLVM"
      Lean.IR.emitLLVM env mainModule bcArtifact.staged.toString
    -- Serialize only the short commit phase within this file-worker process. Cross-worker and
    -- cross-process publication coordination belongs to the broker rather than this LSP handler.
    -- Without this lock, requests handled by one worker could interleave their per-file renames.
    artifactPublicationMutex.atomically do
      -- Cancellation and document invalidation are honored until this explicit commit point. Once
      -- publication starts it runs to completion so success/failure agrees with the artifact family.
      checkRequestCancelled
      publishStagedArtifacts stagedArtifacts
  finally
    cleanupStagedArtifacts stagedArtifacts
  pure {
    written := true
    version := doc.meta.version
    textHash := currentDocumentTextHash doc
  }

def handleSaveArtifacts
    (p : SaveArtifactsParams) :
    RequestM (RequestTask SaveArtifactsResult) := do
  let doc ← RequestM.readDoc
  checkExpectedDocument doc p.expectedVersion p.expectedTextHash
  let t := doc.reporter.bindCheap (fun _ => doc.cmdSnaps.waitAll)
  RequestM.mapTaskCostly t fun (snaps, _) => do
    saveCurrentArtifacts doc snaps p

def handleSaveReadiness
    (p : SaveReadinessParams) :
    RequestM (RequestTask SaveReadinessResult) := do
  let doc ← RequestM.readDoc
  checkExpectedDocument doc p.expectedVersion p.expectedTextHash
  let t := doc.reporter
  RequestM.mapTaskCostly t fun _ => do
    let (readiness, _, _, _) ← collectSaveReadiness doc
    pure readiness

end Beam.LSP.Save
