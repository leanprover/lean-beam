# Lean MCTS Search

Use this reference when the task is no longer “try one tactic at one position” and has become
“preserve a speculative proof state, branch from it, run linear playouts, and release side
branches.”

## Core pattern

Use these commands:

```bash
lean-beam run-at-handle "Proofs.lean" <snapshot-from-update> 42 6 "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with "Proofs.lean" - "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam run-with-linear "Proofs.lean" - "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam release "Proofs.lean" -
```

Or use the shorter helper:

```bash
lean-beam-search mint "Proofs.lean" <snapshot-from-update> 42 6 "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search branch "Proofs.lean" "constructor"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search linear "Proofs.lean" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search playout "Proofs.lean" "exact trivial" "exact trivial"
printf '%s\n' "$HANDLE_JSON" | lean-beam-search release "Proofs.lean"
```

Rules:

- `lean-beam run-at-handle` mints a preserved root handle from the explicit broker document snapshot
- `lean-beam run-with` is non-linear: it preserves the current handle and returns a successor handle
- `lean-beam run-with-linear` is linear: it consumes the current handle and returns a successor handle
- `lean-beam release` explicitly drops a preserved handle you no longer need
- after a same-document edit, `lean-beam update`, `lean-beam sync`, close, or restart, reacquire handles from a fresh root

## Minimal branching example

```bash
# with `lean-beam serve` running in another process
root="$(lean-beam run-at-handle "Proofs.lean" <snapshot-from-update> 42 6 "constructor")"

# writing handles to files avoids stdin conflicts in larger shell scripts
printf '%s\n' "$root" > root.handle.json
left="$(lean-beam run-with "Proofs.lean" --handle-file root.handle.json "constructor")"
right="$(lean-beam run-with "Proofs.lean" --handle-file root.handle.json "aesop")"

# stdin handle flow remains supported too
left_pipe="$(printf '%s\n' "$root" | lean-beam run-with "Proofs.lean" - "constructor")"
right_pipe="$(printf '%s\n' "$root" | lean-beam run-with "Proofs.lean" - "aesop")"

printf '%s\n' "$left" | lean-beam release "Proofs.lean" -
printf '%s\n' "$right" | lean-beam release "Proofs.lean" -
```

Use this when you want to explore multiple children from the same preserved basis.

## Minimal linear playout example

```bash
# with `lean-beam serve` running in another process
root="$(lean-beam run-at-handle "Proofs.lean" <snapshot-from-update> 42 6 "constructor")"
# file-backed handles are often easier in longer shell loops
printf '%s\n' "$root" > root.handle.json
step1="$(lean-beam run-with-linear "Proofs.lean" --handle-file root.handle.json "constructor")"
printf '%s\n' "$step1" > step1.handle.json
step2="$(lean-beam run-with-linear "Proofs.lean" --handle-file step1.handle.json "exact trivial")"
printf '%s\n' "$step2" > step2.handle.json
lean-beam run-with-linear "Proofs.lean" --handle-file step2.handle.json "exact trivial"

# stdin handle flow remains supported when you prefer pipes
step1_pipe="$(printf '%s\n' "$root" | lean-beam run-with-linear "Proofs.lean" - "constructor")"
step2_pipe="$(printf '%s\n' "$step1_pipe" | lean-beam run-with-linear "Proofs.lean" - "exact trivial")"
printf '%s\n' "$step2_pipe" | lean-beam run-with-linear "Proofs.lean" - "exact trivial"
```

Use this when you want one evolving playout path instead of a preserved branch point.

## Root / branch / playout recipe

1. Mint one preserved root handle from the saved file.
2. Use `lean-beam run-with` from the root to create children.
3. Use `lean-beam run-with-linear` on a child when you want a playout path that consumes itself step by
   step.
4. Keep preserved handles only when you expect to revisit them.
5. Release side branches aggressively.

Concrete shell sketch:

```bash
# with `lean-beam serve` running in another process
root="$(lean-beam run-at-handle "Proofs.lean" <snapshot-from-update> 42 6 "constructor")"

child_a="$(printf '%s\n' "$root" | lean-beam run-with "Proofs.lean" - "constructor")"
child_b="$(printf '%s\n' "$root" | lean-beam run-with "Proofs.lean" - "aesop")"

playout_a1="$(printf '%s\n' "$child_a" | lean-beam run-with-linear "Proofs.lean" - "exact trivial")"
playout_a2="$(printf '%s\n' "$playout_a1" | lean-beam run-with-linear "Proofs.lean" - "exact trivial")"

printf '%s\n' "$child_b" | lean-beam release "Proofs.lean" -
```

The same sketch with the helper:

```bash
# with `lean-beam serve` running in another process
root="$(lean-beam-search mint "Proofs.lean" <snapshot-from-update> 42 6 "constructor")"
child_a="$(printf '%s\n' "$root" | lean-beam-search branch "Proofs.lean" "constructor")"
child_b="$(printf '%s\n' "$root" | lean-beam-search branch "Proofs.lean" "aesop")"
playout_a="$(printf '%s\n' "$child_a" | lean-beam-search playout "Proofs.lean" "exact trivial" "exact trivial")"
printf '%s\n' "$child_b" | lean-beam-search release "Proofs.lean"
```

## Failure semantics to expect

- semantic tactic failure should not invent a successor handle
- reusing a consumed linear handle should fail
- reusing a released handle should fail
- editing the file invalidates outstanding handles for that document

This means:

- branch handles are reusable until released or invalidated
- linear handles are not reusable after a successful linear step
- failure is data: use it to score the move, then continue from a still-valid preserved handle

## After a real edit

Do not try to salvage old handles.

```bash
# make a real edit and save the source file to disk
lean-beam update "Proofs.lean"
root="$(lean-beam run-at-handle "Proofs.lean" <snapshot-from-update> 42 6 "constructor")"
```

## When to stop using search

Stop branching when one path is clearly good enough to commit to source.

Then:

```bash
# make the real edit in Proofs.lean and save the source file to disk
lean-beam sync "Proofs.lean"
# only after a successful sync on a valid workspace module
lean-beam save "Proofs.lean"
```

## In-repo references

If you are working inside the `lean-beam` repo itself, the concrete search patterns live in:

- `tests/lean/BeamTest/LSP/Scenario/MctsProofSearchTest.lean`
- `tests/lean/BeamTest/LSP/Scenario/SearchWorkloadReport.lean`
- `tests/scenario/handleSearchCancelDsl.scn`
