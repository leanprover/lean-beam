# Custom Lean targets

Use a custom target when developing Lean locally through an Elan link such as `lean4-stage0`
or `lean4-dev`. Custom targets are explicit installer inputs rather than validated release targets.
Canonical official RC and patch releases from `compatible-lean-release-lines` can use `--toolchain`.

## Install

Link the complete local Lean installation, then construct Beam for it:

```bash
elan toolchain link lean4-dev /path/to/lean/build/release/stage1
./scripts/install-beam.sh --custom-toolchain lean4-dev
```

Repeat `--toolchain` or `--custom-toolchain` to construct several targets in one standalone Beam
installation. The installer resolves each compiler installation once, builds its matching daemon
and plugin, qualifies the plugin, and copies the complete runtime into the staged installation.
The published manifest records the target relationships and the hashes of the installed files.
The target set and source provenance participate in the installation generation.
See [SETUP.md](SETUP.md) for installer locations and agent registration.

## Project selection

Set the project's `lean-toolchain` to the local link or an exact installed descriptor. Beam resolves
that local context and looks for the canonical Lean executable in its own installation's recorded
target set. An inherited `ELAN_TOOLCHAIN` does not retarget the project. A bundled Beam executable
has only its containing Lean installation as a target; see [TOOLCHAIN_BUNDLING.md](TOOLCHAIN_BUNDLING.md).

Normal execution never builds a missing target, searches another Beam installation, or invokes a
candidate compiler to decide whether to reject it. Missing targets require another installer run.
Floating channel names require an explicit local link or an exact project pin; Beam does not
resolve them over the network or reinterpret them as the newest locally installed release.

A workspace retains the runtime it accepted. Changing its selector to another installation rejects
further runtime use until that workspace is dropped and recreated. Another alias for the same
canonical Lean installation preserves the binding and its documents and handles.

## Updating a local Lean build

Treat the selected Lean installation and its matching Beam runtime as immutable during use. After
rebuilding Lean or relinking a target, rerun the installer and restart Beam owners and MCP clients.
Construction records the exact compiler revision and Lean/Lake descriptions, but a Git revision does
not distinguish every local modification or compiler configuration. Runtime admission trusts the
published installation record; it does not rehash arbitrary in-place changes on every request.

A changed target set produces another Beam generation. Switching the launcher's `current` link
affects future processes; an existing process remains bound to its concrete installation. Replacing
that process's own record requires a restart. The installer retains prior generations until explicit
pruning; stop their owners and clients before removing them.

## Diagnose selection

Run `lean-beam doctor` from the project. A present target reports its installation root, recorded
target, Lean executable, daemon, plugin, and generation. An unavailable target fails with setup
guidance without executing Elan or the candidate compiler. Session and recovery information is
printed before installation inspection, so a broken runtime does not hide recorded owner state.

## Stage0 smoke

With an existing `lean4-stage0` link, run:

```bash
bash tests/test-stage0-toolchain.sh
```

Set `BEAM_STAGE0_TOOLCHAIN=lean4-dev` to select another explicit construction target. The smoke
skips an unavailable link. Otherwise it constructs the custom runtime, checks recorded membership,
and starts and stops a foreground owner in an isolated installation.
