/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.Broker.OpenDocs
import BeamTest.Broker.JsonAssert

open Lean
open Beam.Broker
open BeamTest.Broker.JsonAssert

namespace BeamTest.Broker.OpenDocsTest

private def requireArray (label : String) (json : Json) : IO (Array Json) := do
  match json with
  | .arr values => pure values
  | _ => throw <| IO.userError s!"{label}: expected array, got {json.compress}"

private def requireOnlyFile (label : String) (sessionJson : Json) : IO Json := do
  let files ← requireArray label (← requireObjVal label "files" sessionJson)
  require s!"{label}: expected one file, got {files.size}" (files.size == 1)
  pure files[0]!

private def mkDoc (text : String) (version : Nat := 1) : DocState := {
  version
  textHash := hash text
  textTraceHash := default
  textMTime := default
}

private def checkInactivePayload : IO Unit := do
  let root := System.FilePath.mk "/workspace"
  let payload ← OpenDocs.payload root none none
  requireJsonString "open docs payload" "root" root.toString payload
  let sessions ← requireObjVal "open docs payload" "sessions" payload
  let leanSession ← requireObjVal "open docs sessions" "lean" sessions
  let rocqSession ← requireObjVal "open docs sessions" "rocq" sessions
  requireJsonBool "inactive lean session" "active" false leanSession
  requireJsonBool "inactive rocq session" "active" false rocqSession
  require "inactive lean session has empty files"
    ((← requireArray "inactive lean files" (← requireObjVal "inactive lean session" "files" leanSession)).isEmpty)
  require "inactive rocq session has empty files"
    ((← requireArray "inactive rocq files" (← requireObjVal "inactive rocq session" "files" rocqSession)).isEmpty)

private def checkDocProjection : IO Unit := do
  let root := System.FilePath.mk s!"/tmp/beam-open-docs-test-{← IO.monoNanosNow}"
  try
    IO.FS.createDirAll root
    let path := root / "Demo.lean"
    let text := "def demo : Nat := 1\n"
    IO.FS.writeFile path text
    let uri := (System.Uri.pathToUri path : String)
    let docs : DocumentState.Docs :=
      Std.TreeMap.empty.insert uri {
        (mkDoc text 2) with
        checkpointedVersion? := some 2
        fileProgress? := some { updates := 3, done := true }
      }
    let session : OpenDocs.SessionView := {
      sessionToken := "test-session"
      root
      docs
    }
    let sessionJson ← OpenDocs.sessionJson (some session)
    requireJsonBool "open docs active session" "active" true sessionJson
    let file ← requireOnlyFile "open docs saved session" sessionJson
    requireJsonString "open docs file" "uri" uri file
    requireJsonString "open docs file" "path" "Demo.lean" file
    requireJsonString "open docs file" "snapshot" "test-session/2" file
    requireJsonString "open docs file" "diskStatus" "matchesTracked" file
    requireFieldAbsent "open docs file" "status" file
    requireJsonBool "open docs file" "checkpointed" true file
    requireFieldAbsent "open docs file" "saved" file
    requireFieldAbsent "open docs file" "savedOlean" file
    requireFieldAbsent "open docs file" "saveEligible" file
    requireFieldAbsent "open docs file" "saveReason" file
    requireFieldAbsent "open docs file" "saveModule" file
    requireFieldAbsent "open docs file" "saveDetail" file
    discard <| requireObjVal "open docs file" "fileProgress" file

    IO.FS.writeFile path "def demo : Nat := 2\n"
    let changedSessionJson ← OpenDocs.sessionJson (some session)
    let changedFile ← requireOnlyFile "open docs changed session" changedSessionJson
    requireJsonString "open docs changed file" "diskStatus" "differsFromTracked" changedFile
    requireJsonBool "open docs changed file" "checkpointed" false changedFile

    IO.FS.removeFile path
    let missingSessionJson ← OpenDocs.sessionJson (some session)
    let missingFile ← requireOnlyFile "open docs missing session" missingSessionJson
    requireJsonString "open docs missing file" "diskStatus" "missing" missingFile
    requireJsonBool "open docs missing file" "checkpointed" false missingFile

    let nonFileUri := "https://example.invalid/Demo.lean"
    let nonFileSession : OpenDocs.SessionView := {
      sessionToken := "test-session"
      root
      docs := Std.TreeMap.empty.insert nonFileUri {
        (mkDoc text 2) with checkpointedVersion? := some 2
      }
    }
    let nonFileSessionJson ← OpenDocs.sessionJson (some nonFileSession)
    let unknownFile ← requireOnlyFile "open docs non-file session" nonFileSessionJson
    requireJsonString "open docs non-file URI" "diskStatus" "unknown" unknownFile
    requireJsonBool "open docs non-file URI" "checkpointed" false unknownFile
    requireFieldAbsent "open docs non-file URI" "path" unknownFile
  finally
    try
      if ← root.pathExists then
        IO.FS.removeDirAll root
    catch _ =>
      pure ()

def main : IO Unit := do
  checkInactivePayload
  checkDocProjection

end BeamTest.Broker.OpenDocsTest

def main := BeamTest.Broker.OpenDocsTest.main
