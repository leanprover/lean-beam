/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Lean

open Lean

namespace Beam

private def indentString : Nat -> String
  | 0 => ""
  | n + 1 => " " ++ indentString n

private def jsonString (text : String) : String :=
  "\"" ++ Json.escape text ++ "\""

-- Presentation-only priority for wrapper/client stdout. This does not change the JSON contract.
private def jsonFieldPriority : String -> Nat
  | "ok" => 0
  | "result" => 1
  | "error" => 2
  | "reason" => 13
  | "expectedVersion" | "expectedSnapshot" => 4
  | "acceptedVersion" => 5
  | "path" => 10
  | "snapshot" => 11
  | "saveReady" => 12
  | "changed" => 14
  | "diagnostics" => 20
  | "counts" => 21
  | "items" => 22
  | "readiness" => 30
  | "blockingErrorCount" => 32
  | "blockingDiagnostics" => 33
  | "blockingMessages" => 34
  | "fileProgress" => 40
  | "warning" => 51
  | "information" => 52
  | "hint" => 53
  | "unknown" => 54
  | "total" => 55
  | "message" => 80
  | "range" => 81
  | "severity" => 82
  | "saveBlocking" => 83
  | "completionBlocking" => 84
  | "done" => 85
  | "updates" => 86
  | "start" => 90
  | "end" => 91
  | "line" => 92
  | "character" => 93
  | "rangeStartLine" => 94
  | "rangeEndLine" => 95
  | _ => 1000

private def jsonFieldLess (left right : Prod String Json) : Bool :=
  let leftPriority := jsonFieldPriority left.fst
  let rightPriority := jsonFieldPriority right.fst
  leftPriority < rightPriority ||
    (leftPriority == rightPriority && left.fst < right.fst)

partial def orderedJsonPretty (json : Json) (indent : Nat := 0) : String :=
  match json with
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num number => number.toString
  | .str text => jsonString text
  | .arr values =>
      if values.isEmpty then
        "[]"
      else
        let nextIndent := indent + 2
        let lines := values.toList.map fun value =>
          indentString nextIndent ++ orderedJsonPretty value nextIndent
        "[\n" ++ String.intercalate ",\n" lines ++ "\n" ++ indentString indent ++ "]"
  | .obj fields =>
      let sortedFields := Std.TreeMap.Raw.toList fields |>.mergeSort jsonFieldLess
      match sortedFields with
      | [] => "{}"
      | fields =>
          let nextIndent := indent + 2
          let lines := fields.map fun (key, value) =>
            indentString nextIndent ++ jsonString key ++ ": " ++ orderedJsonPretty value nextIndent
          "{\n" ++ String.intercalate ",\n" lines ++ "\n" ++ indentString indent ++ "}"

end Beam
