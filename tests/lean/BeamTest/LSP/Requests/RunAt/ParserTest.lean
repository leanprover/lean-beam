/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/

import Beam.LSP.RunAt

open Lean Elab

local macro "runPrivate% " name:ident : term =>
  pure <| mkIdent (mkPrivateNameCore `Beam.LSP.RunAt name.getId)

-- Run in its own Lean process: test-lsp.sh also requires empty stderr. A native panic can
-- otherwise print a backtrace and return a default value without making the process fail.
run_cmd do
  let env ← getEnv
  for text in ["", " ", "\n  \r\n", "\t", "  \t", "-- note", "/- note -/",
      "/-", "/- unterminated", "/- outer /- inner -/", "by", "by -- note", "(by)"] do
    match (runPrivate% Beam.LSP.RunAt.parseTacticText) env none text with
    | .error diagnostic =>
        if diagnostic.isEmpty then throwError "empty parser diagnostic for {text.quote}"
    | .ok _ => throwError "expected rejected tactic input: {text.quote}"
