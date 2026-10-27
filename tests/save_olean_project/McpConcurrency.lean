import Lean

open Lean Elab Tactic

private partial def waitForMcpGateRelease (path : System.FilePath) : TacticM Unit := do
  if ← path.pathExists then
    pure ()
  else
    IO.sleep 20
    if let some tk := (← readThe Core.Context).cancelTk? then
      if ← tk.isSet then
        throwInterruptException
    waitForMcpGateRelease path

elab "mcp_concurrency_gate" : tactic => do
  let some startedText ← IO.getEnv "BEAM_MCP_GATE_STARTED"
    | throwError "missing BEAM_MCP_GATE_STARTED"
  let some releaseText ← IO.getEnv "BEAM_MCP_GATE_RELEASE"
    | throwError "missing BEAM_MCP_GATE_RELEASE"
  IO.FS.writeFile (System.FilePath.mk startedText) "started\n"
  waitForMcpGateRelease (System.FilePath.mk releaseText)
  evalTactic (← `(tactic| exact trivial))

/-- Like `mcp_concurrency_gate`, but never observes cancellation while it waits. -/
private partial def waitForMcpGateReleaseIgnoringCancel (path : System.FilePath) : IO Unit := do
  if ← path.pathExists then
    pure ()
  else
    IO.sleep 20
    waitForMcpGateReleaseIgnoringCancel path

elab "mcp_unresponsive_gate" : tactic => do
  let some startedText ← IO.getEnv "BEAM_MCP_GATE_STARTED"
    | throwError "missing BEAM_MCP_GATE_STARTED"
  let some releaseText ← IO.getEnv "BEAM_MCP_GATE_RELEASE"
    | throwError "missing BEAM_MCP_GATE_RELEASE"
  IO.FS.writeFile (System.FilePath.mk startedText) "started\n"
  waitForMcpGateReleaseIgnoringCancel (System.FilePath.mk releaseText)
  evalTactic (← `(tactic| exact trivial))

example : True := by
  trivial
