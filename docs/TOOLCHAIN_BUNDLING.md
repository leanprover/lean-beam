# Bundling Beam with a native Lean installation

Release builders can compile Beam for one explicitly selected Lean installation without running the
standalone installer. This mode uses the containing installation's Lean, Lake, daemon, and plugin.
The standalone installer and its toolchain registries retain their existing behavior.
Windows x86_64 support covers this bundled runtime; the checkout installer and shell wrappers
target Linux and macOS.

The three installation models have different responsibilities:

| Installation | Lean selection | Beam runtime artifacts |
| --- | --- | --- |
| Regular Lean through elan | Elan's normal selection, including inherited overrides | Beam is provided separately unless the Lean distributor bundles it |
| Standalone Beam, from a checkout or its installer | The project's declared `lean-toolchain`, resolved explicitly | Managed installed bundles, with a qualified local build as fallback |
| Beam bundled with Lean | The containing Lean installation; a declared project selector must name that installation | The installed sibling executables and private plugin, with no fallback build |

The implementation calls the standalone strategy **managed**, and the bundled strategy **SDK**.
Here a Lean SDK means the complete Lean installation, including Lean, Lake, and their libraries.
Operating-system SDK headers used to compile native helpers are a separate build dependency.
This interface lets distributors opt into bundling Beam; an ordinary elan toolchain need not contain it.

For managed Beam, the compiler executable and bundle come from the same resolved toolchain
fingerprint. An inherited `ELAN_TOOLCHAIN` does not retarget either part of a project runtime.

Use CMake 3.21 or later from a Beam source checkout pinned to an immutable revision:

```sh
cmake -DLEAN_PREFIX="/path/to/selected/lean/stage" -P scripts/build-toolchain.cmake
cmake -DLEAN_PREFIX="/path/to/selected/lean/stage" -DPREFIX="/path/to/install/prefix" -P scripts/install-toolchain.cmake
```

The control-directory helper also needs native SDK headers: the Apple SDK selected by `xcrun` on macOS,
and a full clang SDK on `PATH` on Windows (the native CI uses MSYS2 clang64). Windows builders can
instead pass `-DNATIVE_CLANG_RESOURCE_DIR=/sdk/lib/clang/VERSION` to the build command. Beam compiles
with the selected Lean installation's compiler and links against its libraries.
`control_dir.c` uses this compiler and native header setup; its object-cache identity includes
the selected Lean toolchain and compiler.
The installed Windows runtime does not require MSYS2 or Git Bash on `PATH`. Elan is needed only
when resolving a project's `lean-toolchain` selector.

`LEAN_PREFIX` contains `bin/lean`, `bin/lake`, the compiler configuration, and Lean/Lake libraries.
It can be any native build stage or installed toolchain. The scripts do not select a stage number,
consult Beam's `lean-toolchain`, link an elan toolchain, download other runtimes, or modify agent
configuration. The exact Lean compiler commit embedded in Lake and Beam must match the selected
Lean executable. The build records the Beam source commit, and installation uses that recorded commit
rather than the checkout's current revision. The installer rejects payload artifacts changed after
the recorded toolchain build. Git metadata is needed only for the build.

Native configuration and outputs live separately under `.lake/toolchain-lakefile.lean` and
`.lake/toolchain-build`. A warmed standalone configuration or CLI is preserved; the native
scripts explicitly reconfigure their own Lake file for the requested build mode.

`PREFIX` is the destination Lean installation, with its corresponding Lean files installed by the
release builder. It may equal `LEAN_PREFIX`. Spaces are supported. The installed Beam files are:

- `bin/lean-beam`, `bin/beam-daemon`, and `bin/lean-beam-mcp` (with `.exe` on Windows)
- `lib/lean-beam/libbeam_Beam_LSP.so` on Linux,
  `lib/lean-beam/libbeam_Beam_LSP.dylib` on macOS, or
  `lib/lean-beam/beam_Beam_LSP.dll` on Windows
- `lib/lean-beam/LICENSE` and `lib/lean-beam/provenance.json`

The executables locate these files relative to themselves. The MCP server uses the sibling
`lean-beam` automatically and rejects runtime options selecting a different toolchain. Provenance
records the Beam source commit, a SHA-256 identity of the CLI, daemon, MCP server, and plugin payload,
and the selected Lean/Lake identities.
`lean-beam version` and `lean-beam --root PROJECT doctor` read this installed record. The payload
identity also participates in session configuration: replacing it requires stopping the old
foreground owner before attaching to a new session.

Toolchain mode ignores `BEAM_HOME`, `BEAM_INSTALL_BUNDLE_DIR`, and `BEAM_BUNDLE_DIR`. It neither
fetches Beam sources nor builds or selects standalone runtime bundles. Missing runtime files are
errors; reinstall the toolchain to repair them. Session and other state-location controls keep
their normal meaning.
Malformed provenance makes `version` and `doctor` fail. Doctor prints and flushes session and recovery
diagnostics before inspecting the runtime. Recorded-owner `stop` and `recover` remain available because
they use the saved session descriptor rather than resolving the current runtime.

Standalone runtime management commands (`bundle-install`, `prune`, `validated-toolchains`, and
`compatible-release-lines`) and standalone install metadata helpers are unavailable
in this mode. Use `version` or `doctor` for the
bundled identities, and the Lean toolchain's installer to update or repair its Beam payload.

For a project with `lean-toolchain`, the declared selector must resolve to the containing installation's
Lean executable. Inspect its prefix with `elan run SELECTOR lean --print-prefix`, using the file's contents for
`SELECTOR`. Project selectors take precedence over inherited `ELAN_TOOLCHAIN` settings.
Selectors require an existing elan toolchain link or installation.
Selector aliases and symlinks are compared by canonical path. A different
installation is rejected even if its version label is the same; use that installation's
`lean-beam`. A Lake project without a selector can use the directly invoked bundled executable
without elan. Project configuration and structured Lake `leanOptions` still load through Lake,
with the same exact compiler-ABI check before loading a workspace in-process.

Use `elan run SELECTOR lean-beam-mcp` to launch the MCP server with an explicit toolchain.
If launched through an elan proxy, the launch directory and elan overrides select the executable
when the server starts.
The running server remains bound to its containing Lean installation; later MCP requests do not
repeat elan's selection. It can serve multiple projects using that installation, but rejects projects
selecting a different installation. Start the matching toolchain's server for those projects. The checkout installer retains
its ability to serve projects using different toolchains from one MCP server.

The normal foreground owner and document-version contract applies:

```sh
lean-beam --root PROJECT serve
# In another process, after saving source edits:
lean-beam --root PROJECT update Demo.lean
lean-beam --root PROJECT run-at Demo.lean VERSION LINE CHARACTER -- 'trivial'
lean-beam --root PROJECT sync Demo.lean
lean-beam --root PROJECT save Demo.lean
lean-beam --root PROJECT stop
```

Coordinates are zero-based. Save is a checkpoint from the accepted language-server snapshot,
subject to [the save contract](SYNC_AND_DIAGNOSTICS.md). Lake module checkpoints include
`.ir.sig` and its metadata. `compiler.postponeCompile` requires Lake's separate `leanir` compilation
phase and is unsupported for zero-build save, including declarations deferred by a scoped option;
use `lake build` for that configuration.

Run the native build/install/relocation/runtime regression with:

```sh
python3 tests/test-native-toolchain.py /path/to/selected/lean/stage
```

CI runs this regression on Linux, macOS, and Windows x86_64 with the repository's pinned compiler.
See the [CI map](TESTING.md#ci-map) for platform matrices and Windows qualification details.
A release integration must also run this test against the actual compiler being shipped. Wasm, MCP
registration and skill installation are outside this build/install interface.

Runtime resolution is owned by the application installation adapters. The bundled adapter observes
provenance, compiler identity, and any declared project selector once for each resolution operation,
then applies a pure admission check. The managed adapter owns source and bundle-cache resolution.
Both supply complete runtime configurations to session and broker code; those components do not
interpret SDK directories, install manifests, or cache layouts.

The application selects an adapter at startup without resolving a project. Starting an owner first
validates the private control directory, then resolves its runtime. Attaching to a bundled-runtime owner
checks the current payload identity. Stopping or recovering a recorded owner does not require the
current runtime to resolve, so broken or replaced installation metadata cannot prevent cleanup.
