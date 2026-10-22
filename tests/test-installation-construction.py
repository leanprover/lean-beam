#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Validate complete construction records through a non-shipped library fixture."""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
suffix = ".exe" if os.name == "nt" else ""
fixture = ROOT / ".lake/build/bin" / ("beam-installation-construction-test" + suffix)


def check_hardlinked_output():
    with tempfile.TemporaryDirectory(prefix="beam-staging-hardlink-") as temporary:
        directory = Path(temporary)
        cache = directory / "cache/artifacts/plugin"
        cache.parent.mkdir(parents=True)
        contents = bytes([0, 10, 13, 10, 26, 128, 255])
        cache.write_bytes(contents)
        source = directory / "build/plugin"
        source.parent.mkdir()
        os.link(cache, source)
        assert source.samefile(cache), (source, cache)
        assert source.stat().st_nlink == 2, (source, source.stat())
        staged = directory / "staged payload/runtimes/0/plugin"
        subprocess.run([fixture, "stage-output", source, staged], check=True, timeout=15)
        assert staged.read_bytes() == contents, staged
        assert not staged.samefile(source), (staged, source)
        assert staged.stat().st_nlink == 1, (staged, staged.stat())
        # A write to the staged copy must not change the build output or its cache alias.
        staged.write_bytes(b"changed staged output")
        assert source.read_bytes() == contents, source
        assert cache.read_bytes() == contents, cache
        assert source.samefile(cache), (source, cache)
        assert source.stat().st_nlink == 2, (source, source.stat())
    print("production staging preserves cache-linked inputs and creates an independent copy", flush=True)


def check(prefix, environment):
    with tempfile.TemporaryDirectory(prefix=prefix) as temporary:
        directory = Path(temporary)
        linked = directory / "linked-inventory"
        linked.mkdir()
        target = directory / "empty-link-target"
        target.mkdir()
        if os.name == "nt":
            subprocess.run(["cmd", "/d", "/c", "mklink", "/J", linked / "extra", target],
                           check=True, capture_output=True, timeout=15)
        else:
            (linked / "extra").symlink_to(target, target_is_directory=True)
        (directory / "existing-construction-dir/.construction").mkdir(parents=True)
        (directory / "existing-construction-dir/.construction/sentinel").write_text("owned elsewhere")
        (directory / "existing-construction-file").mkdir()
        (directory / "existing-construction-file/.construction").write_text("not a directory")
        if os.name != "nt":
            (directory / "existing-construction-target").mkdir()
            (directory / "existing-construction-target/sentinel").write_text("link target")
            (directory / "existing-construction-link").mkdir()
            (directory / "existing-construction-link/.construction").symlink_to(
                directory / "existing-construction-target", target_is_directory=True)
            toolchain_lib = directory / "toolchain/lib/lean/Init"
            toolchain_lib.mkdir(parents=True)
            (toolchain_lib / "Prelude.olean").write_text("toolchain bytes")
            link_parent = directory / "discarded-build/lake-home/.lake/build/lib/lean"
            link_parent.mkdir(parents=True)
            (link_parent / "Init").symlink_to(toolchain_lib, target_is_directory=True)
            (directory / "build-output").mkdir()
            (directory / "build-output/linked-plugin").symlink_to("plugin")
        subprocess.run([fixture, directory], env=environment, check=True, timeout=90)
        if os.name != "nt":
            assert (toolchain_lib / "Prelude.olean").read_text() == "toolchain bytes"
        installation = directory / "one-target"
        assert (installation / "payload.bin").read_bytes() == bytes([0, 10, 13, 10, 26, 128, 255])
        manifest = json.loads((installation / "manifest.json").read_text(encoding="utf-8"))
        expected = {"LICENSE", "libexec/beam-cli", "libexec/lean-beam-mcp", "payload.bin",
                    "runtimes/0/daemon", "runtimes/0/plugin", "runtimes/1/daemon", "runtimes/1/plugin"}
        assert {artifact["destination"] for artifact in manifest["artifacts"]} == expected
        for artifact in manifest["artifacts"]:
            assert artifact["source"] == artifact["destination"], artifact
            actual = hashlib.sha256((installation / artifact["destination"]).read_bytes()).hexdigest()
            assert actual == artifact["hash"], artifact


def selected_sdk(environment):
    compiler = environment.get("LEAN", "lean")
    if not os.path.dirname(compiler):
        # Windows subprocess lookup does not use PATH from the supplied environment.
        found = shutil.which(compiler, path=environment.get("PATH", os.defpath))
        if found is None:
            raise FileNotFoundError(f"compiler not found on PATH: {compiler!r}")
        compiler = found
    prefix = subprocess.check_output([compiler, "--print-prefix"], cwd=ROOT,
                                     env=environment, text=True).strip()
    assert prefix, "selected compiler returned no SDK prefix"
    return Path(prefix).resolve()


def check_selected_sdk(sdk):
    compiler = sdk / "bin" / ("lean" + suffix)
    environment = dict(os.environ, LEAN_SYSROOT=str(sdk),
                       PATH=str(sdk / "bin") + os.pathsep + os.environ["PATH"])
    environment.pop("LEAN", None)
    assert selected_sdk(environment) == sdk, "default selection ignored lean on PATH"
    assert selected_sdk(dict(environment, LEAN="lean" + suffix)) == sdk, \
        "explicit compiler name ignored PATH"
    with tempfile.TemporaryDirectory(prefix="beam-selected-sdk-") as temporary:
        directory = Path(temporary)
        ambient = directory / ("lean" + suffix)
        ambient.write_bytes(b"not a Lean executable\n")
        ambient.chmod(0o755)
        poisoned = dict(environment, PATH=str(directory) + os.pathsep + environment["PATH"])
        found = shutil.which("lean" + suffix, path=poisoned["PATH"])
        assert found and Path(found).resolve() == ambient.resolve(), (found, ambient)
        for rejected in [poisoned, dict(poisoned, LEAN="lean" + suffix)]:
            try:
                selected_sdk(rejected)
            except OSError:
                pass
            else:
                raise AssertionError("unusable PATH compiler fell back to another compiler")
        explicit = dict(poisoned, LEAN=str(compiler))
        assert selected_sdk(explicit) == sdk, "explicit selection consulted ambient lean"
        try:
            selected_sdk(dict(environment, LEAN=str(directory / ("missing-lean" + suffix))))
        except FileNotFoundError:
            pass
        else:
            raise AssertionError("missing explicit compiler fell back to lean on PATH")
    print("construction SDK selection honors explicit compilers without ambient fallback", flush=True)


def check_lake_environment(sdk):
    variables = ["LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_CC", "LEAN_AR", "LEAN_ABORT_ON_PANIC"]
    with tempfile.TemporaryDirectory(prefix="beam-construction-env-") as temporary:
        workspace = Path(temporary)
        library = "bin/fixture.lib" if os.name == "nt" else "lib/lean/fixture.lib"
        (workspace / "lakefile.lean").write_text(
            "import Lake\nopen Lake DSL\npackage construction_env\n" +
            "script beamSharedRuntimeFiles do\n" +
            f"  for key in {json.dumps(variables)} do\n" +
            "    if (← IO.getEnv key).isSome then throw <| IO.userError s!\"inherited {key}\"\n" +
            f"  IO.println {json.dumps(json.dumps([library]))}\n  return 0\n", encoding="utf-8")
        environment = dict(os.environ, **{key: "unrelated-build-override" for key in variables})
        subprocess.run([fixture, "lake-environment", sdk, workspace],
                       env=environment, check=True, timeout=60)
    print("standalone construction uses a clean selected-SDK environment", flush=True)


def check_installer_environment():
    if os.name == "nt":
        return  # The shell installer is qualified on POSIX; native Windows uses CMake.
    with tempfile.TemporaryDirectory(prefix="beam-frontend-env-") as temporary:
        directory = Path(temporary).resolve()
        sdk = directory / "SDK with spaces"
        (sdk / "bin").mkdir(parents=True)
        selected_sdk = directory / "SDK alias"
        selected_sdk.symlink_to(sdk, target_is_directory=True)
        commands = directory / "commands"
        commands.mkdir()
        (commands / "elan").write_text('#!/bin/sh\nprintf "%s\\n" "$BEAM_TEST_SELECTED_SDK"\n')
        (commands / "elan").chmod(0o755)
        (sdk / "bin/lake").write_text('''#!/bin/sh
set -eu
for key in LAKE_HOME LEAN_PATH LEAN_SRC_PATH LEAN_CC LEAN_AR LEAN_ABORT_ON_PANIC; do
  if env | grep -q "^$key="; then
    echo "frontend inherited $key" >&2
    exit 1
  fi
done
[ "$LEAN" = "$BEAM_TEST_SDK/bin/lean" ]
[ "$LEAN_SYSROOT" = "$BEAM_TEST_SDK" ]
[ "$1" = build ]
touch "$BEAM_TEST_ENV_OBSERVED"
''')
        (sdk / "bin/lake").chmod(0o755)
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           BEAM_TEST_SELECTED_SDK=str(selected_sdk), BEAM_TEST_SDK=str(sdk),
                           BEAM_TEST_ENV_OBSERVED=str(directory / "observed"))
        for key in ["LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_CC", "LEAN_AR", "LEAN_ABORT_ON_PANIC"]:
            environment[key] = "unrelated-frontend-override"
        result = subprocess.run(["bash", "-c", '''
source scripts/install-beam.sh
dont_ask=1
runtime_artifacts_ready() { test -f "$BEAM_TEST_ENV_OBSERVED"; }
ensure_runtime_artifacts
'''], cwd=ROOT, env=environment, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (directory / "observed").is_file()
    print("installer frontend uses a clean selected-SDK environment", flush=True)


check_hardlinked_output()
sdk = selected_sdk(os.environ)
check_selected_sdk(sdk)
check_lake_environment(sdk)
check_installer_environment()

if os.name == "nt":
    # Native Windows paths already contain backslashes. Use the real installed hash tool.
    check("beam construction-", os.environ.copy())
else:
    tools = [(name, shutil.which(name)) for name in ["sha256sum", "shasum"]]
    assert any(path for _, path in tools), "construction fixture needs a real checksum tool"
    for name, executable in tools:
        if executable is None:
            continue
        with tempfile.TemporaryDirectory(prefix="beam-checksum-tool-") as temporary:
            tool = Path(temporary) / name
            tool.symlink_to(executable)
            environment = dict(os.environ, PATH=temporary)
            for prefix in ["beam construction-", "beam construction-back\\slash-",
                           "beam construction-new\nline-"]:
                check(prefix, environment)
            print(f"construction raw-byte hashes and escaped filenames: {name} passed", flush=True)

    valid = "a" * 64
    for label, token, exit_code in [("empty", "", 0), ("short", "abc", 0), ("bad-hex", "g" * 64, 0),
                                    ("double-marker", "\\\\" + valid, 0), ("nonzero", valid, 7)]:
        with tempfile.TemporaryDirectory(prefix="beam-checksum-reject-") as temporary:
            directory = Path(temporary)
            tool = directory / "sha256sum"
            tool.write_text('#!/bin/sh\nif [ "${1-}" = --version ]; then exit 0; fi\n' +
                            "printf '%s\\n' " + shlex.quote(token + "  -") +
                            f"\nexit {exit_code}\n", encoding="utf-8")
            tool.chmod(0o755)
            result = subprocess.run([fixture, directory / "construction"],
                                    env=dict(os.environ, PATH=temporary),
                                    capture_output=True, text=True, encoding="utf-8", timeout=90)
            message = "SHA-256 command failed" if exit_code else "invalid SHA-256 digest"
            assert result.returncode != 0 and message in result.stderr, (label, result)
            assert not (directory / "construction/one-target/manifest.json").exists(), label
    print("construction malformed checksums and failed hash commands rejected", flush=True)
