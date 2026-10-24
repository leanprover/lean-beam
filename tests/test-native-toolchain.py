#!/usr/bin/env python3
"""Build, relocate, and exercise a toolchain-only Beam payload (no standalone installer)."""

import argparse
import datetime
import errno
import hashlib
import importlib.util
import json
import os
import platform
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import traceback


REPO = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
watchdog_spec = importlib.util.spec_from_file_location(
    "process_watchdog", REPO / "tests/lib/process_watchdog.py")
watchdog = importlib.util.module_from_spec(watchdog_spec)
watchdog_spec.loader.exec_module(watchdog)


def run(args, *, cwd=REPO, env=None, ok=True):
    print("+", shlex.join(str(a) for a in args), flush=True)
    result = subprocess.run([str(a) for a in args], cwd=cwd, env=env,
                            text=True, encoding="utf-8", capture_output=True, timeout=600)
    if ok and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def check_native_cli_usage(beam, env, management_commands):
    help_result = run([beam, "--help"], env=env)
    assert "lean-beam [--pretty] [--root PATH] run-at " in help_result.stdout, help_result
    invalid_command = run([beam, "unknown-command"], env=env, ok=False)
    assert invalid_command.returncode == 2, invalid_command
    response = json.loads(invalid_command.stdout)
    assert response["ok"] is False, response
    assert response["error"]["code"] == "invalidParams", response
    assert "unknown-command" in response["error"]["message"], response
    assert "unknown-command" in invalid_command.stderr, invalid_command
    assert "usage: lean-beam " in invalid_command.stderr, invalid_command
    assert "--help" in invalid_command.stderr, invalid_command
    assert len(invalid_command.stderr.splitlines()) <= 3, invalid_command
    assert "lean-beam [--pretty] [--root PATH] run-at " not in invalid_command.stderr, invalid_command
    assert "uncaught exception:" not in invalid_command.stderr, invalid_command
    for text in [help_result.stdout, invalid_command.stderr]:
        assert all(f"  lean-beam {command}" not in text for command in management_commands), text
    return help_result, invalid_command


def record_document_rejection(result, cases, evidence_path):
    observation = {
        "command": [str(argument) for argument in result.args],
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }
    cases.append(observation)
    write_report(evidence_path, {"cases": cases})
    assert result.returncode != 0, observation
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise AssertionError(f"native document rejection returned invalid JSON: {observation!r}") from error
    return response["error"]


def mcp_smoke(mcp, source, *, cwd, env, trace=False):
    command = [sys.executable, str(REPO / "tests/lib/installed-mcp-smoke.py"),
               str(mcp), str(cwd), str(source)]
    if trace:
        command.append("--server-trace")
    timeout = float(os.environ.get("BEAM_MCP_SMOKE_WATCHDOG_SECONDS", "600"))
    try:
        result = watchdog.run_with_watchdog(command, timeout=timeout, cwd=cwd, env=env)
    except subprocess.TimeoutExpired as error:
        raise AssertionError(
            f"{command}: external watchdog expired\n{error.stdout}\n{error.stderr}") from error
    assert result.returncode == 0, result
    assert json.loads(result.stdout)["ok"] is True, result
    return result


def native_object_traces(build_dir):
    return {name: json.loads((build_dir / "native" / f"{name}.o.trace").read_text())["depHash"]
            for name in ["control_dir", "process_job"]}


def check_relative_native_includes(lake, scratch, env, includes):
    callers = [scratch / "sdk A λ", scratch / "sdk B λ"]
    for caller in callers:
        (caller / "include").mkdir(parents=True)
    # The relative directory is deliberately identical in both environments; the remaining
    # directories supply the real SDK. No SDK headers need to be copied into these fixtures.
    relative_env = dict(env, BEAM_NATIVE_SYSTEM_INCLUDE_DIRS=json.dumps(["include", *includes]))
    traces = []
    for index, caller in enumerate([callers[0], callers[1], callers[0]]):
        run([lake, "-d", REPO, *(["--reconfigure", "-KbeamToolchain=false"] if index == 0 else []),
             "--no-cache", "build", "beamControlDirObj", "beamProcessJobObj"],
            cwd=caller, env=relative_env)
        traces.append(native_object_traces(REPO / ".lake/build"))
    assert all(traces[0][name] != traces[1][name] for name in traces[0]), traces
    assert traces[0] == traces[2], traces
    print("native SDK relative include paths: both object traces passed A -> B -> A", flush=True)


def run_ordinary_source_checks(lean_prefix: Path, build_env: dict[str, str]) -> None:
    """Portable checks against the providing SDK's ordinary build, before native installation."""
    for executable in ["beam-backend-process-test", "beam-transport-test",
                       "beam-transaction-test", "beam-publication-test", "beam-prune-lock-test"]:
        run([sys.executable, REPO / "tests/lib/process_watchdog.py", "--timeout", "30", "--",
             REPO / ".lake/build/bin" / f"{executable}{EXE}"], env=build_env)
    run([sys.executable, "-X", "utf8", REPO / "tests/test-system-contracts.py"], env=build_env)
    run([sys.executable, "-X", "utf8", REPO / "tests/test-save-trace-format.py",
         "--lean-prefix", lean_prefix], env=build_env)
    run([sys.executable, "-X", "utf8", REPO / "tests/test-installation-manifest.py"], env=build_env)
    run([sys.executable, "-X", "utf8", REPO / "tests/test-installation-construction.py"], env=build_env)
    # Native platform jobs also qualify real Elan links, including Windows junctions,
    # and ordinary-directory impostors with the selected SDK's native filesystem helper.
    run([sys.executable, "-X", "utf8", REPO / "tests/test-installation-lookup.py"], env=build_env)


def qualify(args, lean_prefix, scratch):
    # The parent captures UTF-8, including unittest failures with non-ASCII fixture names.
    run([sys.executable, "-X", "utf8", REPO / "tests/test-native-provenance.py"])
    real_elan = shutil.which("elan")
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
        native_cmake_args = []
        if os.name == "nt":
            # Resolve the full native SDK before Lake prepends the packaged compiler to PATH.
            build_env["BEAM_NATIVE_CLANG_RESOURCE_DIR"] = run(
                ["clang", "--print-resource-dir"], env=build_env).stdout.strip()
            includes = [str(path.resolve()) for path in args.native_system_include_dir]
            build_env["BEAM_NATIVE_SYSTEM_INCLUDE_DIRS"] = json.dumps(includes)
            native_cmake_args = [
                f"-DNATIVE_CLANG_RESOURCE_DIR={build_env['BEAM_NATIVE_CLANG_RESOURCE_DIR']}",
                "-DNATIVE_SYSTEM_INCLUDE_DIRS=" + ";".join(path.replace(";", "\\;") for path in includes)]
            for value, message in [
                    ("not JSON", "invalid BEAM_NATIVE_SYSTEM_INCLUDE_DIRS"),
                    ("[7]", "invalid BEAM_NATIVE_SYSTEM_INCLUDE_DIRS"),
                    (json.dumps([str(scratch / "missing native headers λ")]),
                     "native Windows system include directory does not exist")]:
                rejected_env = dict(build_env, BEAM_NATIVE_SYSTEM_INCLUDE_DIRS=value)
                rejected = run([lean_prefix / "bin" / f"lake{EXE}", "--no-cache", "build",
                                "beamControlDirObj"], env=rejected_env, ok=False)
                assert rejected.returncode != 0 and message in rejected.stdout + rejected.stderr, rejected
            if includes:
                check_relative_native_includes(lean_prefix / "bin" / f"lake{EXE}", scratch,
                                               build_env, includes)
        # Lake preserves configuration options in its cached lakefile. Warm the ordinary
        # configuration and CLI first, then prove the native builder uses its requested mode
        # without replacing that CLI or changing the ordinary configuration.
        run([lean_prefix / "bin" / f"lake{EXE}", "--reconfigure", "-KbeamToolchain=false",
             "--no-cache", "build", "beam-cli",
             "beam-lake-helper-client-fixture", "beam-installation-lookup-test",
             "beam-installation-construction-test", "beam-installation-manifest-test",
             "beam-system-contract-test", "beam-backend-process-test", "beam-transport-test",
             "beam-transaction-test", "beam-publication-test", "beam-prune-lock-test"],
            env=build_env)
        run_ordinary_source_checks(lean_prefix, build_env)
        runtime_files = json.loads(run([lean_prefix / "bin" / f"lake{EXE}", "script", "run",
                                       "beamSharedRuntimeFiles"], env=build_env).stdout)
        runtime_paths = [REPO / ".lake/build" / path for path in runtime_files]
        stub, = [path for path in runtime_paths if path.name.startswith("libInit_shared.")]
        intact = {path: path.stat().st_mtime_ns for path in runtime_paths if path != stub}
        stub.write_bytes(b"incomplete shared library")
        run([lean_prefix / "bin" / f"lake{EXE}", "--no-cache", "build", "beamSharedRuntime"], env=build_env)
        original_stub = lean_prefix / next(path for path in runtime_files if Path(path).name == stub.name)
        assert stub.read_bytes() == original_stub.read_bytes()
        assert all(path.stat().st_mtime_ns == timestamp for path, timestamp in intact.items())
        assert not list(stub.parent.glob("*.beam-stage-*.tmp"))
        standalone = REPO / ".lake" / "build" / "bin" / f"beam-cli{EXE}"
        standalone_hash = hashlib.sha256(standalone.read_bytes()).hexdigest()
        configs = [REPO / ".lake" / "lakefile.olean.trace",
                   REPO / ".lake" / "config" / "0" / "lakefile.olean.trace"]
        config_before = {path: path.read_bytes() for path in configs if path.exists()}
        assert config_before, "standalone Lake configuration trace was not written"
        first_native_trace = None
        if args.previous_lean_prefix:
            for selected in [lean_prefix, args.previous_lean_prefix.resolve()]:
                run(["cmake", f"-DLEAN_PREFIX={selected}", *native_cmake_args,
                     "-P", "scripts/build-toolchain.cmake"], env=build_env)
                trace = native_object_traces(REPO / ".lake/toolchain-build")
                if first_native_trace is None:
                    first_native_trace = trace
                else:
                    assert all(trace[name] != first_native_trace[name] for name in trace), trace
        run(["cmake", f"-DLEAN_PREFIX={lean_prefix}", *native_cmake_args,
             "-P", "scripts/build-toolchain.cmake"], env=build_env)
        final_native_trace = native_object_traces(REPO / ".lake/toolchain-build")
        if first_native_trace is not None:
            assert final_native_trace == first_native_trace, final_native_trace
        assert hashlib.sha256(standalone.read_bytes()).hexdigest() == standalone_hash
        assert all(path.read_bytes() == content for path, content in config_before.items())
        if sys.platform == "darwin":
            for name in ["beam-cli", "beam-daemon", "lean-beam-mcp"]:
                executable = REPO / ".lake/toolchain-build/bin" / (name + EXE)
                assert not executable.is_symlink() and executable.stat().st_nlink == 1, executable
        # Probe an ordinary payload with independent files, as the standalone installer does.
        # A cache hard link is not a runtime directory on Darwin: dyld can name its cache alias.
        ordinary_root = scratch / "ordinary payload"
        ordinary = ordinary_root / "bin" / f"beam-cli{EXE}"
        ordinary.parent.mkdir(parents=True)
        shutil.copy2(standalone, ordinary)
        assert ordinary.read_bytes() == standalone.read_bytes()
        for relative in runtime_files:
            destination = ordinary_root / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / ".lake/build" / relative, destination)
        ordinary = run([ordinary, "toolchain-build-info"], ok=False)
        assert ordinary.returncode != 0 and "not built with -KbeamToolchain=true" in ordinary.stderr, ordinary
        ordinary_help = run([ordinary_root / "bin" / f"beam-cli{EXE}", "--help"]).stdout
        assert "  lean-beam prune" in ordinary_help, ordinary_help
        assert all(f"  lean-beam {command}" not in ordinary_help for command in management_commands if command != "prune"), ordinary_help
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
    for relative in ["scripts/install-toolchain.cmake", "scripts/toolchain-manifest.cmake",
                     ".lake/toolchain-build.json"]:
        destination = install_source / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, destination)
    build_manifest = json.loads((REPO / ".lake/toolchain-build.json").read_text())
    for artifact in build_manifest["artifacts"]:
        relative = artifact["source"]
        destination = install_source / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        copy_file(REPO / relative, destination)
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
    assert metadata["payloadHash"] and metadata["components"]["targets"][0]["leanVersion"]
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
               BEAM_PUBLIC_COMMAND="ambient-wrong-name")
    version = run([beam, "version"], cwd=scratch, env=env).stdout
    assert version.startswith("lean-beam "), version
    assert metadata["payloadHash"] in version and metadata["components"]["targets"][0]["leanVersion"] in version, version
    mcp = relocated / "bin" / f"lean-beam-mcp{EXE}"
    mcp_version = run([mcp, "--version"], cwd=scratch, env=env).stdout
    # A relative loader path must use the containing SDK, without an absolute build-prefix fallback.
    shared_dir = relocated / ("bin" if os.name == "nt" else "lib/lean")
    suffix = ".dll" if os.name == "nt" else ".dylib" if sys.platform == "darwin" else ".so"
    for name in ["libleanshared", "libLake_shared"]:
        library = shared_dir / (name + suffix)
        parked = library.with_name(library.name + ".parked")
        library.rename(parked)
        try:
            for executable, arguments in [
                (beam, ["version"]), (mcp, ["--version"]),
                (relocated / "bin" / f"beam-daemon{EXE}", ["build-info"]),
            ]:
                rejected = run([executable, *arguments], cwd=scratch, env=env, ok=False)
                assert rejected.returncode != 0, (executable, library, rejected)
        finally:
            parked.rename(library)
    assert "lean-beam-mcp" in mcp_version and metadata["payloadHash"] in mcp_version, mcp_version
    foreign_cli = run([mcp, "--beam-cli", lean_prefix / "bin" / f"lean{EXE}", "--version"],
                      cwd=scratch, env=env, ok=False)
    assert foreign_cli.returncode != 0 and "unexpected lean-beam-mcp argument" in foreign_cli.stderr, foreign_cli
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
    assert "target membership: present" in doctor and metadata["payloadHash"] in doctor, doctor
    check_native_cli_usage(beam, env, management_commands)
    for standalone_command in ["install-layout", "mcp-config", *management_commands, "bundle-install"]:
        rejected = run([beam, "--root", project, standalone_command,
                        *(["unused-toolchain"] if standalone_command == "bundle-install" else [])],
                       env=env, ok=False)
        assert rejected.returncode != 0, rejected
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
            # Document rejection must precede worker creation in the installed CLI too.
            # serve deliberately ensures a backend session before accepting requests.
            before = json.loads(call("stats").stdout)["result"]
            assert before["session"]["open_doc_count"] == 0, before
            external = scratch / "project with spaces-other"
            external.mkdir()
            outside = external / "Other.lean"
            outside.write_text("def outsideFixture : Nat := 1\n")
            escape = project / "outside-link"
            if os.name == "nt":
                run(["cmd", "/d", "/c", "mklink", "/J", escape, external], env=env)
            else:
                escape.symlink_to(external, target_is_directory=True)
            rejection_cases = []
            rejection_evidence = project / ".beam" / "document-path-rejections.json"
            for path in [str(outside), "../project with spaces-other/Other.lean",
                         "outside-link/Other.lean"]:
                for operation in [("sync", path), ("refresh", path),
                                  ("run-at", path, "1", "0", "0", "#check Nat")]:
                    rejected = call(*operation, ok=False)
                    failure = record_document_rejection(rejected, rejection_cases, rejection_evidence)
                    assert failure["code"] == "invalidParams", failure
                    assert "resolves outside workspace root" in failure["message"], failure
                    assert "select a workspace containing the document" in failure["message"], failure
            stats = json.loads(call("stats").stdout)["result"]
            assert stats["session"] == before["session"], (before, stats)
            assert stats["metrics"]["session_starts"] == before["metrics"]["session_starts"], (before, stats)
            updated = json.loads(call("update", "Demo.lean").stdout)
            version = updated["result"]["version"]
            # Observe the actual volume rather than assuming that macOS folds path case.
            case_root = project.with_name(project.name.swapcase())
            case_probe = {
                "platform": sys.platform,
                "device": project.stat().st_dev,
                "root": str(project),
                "alias": str(case_root),
                "case_insensitive": case_root.exists() and case_root.samefile(project),
            }
            case_evidence = project / ".beam" / "document-path-case.json"
            case_evidence.parent.mkdir(exist_ok=True)
            if case_probe["case_insensitive"]:
                alias_update = call("update", str(case_root / source.name), ok=False)
                case_probe.update(returncode=alias_update.returncode, stdout=alias_update.stdout,
                                  stderr=alias_update.stderr)
                write_report(case_evidence, case_probe)
                assert alias_update.returncode == 0, case_probe
                assert json.loads(alias_update.stdout)["result"]["version"] == version, case_probe
                alias_stats = json.loads(call("stats").stdout)["result"]
                case_probe["open_document_count"] = alias_stats["session"]["open_doc_count"]
                write_report(case_evidence, case_probe)
                assert case_probe["open_document_count"] == 1, case_probe
            else:
                write_report(case_evidence, case_probe)
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
            ir_sig = Path(saved["result"]["ir_sig"])
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

    # Exercise the relocated executable over real stdio in both supported protocol families.
    mcp_smoke(mcp, source, cwd=project, env=env)
    mcp_smoke(mcp, source, cwd=project, env=env, trace=True)
    build_info = json.loads(run([beam, "toolchain-build-info"], cwd=scratch, env=env).stdout)
    assert build_info["compiledLeanRevision"] == metadata["components"]["frontends"]["compilerRevision"] == build_info["loadedLeanRevision"], build_info
    assert build_info["sourceRevision"] == metadata["sourceCommit"], build_info
    assert build_info["buildId"] == metadata["buildId"] and build_info["buildId"], build_info
    if build_info["lakeSupportsDeferredCompilation"]:
        # Current Lake defers this compilation to leanir. A zero-build checkpoint must reject it
        # without invalidating the artifact family already published by Lake.
        postponed_config = config.replace("maxRecDepth = 777", 'maxRecDepth = 777\ncompiler.postponeCompile = true')
        for variant, selected_config, selected_source in [
            ("lake-option", postponed_config, "module\npublic def value : Nat := 3\n"),
            ("source-option", config, "module\nset_option compiler.postponeCompile true in\npublic def value : Nat := 4\n"),
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
                    # Retain the actual subprocess failure before JSON decoding can obscure it.
                    evidence = {
                        "variant": variant, "argv": unsupported.args,
                        "returncode": unsupported.returncode,
                        "stdout": unsupported.stdout, "stderr": unsupported.stderr,
                    }
                    receipt = project / ".beam" / f"deferred-compilation-{variant}.json"
                    receipt.parent.mkdir(parents=True, exist_ok=True)
                    write_report(receipt, evidence)
                    assert unsupported.returncode != 0, unsupported
                    try:
                        failure = json.loads(unsupported.stdout)["error"]
                    except json.JSONDecodeError as error:
                        raise AssertionError(f"deferred-compilation save returned invalid JSON: {evidence}") from error
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
    run([real_elan, "toolchain", "link", "native-match-second", relocated], env=env)
    (project / "lean-toolchain").write_text("native-match\n")
    assert "target membership: present" in call("doctor").stdout
    alias = scratch / "toolchain alias"
    try:
        alias.symlink_to(relocated, target_is_directory=True)
    except OSError:
        assert os.name == "nt", "native symlink creation failed"
    else:
        run([real_elan, "toolchain", "link", "native-alias", alias], env=env)
        (project / "lean-toolchain").write_text("native-alias\n")
        assert "target membership: present" in call("doctor").stdout
    run([real_elan, "toolchain", "link", "native-other", lean_prefix], env=env)
    (project / "lean-toolchain").write_text("native-other\n")
    mismatch = call("serve", ok=False)
    assert mismatch.returncode != 0 and "not a member of this Beam installation" in mismatch.stderr, mismatch

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
            assert resolved.returncode == 0 and "target membership: present" in resolved.stdout, resolved
        else:
            assert resolved.returncode != 0 and "not a member of this Beam installation" in resolved.stderr, resolved

    (project / "lean-toolchain").write_text("native-not-installed\n")
    missing_selector = call("doctor", ok=False)
    assert missing_selector.returncode != 0 and "unavailable locally" in missing_selector.stderr, missing_selector
    assert not (scratch / "elan-home" / "toolchains" / "native-not-installed").exists()

    # A live workspace must readmit without provisioning, and cleanup must survive failed admission.
    lifetime_spec = importlib.util.spec_from_file_location(
        "bundled_mcp_lifetime", REPO / "tests/lib/bundled-mcp-lifetime.py")
    lifetime = importlib.util.module_from_spec(lifetime_spec)
    lifetime_spec.loader.exec_module(lifetime)
    lifetime.check(mcp, provenance, "native-other", env=env,
                   matching_selectors=("native-match", "native-match-second"))

    # Native platform jobs do not run the whole fast suite. Qualify the real installed helper's
    # job/group ownership and both MCP protocol families under the selected SDK as well.
    run([sys.executable, REPO / "tests/lib/process_watchdog.py", "--timeout", "180", "--",
         sys.executable, REPO / "tests/test-lake-helper-lifetime.py",
         "--native-prefix", relocated], cwd=scratch, env=env)

    assert not (scratch / "forbidden-source").exists()
    assert not (project / ".beam" / "bundles").exists()
    assert not (home / ".codex").exists() and not (home / ".claude").exists()
    print("native toolchain build/install/relocation/runtime/save checks passed", flush=True)


def write_report(path, report):
    staged = path.with_name(path.name + ".tmp")
    staged.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    staged.replace(path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lean_prefix", type=Path)
    parser.add_argument("--scratch", type=Path, default=REPO / ".native-test")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true", help="check native/standalone build isolation only")
    parser.add_argument("--crlf", action="store_true", help="exercise Windows line endings on any host")
    parser.add_argument("--previous-lean-prefix", type=Path,
                        help="qualify compiler switching through the same native object cache")
    parser.add_argument("--native-system-include-dir", type=Path, action="append", default=[],
                        help="Windows native SDK system include directory; repeat for multiple directories")
    args = parser.parse_args(argv)
    lean_prefix = args.lean_prefix.resolve()
    args.scratch.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="toolchain-", dir=args.scratch.resolve()))
    report_path = scratch / "qualification.json"
    report = {
        "lean_prefix": str(lean_prefix),
        "platform": platform.platform(),
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "options": {
            "skip_build": args.skip_build,
            "build_only": args.build_only,
            "crlf": args.crlf,
            "previous_lean_prefix": str(args.previous_lean_prefix) if args.previous_lean_prefix else None,
            "native_system_include_dirs": [str(path) for path in args.native_system_include_dir],
        },
    }
    print(f"native toolchain test scratch: {scratch}", flush=True)
    try:
        # Retain each successful observation even if a later SDK probe or build fails.
        report["beam_commit"] = run(["git", "rev-parse", "HEAD"]).stdout.strip()
        report["source_dirty"] = bool(run(["git", "status", "--porcelain"]).stdout.strip())
        report["lean_version"] = run([lean_prefix / "bin" / f"lean{EXE}", "--version"]).stdout.strip()
        report["lean_githash"] = run([lean_prefix / "bin" / f"lean{EXE}", "--githash"]).stdout.strip()
        report["lake_version"] = run([lean_prefix / "bin" / f"lake{EXE}", "--version"]).stdout.strip()
        print(json.dumps(report, indent=2), flush=True)
        write_report(report_path, {**report, "result": "running"})
        qualify(args, lean_prefix, scratch)
    except Exception as failure:
        outcome = {
            **report,
            "result": "failed",
            "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "failure": traceback.format_exc(),
        }
        if isinstance(failure, (subprocess.TimeoutExpired, subprocess.CalledProcessError)):
            for stream in ("stdout", "stderr"):
                value = getattr(failure, stream)
                if value is not None:
                    outcome[stream] = (
                        value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value
                    )
        try:
            write_report(report_path, outcome)
        except OSError as error:
            print(f"could not write qualification report: {error}", file=sys.stderr)
        raise
    else:
        write_report(report_path, {**report, "result": "passed",
                                  "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat()})
        print(f"native qualification report: {report_path}", flush=True)


if __name__ == "__main__":
    main()
