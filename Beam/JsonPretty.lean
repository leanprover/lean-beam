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

-- Presentation-only priority. Internal broker fields and opaque error data retain their own
-- spellings; ordering those keys does not introduce aliases in the public schema.
private def jsonFieldPriority : String -> Nat
  | "ok" => 0
  | "result" => 1
  | "error" => 2
  | "reason" => 13
  | "expected_version" | "expectedVersion" => 4
  | "accepted_version" | "acceptedVersion" => 5
  | "path" => 10
  | "version" => 11
  | "save_ready" | "saveReady" => 12
  | "changed" => 14
  | "diagnostics" => 20
  | "counts" => 21
  | "items" => 22
  | "readiness" => 30
  | "blocking_error_count" | "blockingErrorCount" => 32
  | "blocking_diagnostics" | "blockingDiagnostics" => 33
  | "blocking_messages" | "blockingMessages" => 34
  | "document_progress" | "fileProgress" => 40
  | "warning" => 51
  | "information" => 52
  | "hint" => 53
  | "unknown" => 54
  | "total" => 55
  | "message" => 80
  | "range" => 81
  | "severity" => 82
  | "save_blocking" | "saveBlocking" => 83
  | "completion_blocking" | "completionBlocking" => 84
  | "done" => 85
  | "updates" => 86
  | "start" => 90
  | "end" => 91
  | "line" => 92
  | "character" => 93
  | "range_start_line" | "rangeStartLine" => 94
  | "range_end_line" | "rangeEndLine" => 95
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

/-- Compact JSON with the same presentation order as `orderedJsonPretty`. -/
partial def orderedJsonCompact (json : Json) : String :=
  match json with
  | .null => "null"
  | .bool true => "true"
  | .bool false => "false"
  | .num number => number.toString
  | .str text => jsonString text
  | .arr values =>
      "[" ++ String.intercalate "," (values.toList.map orderedJsonCompact) ++ "]"
  | .obj fields =>
      let sortedFields := Std.TreeMap.Raw.toList fields |>.mergeSort jsonFieldLess
      let entries := sortedFields.map fun (key, value) =>
        jsonString key ++ ":" ++ orderedJsonCompact value
      "{" ++ String.intercalate "," entries ++ "}"

end Beam
