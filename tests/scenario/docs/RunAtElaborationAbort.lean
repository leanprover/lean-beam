import Lean

open Lean Elab Tactic

elab "abort_term_probe" : tactic => do
  logError "logged elaboration abort"
  throwAbortTerm

elab "abort_tactic_probe" : tactic => do
  logError "logged elaboration abort"
  throwAbortTactic

elab "abort_command_probe" : tactic => do
  logError "logged elaboration abort"
  throwAbortCommand

elab "abort_without_diagnostics_probe" : tactic => throwAbortTerm

elab "unexpected_internal_probe" : tactic => do
  logError "logged before internal exception"
  throw <| Exception.internal postponeExceptionId

elab "silent_error_probe" : tactic =>
  log (m!"hidden diagnostic") .error (isSilent := true)

elab "silent_abort_probe" : tactic => do
  log (m!"hidden diagnostic") .error (isSilent := true)
  throwAbortTerm

elab "mixed_error_probe" : tactic => do
  log (m!"hidden diagnostic") .error (isSilent := true)
  logError "visible diagnostic"
  throwAbortTerm

elab "silent_then_throw_probe" : tactic => do
  log (m!"hidden diagnostic") .error (isSilent := true)
  throwError "visible exception diagnostic"

elab "silent_info_probe" : tactic =>
  log (m!"hidden diagnostic") .information (isSilent := true)

elab "silent_warning_probe" : tactic =>
  log (m!"hidden diagnostic") .warning (isSilent := true)

elab "#silent_error_probe" : command =>
  log (m!"hidden diagnostic") .error (isSilent := true)

elab "#silent_info_probe" : command =>
  log (m!"hidden diagnostic") .information (isSilent := true)

elab "#silent_warning_probe" : command =>
  log (m!"hidden diagnostic") .warning (isSilent := true)

def commandAnchor : Nat := 0 -- command

example : True ∧ True := by
  constructor <;> trivial -- probe
