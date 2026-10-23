/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean.Server.FileWorker.RequestHandling
import Lean.Server.Requests

open Lean
open Lean.Server
open Lean.Server.RequestM

namespace Beam.LSP.Lib

/-
Shared request hygiene for independent LSP families.

Keep this module small: helpers belong here only when multiple request families need the same
transport-level checks. Feature-specific execution state should stay in the owning family.
-/

def checkRequestCancelled : RequestM Unit := do
  let rc ← readThe RequestContext
  if ← rc.cancelTk.wasCancelledByEdit then
    throw RequestError.fileChanged
  if ← rc.cancelTk.wasCancelledByCancelRequest then
    throw RequestError.requestCancelled

def requireDocumentVersion (textDocument : Lean.Lsp.VersionedTextDocumentIdentifier) :
    RequestM Unit := do
  let doc ← RequestM.readDoc
  match textDocument.version? with
  | none =>
      throw <| RequestError.invalidParams
        "textDocument.version is required for snapshot-bound Beam LSP requests"
  | some expectedVersion =>
      unless doc.meta.version == expectedVersion do
        throw {
          code := Lean.JsonRpc.ErrorCode.contentModified
          message :=
            s!"document version mismatch: requested version {expectedVersion}, accepted version {doc.meta.version}"
          : RequestError
        }

def lineUtf16Length (text : FileMap) (line : Nat) : Nat :=
  let start := text.lineStart (line + 1)
  let stop :=
    if line + 1 < text.getLastLine then
      text.lineStart (line + 2)
    else
      text.source.rawEndPos
  let lineText := String.Pos.Raw.extract text.source start stop
  let lineText :=
    if lineText.endsWith "\n" then
      (lineText.dropEnd 1).copy
    else
      lineText
  lineText.utf16Length

private def checkPositionBounds (position : Lean.Lsp.Position)
    (lastLine maxCharacter : Nat) : Except String Unit := do
  if position.line > lastLine then
    throw s!"position {position} is outside the document: line {position.line} is beyond the last line {lastLine}"
  if position.character > maxCharacter then
    throw s!"position {position} is outside the document: character {position.character} is beyond max character {maxCharacter} for line {position.line}"

/-- Bounds derived from Lean's accepted text, without retaining a second copy of the source. -/
structure PositionBounds where
  private mk ::
  private lineLengths : Array Nat

def PositionBounds.ofFileMap (text : FileMap) : PositionBounds :=
  let eof := text.utf8PosToLspPos text.source.rawEndPos
  { lineLengths := (Array.range (eof.line + 1)).map (lineUtf16Length text) }

def PositionBounds.validate (bounds : PositionBounds) (position : Lean.Lsp.Position) : Except String Unit :=
  checkPositionBounds position (bounds.lineLengths.size - 1)
    ((bounds.lineLengths[position.line]?).getD 0)

def validatePosition (position : Lean.Lsp.Position) : RequestM Unit := do
  let doc ← RequestM.readDoc
  let text := doc.meta.text
  let eof := text.utf8PosToLspPos text.source.rawEndPos
  let maxCharacter := if position.line > eof.line then 0 else lineUtf16Length text position.line
  match checkPositionBounds position eof.line maxCharacter with
  | .ok () => pure ()
  | .error message => throw <| RequestError.invalidParams message

end Beam.LSP.Lib
