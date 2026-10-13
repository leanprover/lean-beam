/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Lean.Data.Lsp.Ipc
import Beam.LSP.Lib.NativeLib

open Lean
open Lean.Lsp
open Lean.JsonRpc
open Lean.Lsp.Ipc

namespace BeamTest.TestHarness

structure RequestOutcome where
  result? : Option Json := none
  errorCode? : Option String := none
  errorMessage : String := ""
  deriving Inhabited

def pluginPath : IO System.FilePath := do
  IO.FS.realPath <| Beam.LSP.Lib.pluginSharedLibPath (System.FilePath.mk ".lake/build/lib")

/-- Resolve before changing to a fixture directory, so Lean matches the repository-built plugin. -/
def leanCmd : IO String := do
  let out ← IO.Process.output { cmd := "elan", args := #["which", "lean"] }
  if out.exitCode != 0 then
    throw <| IO.userError s!"failed to resolve test Lean executable\n{out.stderr}"
  let path := out.stdout.trimAscii.toString
  if path.isEmpty then
    throw <| IO.userError "elan returned an empty test Lean executable path"
  pure path

def errorCodeName : ErrorCode → String
  | .parseError => "parseError"
  | .invalidRequest => "invalidRequest"
  | .methodNotFound => "methodNotFound"
  | .invalidParams => "invalidParams"
  | .internalError => "internalError"
  | .serverNotInitialized => "serverNotInitialized"
  | .unknownErrorCode => "unknownErrorCode"
  | .contentModified => "contentModified"
  | .requestCancelled => "requestCancelled"
  | .rpcNeedsReconnect => "rpcNeedsReconnect"
  | .workerExited => "workerExited"
  | .workerCrashed => "workerCrashed"

def decodePublishDiagnostics (params : Json) : IO PublishDiagnosticsParams := do
  match fromJson? params with
  | .ok diagnosticParam => pure <| Ipc.normalizePublishDiagnosticsParams diagnosticParam
  | .error inner => throw <| IO.userError s!"Cannot decode publishDiagnostics parameters\n{inner}"

def initializeServer : Ipc.IpcM Unit := do
  let initializationOptions? : Option InitializationOptions := some {
    hasWidgets? := some true
    logCfg? := none
  }
  let capabilities : ClientCapabilities := {
    textDocument? := some {
      completion? := some {
        completionItem? := some {
          insertReplaceSupport? := true
        }
      }
    }
  }
  Ipc.writeRequest ⟨0, "initialize", { initializationOptions?, capabilities : InitializeParams }⟩
  let _ ← Ipc.readResponseAs 0 InitializeResult
  Ipc.writeNotification ⟨"initialized", InitializedParams.mk⟩

def shutdownServer (requestNo : Nat) : Ipc.IpcM Unit := do
  Ipc.shutdown requestNo
  discard <| Ipc.waitForExit

end BeamTest.TestHarness
