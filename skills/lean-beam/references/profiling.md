# Speculative Profiling

Use `--profile` (CLI) or `profile: true` (MCP) on `run-at`, `run-at-handle`, `run-with`, and
`run-with-linear` to compare speculative proof or declaration elaboration times in the loaded
environment.

## Invocation

Place `--profile` immediately before the text selector. When profiling is off, a standalone
`--profile` after the text selector (including `--`) is a usage error; Beam does not scan inside a
complete text argument, stdin, or file contents.

```bash
lean-beam run-at "Foo.lean" <version> <line> <character> --profile -- "simp"
lean-beam run-at-handle "Foo.lean" <version> <line> <character> --profile --text-file proof.txt
lean-beam run-with "Foo.lean" --handle-file handle.json --profile -- "exact trivial"
```

- **Complete declaration timing:** select its leading doc comment or first attribute (whichever
  comes first), or the declaration keyword if neither exists, and submit the entire block (doc
  comment, attributes, header, proof). Selecting the keyword after an attribute may fail with
  "has already been declared."
- **Proof-only timing:** select the first tactic's before-state and submit the tactic block without
  `by`.
- **Profiled handles:** a handle created with `--profile` requires `--profile` on every
  continuation and successor. An unprofiled continuation fails with `invalidParams` without consuming
  the handle (including `run-with-linear`); retry with `--profile`, or start from the document / an
  ordinary handle for unprofiled comparisons.
- **`#guard_msgs` unsupported:** trace retention can change `#guard_msgs` verdicts. Beam returns
  `invalidParams` for direct or command-recorded guards; a post-execution rejection does not undo
  external IO.

## Reading The Result

Inspect `success` and ordinary warnings/errors first, then `profile.elapsed_ms` and
`profile.summary`:

- `summary.top_spans`: groups single-child chains and ranks up to 10 by outer inclusive duration.
  Optional `inner_span` is the deepest descendant retaining at least half of the positive outer
  duration (a display heuristic, not a root-cause guarantee; the outer duration is not the inner
  step's cost). An inner label identical to its outer displayed label is omitted.
- `summary.phase_spans`: largest observed span for each known declaration-phase category (not
  totals, and absent phases are omitted).
- `summary.collapsed_spans` + `summary.omitted_from_top` + `summary.top_spans.length` equals
  `profile.spans.length` (counts retained spans only, not unrecorded work).
- `profile.spans`: retained tree (`span` indices in `summary` point here). Nested and parallel
  spans overlap—never sum durations.
- Labels are Lean-rendered headers clipped to 160 chars with `…`, rendered after the elapsed
  interval; they may show expanded syntax and are not proof verdicts or source locations.

## Timing Scope And Limits

- `elapsed_ms` is wall time for speculative re-elaboration in the loaded environment (not the
  original file, a cold build, or CPU time). It starts after parsing and ends once synchronous
  execution and tasks registered in the final Lean snapshot settle. Backtracked/unregistered tasks
  are not covered.
- Parse failures have no profile; elaboration failures after parsing can include one.
- Ordinary warnings/errors are kept, while ordinary Lean trace text is suppressed (`traces: []`).
- Each continuation profile measures only that call, not earlier handle work.
- `initial_threshold_ms` is Beam's initial 1 ms trace threshold, not a guarantee of the effective
  threshold (submitted code may alter profiler options). `truncated: true` means projection hit a
  cap, clipped raw category/tag text, or skipped incompatible-clock nodes; `truncated: false` does
  not prove complete trace coverage.
- Caps: at most 128 spans, 16,384 traversal visits, and `MessageData` depth 256. Shallow nodes are
  visited first; retained spans reserve the largest observation per summary phase plus ancestors,
  then fill by inclusive duration in original tree order.
- `thread` numbers start at 0 in first-seen order per response. `elapsed_ms` and span endpoints
  round to 0.1 ms relative to request start (`duration_ms` is the rounded endpoint difference;
  ranking uses unrounded durations). `parent` indexes the nearest retained ancestor in `spans`.
  `range` (when present, omitted if submitted text > 8,192 UTF-8 bytes) is a half-open 0-based
  UTF-16 range within the submitted snippet, not a document position.
- Profiling adds overhead. Compare candidates against the same snapshot/handle and environment,
  repeat measurements, and confirm wins with profiling disabled.
