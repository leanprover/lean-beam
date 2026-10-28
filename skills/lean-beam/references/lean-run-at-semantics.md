# Lean Run-At Semantics

Use this reference when a task is confused about what `lean-beam run-at` means. The short rule is:
`lean-beam run-at` is a speculative execution probe against one explicit broker document version, not a source edit.

For coordinates and tactic-state selection, see [Position Semantics](workflow-details.md#position-semantics).

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
lean-beam run-at "Foo.lean" <version-from-update> 20 2 "exact h"
# then expect diagnostics for unrelated later declarations as if Foo.lean had been edited
```

Correct workflow:

```bash
# make the real edit in Foo.lean and save it to disk
lean-beam sync "Foo.lean"
```

Use `lean-beam sync` when you need diagnostics for the saved file version as a whole. `lean-beam run-at`
only waits for the snapshot needed by that speculative request.

It should still report errors produced by the speculative text itself. For example, a top-level
theorem command whose proof body fails should return `success=false`; that is different from
replaying diagnostics from unrelated saved declarations.

If the speculative probe looks right and you want to keep it, open
[commit-speculative.md](commit-speculative.md).

## 2. Expecting One Probe To Become The Basis Of The Next

Wrong expectation:

```bash
lean-beam run-at "Foo.lean" <version-from-update> 30 2 "tac1"
lean-beam run-at "Foo.lean" <version-from-update> 30 2 "tac2"
# then expect the second call to continue from the speculative `tac1`
```

Correct workflow:

```bash
root="$(lean-beam run-at-handle "Foo.lean" <version-from-update> 30 2 "tac1")"
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
printf 'def tmpA : Nat := 1\n\n#check tmpA\n' | lean-beam run-at "Foo.lean" <version-from-update> 30 0 --stdin
```

Correct workflows:

```bash
root="$(lean-beam run-at-handle "Foo.lean" <version-from-update> 30 0 "def tmpA : Nat := 1")"
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
lean-beam run-at "Foo.lean" <version-from-update> 18 0 "exact h"
# where line 18 is a blank line inside an indented block, and expect the wrapper to infer indentation
#
# or expect the wrapper to add a leading/trailing newline around the text automatically
```

Correct workflow:

```bash
# on a truly empty line, only column 0 is valid, so provide the indentation in the text yourself
lean-beam run-at "Foo.lean" <version-from-update> 18 0 "    exact h"

# or probe after the existing indentation and pass only the code text
lean-beam run-at "Foo.lean" <version-from-update> 18 4 "exact h"
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
printf '  first | exact h1\n  | exact h2\n' | lean-beam run-at "Foo.lean" <version-from-update> 18 0 --stdin

# or read the probe from a file
lean-beam run-at "Foo.lean" <version-from-update> 18 0 --text-file probe.lean

# ANSI-C shell quoting also works when you do want to keep everything on one command line
lean-beam run-at "Foo.lean" <version-from-update> 18 0 $'  first | exact h1\n  | exact h2'
```

Do not expect the wrapper to turn `"first | exact h1 | exact h2"` into a properly line-broken block,
or to add missing `\n` separators around the text.

At a tactic position or term placeholder, send a tactic sequence or an outer `by` block, optionally
parenthesized. Comments around the `by` are parsed by Lean. The same grammar applies to proof-handle
continuations. Command-mode input still accepts exactly one command.

Beam tries the text on its own first, using Lean's tactic-sequence grammar:

- sibling tactics share the first tactic's column, or are separated by `;`
- a more indented line can continue the previous tactic's arguments
- nested `have ... := by` proofs, bullets, and other blocks keep normal Lean layout

Only if parsing fails, `run-at` may retry copied file indentation: the first line must start without
whitespace, and every later nonblank line must have at least the run position's column in leading
spaces. Beam pads the first line to that column and leaves the other lines unchanged. A successful
standalone parse is never reinterpreted, even if its indentation expresses something unintended;
elaboration errors do not trigger a retry. This fallback does not simulate a source edit.

A handle continuation has no run position, so it has no cursor-column retry. Align its standalone
tactics or supply a `by` block. Empty `by` input is rejected. An unfinished nested block can still
fail without creating a handle; an error result's displayed goals are not accepted partial progress.

```bash
printf 'intro a b\nomega\n' | lean-beam run-at "Foo.lean" <version-from-update> 18 2 --stdin
printf 'have h : 0 < 1 := by\n  decide\nomega\n' | lean-beam run-at "Foo.lean" <version-from-update> 18 2 --stdin
```

## 5. Introducing Local Recursion In A Tactic Probe

`lean-beam run-at`, `run-at-handle`, `run-with`, and `run-with-linear` reject newly introduced local
`let rec` definitions in tactic probes, including inside terms passed to `refine` or nested `have`
proofs. This also applies to their matching MCP tools. A valid recursive definition can trigger this
restriction; do not interpret it as a termination error or keep retrying the same definition through
different tactic syntax or handles.

Lean defers turning local recursive definitions into auxiliary declarations and checking termination
until it finishes the enclosing theorem or definition. Closing the visible tactic goals does not
perform that work. Beam rejects the fragment rather than reporting an unchecked recursive definition
as successful.

The request completes with `success=false`, a message beginning
`Local recursive declarations are not supported in runAt tactics`, the original proof state, and no
successor handle. A non-linear parent handle remains usable; `run-with-linear` consumes its input
handle on failure as usual. Recursion discarded by tactic backtracking does not trigger the
restriction if no pending recursive definitions remain.

To validate the recursive code:

1. Write and save the complete enclosing declaration in the real Lean file, including its `let rec`
   and the rest of the proof or definition.
2. Run `lean-beam sync "Foo.lean"` (MCP: `lean_sync`) and inspect the diagnostics/readiness result.
   Sync reads the saved file; it does not recover speculative text.
3. After successful sync, use its returned `version` for later position-bound probes. The edit
   invalidates old handles, so create new ones if continuation is needed. For repeated probes using
   a recursive helper, define the helper in the document and sync before probing its uses.

For a speculative check without editing the file, probe one complete theorem or definition at a
command position outside a proof. Complete command probes use Lean's normal declaration finalization:
valid local recursion is accepted and invalid termination is rejected. Beam selects the execution
basis from the position; there is no public command/tactic mode flag. The result remains speculative.
