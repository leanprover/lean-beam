#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Exercise the real native build writer and installer with fixture compiler probes."""

import json
import os
from pathlib import Path
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
  list(FIND ARGV OUTPUT_VARIABLE index)
  if(index EQUAL -1)
    return() # Artifacts are supplied by the fixture instead of a native Lake build.
  endif()
  math(EXPR index "${index}+1")
  list(GET ARGV ${index} output)
  if(ARGV1 STREQUAL "git")
    set(value "1111111111111111111111111111111111111111")
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
include("${SCRIPT}")
''', encoding="utf-8")

    def run_script(self, name, destination=None):
        fixture = self.root / "fixture.json"
        fixture.write_text(json.dumps(dict(version=self.version, lake=self.lake,
                                          revision=self.revision, compiled=self.compiled,
                                          destination_revision=self.destination_revision)), encoding="utf-8")
        args = ["cmake", f"-DLEAN_PREFIX={self.sdk}", f"-DFIXTURE={fixture}",
                f"-DNATIVE_CLANG_RESOURCE_DIR={self.resource}",
                f"-DSCRIPT={self.source / 'scripts' / name}"]
        if destination is not None:
            args.append(f"-DPREFIX={destination}")
        return subprocess.run([*args, "-P", str(self.driver)], capture_output=True,
                              text=True, encoding="utf-8", timeout=15)

    def build_record(self):
        result = self.run_script("build-toolchain.cmake")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
