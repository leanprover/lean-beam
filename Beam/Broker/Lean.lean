/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Backend.Lean
import Beam.Broker.Backend.Shared
import Beam.LSP.Save

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

def backendCommand
    (config : BrokerConfig)
    (backend : Backend) : IO (String × Array String × Array (String × Option String)) := do
  match backend with
  | .lean => Backend.Lean.command config

def initializeParams (backend : Backend) (root : System.FilePath) : Lean.Json :=
  match backend with
  | .lean => Backend.Lean.initializeParams root

def runAtMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runAtMethod

def hoverMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.hoverMethod

def signatureHelpMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.signatureHelpMethod

def definitionMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.definitionMethod

def referencesMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.referencesMethod

def documentSymbolsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.documentSymbolsMethod

def workspaceSymbolsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.workspaceSymbolsMethod

def codeActionResolveMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.codeActionResolveMethod

def runWithMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runWithMethod

def releaseMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.releaseMethod

def saveArtifactsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.saveArtifactsMethod

def diagnosticsBarrierMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.diagnosticsBarrierMethod

def goalsMethod (backend : Backend) (mode? : Option GoalMode := none) : Except String String :=
  match backend with
  | .lean => .ok (Backend.Lean.goalsMethod mode?)

def todoMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.todoMethod

def goalPpFormatValue (ppFormat? : Option GoalPpFormat) : String :=
  Backend.Shared.goalPpFormatValue ppFormat?

end Beam.Broker
