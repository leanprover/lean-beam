# Profiling follow-ups

This note records possible future work. The current profiling contract is in [MCP.md](MCP.md#speculative-profiling).

- **Source attribution:** spans include a range only when Lean supplies one. Investigate whether an upstream Lean trace API can carry provenance to nested nodes. Do not infer child ranges from parent ranges or tactic labels.
- **Large results:** the 1024-span cap protects response construction but still permits large results. Explore a compact summary with access to the full retained spans, without requiring a new mode for ordinary probes.
- **Collection metadata:** source code can change Lean profiler options, and Beam cannot detect every change. Investigate whether Lean can report effective per-node clock/threshold settings or missing-coverage reasons before designing a public result change.
