# Custom Toolchains And Runtime Bundles

Custom toolchains are for local Lean development workflows, especially using Beam against a Lean
source checkout through an elan-linked toolchain such as `lean4-stage0` or `lean4-dev`.

They are explicit opt-ins, not validated release targets. Canonical official RC and patch
toolchains from lines in `compatible-lean-release-lines` do not need this opt-in. Custom admission
accepts an explicitly named toolchain outside those policy registries, typically a linked name,
nightly, other vendor, or other noncanonical toolchain.

## Install

Link the local Lean build with elan, then install Beam with the same toolchain name:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

The installer records the name in the installed runtime's `custom-lean-toolchains` registry and
prebuilds an installed bundle for it. Runtime requests accept exact validated toolchains from
`validated-lean-toolchains`, canonical RC/patch variants from `compatible-lean-release-lines`, or
explicit custom names from the installed custom registry. General installer locations and
toolchain prebuild options are documented in
[SETUP.md](SETUP.md).

## Bundle Resolution

Standalone Beam resolves the project's `lean-toolchain` selector explicitly. The compiler executable
and bundle use the same observed Lean/Lake fingerprint, so an inherited `ELAN_TOOLCHAIN` does not
silently select a different compiler for the bundle. Bundled Beam uses its containing installation;
see the [installation comparison](TOOLCHAIN_BUNDLING.md).

When a project requests a Lean toolchain, Beam resolves helpers in this order:

1. an installed bundle cache under the Beam install state
2. a project-local runtime fallback under `.beam/bundles/`
3. failure for toolchains that are neither validated, release-line-compatible, nor explicitly custom

The installed bundle path avoids rebuilding inside each project. The fallback path exists so an
accepted toolchain can still run when no matching installed bundle is available, but it may need a
full `lake build` and network access on a cold machine.

## Bundle Identity

Bundle keys include all of these inputs:

- the requested toolchain name
- the resolved Lean/Lake fingerprint for that name
- the current platform
- the Beam runtime source hash

The resolved fingerprint records:

- `lean --version`
- `lean --print-prefix`
- `lean --print-libdir`
- `lake --version`

This is what makes custom toolchains safe enough for local Lean development: relinking the same elan
name to a different local build, or changing the reported Lean/Lake identity, produces a different
bundle key instead of silently reusing stale helpers.

The Beam source hash includes the runtime source tree plus `lean-toolchain`, `lake-manifest.json`,
`validated-lean-toolchains`, `compatible-lean-release-lines`, and `custom-lean-toolchains`. It
intentionally excludes the full `.lake/packages` checkout tree.

## Doctor Output

Use `lean-beam doctor` from the target project when bundle resolution is unclear. For a custom
toolchain installed correctly, the Lean doctor output should show:

```text
project toolchain admission: custom
project toolchain validated: false
project toolchain release line: (not applicable)
project toolchain accepted: true
bundle source: installed
bundle toolchain fingerprint: ...
```

For a rejected toolchain, doctor reports the rejection without resolving the toolchain fingerprint.
That keeps unsupported names from triggering arbitrary local elan resolution during diagnostics.

## Stage0 Smoke

Run the optional local stage0 check when a `lean4-stage0` elan toolchain is available:

```bash
bash tests/test-stage0-toolchain.sh
```

Set `BEAM_STAGE0_TOOLCHAIN` to use another local toolchain name:

```bash
BEAM_STAGE0_TOOLCHAIN=lean4-dev bash tests/test-stage0-toolchain.sh
```

The smoke skips when the requested elan toolchain is unavailable. When it runs, it installs Beam
with `--custom-toolchain`, checks that `doctor` resolves the installed bundle and reports a
fingerprint, then starts and closes an explicit `serve` wrapper session.
