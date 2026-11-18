/-
Copyright (c) 2026 Lean FRO LLC. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Author: Emilio J. Gallego Arias
-/
import BeamTest.LSP.Requests.RunAt.ProfileCostlyTest

open Lean BeamTest.LSP.Requests.RunAt.ProfileCostlyTest

/-- Run the same declaration and assertions through the compatibility suite's installed CLI. -/
def main (command : List String) : IO Unit := do
  let cmd :: prefixArgs := command | throw <| IO.userError "expected compatibility wrapper command"
  let call := fun args => do
    let out ← IO.Process.output { cmd, args := prefixArgs.toArray ++ args }
    unless out.exitCode == 0 do throw <| IO.userError s!"{out.stdout}\n{out.stderr}"
    let envelope ← IO.ofExcept (Json.parse out.stdout)
    IO.ofExcept (envelope.getObjVal? "result")
  let start ← IO.monoMsNow
  let file := "ProfileCostly.lean"
  let updated ← call #["update", file]
  let version ← IO.ofExcept (updated.getObjValAs? Nat "version")
  discard <| call #["sync", file]
  let result ← call #["run-at", file, toString version, toString anchorLine, "0", "--profile", "--", declaration]
  unless (← IO.ofExcept (result.getObjValAs? Bool "success")) do
    throw <| IO.userError s!"costly declaration failed: {result}"
  checkProfile (← IO.ofExcept (result.getObjVal? "profile"))
  IO.println s!"costly profile (update, sync and probe): {(← IO.monoMsNow) - start} ms"
