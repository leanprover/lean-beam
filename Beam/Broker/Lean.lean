/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.Backend.Lean
import Beam.Broker.Backend.Rocq
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
  | .rocq =>
      let (cmd, args) ← Backend.Rocq.command config
      pure (cmd, args, #[])

def initializeParams (backend : Backend) (root : System.FilePath) : Lean.Json :=
  match backend with
  | .lean => Backend.Lean.initializeParams root
  | .rocq => Backend.Rocq.initializeParams root

def runAtMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runAtMethod
  | .rocq => Backend.Rocq.runAtMethod

def hoverMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.hoverMethod
  | .rocq => .error "rocq backend does not support hover queries"

def signatureHelpMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.signatureHelpMethod
  | .rocq => .error "rocq backend does not support signature help queries"

def definitionMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.definitionMethod
  | .rocq => .error "rocq backend does not support definition queries"

def referencesMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.referencesMethod
  | .rocq => .error "rocq backend does not support reference queries"

def documentSymbolsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.documentSymbolsMethod
  | .rocq => .error "rocq backend does not support document symbol queries"

def workspaceSymbolsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.workspaceSymbolsMethod
  | .rocq => .error "rocq backend does not support workspace symbol queries"

def codeActionResolveMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.codeActionResolveMethod
  | .rocq => .error "rocq backend does not support code action resolution"

def runWithMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.runWithMethod
  | .rocq => Backend.Rocq.runWithMethod

def releaseMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.releaseMethod
  | .rocq => Backend.Rocq.releaseMethod

def saveArtifactsMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.saveArtifactsMethod
  | .rocq => Backend.Rocq.saveArtifactsMethod

def diagnosticsBarrierMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.diagnosticsBarrierMethod
  | .rocq => .error "rocq backend does not support diagnostics barriers"

def goalsMethod (backend : Backend) (mode? : Option GoalMode := none) : Except String String :=
  match backend with
  | .lean => .ok (Backend.Lean.goalsMethod mode?)
  | .rocq => .ok Backend.Rocq.goalsMethod

def todoMethod (backend : Backend) : Except String String :=
  match backend with
  | .lean => .ok Backend.Lean.todoMethod
  | .rocq => .error "rocq backend does not support todo queries"

def goalPpFormatValue (ppFormat? : Option GoalPpFormat) : String :=
  Backend.Shared.goalPpFormatValue ppFormat?

end Beam.Broker
