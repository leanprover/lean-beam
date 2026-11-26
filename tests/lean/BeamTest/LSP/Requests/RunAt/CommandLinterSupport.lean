/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean Elab Command Linter

namespace BeamTest.LSP.Requests.RunAt.CommandLinterSupport

register_option linter.style.header : Bool := {
  defValue := false
  descr := "test header linter matching Mathlib's cmdPos-at-start-of-fileMap check"
}

register_option linter.style.longLine : Bool := {
  defValue := false
  descr := "test long-line linter"
}

register_option linter.style.whitespace : Bool := {
  defValue := false
  descr := "test command-column whitespace linter"
}

register_option linter.style.emptyLine : Bool := {
  defValue := false
  descr := "test empty-line linter"
}

register_option linter.hashCommand : Bool := {
  defValue := false
  descr := "test hash-command linter"
}

register_option linter.semanticProbe : Bool := {
  defValue := false
  descr := "test semantic linter that should still run on command probes"
}

private def testHeaderLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.style.header (← getLinterOptions) do
      return
    let map ← getFileMap
    let startPos := (Parser.whitespace.run
      (Parser.mkInputContext map.source (← getFileName))
      { env := ← getEnv, options := {} }
      (Parser.getTokenTable (← getEnv))
      (Parser.mkParserState map.source)).pos
    if (← read).cmdPos == startPos then
      Linter.logLint linter.style.header stx m!"missing module docstring before probe"

private def testLongLineLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.style.longLine (← getLinterOptions) do
      return
    let map ← getFileMap
    if map.source.splitOn "\n" |>.any (·.length > 100) then
      Linter.logLint linter.style.longLine stx m!"line exceeds 100 chars"

private def testWhitespaceLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.style.whitespace (← getLinterOptions) do
      return
    if let some pos := stx.getPos? then
      if ((← getFileMap).toPosition pos).column != 0 then
        Linter.logLint linter.style.whitespace stx m!"command starts past column 0"

private def testEmptyLineLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.style.emptyLine (← getLinterOptions) do
      return
    let map ← getFileMap
    if (map.source.splitOn "\n\n").length > 1 then
      Linter.logLint linter.style.emptyLine stx m!"empty line inside command"

private def testHashCommandLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.hashCommand (← getLinterOptions) do
      return
    if let some tok := stx.getHead? then
      if tok.getAtomVal.startsWith "#" then
        Linter.logLint linter.hashCommand tok m!"hash command forbidden"

private def testSemanticLinter : Linter where
  run := withSetOptionIn fun stx => do
    unless getLinterValue linter.semanticProbe (← getLinterOptions) do
      return
    if stx.prettyPrint.pretty.contains "triggerSemanticLinter" then
      Linter.logLint linter.semanticProbe stx m!"semantic probe lint"

initialize
  addLinter testHeaderLinter
  addLinter testLongLineLinter
  addLinter testWhitespaceLinter
  addLinter testEmptyLineLinter
  addLinter testHashCommandLinter
  addLinter testSemanticLinter

end BeamTest.LSP.Requests.RunAt.CommandLinterSupport
