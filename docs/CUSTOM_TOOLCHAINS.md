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

Repeat `--toolchain` or `--custom-toolchain` in **one installer invocation** to construct several
targets in one standalone Beam installation. Each run selects the complete target set for the new
installation; it does not merge with the previous selection or automatically retain the repo-pinned
target. Include every target you want to retain when reinstalling.

The installer resolves each compiler installation once, builds its matching daemon
and plugin, qualifies the plugin, and copies the complete runtime into the staged installation.
The published manifest records the target relationships and the hashes of the installed files.
The target set and source provenance participate in the installation generation.
See [SETUP.md](SETUP.md) for installer locations and agent registration.

The standalone installer copies Beam's runtime components, not the complete selected Lean SDK.
Its record retains the canonical path to that SDK's Lean executable. Keep the selected development
SDK available and unchanged for every Beam generation that uses it; deleting a review or build
directory can invalidate the target even though Beam's own files are still installed. Before
removing or replacing that SDK, stop its CLI owners and drop its MCP workspaces, establishing completed
cleanup. Construct a new Beam generation for the replacement target and restart clients afterward.
Bundled release packages instead include their containing Lean SDK and are qualified as that unit.

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
guidance without executing Elan or the candidate compiler. If installation inspection fails,
session and recovery information remains in the error response's `error.data.diagnostics` field.

A Lean source checkout may select a relative SDK path such as `build/release/stage1`. If doctor
reports that the compiler was found but this Beam installation has no runtime for it, the SDK exists
and needs a matching Beam runtime. Follow the custom-target installation steps above using that
SDK. Beam matches canonical compiler paths, so the existing relative project selector can stay in
place.

## Layout qualification

The POSIX fast suite runs `tests/test-nonstandard-toolchain.py` with the selected installed SDK.
It puts Lake modules in a distinct library directory, requires the ordinary Lake invocation to
fail, then builds a small target through the production construction adapter, stages its outputs,
and qualifies the staged plugin. It also checks that discarding the build directory leaves the SDK's
linked modules untouched. This regression qualifies
the layout adapter; a complete stage0 compiler build still needs the smoke below. Nonstandard
standalone SDK layouts remain unsupported on Windows.

## Stage0 smoke

With an existing `lean4-stage0` link, run:

```bash
bash tests/test-stage0-toolchain.sh
```

Set `BEAM_STAGE0_TOOLCHAIN=lean4-dev` to select another explicit construction target. The smoke
skips an unavailable link. Otherwise it constructs the custom runtime, checks recorded membership,
and starts and stops a foreground owner in an isolated installation.
