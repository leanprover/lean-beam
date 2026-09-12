# Related Tools

This page describes Lean Beam alongside two publicly documented Lean integrations: `lean-lsp-mcp`
and Pantograph. It is intended to help readers identify the interfaces relevant to their workflows;
it does not express a preference among the projects. Their scopes differ and may be complementary.

The descriptions here are based on each project's public documentation and published material. For
complete and current details, read the linked project documentation directly.

## Short Answer

Lean Beam consists of a Lean-side extension and a local broker. Its main operation is an isolated,
version-bound saved-file probe: `runAt(pos, "lean text")`. The broker exposes that operation model
through the `lean-beam` CLI and `lean-beam-mcp`.

[`lean-lsp-mcp`](https://github.com/oOo0oOo/lean-lsp-mcp) is an MCP server for Lean projects. Its
[README](https://github.com/oOo0oOo/lean-lsp-mcp#readme) and
[tools documentation](https://github.com/oOo0oOo/lean-lsp-mcp/blob/main/docs/tools.md) describe
agent interaction with Lean through LSP, including diagnostics, goal states, term information,
hover documentation, build-related tools, local source search, and external search services.

[`Pantograph`](https://github.com/stanford-centaur/PyPantograph) is a machine-to-machine interface
for Lean 4. The [Pantograph paper](https://arxiv.org/abs/2410.16429) presents it as an interface for
advanced theorem proving, high-level reasoning, and data extraction, with support for proof-search
workflows such as Monte Carlo Tree Search.

## Beam And lean-lsp-mcp

Both Beam and `lean-lsp-mcp` support agent workflows around Lean projects, and both can expose an
MCP server. Their documentation emphasizes different integration layers.

Beam starts from a Lean plugin and a typed execution contract. The broker owns Lean LSP
sessions, routes requests, tracks document versions, and exposes CLI and MCP projections over the
same operation layer. This is why Beam emphasizes isolated saved-file probes, explicit `sync`, stale
version handling, saved snapshot checkpoints, and the public `runAt` request shape.

`lean-lsp-mcp` exposes an MCP-facing Lean toolbox. Its documented surface includes Lean LSP
inspection tools, build-oriented tools, local project search, and external search services such as
Loogle and LeanSearch.

Beam's documented workflow centers on trying a Lean command or tactic at a position in a saved
module without changing the file, with the result tied to the document version. The documented
`lean-lsp-mcp` surface combines Lean LSP interaction with project search, builds, and theorem-search
services through MCP.

## Beam And Pantograph

Both projects expose machine-facing interaction with Lean. Their public documentation describes
different interfaces and client contexts.

Beam is an agent- and tool-facing local layer around Lean LSP plus Beam-specific extensions. Its
base workflow is to update or sync a saved file, run an isolated probe at a position, inspect
messages and optional proof state, then make any accepted edit in the real source.
Beam documents this workflow for proof repair, proof translation, autoformalization experiments,
and AI-assisted editing where the target remains an ordinary Lean project on disk.

Pantograph is presented as a machine-to-machine interface for advanced theorem-proving systems. Its
paper emphasizes proof search, high-level reasoning, data extraction, and robust handling of Lean 4
inference steps. Its README also documents programmatic tactic execution, metavariable coupling,
whole-file specification conformity checks, tactic-invocation data extraction, and inspection of
Lean constants.

Beam's request model is tied to saved project files and document versions. Pantograph documents a
programmatic interface for theorem-proving systems and research workflows involving proof search,
high-level reasoning, or Lean data extraction.

## Scope Boundaries

Beam's documented scope is isolated speculative execution and related saved-file operations,
exposed through a CLI, MCP server, and agent skill text. Lake, editors, theorem-search services,
`lean-lsp-mcp`, Pantograph, and prover research frameworks provide other capabilities and
interfaces.
