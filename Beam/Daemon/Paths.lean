/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean
import Beam.Path

namespace Beam.Daemon

private def beamStateDir (root : System.FilePath) : System.FilePath :=
  root / ".beam"

/-- Stable FNV-1a tag used only for deterministic `BEAM_SESSION_ROOT` discovery. -/
private def controlRootTag (root : System.FilePath) : String :=
  let hash := root.toString.toUTF8.foldl
    (fun acc byte => (acc ^^^ byte.toUInt64) * 1099511628211)
    (14695981039346656037 : UInt64)
  toString hash.toNat

def controlDirFor
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  match explicitControlDir? with
  | some dir => pure dir
  | none =>
      match ← IO.getEnv "BEAM_SESSION_ROOT" with
      | some base =>
          let base := System.FilePath.mk base
          unless base.isAbsolute do
            throw <| IO.userError
              s!"BEAM_SESSION_ROOT must be an absolute path, got '{base}'"
          let base ← Beam.resolvePathForCreation base
          pure (base / controlRootTag root)
      | none =>
          pure (beamStateDir root)

/-- Resolve the default or environment-selected control directory for one CLI session. -/
def controlDir (root : System.FilePath) : IO System.FilePath :=
  controlDirFor root

/-- The descriptor leaf for an already selected session directory. -/
def registryPathIn (sessionDir : System.FilePath) : System.FilePath :=
  sessionDir / "beam-daemon.json"

def registryPathFor
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  pure (registryPathIn (← controlDirFor root explicitControlDir?))

def registryPath (root : System.FilePath) : IO System.FilePath := do
  registryPathFor root

def daemonStartupLogPathFor
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  pure ((← controlDirFor root explicitControlDir?) / "beam-daemon-startup.log")

def daemonStartupLogPath (root : System.FilePath) : IO System.FilePath :=
  daemonStartupLogPathFor root

def daemonFailureIncidentDirFor
    (root : System.FilePath)
    (explicitControlDir? : Option System.FilePath := none) : IO System.FilePath := do
  pure ((← controlDirFor root explicitControlDir?) / "daemon-failures")

def daemonFailureIncidentDir (root : System.FilePath) : IO System.FilePath :=
  daemonFailureIncidentDirFor root

end Beam.Daemon
