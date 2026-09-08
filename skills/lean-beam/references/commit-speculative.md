# Committing A Speculative Result

Use this reference when a speculative `lean-beam run-at` or handle-based probe looks right and you want
that result to become real source.

## Current Rule

Today, committing a speculative result still means:

1. make the real source edit in the `.lean` file
2. save the file to disk
3. run `lean-beam sync`

That is the current explicit handoff from speculative execution to saved file state.

## Minimal Pattern

```bash
lean-beam run-at "Foo.lean" <snapshot-from-update> 20 2 "exact h"

# if the speculative result is the change you want:
# 1. edit Foo.lean for real
# 2. save Foo.lean
lean-beam sync "Foo.lean"
```

Use `lean-beam save` only after that sync succeeds and only when the file is a valid workspace module.

## If Exact Speculative Continuation Matters First

Sometimes the task is:

- first continue exactly from the speculative state
- then decide whether to commit the final result to source

Use the handle path first:

```bash
root="$(lean-beam run-at-handle "Foo.lean" <snapshot-from-update> 20 2 "tac1")"
next="$(printf '%s\n' "$root" | lean-beam run-with-linear "Foo.lean" - "tac2")"
```

If that sequence is the one you want to keep, the commit path is still the same: apply the edit to
the file, save it, then `lean-beam sync`.

## What Not To Assume

- `lean-beam run-at` does not edit the file for you
- `lean-beam run-at` does not make the speculative text become the new baseline automatically
- `lean-beam sync` syncs the current saved file; it does not recover speculative text that you never
  wrote into the file

## Future Direction

After the client has written and saved accepted text, the intended future direction is for
`lean-beam update` or `lean-beam sync` to reuse matching speculative execution instead of replaying
the work from scratch. Beam would still not apply the source edit. That is not the current contract
yet, so the safe workflow today is still: real edit, save, `lean-beam sync`.
