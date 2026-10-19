#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise the real native build writer and installer with fixture compiler probes."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
PLUGIN = ("beam_Beam_LSP.dll" if os.name == "nt" else
          "libbeam_Beam_LSP.dylib" if sys.platform == "darwin" else "libbeam_Beam_LSP.so")


class NativeBuildRecordTest(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="beam-native-record-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.source = self.root / "source checkout"
        (self.source / "scripts").mkdir(parents=True)
        for name in ["build-toolchain.cmake", "install-toolchain.cmake", "toolchain-manifest.cmake"]:
            if (REPO / "scripts" / name).exists():
                shutil.copy2(REPO / "scripts" / name, self.source / "scripts" / name)
        (self.source / "lakefile.lean").write_text("-- fixture\n", encoding="utf-8")
        (self.source / "LICENSE").write_text("fixture license\n", encoding="utf-8")
        self.revision = "2" * 40
        self.compiled = self.revision
        self.destination_revision = self.revision
        self.version = 'Lean fixture "quoted" \\stage; λ'
        self.lake = 'Lake \\cache; ' + ''.join(chr(i) for i in range(1, 32)) + ' end'
        self.sdk = self.root / "SDK"
        (self.sdk / "bin").mkdir(parents=True)
        self.build = self.source / ".lake/toolchain-build"
        for name in [f"bin/beam-cli{EXE}", f"bin/beam-daemon{EXE}",
                     f"bin/lean-beam-mcp{EXE}", f"lib/{PLUGIN}"]:
            artifact = self.build / name
            artifact.parent.mkdir(parents=True, exist_ok=True)
            artifact.write_bytes(b"fixture artifact\n")
        self.resource = self.root / "clang-resource"
        (self.resource / "include").mkdir(parents=True)
        (self.resource / "include/x86intrin.h").touch()
        self.driver = self.root / "fixture.cmake"
        self.driver.write_text('''file(READ "${FIXTURE}" fixture)
foreach(field version lake revision compiled destination_revision)
  string(JSON fixture_${field} GET "${fixture}" ${field})
endforeach()
function(execute_process)
  if(ARGV1 STREQUAL "${CMAKE_COMMAND}" AND ARGV2 STREQUAL "-E" AND ARGV3 STREQUAL "env")
    foreach(variable LAKE_HOME LEAN_PATH LEAN_SRC_PATH LEAN_CC LEAN_AR LEAN_ABORT_ON_PANIC)
      list(FIND ARGV "--unset=${variable}" cleared)
      if(cleared EQUAL -1)
        message(FATAL_ERROR "native Lake invocation inherited ${variable}")
      endif()
    endforeach()
    list(FIND ARGV "--no-cache" native_build)
    if(FORCE_WINDOWS_SDK AND NOT native_build EQUAL -1)
      math(EXPR last "${ARGC}-1")
      foreach(index RANGE 0 ${last})
        set(arg "${ARGV${index}}")
        if(arg MATCHES "^BEAM_NATIVE_SYSTEM_INCLUDE_DIRS=(.*)$")
          file(WRITE "${SDK_CAPTURE}/includes.json" "${CMAKE_MATCH_1}")
        elseif(arg MATCHES "^BEAM_NATIVE_CLANG_RESOURCE_DIR=(.*)$")
          file(WRITE "${SDK_CAPTURE}/resource.txt" "${CMAKE_MATCH_1}")
        endif()
      endforeach()
    endif()
  endif()
  list(FIND ARGV OUTPUT_VARIABLE index)
  if(index EQUAL -1)
    return() # Artifacts are supplied by the fixture instead of a native Lake build.
  endif()
  math(EXPR index "${index}+1")
  list(GET ARGV ${index} output)
  if(ARGV1 STREQUAL "git")
    set(value "1111111111111111111111111111111111111111")
  elseif(ARGV2 STREQUAL "--print-resource-dir")
    message(FATAL_ERROR "explicit SDK construction must not discover another clang")
  elseif(ARGV2 STREQUAL "--version")
    if(output STREQUAL "LAKE_VERSION")
      set(value "${fixture_lake}")
    else()
      set(value "${fixture_version}")
    endif()
  elseif(ARGV2 STREQUAL "toolchain-build-info")
    set(value "{\\"leanGithash\\":\\"${fixture_compiled}\\",\\"compiledLeanRevision\\":\\"${fixture_compiled}\\",\\"loadedLeanRevision\\":\\"${fixture_revision}\\",\\"buildId\\":\\"${BEAM_BUILD_ID}\\",\\"sourceRevision\\":\\"${SOURCE_COMMIT}\\"}")
  elseif(ARGV2 STREQUAL "--githash" AND NOT ARGV1 STREQUAL "${LEAN_PREFIX}/bin/lean${EXE}")
    set(value "${fixture_destination_revision}")
  else()
    set(value "${fixture_revision}")
  endif()
  set(${output} "${value}" PARENT_SCOPE)
endfunction()
if(FORCE_WINDOWS_SDK)
  set(CMAKE_HOST_WIN32 TRUE)
  set(CMAKE_HOST_APPLE FALSE)
endif()
include("${SCRIPT}")
''', encoding="utf-8")

    def run_script(self, name, destination=None, *, system_includes=None, windows_sdk=False):
        fixture = self.root / "fixture.json"
        fixture.write_text(json.dumps(dict(version=self.version, lake=self.lake,
                                          revision=self.revision, compiled=self.compiled,
                                          destination_revision=self.destination_revision)), encoding="utf-8")
        args = ["cmake", f"-DLEAN_PREFIX={self.sdk}", f"-DFIXTURE={fixture}",
                f"-DNATIVE_CLANG_RESOURCE_DIR={self.resource}",
                f"-DSCRIPT={self.source / 'scripts' / name}"]
        if destination is not None:
            args.append(f"-DPREFIX={destination}")
        if system_includes is not None:
            args.append("-DNATIVE_SYSTEM_INCLUDE_DIRS=" + ";".join(
                str(path).replace(";", "\\;") for path in system_includes))
        if windows_sdk:
            for artifact in ["bin/beam-cli.exe", "bin/beam-daemon.exe",
                             "bin/lean-beam-mcp.exe", "lib/beam_Beam_LSP.dll"]:
                path = self.build / artifact
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"fixture Windows artifact\n")
            args.extend(["-DFORCE_WINDOWS_SDK=ON", f"-DSDK_CAPTURE={self.root}"])
        return subprocess.run([*args, "-P", str(self.driver)], capture_output=True,
                              text=True, encoding="utf-8", timeout=15)

    def build_record(self):
        result = self.run_script("build-toolchain.cmake")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_explicit_windows_sdk_directories_reach_the_native_lake_build(self):
        directories = [self.root / "native headers λ", self.root / "extra;headers"]
        for directory in directories:
            directory.mkdir()
        result = self.run_script("build-toolchain.cmake", system_includes=directories,
                                 windows_sdk=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "includes.json").read_text(encoding="utf-8")),
                         [directory.resolve().as_posix() for directory in directories])
        self.assertEqual((self.root / "resource.txt").read_text(encoding="utf-8"), str(self.resource))

    def test_windows_sdk_with_no_explicit_system_directories_forwards_an_empty_list(self):
        result = self.run_script("build-toolchain.cmake", windows_sdk=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "includes.json").read_text(encoding="utf-8")), [])

    @unittest.skipIf(os.name == "nt", "POSIX stand-ins exercise Windows CMake argument transport")
    def test_windows_sdk_environment_survives_real_child_processes(self):
        # Keep execute_process intact: the child must observe the actual cmake -E env arguments.
        probe = self.root / "probe.py"
        probe.write_text('''import json
import os
from pathlib import Path
import sys
root = Path(__file__).parent
name = Path(sys.argv[1]).name
args = sys.argv[2:]
revision = "2" * 40
if name == "git":
    print("1" * 40)
elif "--version" in args:
    print("fixture compiler")
elif name == "lean.exe" or (name == "lake.exe" and "--no-cache" not in args):
    print(revision)
elif name == "lake.exe":
    (root / "child-env.json").write_text(json.dumps({key: os.environ.get(key) for key in
        ["BEAM_NATIVE_CLANG_RESOURCE_DIR", "BEAM_NATIVE_SYSTEM_INCLUDE_DIRS"]}), encoding="utf-8")
    build_id = next(arg.split("=", 1)[1] for arg in args if arg.startswith("-KbeamBuildId="))
    (root / "build-info.json").write_text(json.dumps(dict(compiledLeanRevision=revision,
        loadedLeanRevision=revision, buildId=build_id, sourceRevision="1" * 40)), encoding="utf-8")
else:
    print((root / "build-info.json").read_text(encoding="utf-8"))
''', encoding="utf-8")
        for executable in [self.sdk / "bin/lean.exe", self.sdk / "bin/lake.exe",
                           self.root / "git", self.build / "bin/beam-cli.exe"]:
            executable.write_text(f'#!/bin/sh\nexec {shlex.quote(sys.executable)} '
                                  f'{shlex.quote(str(probe))} "$0" "$@"\n', encoding="utf-8")
            executable.chmod(0o755)
        for artifact in ["bin/beam-daemon.exe", "bin/lean-beam-mcp.exe", "lib/beam_Beam_LSP.dll"]:
            (self.build / artifact).write_bytes(b"fixture Windows artifact\n")
        driver = self.root / "real-process.cmake"
        driver.write_text('''set(CMAKE_HOST_WIN32 TRUE)
set(CMAKE_HOST_APPLE FALSE)
include("${SCRIPT}")
''', encoding="utf-8")
        directories = [self.root / "headers λ", self.root / "extra;headers"]
        for directory in directories:
            directory.mkdir()
        for spelling in ["clang-resource", "resource [", "resource;semi", "resource λ spaces"]:
            resource = self.root / spelling
            values = [str(resource)]
            if spelling == "clang-resource":
                values.append(str(resource) + "\\")
            for value in values:
                # On POSIX, a backslash is a filename character rather than a separator.
                (Path(value) / "include").mkdir(parents=True, exist_ok=True)
                (Path(value) / "include/x86intrin.h").touch()
                for includes in [[], directories]:
                    with self.subTest(resource=value, includes=includes):
                        encoded = ";".join(str(path).replace(";", "\\;") for path in includes)
                        result = subprocess.run([
                            "cmake", f"-DLEAN_PREFIX={self.sdk}",
                            f"-DNATIVE_CLANG_RESOURCE_DIR={value}",
                            f"-DNATIVE_SYSTEM_INCLUDE_DIRS={encoded}",
                            f"-DSCRIPT={self.source / 'scripts/build-toolchain.cmake'}",
                            "-P", str(driver)],
                            env=dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ["PATH"]),
                            capture_output=True, text=True, encoding="utf-8", timeout=15)
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                        actual = json.loads((self.root / "child-env.json").read_text(encoding="utf-8"))
                        self.assertEqual(actual["BEAM_NATIVE_CLANG_RESOURCE_DIR"], value)
                        self.assertEqual(json.loads(actual["BEAM_NATIVE_SYSTEM_INCLUDE_DIRS"]),
                                         [path.resolve().as_posix() for path in includes])

    def test_missing_windows_system_headers_fail_before_lake_or_manifest_publication(self):
        result = self.run_script("build-toolchain.cmake",
                                 system_includes=[self.root / "missing headers λ"], windows_sdk=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native Windows system include directory", result.stderr)
        self.assertFalse((self.root / "includes.json").exists())
        self.assertFalse((self.source / ".lake/toolchain-build.json").exists())

    def mutate_record(self, mutation):
        script = self.root / "mutate.cmake"
        script.write_text('''file(READ "${RECORD}" record)
''' + mutation + '''
beam_manifest_payload_hash("${record}" payload)
string(JSON record SET "${record}" payloadHash "\\\"${payload}\\\"")
file(WRITE "${RECORD}" "${record}\\n")
''', encoding="utf-8")
        # Use the production digest for the relationship and inventory together.
        script.write_text(f'include("{self.source.as_posix()}/scripts/toolchain-manifest.cmake")\n' +
                          script.read_text(encoding="utf-8"), encoding="utf-8")
        subprocess.run(["cmake", f"-DRECORD={self.source / '.lake/toolchain-build.json'}",
                        "-P", str(script)], check=True, capture_output=True,
                       text=True, encoding="utf-8")

    def test_native_digest_scope_and_fixed_encoding(self):
        script = self.root / "digest.cmake"
        script.write_text('''include("${MANIFEST_SCRIPT}")
file(READ "${FIXTURE}" fixture)
string(JSON record GET "${fixture}" native record)
string(JSON expected GET "${fixture}" native sha256)
beam_manifest_payload_hash("${record}" actual)
if(NOT actual STREQUAL expected)
  message(FATAL_ERROR "native payload digest encoding changed: ${actual}")
endif()
# These fields are checked independently by the native admission policy.
foreach(field sourceCommit buildId schemaVersion payloadHash)
  string(JSON changed SET "${record}" "${field}" "\\\"different metadata\\\"")
  beam_manifest_payload_hash("${changed}" actual)
  if(NOT actual STREQUAL expected)
    message(FATAL_ERROR "native payload digest unexpectedly includes ${field}")
  endif()
endforeach()
foreach(field_path "components;targets;0;toolchain" "artifacts;0;hash")
  string(JSON changed SET "${record}" ${field_path} "\\\"changed payload\\\"")
  beam_manifest_payload_hash("${changed}" actual)
  if(actual STREQUAL expected)
    message(FATAL_ERROR "native payload digest omitted ${field_path}")
  endif()
endforeach()
''', encoding="utf-8")
        result = subprocess.run([
            "cmake", f"-DMANIFEST_SCRIPT={self.source / 'scripts/toolchain-manifest.cmake'}",
            f"-DFIXTURE={REPO / 'tests/fixtures/installation-digests.json'}", "-P", str(script)],
            capture_output=True, text=True, encoding="utf-8", timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    @unittest.skipIf(os.name == "nt", "Darwin file replacement is exercised on POSIX hosts")
    def test_darwin_executables_are_independent_of_cache_hard_links(self):
        self.driver.write_text(self.driver.read_text().replace(
            'include("${SCRIPT}")', 'set(CMAKE_HOST_APPLE TRUE)\ninclude("${SCRIPT}")'))
        if PLUGIN != "libbeam_Beam_LSP.dylib":
            shutil.copy2(self.build / "lib" / PLUGIN, self.build / "lib/libbeam_Beam_LSP.dylib")
        cached = []
        for name in ["beam-cli", "beam-daemon", "lean-beam-mcp"]:
            executable = self.build / "bin" / name
            alias = self.root / (name + ".cached")
            os.link(executable, alias)
            alias.chmod(0o555)
            cached.append((executable, alias, alias.read_bytes()))
        self.build_record()
        for executable, alias, contents in cached:
            self.assertEqual(executable.read_bytes(), contents)
            self.assertEqual(alias.read_bytes(), contents)
            self.assertNotEqual(executable.stat().st_ino, alias.stat().st_ino)
            self.assertEqual(executable.stat().st_nlink, 1)
            self.assertEqual(alias.stat().st_mode & 0o777, 0o555)
            self.assertTrue(os.access(executable, os.X_OK))
        self.assertEqual(list((self.build / "bin").glob("*.beam-stage-*")), [])

    def test_singleton_membership_is_recorded(self):
        self.build_record()
        record = json.loads((self.source / ".lake/toolchain-build.json").read_text(encoding="utf-8"))
        components = record["components"]
        self.assertEqual(components["frontends"], {
            "cli": f"bin/lean-beam{EXE}", "mcp": f"bin/lean-beam-mcp{EXE}",
            "compilerRevision": self.revision})
        self.assertEqual(len(components["targets"]), 1)
        target = components["targets"][0]
        self.assertEqual(target["lean"], f"bin/lean{EXE}")
        self.assertEqual(target["compilerRevision"], self.revision)
        self.assertEqual(target["daemon"], f"bin/beam-daemon{EXE}")
        self.assertEqual(target["plugin"], f"lib/lean-beam/{PLUGIN}")

    def test_invalid_component_sets_are_rejected_before_writing(self):
        mutations = {
            "missing daemon": 'string(JSON record REMOVE "${record}" artifacts 1)',
            "duplicate destination": '''string(JSON path GET "${record}" artifacts 0 destination)
string(JSON record SET "${record}" artifacts 1 destination "\\\"${path}\\\"")''',
            "empty targets": 'string(JSON record SET "${record}" components targets "[]")',
            "duplicate target": '''string(JSON target GET "${record}" components targets 0)
string(JSON record SET "${record}" components targets 1 "${target}")''',
            "foreign helper": 'string(JSON record SET "${record}" components targets 0 daemon "\\\"/other/beam-daemon\\\"")',
        }
        for field in ["toolchain", "leanVersion", "lakeVersion"]:
            mutations["empty " + field] = f'string(JSON record SET "${{record}}" components targets 0 {field} "\\\"\\\"")'
        mutations["numeric description"] = 'string(JSON record SET "${record}" components targets 0 leanVersion "17")'
        mutations["numeric frontend"] = '''string(JSON record SET "${record}" components frontends cli "17")
string(JSON record SET "${record}" artifacts 0 destination "\\\"17\\\"")'''
        mutations["numeric license"] = '''string(JSON record SET "${record}" components license "17")
string(JSON record SET "${record}" artifacts 4 destination "\\\"17\\\"")'''
        for path in ["bin/CON.exe", "bin/lpt¹.dll", "bin/helper.", "bin/helper ", "bin/plug?in"]:
            mutations[path] = f'''string(JSON record SET "${{record}}" artifacts 1 destination "\\\"{path}\\\"")
string(JSON record SET "${{record}}" components targets 0 daemon "\\\"{path}\\\"")'''
        for name, mutation in mutations.items():
            with self.subTest(name=name):
                self.build_record()
                self.mutate_record(mutation)
                destination = self.root / name
                result = self.run_script("install-toolchain.cmake", destination)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(destination.exists())

    def test_shared_manifest_contract(self):
        cases = json.loads((REPO / "tests/fixtures/installation-manifest-contract.json").read_text(encoding="utf-8"))
        materialized = []
        for case in cases:
            with self.subTest(name=case["name"]):
                self.build_record()
                path = self.source / ".lake/toolchain-build.json"
                record = json.loads(path.read_text(encoding="utf-8"))
                for field, key in [("destination", "destination"), ("source", "source")]:
                    if field in case:
                        record["artifacts"][1][key] = case[field].replace("@EXE@", EXE)
                if "reference" in case:
                    record["components"]["targets"][0]["daemon"] = case["reference"].replace("@EXE@", EXE)
                path.write_text(json.dumps(record), encoding="utf-8")
                self.mutate_record("") # Recompute the production digest, so admission tests structure.
                record = json.loads(path.read_text(encoding="utf-8"))
                materialized.append(dict(name=case["name"], valid=case["valid"], record=record))
                destination = self.root / ("contract-" + case["name"])
                result = self.run_script("install-toolchain.cmake", destination)
                self.assertEqual(result.returncode == 0, case["valid"], result.stdout + result.stderr)
                if case["valid"]:
                    self.assertTrue((destination / record["components"]["targets"][0]["daemon"]).is_file())
                else:
                    self.assertFalse(destination.exists())
        if output := os.environ.get("BEAM_MANIFEST_CORPUS_OUTPUT"):
            Path(output).write_text(json.dumps(materialized), encoding="utf-8")

    def test_actual_writer_round_trip(self):
        self.version += ' ]==] suffix'
        self.lake += ' ]=] ]==] suffix'
        self.build_record()
        destination = self.root / "installed toolchain"
        result = self.run_script("install-toolchain.cmake", destination)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        installed = destination / "lib/lean-beam/provenance.json"
        self.assertEqual(installed.read_bytes(), (self.source / ".lake/toolchain-build.json").read_bytes())
        actual = json.loads(installed.read_text(encoding="utf-8"))
        self.assertEqual(actual["components"]["targets"][0]["leanVersion"], self.version)
        self.assertEqual(actual["components"]["targets"][0]["lakeVersion"], self.lake)

    def test_exact_source_revision_for_empty_and_populated_staging(self):
        self.build_record()
        self.revision = "3" * 40 # Display version is unchanged.
        for populated in [False, True]:
            with self.subTest(populated=populated):
                destination = self.root / ("populated" if populated else "empty")
                if populated:
                    (destination / "bin").mkdir(parents=True)
                    (destination / "bin" / f"lean{EXE}").touch()
                result = self.run_script("install-toolchain.cmake", destination)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse((destination / "lib/lean-beam").exists())

    def test_populated_destination_revision_is_checked_separately(self):
        self.build_record()
        destination = self.root / "existing toolchain"
        (destination / "bin").mkdir(parents=True)
        (destination / "bin" / f"lean{EXE}").touch()
        self.destination_revision = "3" * 40
        rejected = self.run_script("install-toolchain.cmake", destination)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertFalse((destination / "lib/lean-beam").exists())
        self.destination_revision = self.revision
        accepted = self.run_script("install-toolchain.cmake", destination)
        self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)

    def test_compiled_revision_is_independent_of_loaded_revision(self):
        self.compiled = "4" * 40
        result = self.run_script("build-toolchain.cmake")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("compiler", result.stderr)

    def test_changed_artifact_is_rejected_before_install(self):
        self.build_record()
        (self.build / "bin" / f"beam-cli{EXE}").write_bytes(b"changed\n")
        destination = self.root / "damaged install"
        result = self.run_script("install-toolchain.cmake", destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
