# Compatibility Policy

Lean Beam is beta software. Preserve compatibility only for named external or versioned targets; do
not keep payload shapes, aliases, command spellings, permissive decoders, or harness behavior for
hypothetical clients.

## Current Targets

The [native toolchain build/install interface](TOOLCHAIN_BUNDLING.md) also targets an explicitly
supplied native Lean installation, including development compilers, when its build and runtime
regression passes. The standalone toolchain registries below govern the standalone install path.

A Lean release line is the canonical `major.minor` family recorded in
`compatible-lean-release-lines`. An exact toolchain variant is a canonical immutable
`major.minor.patch` or `major.minor.patch-rcN` name within that family.

- The core product goal is still the small Lean request shaped like `runAt(pos, "lean text")`,
  with typed request and response data.
- The supported Lean release window is 4.33–4.35. Lean 4.28–4.32, including their RC and patch
  variants, are no longer admitted by the validated-toolchain or compatible-release-line registries.
- Exact CI-validated Lean toolchains listed in `validated-lean-toolchains`: the latest stable point
  release of each supported line. Linux runs the exact compatibility matrix; macOS runs it in full
  mode, while combined mode qualifies the repository-pinned version. Installer tests prebuild every
  validated toolchain in both modes. See the [CI map](TESTING.md#ci-map).
  CI does not build RCs or superseded stable points. Canonical RC and patch toolchains remain admitted by release lines in
  `compatible-lean-release-lines`. Release-line variants must build and pass the local plugin
  qualification probe for their exact fingerprint.
  Shims must name the Lean/Lake API boundary they support and should be removed when the support
  window no longer needs them.
- Lean nightly toolchain distributions, qualified separately on Linux by
  [Lean Nightly](../.github/workflows/nightly.yml) through the native build/install interface.
  Each run pins one dated SDK;
  `leanprover/lean4-nightly:nightly-2026-10-13` is the initial source-build target for Lake's optional
  `ModuleOutputDescrs.c?` descriptor. Standalone installations require explicit custom-toolchain
  admission for nightly toolchains; native builds use their supplied SDK directly. Nightlies are
  not added to the validated release registry.
- Module saves publish the `.ir.sig` companion and its Lake output descriptor on every supported
  toolchain. The internal module-save request requires an IR signature output path. Save traces
  use Lake's full `ModulePreSetup.trace` directly.
- Runtime bundle metadata schema 2 and install manifest schema 3. Install manifest schema 2 is
  cleanup-only compatibility during the 0.2 release line: identity and `lean-beam prune` may read it,
  but the installer does not reuse it. Remove the schema-2 decoder when 0.3 development opens.
- CLI session descriptor schema 4. It freezes one workspace binding plus one
  generation identity, lifecycle, endpoint, and capability. Workspace bindings require a Lean
  command, plugin, toolchain, and bundle identity. Descriptors and their workspace bindings reject
  undeclared fields, including removed Rocq configuration. Schema-less, schema-1, the superseded
  schema-2 multi-binding shape, schema 3 with its obsolete client-executable and
  caller-selected-port fields, and unknown records are reported and remain fenced;
  normal startup does not decode, delete, or migrate them.
  After independently stopping the generation that wrote an opaque record, an operator may
  quarantine it with `lean-beam --root ROOT recover --force`. Current descriptors instead require
  their exact generation ID. Persisted PIDs are never recovery signal capabilities.
- MCP `2026-07-28` is the preferred stdio protocol revision. MCP `2025-11-25` remains a named
  transition target for initialization-based clients. Reconsider the legacy path before the 0.3
  release once the clients named by the setup guide can all use per-request metadata.
- Codex CLI `0.147.0` is the validated target for the client-specific
  `mcp_servers.lean-beam.supports_parallel_tool_calls = true` adapter owned by
  `scripts/install-mcp.sh`. Remove the adapter once the supported Codex client infers safe
  concurrency from MCP tool annotations or otherwise no longer requires the setting.
- Documented real client requirements, when they name an owner and removal condition.

## Change Rule

CLI and MCP command/tool surfaces are discoverable from the installed skill file, help text, and MCP
`tools/list` schemas. During beta, discovery is the compatibility story for those surfaces. The
local broker JSON stream is an implementation boundary, and maintainer harness scripts are local
contributor tooling. LSP compatibility is not a release target until after beta.

If a compatibility branch, deprecated field, alias, or permissive decoder cannot name one of the
current targets above, remove it and update docs/tests to the current typed contract.

## Beta Deprecations

Beta deprecations should be short and explicit: document the replacement and removal trigger in the
same change. Otherwise, treat the surface as current behavior, not compatibility policy.
