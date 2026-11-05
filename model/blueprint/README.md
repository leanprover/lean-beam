# Understanding Beam's ownership models

This Verso Blueprint is the guided introduction to the model. Start with
[What are we modeling?](BeamBlueprint/Chapters/Orientation.lean), then follow
admission, publication, protocol observations, settlement, and the remaining
[implementation connections](BeamBlueprint/Chapters/Connections.lean).

The generated site provides declaration previews, a dependency graph, linked
technical terms, and checked transition examples with their expected output. Every
associated declaration comes from the actual repository sources. No model or
production component is copied into this project. The graph is curated: its
edges express selected mathematical dependencies, not complete runtime wiring.
Direct production laws and abstract laws are identified in their statements.

The [implementation correspondence](../../docs/CLOSE_SAVE_MODEL.md) remains the
reference for exact broker boundaries, regression names, CI coverage, and
assumptions. The Blueprint explains the ideas and traces rather than duplicating
that maintenance table. Neither document claims complete broker verification.

## Build and read

From this directory, with `ELAN_TOOLCHAIN` unset so elan uses the local selector:

```sh
lake exe vbp build --serve
```

The server prints its preview URL. The generated entry point is
`_out/site/html-multi/index.html`. `bash scripts/ci-pages.sh` is the noninteractive
build entry point. This is an opt-in documentation build, not part of Beam's fast
suite. The root `lake build BeamModel` remains the normal proof check.

The committed manifest pins the documentation dependencies. Use `lake update`
only when intentionally updating that lockfile. `lake exe vbp discover` reports
the generator and output paths.

Useful inspection commands after generation:

```sh
lake exe vbp query labels
lake exe vbp query node settlement-retains-custody
lake exe vbp query uses settlement-retains-custody
lake exe vbp query work-queue
```

Blueprint status reflects attached declarations and proofs, not proof of the
runtime adapter. Unproved bridges and environmental assumptions are explained in
prose; they are not registered as new axioms or completed theorem nodes.

## Toolchain and provenance

The documentation package pins Verso Blueprint at
`4943d3335ffa9221a39949e60836a8ad5dc2a456` and its matching Lean 4.35.0 toolchain.
Beam's root toolchain and runtime dependencies are unchanged. This package builds
the existing model files and pure production `DocumentAdmission` component from
relative source paths under the documentation compiler, into its own build tree.
It does not import the effectful broker. Root proof/test validation still uses
Beam's own selected compiler; a documentation build does not replace it.

The project skeleton was created with the Verso template initializer using the
`blueprint` template from `ejgallego/verso-templates`, branch
`feat/blueprint-template` at `cfa2a5ab58082cf95f98e47013ecf16460550103`.
When scaffolded on 2026-10-28, the upstream `leanprover/verso-templates` main
branch did not yet contain that template. The dependency was then updated to the pinned Blueprint release-line
commit above; arithmetic examples were replaced with Beam's narrative and source
associations. No template-specific source or build dependency remains.

When editing, preserve stable labels. Use `uses` for mathematical dependencies
and `bpref` for navigation. Keep proof-only dependencies on the proof block.
Rebuild after changing prose, associations, or dependency edges, and inspect the
relevant nodes. Semantic changes must also update the repository's implementation
correspondence where needed.

## Verso authoring conventions

- Give chapters and durable sections explicit `tag` metadata. Use `ref` for their
  links; do not construct URLs from rendered heading text.
- Define model vocabulary with `deftech` and use `tech` when the distinction
  matters. In particular, an event trace differs from a build trace, and a
  settlement claim differs from a publication claim.
- Use `bpref` for prose links to Blueprint nodes. These links must not introduce
  mathematical `uses` edges.
- Use `InlineLean.name` for compiler-checked names in prose. For executable
  examples use `InlineLean.lean -keep` with a name and `InlineLean.leanOutput` to
  check the result. The qualified directives distinguish examples from Blueprint's
  labeled Lean attachments. Examples call existing transitions; do not copy them.
- Keep example lines within Verso's default narrow-screen limit. Check the
  rendered table, code blocks, glossary links, and graph at desktop and phone sizes.

The three checked examples are finite schedules, not additional general theorems
or integration tests. They run as part of the opt-in Blueprint build. Ordinary
Beam CI coverage remains documented in the implementation correspondence.

The pinned renderer currently omits HTML fragment targets for page-level headings
(chapter titles and the generated graph/summary pages). Their page URLs work;
section, glossary, and Blueprint-node targets are present. Keep native references
rather than adding custom HTML to compensate for this renderer limitation.
