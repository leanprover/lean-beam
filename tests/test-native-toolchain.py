#!/usr/bin/env python3
"""Build, relocate, and exercise a toolchain-only Beam payload (no standalone installer)."""

import argparse
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


REPO = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
watchdog_spec = importlib.util.spec_from_file_location(
    "process_watchdog", REPO / "tests/lib/process_watchdog.py")
watchdog = importlib.util.module_from_spec(watchdog_spec)
watchdog_spec.loader.exec_module(watchdog)


def run(args, *, cwd=REPO, env=None, ok=True):
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            text=True, encoding="utf-8", capture_output=True, timeout=600)
    if ok and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def self_check(mcp, source, *, cwd, env):
    command = [str(mcp), "--self-check", str(source)]
    timeout = float(os.environ.get("BEAM_MCP_SELF_CHECK_WATCHDOG_SECONDS", "600"))
    try:
        result = watchdog.run_with_watchdog(command, timeout=timeout, cwd=cwd, env=env)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f"{command}: external watchdog expired\n{error.stdout}\n{error.stderr}") from error
    assert result.returncode == 0, result
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lean_prefix", type=Path)
    parser.add_argument("--scratch", type=Path, default=REPO / ".native-test")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true", help="check native/standalone build isolation only")
    parser.add_argument("--crlf", action="store_true", help="exercise Windows line endings on any host")
    parser.add_argument("--previous-lean-prefix", type=Path,
                        help="qualify compiler switching through the same native object cache")
    args = parser.parse_args()
    lean_prefix = args.lean_prefix.resolve()
    real_elan = shutil.which("elan")
    args.scratch.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="toolchain-", dir=args.scratch.resolve()))
    print(f"native toolchain test scratch: {scratch}", flush=True)
    management_commands = ["prune", "validated-toolchains", "compatible-release-lines"]
    build_commit = None
    if not args.skip_build:
        build_commit = run(["git", "rev-parse", "HEAD"]).stdout.strip()
        build_env = os.environ.copy()
        for key in ["LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH", "LEAN_CC", "LEAN_AR"]:
            build_env.pop(key, None)
        build_env.update(LEAN=str(lean_prefix / "bin" / f"lean{EXE}"),
                         LEAN_SYSROOT=str(lean_prefix),
                         LAKE_CACHE_DIR=str(REPO / ".lake" / "toolchain-cache"))
        if os.name == "nt":
            # Resolve the full native SDK before Lake prepends the packaged compiler to PATH.
            build_env["BEAM_NATIVE_CLANG_RESOURCE_DIR"] = run(
                ["clang", "--print-resource-dir"], env=build_env).stdout.strip()
        # Lake preserves configuration options in its cached lakefile. Warm the ordinary
        # configuration and CLI first, then prove the native builder uses its requested mode
        # without replacing that CLI or changing the ordinary configuration.
        run([lean_prefix / "bin" / f"lake{EXE}", "--reconfigure", "-KbeamToolchain=false",
             "--no-cache", "build", "beam-cli", "beam-mcp-protocol-test"], env=build_env)
        # Exercise the same typed self-check fixtures with the native SDK's header/DLL environment.
        run([sys.executable, REPO / "tests/lib/process_watchdog.py", "--timeout", "90", "--",
             REPO / ".lake/build/bin" / f"beam-mcp-protocol-test{EXE}", "--self-check-tests"],
            env=build_env)
        standalone = REPO / ".lake" / "build" / "bin" / f"beam-cli{EXE}"
        standalone_hash = hashlib.sha256(standalone.read_bytes()).hexdigest()
        configs = [REPO / ".lake" / "lakefile.olean.trace",
                   REPO / ".lake" / "config" / "0" / "lakefile.olean.trace"]
        config_before = {path: path.read_bytes() for path in configs if path.exists()}
        assert config_before, "standalone Lake configuration trace was not written"
        def control_dir_object_trace():
            path = REPO / ".lake/toolchain-build/native/control_dir.o.trace"
            return json.loads(path.read_text())["depHash"]

        first_native_trace = None
        if args.previous_lean_prefix:
            for selected in [lean_prefix, args.previous_lean_prefix.resolve()]:
                run(["cmake", f"-DLEAN_PREFIX={selected}", "-P", "scripts/build-toolchain.cmake"])
                trace = control_dir_object_trace()
                if first_native_trace is None:
                    first_native_trace = trace
                else:
                    assert trace != first_native_trace, trace
        run(["cmake", f"-DLEAN_PREFIX={lean_prefix}", "-P", "scripts/build-toolchain.cmake"])
        final_native_trace = control_dir_object_trace()
        if first_native_trace is not None:
            assert final_native_trace == first_native_trace, final_native_trace
        assert hashlib.sha256(standalone.read_bytes()).hexdigest() == standalone_hash
        assert all(path.read_bytes() == content for path, content in config_before.items())
        ordinary = run([standalone, "toolchain-build-info"], ok=False)
        assert ordinary.returncode != 0 and "not built with -KbeamToolchain=true" in ordinary.stderr, ordinary
        ordinary_help = run([standalone, "--help"]).stdout
        assert all(f"  lean-beam {command}" in ordinary_help for command in management_commands), ordinary_help
    if args.build_only:
        assert not args.skip_build, "--build-only requires an actual build"
        print("native toolchain build/standalone isolation checks passed", flush=True)
        return
    prefix = scratch / "installed"
    # Hard links keep this test cheap while retaining a complete, relocatable Lean installation.
    # No hard-linked file is edited; Beam artifacts are copied by the installer.
    def copy_file(src, dest):
        try:
            return os.link(src, dest)
        except OSError as err:
            if err.errno not in [errno.EXDEV, errno.EPERM] and os.name != "nt":
                raise
            return shutil.copy2(src, dest)

    prefix.mkdir()
    # Native consumer builds also need the compiler's shared libraries and sysroot
    # archives outside lib/lean. Preserve the whole toolchain library layout.
    for directory in ["bin", "lib", "include", "share"]:
        if (lean_prefix / directory).is_dir():
            shutil.copytree(lean_prefix / directory, prefix / directory,
                            copy_function=copy_file, symlinks=True,
                            ignore=shutil.ignore_patterns("cache", "lean-beam", f"lean-beam{EXE}",
                                                         f"beam-daemon{EXE}", f"lean-beam-mcp{EXE}"))
    # Installation must use build-time provenance even without the build checkout's Git metadata.
    install_source = scratch / "install-source"
    for relative in ["scripts/install-toolchain.cmake", "LICENSE", ".lake/toolchain-build.cmake"]:
        destination = install_source / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, destination)
    plugin = ("beam_Beam_LSP.dll" if os.name == "nt" else
              "libbeam_Beam_LSP.dylib" if sys.platform == "darwin" else "libbeam_Beam_LSP.so")
    for relative in [f"bin/beam-cli{EXE}", f"bin/beam-daemon{EXE}",
                     f"bin/lean-beam-mcp{EXE}", f"lib/{plugin}"]:
        destination = install_source / ".lake" / "toolchain-build" / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy_file(REPO / ".lake" / "toolchain-build" / relative, destination)
    # Prevent Git from finding the enclosing repo when scratch lives under REPO.
    install_env = dict(os.environ, GIT_CEILING_DIRECTORIES=str(scratch))
    run(["cmake", f"-DLEAN_PREFIX={lean_prefix}", f"-DPREFIX={prefix}",
         "-P", install_source / "scripts" / "install-toolchain.cmake"], env=install_env)
    relocated = scratch / "relocated toolchain with spaces"
    prefix.rename(relocated)
    beam = relocated / "bin" / f"lean-beam{EXE}"
    lake = relocated / "bin" / f"lake{EXE}"
    private = relocated / "lib" / "lean-beam"
    provenance = private / "provenance.json"
    metadata = json.loads(provenance.read_text())
    assert metadata["payloadHash"] and metadata["leanVersion"]
    if build_commit is not None:
        assert metadata["sourceCommit"] == build_commit, metadata
    env = os.environ.copy()
    for key in ["LEAN", "LEAN_SYSROOT", "LAKE_HOME", "LEAN_PATH", "LEAN_SRC_PATH"]:
        env.pop(key, None)
    home = scratch / "home"
    home.mkdir()
    env.update(HOME=str(home), USERPROFILE=str(home), CODEX_HOME=str(home / "codex"),
               CLAUDE_HOME=str(home / "claude"), LAKE_ARTIFACT_CACHE="false",
               BEAM_HOME=str(scratch / "forbidden-source"),
               BEAM_INSTALL_BUNDLE_DIR=str(scratch / "forbidden-install-cache"),
               BEAM_BUNDLE_DIR=str(scratch / "forbidden-runtime-cache"),
               BEAM_PUBLIC_COMMAND="ambient-wrong-name")
    version = run([beam, "version"], cwd=scratch, env=env).stdout
    assert version.startswith("lean-beam "), version
    assert metadata["payloadHash"] in version and metadata["leanVersion"] in version, version
    mcp = relocated / "bin" / f"lean-beam-mcp{EXE}"
    mcp_version = run([mcp, "--version"], cwd=scratch, env=env).stdout
    assert "lean-beam-mcp" in mcp_version and metadata["payloadHash"] in mcp_version, mcp_version
    foreign_cli = run([mcp, "--beam-cli", lean_prefix / "bin" / f"lean{EXE}", "--version"],
                      cwd=scratch, env=env, ok=False)
    assert foreign_cli.returncode != 0 and "containing toolchain" in foreign_cli.stderr, foreign_cli
    project = scratch / "project with spaces"
    project.mkdir()
    config = 'name = "native_test"\n[leanOptions]\nmaxRecDepth = 777\n[[lean_lib]]\nname = "Demo"\n'
    config += '[[lean_exe]]\nname = "nativeCheck"\nroot = "NativeCheck"\n'
    (project / "lakefile.toml").write_text(config)
    source = project / "Demo.lean"
    (project / "Demo").mkdir()
    (project / "Demo" / "Dep.lean").write_text("module\npublic def base : Nat := 7\n")
    text = ("module\npublic import Lean\npublic import Demo.Dep\n\nopen Lean Elab Command\n"
            'elab "#configured" : command => do\n'
            '  unless maxRecDepth.get (← getOptions) == 777 do throwError "missing structured Lake option"\n'
            "#configured\n\n@[noinline] public def value : Nat := 1\n\nexample : True := by\n  trivial\n")
    tactic_line = str(text.splitlines().index("  trivial"))
    if args.crlf:
        text = text.replace("\n", "\r\n")
    source.write_text(text, encoding="utf-8", newline="")
    # This project has no selector, and elan must not be used to locate sibling Lean/Lake.
    shim = scratch / "shim"
    shim.mkdir()
    if os.name != "nt":
        elan = shim / "elan"
        elan.write_text('#!/bin/sh\necho "unexpected elan invocation" >&2\nexit 99\n')
        elan.chmod(0o755)
    if os.name != "nt":
        for forbidden_command in ["git", "curl", "date"]:
            trap = shim / forbidden_command
            trap.write_text(f'#!/bin/sh\necho "unexpected {forbidden_command} invocation" >&2\nexit 99\n')
            trap.chmod(0o755)
    env["PATH"] = str(shim) + os.pathsep + str(relocated / "bin") + os.pathsep + env["PATH"]
    doctor = run([beam, "--root", project, "doctor"], env=env).stdout
    assert "bundle source: toolchain" in doctor and metadata["payloadHash"] in doctor, doctor
    native_help = run([beam, "--help"], env=env).stdout
    invalid_command = run([beam, "unknown-command"], env=env, ok=False)
    assert invalid_command.returncode != 0, invalid_command
    for help_text in [native_help, invalid_command.stderr]:
        assert "lean-beam [--root PATH] run-at " in help_text, help_text
        assert all(f"  lean-beam {command}" not in help_text for command in management_commands), help_text
    mcp_config = json.loads(run([beam, "--root", project, "mcp-config"], env=env).stdout)
    assert metadata["payloadHash"] in mcp_config["bundle_id"], mcp_config
    for standalone_command in ["install-layout", *management_commands, "bundle-install"]:
        rejected = run([beam, "--root", project, standalone_command,
                        *(["unused-toolchain"] if standalone_command == "bundle-install" else [])],
                       env=env, ok=False)
        assert rejected.returncode != 0 and "bundled lean-beam" in rejected.stderr, rejected
    run([lake, "--no-cache", "build", "Demo"], cwd=project, env=env)

    def call(*args, ok=True):
        return run([beam, "--root", project, *args], env=env, ok=ok)

    owner_log = scratch / "owner.log"
    with owner_log.open("w") as log:
        owner = subprocess.Popen([str(beam), "--root", str(project), "serve"],
                                 cwd=project, env=env, stdout=log, stderr=log)
        try:
            for _ in range(600):
                if "serving Beam session" in owner_log.read_text():
                    break
                assert owner.poll() is None, owner_log.read_text()
                time.sleep(0.1)
            else:
                raise AssertionError(owner_log.read_text())
            updated = json.loads(call("update", "Demo.lean").stdout)
            version = updated["result"]["version"]
            probe = json.loads(call("run-at", "Demo.lean", str(version), tactic_line, "2", "trivial").stdout)
            assert probe["ok"], probe
            # Close before applying a source edit, then update the broker to the new saved text.
            call("close", "Demo.lean")
            source.write_text(text.replace(":= 1", ":= 2"), encoding="utf-8", newline="")
            edited = json.loads(call("update", "Demo.lean").stdout)
            stale = call("run-at", "Demo.lean", str(edited["result"]["version"] + 1), tactic_line, "2", "trivial", ok=False)
            assert stale.returncode != 0, stale
            probe = json.loads(call("run-at", "Demo.lean", str(edited["result"]["version"]),
                                    tactic_line, "2", "trivial").stdout)
            assert probe["ok"], probe
            synced = json.loads(call("sync", "Demo.lean").stdout)
            assert synced["ok"], synced
            saved = json.loads(call("save", "Demo.lean").stdout)
            assert saved["ok"], saved
            arts = project / ".lake" / "build"
            trace = json.loads((arts / "lib" / "lean" / "Demo.trace").read_text())
            ir_sig = Path(saved["result"]["irSig"])
            assert ir_sig.is_file(), saved
            assert ir_sig.parent == arts / "lib" / "lean", saved
            assert trace["outputs"]["rs"].endswith(".ir.sig"), trace
            assert trace["outputs"]["c"].endswith(".c"), trace
            replay = run([lake, "--no-cache", "-v", "build", "Demo"], cwd=project, env=env)
            assert "Replayed Demo" in replay.stdout + replay.stderr, replay
            assert "Built Demo" not in replay.stdout + replay.stderr, replay
            (project / "Check.lean").write_text("import Demo\n#eval value\n")
            imported = run([lake, "env", "lean", "Check.lean"], cwd=project, env=env)
            assert imported.stdout.strip() == "2", imported
            (project / "NativeCheck.lean").write_text("import Demo\ndef main : IO Unit := IO.println value\n")
            run([lake, "--no-cache", "build", "nativeCheck"], cwd=project, env=env)
            native = run([project / ".lake" / "build" / "bin" / f"nativeCheck{EXE}"], cwd=project, env=env)
            assert native.stdout.strip() == "2", native
            # Same Lean and executable paths, new Beam provenance: attaching must be fenced.
            changed = dict(metadata, payloadHash="replacement-payload")
            provenance.write_text(json.dumps(changed))
            replaced = call("stats", ok=False)
            assert replaced.returncode != 0, replaced
            # Stop uses the recorded owner capability even if current runtime metadata is broken.
            provenance.write_text("{broken provenance")
            call("stop")
            assert owner.wait(timeout=30) == 0, owner_log.read_text()
            provenance.write_text(json.dumps(metadata))
        finally:
            if owner.poll() is None:
                provenance.write_text(json.dumps(metadata))
                call("stop", ok=False)
                try:
                    owner.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    owner.terminate()
                    owner.wait(timeout=10)

    self_check(mcp, source, cwd=project, env=env)
    traced_env = dict(env, LEAN_BEAM_BROKER_TRACE="1", LEAN_BEAM_MCP_TRACE="1")
    traced = self_check(mcp, source, cwd=project, env=traced_env)
    assert "Lean Beam MCP self-check passed" in traced.stdout, traced
    build_info = json.loads(run([beam, "toolchain-build-info"], cwd=scratch, env=env).stdout)
    if build_info["lakeSupportsDeferredCompilation"]:
        # Current Lake defers this compilation to leanir. A zero-build checkpoint must reject it
        # without invalidating the artifact family already published by Lake.
        postponed_config = config.replace("maxRecDepth = 777", 'maxRecDepth = 777\ncompiler.postponeCompile = true')
        for selected_config, selected_source in [
            (postponed_config, "module\npublic def value : Nat := 3\n"),
            (config, "module\nset_option compiler.postponeCompile true in\npublic def value : Nat := 4\n"),
        ]:
            (project / "lakefile.toml").write_text(selected_config)
            source.write_text("module\npublic def value : Nat := 3\n")
            run([lake, "--no-cache", "build", "Demo"], cwd=project, env=env)
            trace_path = project / ".lake" / "build" / "lib" / "lean" / "Demo.trace"
            prior_trace = trace_path.read_bytes()
            def artifact_family():
                paths = list((project / ".lake" / "build" / "lib" / "lean").glob("Demo.*"))
                paths += list((project / ".lake" / "build" / "ir").glob("Demo.*"))
                return {path: path.read_bytes() for path in paths if path.is_file()}
            prior_family = artifact_family()
            source.write_text(selected_source)
            postponed_log = scratch / "postponed-owner.log"
            with postponed_log.open("w") as log:
                owner = subprocess.Popen([str(beam), "--root", str(project), "serve"],
                                         cwd=project, env=env, stdout=log, stderr=log)
                try:
                    for _ in range(600):
                        if "serving Beam session" in postponed_log.read_text():
                            break
                        assert owner.poll() is None, postponed_log.read_text()
                        time.sleep(0.1)
                    else:
                        raise AssertionError(postponed_log.read_text())
                    assert json.loads(call("sync", "Demo.lean").stdout)["ok"]
                    unsupported = call("save", "Demo.lean", ok=False)
                    assert unsupported.returncode != 0, unsupported
                    failure = json.loads(unsupported.stdout)["error"]
                    assert failure["code"] == "saveUnsupportedSetup", failure
                    assert failure["data"]["sync"]["readiness"]["reason"] == "deferredCompilation", failure
                    assert "compiler.postponeCompile" in failure["message"] and "lake build" in failure["message"], failure
                    assert trace_path.read_bytes() == prior_trace
                    assert artifact_family() == prior_family
                    call("stop")
                    assert owner.wait(timeout=30) == 0, postponed_log.read_text()
                finally:
                    if owner.poll() is None:
                        call("stop", ok=False)
                        try:
                            owner.wait(timeout=30)
                        except subprocess.TimeoutExpired:
                            owner.terminate()
                            owner.wait(timeout=10)
            (project / "lakefile.toml").write_text(config)

    plugins = list(private.glob("*beam_Beam_LSP*"))
    assert len(plugins) == 1, plugins
    for artifact in [relocated / "bin" / f"beam-daemon{EXE}", *plugins]:
        parked = artifact.with_name(artifact.name + ".parked")
        artifact.rename(parked)
        try:
            missing = call("serve", ok=False)
            assert missing.returncode != 0 and "missing" in missing.stderr, missing
        finally:
            parked.rename(artifact)

    if os.name == "nt":
        # CRT permission bits do not describe a Windows DACL. A directory granting everyone
        # read access must not hold a session descriptor and its generation capability.
        unsafe_session = scratch / "unsafe session directory"
        unsafe_session.mkdir()
        run(["icacls", unsafe_session, "/grant", "*S-1-1-0:(OI)(CI)RX"], cwd=scratch, env=env)
        unsafe_args = [str(beam), "--root", str(project), "--session-dir", str(unsafe_session)]
        unsafe = subprocess.Popen([*unsafe_args, "serve"], cwd=project, env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, encoding="utf-8")
        try:
            stdout, stderr = unsafe.communicate(timeout=20)
            assert unsafe.returncode != 0 and "unsafe" in stderr, (stdout, stderr)
        finally:
            if unsafe.poll() is None:
                run([*unsafe_args, "stop"], env=env, ok=False)
                unsafe.terminate()
                unsafe.communicate(timeout=10)

    assert real_elan, "selector tests require elan (the no-selector workflow above must not invoke it)"
    if os.name != "nt":
        elan.unlink()
    env["ELAN_HOME"] = str(scratch / "elan-home")
    run([real_elan, "toolchain", "link", "native-match", relocated], env=env)
    (project / "lean-toolchain").write_text("native-match\n")
    assert "bundle ready: true" in call("doctor").stdout
    alias = scratch / "toolchain alias"
    try:
        alias.symlink_to(relocated, target_is_directory=True)
    except OSError:
        assert os.name == "nt", "native symlink creation failed"
    else:
        run([real_elan, "toolchain", "link", "native-alias", alias], env=env)
        (project / "lean-toolchain").write_text("native-alias\n")
        assert "bundle ready: true" in call("doctor").stdout
    run([real_elan, "toolchain", "link", "native-other", lean_prefix], env=env)
    (project / "lean-toolchain").write_text("native-other\n")
    mismatch = call("serve", ok=False)
    assert mismatch.returncode != 0 and "project's toolchain" in mismatch.stderr, mismatch

    # An inherited elan override must neither hide a foreign project selector nor reject
    # a project that explicitly selects this installation.
    for declared, override, matching in [
        ("native-other", "native-match", False),
        ("native-match", "native-other", True),
    ]:
        (project / "lean-toolchain").write_text(declared + "\n")
        resolved = run([beam, "--root", project, "doctor"],
                       env=dict(env, ELAN_TOOLCHAIN=override), ok=False)
        if matching:
            assert resolved.returncode == 0 and "bundle ready: true" in resolved.stdout, resolved
        else:
            assert resolved.returncode != 0 and "project's toolchain" in resolved.stderr, resolved

    (project / "lean-toolchain").write_text("native-not-installed\n")
    missing_selector = call("doctor", ok=False)
    assert missing_selector.returncode != 0 and "project's toolchain" in missing_selector.stderr, missing_selector
    assert not (scratch / "elan-home" / "toolchains" / "native-not-installed").exists()

    for name in ["forbidden-source", "forbidden-install-cache", "forbidden-runtime-cache"]:
        assert not (scratch / name).exists(), name
    assert not (project / ".beam" / "bundles").exists()
    assert not (home / ".codex").exists() and not (home / ".claude").exists()
    print("native toolchain build/install/relocation/runtime/save checks passed", flush=True)


if __name__ == "__main__":
    main()
