/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Extra
import Lean.Data.Lsp.LanguageFeatures
import Beam.Broker.Config
import Beam.Broker.LakeHelper
import Beam.Broker.Protocol
import Beam.LSP.Goals
import Beam.LSP.ImportBasis
import Beam.LSP.RunAt
import Beam.LSP.Save
import Beam.LSP.Todo
import Beam.Path

open Lean
open Lean.Lsp

namespace Beam.Broker

/-- Broker-side view of `$/beam/waitForDiagnostics`; keep this JSON shape aligned with the Lean LSP
handler without importing the handler module into the broker. -/
structure DiagnosticsBarrierResult where
  version : Nat
  /-- Whether a snapshot reports a fatal stop preventing further file processing.
      Ordinary elaboration errors do not set this flag. -/
  hasFatalSnapshot : Bool
  directImports : Array String := #[]
  saveReadiness : Beam.LSP.Save.SaveReadinessResult
  deriving Lean.FromJson, Lean.ToJson

def leanCommand (config : BrokerConfig) (control : LakeHelperControl := {}) :
    IO (Except BrokerFailure (String × Array String × Array (String × Option String))) := do
  let some leanConfig := config.lean?
    | throw <| IO.userError "Lean backend is not configured"
  let plugin ← Beam.resolveExistingPath leanConfig.plugin
  let lakeEnv ← match ← runLakeHelperServerEnv leanConfig.lakeHelper { root := config.root.toString } control with
    | .error failure => return .error failure
    | .ok env => pure env
  pure <| .ok (
    leanConfig.command,
    #["--server"] ++ lakeEnv.moreServerArgs ++
      #[s!"--plugin={plugin}", "-Dexperimental.module=true"],
    lakeEnv.env)

def initializeParams (root : System.FilePath) : Json :=
  let rootUri := System.Uri.pathToUri root
  toJson ({
    processId? := some 0
    rootUri? := some rootUri
    workspaceFolders? := some #[{ uri := rootUri, name := root.fileName.getD root.toString }]
    initializationOptions? := some { hasWidgets? := some true, logCfg? := none }
    capabilities := {
      textDocument? := some {
        completion? := some {
          completionItem? := some { insertReplaceSupport? := true }
        }
      }
    }
    : InitializeParams
  })

def importBasisCaptureMethod : String :=
  Beam.LSP.ImportBasis.captureMethod

def importBasisCheckMethod : String :=
  Beam.LSP.ImportBasis.checkMethod

def runAtMethod : String :=
  Beam.LSP.RunAt.method

def hoverMethod : String :=
  "textDocument/hover"

def signatureHelpMethod : String :=
  "textDocument/signatureHelp"

def definitionMethod : String :=
  "textDocument/definition"

def referencesMethod : String :=
  "textDocument/references"

def waitForILeansMethod : String :=
  "$/lean/waitForILeans"

def documentSymbolsMethod : String :=
  "textDocument/documentSymbol"

def workspaceSymbolsMethod : String :=
  "workspace/symbol"

def codeActionResolveMethod : String :=
  "codeAction/resolve"

def runWithMethod : String :=
  Beam.LSP.RunAt.runWithMethod

def releaseMethod : String :=
  Beam.LSP.RunAt.releaseHandleMethod

def saveArtifactsMethod : String :=
  Beam.LSP.Save.saveArtifactsMethod

def diagnosticsBarrierMethod : String :=
  "$/beam/waitForDiagnostics"

def goalsMethod (mode? : Option GoalMode := none) : String :=
  match mode?.getD .after with
  | .before => Beam.LSP.Goals.prevMethod
  | .after => Beam.LSP.Goals.afterMethod

def todoMethod : String :=
  Beam.LSP.Todo.method

end Beam.Broker
