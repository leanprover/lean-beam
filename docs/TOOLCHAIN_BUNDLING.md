# Bundling Beam with a native Lean installation

This is the release-builder interface for including Beam in a Lean toolchain distribution,
including distributions installed through elan. Builders compile Beam for one explicitly selected
Lean installation; the resulting commands use that installation's Lean, Lake, daemon, and plugin.
Installing from a Beam checkout with `scripts/install-beam.sh` is the other installation path.
That installer can publish several explicitly selected target runtimes in one installation.

The two Beam installation paths have different responsibilities:

| Installation | Lean selection | Beam runtime artifacts |
| --- | --- | --- |
| Beam from a checkout | Local project target, looked up in the recorded set | Qualified runtimes copied into this installation before publication |
| Beam bundled with Lean | The containing Lean installation; a declared project selector must name that installation | The installed sibling executables and private plugin, with no fallback build |

Both strategies use the same membership lookup. The bundled strategy is also called **SDK**.
Here a Lean SDK means the complete Lean installation, including Lean, Lake, and their libraries.
Operating-system SDK headers used to compile native helpers are a separate build dependency.
This interface lets distributors opt into bundling Beam; an ordinary elan toolchain need not contain it.

## Build And Install

`LEAN_PREFIX` contains `bin/lean`, `bin/lake`, the compiler configuration, and Lean/Lake libraries.
It can be any native build stage or installed toolchain. The scripts do not select a stage number,
consult Beam's `lean-toolchain`, link an elan toolchain, download other runtimes, or modify agent
configuration. The compiler revision frozen into Beam during elaboration must agree with the loaded
Lean runtime and selected Lean executable. This revision check does not distinguish every local
modification or build configuration and is not a complete ABI fingerprint.

Use CMake 3.21 or later from a Beam source checkout pinned to an immutable revision:

```sh
cmake -DLEAN_PREFIX="/path/to/selected/lean/stage" -P scripts/build-toolchain.cmake
cmake -DLEAN_PREFIX="/path/to/selected/lean/stage" -DPREFIX="/path/to/install/prefix" -P scripts/install-toolchain.cmake
```

The native C helpers also need native SDK headers: the Apple SDK selected by `xcrun` on macOS,
and a full clang SDK on `PATH` on Windows (the native CI uses MSYS2 clang64). Windows builders can
instead pass `-DNATIVE_CLANG_RESOURCE_DIR=/sdk/lib/clang/VERSION` to the build command. In a Lean stage
build, take that directory from the full native compiler configured by Lean, using
`clang --print-resource-dir`. The resource directory supplies compiler headers; the Windows C runtime
and operating-system headers are a separate input. Supply their directories as a CMake list through
`-DNATIVE_SYSTEM_INCLUDE_DIRS="/sdk/clang64/include;/sdk/other/include"`. When these directories are
provided, native helper compilation disables Clang's default system include directories and searches
the explicit directories after the selected Clang resource headers.

Lean release integration should forward its configured native SDK paths to these arguments. Beam
continues to compile with the selected Lean installation's compiler and link against its libraries;
the headers are build inputs and do not enter the installed artifact inventory. Both native helpers'
object-cache identities include these compiler arguments and the selected Lean toolchain and compiler.
Direct developer Lake builds can supply the same include directories as a JSON string array in
`BEAM_NATIVE_SYSTEM_INCLUDE_DIRS`, alongside `BEAM_NATIVE_CLANG_RESOURCE_DIR`.
Lake resolves these SDK paths relative to its caller's working directory and canonicalizes them before
compilation and object-cache tracing. The build retains host header-search settings such as `CPATH`
and `C_INCLUDE_PATH`.

### Build Environment

Selected-SDK construction applies the following environment policy to its Lake invocations:

| Input | Policy |
| --- | --- |
| `LEAN`, `LEAN_SYSROOT` | Set from the captured SDK. The nonstandard development layout uses its private Lake home and clears `LEAN_SYSROOT`. |
| `LAKE_HOME`, `LEAN_PATH`, `LEAN_SRC_PATH`, `LEAN_CC`, `LEAN_AR`, `LEAN_ABORT_ON_PANIC` | Clear inherited values. The nonstandard layout explicitly supplies its private `LAKE_HOME`. |
| `LAKE_CACHE_DIR` | Native CMake builds use `.lake/toolchain-cache`; standalone construction inherits the caller's Lake cache choice. |
| `PATH`, native SDK and host compiler settings | Inherited build-host inputs. Windows CMake selects the clang resource directory before Lake changes `PATH`; macOS uses `xcrun`. |

The same filter applies to standalone frontend and target builds. Ordinary developer `lake build`
retains Lake's environment behavior. In particular, Lake can use host `CC`/`AR` when an SDK lacks
its packaged compiler/archiver; these differ from the cleared `LEAN_CC`/`LEAN_AR` overrides.
The standalone construction-cache key covers Beam source, platform, and the captured Lean SDK
fingerprint, and does not cover arbitrary host environment changes. Reusing it requires an unchanged
native SDK and host compiler configuration. Deliberately changing that configuration requires a fresh
source workspace and construction cache, with `LAKE_CACHE_DIR=` to avoid restoring prior Lake objects.

### Build Record And Staging

A successful build emits `.lake/toolchain-build.json`: the Beam source revision, a fresh build
generation, Lean/Lake descriptions, compiler revision, and one artifact inventory with content hashes.
The installer reads this data record, verifies every listed artifact before copying, and publishes the
same record as installed provenance. It validates the source compiler revision unconditionally and
also checks the destination compiler when present. Git metadata is needed only for the build.

Native configuration and outputs live separately under `.lake/toolchain-lakefile.lean` and
`.lake/toolchain-build`. A warmed standalone configuration or CLI is preserved; the native
scripts explicitly reconfigure their own Lake file for the requested build mode. This interface
supports one native build at a time per checkout; concurrent SDK builds require separate checkouts.

## Installed Files And Publication

`PREFIX` is the destination Lean installation, with its corresponding Lean files installed by the
release builder. It may equal `LEAN_PREFIX`. Spaces are supported. The installed Beam files are:

- `bin/lean-beam`, `bin/beam-daemon`, and `bin/lean-beam-mcp` (with `.exe` on Windows)
- `lib/lean-beam/libbeam_Beam_LSP.so` on Linux,
  `lib/lean-beam/libbeam_Beam_LSP.dylib` on macOS, or
  `lib/lean-beam/beam_Beam_LSP.dll` on Windows
- `lib/lean-beam/LICENSE` and `lib/lean-beam/provenance.json`

The executables locate these files relative to themselves. The bundled MCP application calls the SDK
resolver directly and rejects runtime options selecting a different toolchain. Provenance records the
Beam source and build generation, artifact inventory and SHA-256 payload identity, and selected
Lean/Lake identities.
`lean-beam version` and `lean-beam --root PROJECT doctor` read this installed record. The payload
identity also participates in session configuration: replacing it requires stopping the old
foreground owner before attaching to a new session.

Distributors must validate and publish a complete toolchain as an immutable unit. Runtime admission
trusts its published provenance; it does not rehash all installed files on every operation. Observable
generation changes invalidate reuse, but arbitrary in-place edits without a corresponding published
record are outside this contract. A running MCP server retains its original provenance generation and
cannot describe itself as a replacement generation after the record changes.

## Installation Records And Runtime Libraries

Explicit construction resolves each selected compiler installation once, then uses its exact Lean
and Lake paths for observation, building, and plugin qualification. It compares the constructed
daemon's frozen compiler revision with its loaded runtime and the selected compiler. Normal
execution performs local target lookup without repeating compiler discovery or provisioning.

Both installation manifests record their CLI/MCP companions and complete target relationships in
`components`, referencing one hashed `artifacts` inventory. A native manifest has schema version 3
and one target. A standalone manifest has schema version 4 and one or more installer-selected targets.
Each target names its Lean executable, matching daemon/Lake helper and plugin, and construction-time
compiler identity. Unreferenced files do not add targets. Missing members, duplicate destinations,
duplicate targets, and component paths outside the installation prevent publication.
Component roles refer exactly to inventory destinations; case-folding only detects collisions.
Inventory names use a conservative portable spelling: ASCII controls, Windows reserved device names,
forbidden characters, and trailing dots/spaces are rejected on every platform. Native filesystem admission
must still establish canonical membership; spelling checks do not establish filesystem identity.
See [Windows naming rules](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file).

The standalone installer copies qualified target executables and plugins into `runtimes/` inside
the staged version. Each target has its own `bin/beam-daemon` and Lean/Lake shared libraries under
`lib/lean` (alongside the daemon in `bin` on Windows). Frontends use a separate library set under
the installation's `lib/lean` (`libexec` on Windows). Construction obtains these files from Lake's
declared SDK dependency list; finding an unrelated library in a directory cannot add a dependency.
The executable loader paths are relative to each component's own directory.

The installer records all staged files in the existing artifact inventory, hashes the complete record with its generation field
blank, and publishes only after every target is ready. Target membership and source provenance
therefore participate in the generation. Reusing a generation validates and retains its record;
the installer never refreshes a published manifest in place. A failed construction leaves `current`
unchanged. Each launcher link is published with a same-filesystem rename, preserving its old target
if replacement fails. The shared cache remains a mutable construction input, separate from those copied artifacts.
Its successful record binds the daemon, plugin, and every declared shared library to hashes captured
before qualification and verified afterward. Reuse checks that complete record. Staging checks its
copies against the qualified hashes and executes only the staged daemon. Invalid cache entries are
rejected before publication; hashing arbitrary replacement bytes into a new manifest is not admission.

Native installation copies Beam's contribution into staging. An empty destination need not yet
contain Lean; the record alone therefore does not establish a usable complete toolchain. The
distributor must assemble and validate the containing Lean SDK before publishing the unit. Runtime
admission must require the recorded Lean executable as well as Beam's components.
Native Beam executables link against that SDK's shared Lean/Lake libraries; Beam's contribution
does not duplicate the containing SDK's library inventory.

### Payload Identity

The two published formats retain the wire field `payloadHash` with distinct scopes:

| Format | Digest input | Installation generation |
| --- | --- | --- |
| Native schema 3 | An object containing exactly `artifacts` and `components` | Embedded `buildId` together with this payload digest |
| Standalone schema 4 | The complete typed installation record, with `payloadHash` replaced by the empty string | This installation-record digest |

Both digests use SHA-256. Native construction creates the input object with CMake's
`string(JSON ... SET)` operations, adding `artifacts` then `components`, and hashes that UTF-8
string without a trailing newline. Standalone construction encodes `InstallManifest` with Lean's
`ToJson`, renders it with `Json.pretty`, and hashes the UTF-8 result followed by one LF byte.
Inventory and target array order participates in both encodings. The
[fixed digest fixtures](../tests/fixtures/installation-digests.json) contain Unicode and escaped
descriptions and pin the expected values separately; the formats do not share a canonical JSON encoding.

Changing native source provenance or build generation alone does not change its payload digest.
Admission checks those fields independently against the executable's frozen identity, and a fresh
native build receives a new embedded `buildId`. Standalone source provenance and schema version
participate in its installation-record digest. Changing a serializer can therefore change a digest
even when the component bytes remain identical. The construction-cache record is separate from
both published formats: its qualification and workspace data do not become installation identity.

## Runtime Selection And Maintenance

Toolchain mode ignores `BEAM_HOME`, `BEAM_INSTALL_BUNDLE_DIR`, and `BEAM_BUNDLE_DIR`. It neither
fetches Beam sources nor builds or selects standalone runtime bundles. Missing runtime files are
errors; reinstall the toolchain to repair them. Session and other state-location controls keep
their normal meaning.
Malformed provenance makes `version` and `doctor` fail. Doctor prints and flushes session and recovery
diagnostics before inspecting the runtime. Recorded-owner `stop` and `recover` remain available because
the owning installation uses its saved session descriptor rather than resolving the current runtime.
An independent installation cannot stop or recover that owner, even when its bytes are identical.
Keep the original installation until its owners stop; changing a launcher’s `current` pointer retains
those concrete old versions. Opaque descriptors cannot establish ownership and require operator
archival after independently stopping their owner; there is no force form.

Bundled installations expose no standalone pruning or construction commands. Runtime construction
and toolchain policy are installer responsibilities; shipped CLI and MCP entry points do not accept
arbitrary component/provider options. Use `version` or `doctor` for recorded identity, and the
containing Lean toolchain's installer to update or repair its Beam payload.

For a project with `lean-toolchain`, the declared selector must resolve to the containing installation's
Lean executable. Beam resolves existing local paths, exact installed elan entries, and local
toolchain links without invoking elan or a candidate compiler. Project selectors take precedence
over inherited `ELAN_TOOLCHAIN` settings. Unlinked floating selectors require an exact local pin or
an explicit local link; normal execution does not perform remote resolution.
Selector aliases and symlinks are compared by canonical path. A different
installation is rejected even if its version label is the same; use that installation's
`lean-beam`. A Lake project without a selector can use the directly invoked bundled executable
without elan. Project configuration and structured Lake `leanOptions` still load through Lake,
with compiler-revision agreement checked before loading a workspace in-process.

Use `elan run SELECTOR lean-beam-mcp` to launch the MCP server with an explicit toolchain.
If launched through an elan proxy, the launch directory and elan overrides select the executable
when the server starts.
The running server remains bound to its containing Lean installation. Every Lean operation, including
reuse of an initialized workspace, checks the current project selector and published generation
without building or selecting a fallback runtime. A selector naming an unavailable or foreign
installation, or a changed generation, rejects the operation; drop the workspace or restart the
matching toolchain's server as directed by the error. Aliases of the same installation remain valid.
It never silently retargets open documents or handles. Standalone MCP applies the same reuse policy
and can serve projects using different recorded targets from one server. Its process identity also
retains the installation record observed at startup.

Follow the [user setup guide](SETUP.md#use-beam-bundled-with-lean) for launch commands and
[the common CLI workflow](SETUP.md#use-beam-from-a-lean-project) for session ownership and
document-version handling. Save behavior and unsupported batch compilation options are defined
in [the sync and save contract](SYNC_AND_DIAGNOSTICS.md).

### Runtime Admission

Runtime membership is owned by the application installation adapters. Both supply
[one typed runtime description](../Beam/Runtime.lean) to session and broker code; execution does not
interpret SDK directories, installation manifests, or construction caches. Every shipped entry
point derives its binding from its concrete executable location. Daemons independently validate
configuration hashes; helper and workspace-init requests cannot supply replacement component paths.

Startup captures the installation record without requiring a usable project runtime. Owner creation
validates the private control directory before admitting its target. Reuse compares the retained
binding and workspace instance before dispatch. Local admission observes cancellation; the obsolete
external CLI, compiler, and Elan discovery probes have been removed.

| Operation | Runtime effects |
| --- | --- |
| Help and protocol discovery | No target provisioning or required successful admission |
| Owner or workspace creation | Exact local lookup in the complete recorded component set |
| Workspace reuse | Read-only admission and retained identity comparison |
| Stop and recover | Matching concrete installation and recorded ownership; no current runtime admission |
| Drop | Retained workspace ownership; no current runtime admission |

## Release Qualification

Run the native build/install/relocation/runtime regression with:

```sh
python3 tests/test-native-toolchain.py /path/to/selected/lean/stage
```

The `native-toolchain` CI job exercises Linux x86_64/aarch64 and Windows layouts with the
repository's supported compiler. The combined `macos-platform` job also runs this test on macOS.
Setting `BEAM_FULL_MACOS_CI=true` enables separate macOS x86_64/aarch64 native jobs instead;
see [the CI layout](TESTING.md#ci-map).
The [nightly workflow](../.github/workflows/nightly.yml) selects a dated nightly SDK and invokes this
same command; see [native qualification evidence](TESTING.md#native-toolchain-qualification)
for reports and retained diagnostics.
A release integration must also run this test against the actual compiler being shipped. Wasm, MCP
registration and skill installation are outside this build/install interface.

Version and doctor may read provenance and fail when it is malformed. Release qualification must
also run the actual unpacked distribution with original build/SDK paths unavailable; a relocation
smoke test with libraries symlinked to the original installation does not establish artifact closure.
