# Lean Run-At Semantics

Use this reference when a task is confused about what `lean-beam run-at` means. The short rule is:
`lean-beam run-at` is a speculative execution probe against one explicit broker document snapshot, not a source edit.

For coordinates and tactic-state selection, see [Position Semantics](workflow-details.md#position-semantics).

Read `Foo.lean` and resolve the intended position before obtaining its token. Stop if `update` fails.
The examples below use this `snapshot` variable:

```bash
update_json="$(lean-beam update "Foo.lean")"
snapshot="$(printf '%s\n' "$update_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["snapshot"])')"
```

## What It Is Not

- it is not an edit to the file on disk
- it is not a full-file diagnostics barrier
- it is not implicit continuation from one speculative probe to the next
- it is not an indentation or whitespace synthesizer
- it does not insert missing `\n` separators or rewrite one-line text into a multi-line edit for you
- in command mode, it does not accept a complete top-level command sequence in one request

## 1. Expecting Full-File Diagnostics After A Speculative Probe

Wrong expectation:

```bash
lean-beam run-at "Foo.lean" "$snapshot" 20 2 "exact h"
# then expect diagnostics for unrelated later declarations as if Foo.lean had been edited
```

Correct workflow:

```bash
# make the real edit in Foo.lean and save it to disk
lean-beam sync "Foo.lean"
```

Use `lean-beam sync` when you need diagnostics for the saved file snapshot as a whole. `lean-beam run-at`
only waits for the snapshot needed by that speculative request.

It should still report errors produced by the speculative text itself. For example, a top-level
theorem command whose proof body fails should return `success=false`; that is different from
replaying diagnostics from unrelated saved declarations.

If the speculative probe looks right and you want to keep it, open
[commit-speculative.md](commit-speculative.md).

## 2. Expecting One Probe To Become The Basis Of The Next

Wrong expectation:

```bash
lean-beam run-at "Foo.lean" "$snapshot" 30 2 "tac1"
lean-beam run-at "Foo.lean" "$snapshot" 30 2 "tac2"
# then expect the second call to continue from the speculative `tac1`
```

Correct workflow:

```bash
root="$(lean-beam run-at-handle "Foo.lean" "$snapshot" 30 2 "tac1")"
printf '%s\n' "$root" | lean-beam run-with-linear "Foo.lean" - "tac2"
```

Use a handle when exact speculative continuation matters. Separate `lean-beam run-at` calls do not share
hidden mutable proof state.

If the task is branching or doing playouts, also open
[mcts-search.md](mcts-search.md).

If a speculative step looks right and you want it to become real source, open
[commit-speculative.md](commit-speculative.md).

## 3. Expecting A Command Sequence In One Request

Wrong expectation:

```bash
printf 'def tmpA : Nat := 1\n\n#check tmpA\n' | lean-beam run-at "Foo.lean" "$snapshot" 30 0 --stdin
```

Correct workflows:

```bash
root="$(lean-beam run-at-handle "Foo.lean" "$snapshot" 30 0 "def tmpA : Nat := 1")"
printf '%s\n' "$root" | lean-beam run-with "Foo.lean" - "#check tmpA"
```

or make the command sequence a real saved edit and sync the file:

```bash
lean-beam sync "Foo.lean"
```

One command-mode `run-at` request accepts one Lean command. A top-level command sequence fails with
`runAtSupportsOneCommandOnly` so clients do not mistake the result for an ordinary syntax problem in
the second command.

## 4. Expecting Indentation Or Newlines To Be Filled Automatically

Wrong expectation:

```bash
lean-beam run-at "Foo.lean" "$snapshot" 18 0 "exact h"
# where line 18 is a blank line inside an indented block, and expect the wrapper to infer indentation
#
# or expect the wrapper to add a leading/trailing newline around the text automatically
```

Correct workflow:

```bash
# on a truly empty line, only column 0 is valid, so provide the indentation in the text yourself
lean-beam run-at "Foo.lean" "$snapshot" 18 0 "    exact h"

# or probe after the existing indentation and pass only the code text
lean-beam run-at "Foo.lean" "$snapshot" 18 4 "exact h"
```

Or make the real edit in the file and save it before syncing:

```bash
# edit Foo.lean so the tactic is written with the indentation you want
lean-beam sync "Foo.lean"
```

`lean-beam run-at` uses the text you pass at the position you pass. If layout matters, choose the
position and text together instead of expecting the wrapper to rewrite indentation for you.
On a truly empty line, `18 1` would already be out of range; blank lines are still 0-based Lean/LSP
positions.

If the speculative text is the version you want to keep, open
[commit-speculative.md](commit-speculative.md).

For multi-line probes, include the actual newline characters you want Lean to parse. For example:

```bash
# piping the exact text through stdin avoids shell-escape mistakes
printf '  first | exact h1\n  | exact h2\n' | lean-beam run-at "Foo.lean" "$snapshot" 18 0 --stdin

# or read the probe from a file
lean-beam run-at "Foo.lean" "$snapshot" 18 0 --text-file probe.lean

# ANSI-C shell quoting also works when you do want to keep everything on one command line
lean-beam run-at "Foo.lean" "$snapshot" 18 0 $'  first | exact h1\n  | exact h2'
```

Do not expect the wrapper to turn `"first | exact h1 | exact h2"` into a properly line-broken block,
or to add missing `\n` separators around the text.
