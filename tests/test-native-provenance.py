#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise native provenance serialization without compiling a Lean SDK."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


REPO = Path(__file__).resolve().parents[1]
EXE = ".exe" if os.name == "nt" else ""
PLUGIN = ("beam_Beam_LSP.dll" if os.name == "nt" else
          "libbeam_Beam_LSP.dylib" if sys.platform == "darwin" else "libbeam_Beam_LSP.so")


def main():
    with tempfile.TemporaryDirectory(prefix="beam-native-provenance-") as directory:
        scratch = Path(directory)
        source = scratch / "source checkout"
        (source / "scripts").mkdir(parents=True)
        shutil.copy2(REPO / "scripts/install-toolchain.cmake", source / "scripts/install-toolchain.cmake")
        (source / "LICENSE").write_text("fixture license\n")
        expected = {
            "sourceCommit": "1" * 40,
            "leanGithash": "2" * 40,
            "leanVersion": 'Lean fixture "debug" \\stage; λ',
            "lakeVersion": 'Lake fixture "quoted" \\cache; ',
        }
        fields = []
        for key, field in [("sourceCommit", "SOURCE_COMMIT"), ("leanGithash", "LEAN_GITHASH"),
                           ("leanVersion", "LEAN_VERSION"), ("lakeVersion", "LAKE_VERSION")]:
            fields.append(f"set(BEAM_BUILD_{field} [==[{expected[key]}]==])")
        # Construct controls after CMake has parsed the file, avoiding newline normalization.
        fields += ['foreach(code RANGE 1 31)', '  string(ASCII ${code} control)',
                   '  string(APPEND BEAM_BUILD_LAKE_VERSION "${control}")', 'endforeach()',
                   'string(APPEND BEAM_BUILD_LAKE_VERSION " end")']
        expected["lakeVersion"] += ''.join(chr(i) for i in range(1, 32)) + " end"
        build = source / ".lake/toolchain-build"
        for artifact in [f"bin/beam-cli{EXE}", f"bin/beam-daemon{EXE}",
                         f"bin/lean-beam-mcp{EXE}", f"lib/{PLUGIN}"]:
            path = build / artifact
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture artifact\n")
            fields.append(f"set(BEAM_BUILD_HASH_{artifact} {hashlib.sha256(path.read_bytes()).hexdigest()})")
        (source / ".lake/toolchain-build.cmake").write_text("\n".join(fields) + "\n", encoding="utf-8")
        driver = scratch / "install-fixture.cmake"
        # Stub only the compiler-version probe. Artifact checks, copying and JSON writing are real.
        driver.write_text('''function(execute_process)
  if(NOT "${ARGV2}" STREQUAL "--version")
    message(FATAL_ERROR "unexpected fixture compiler probe: ${ARGV}")
  endif()
  set(LEAN_VERSION "${BEAM_BUILD_LEAN_VERSION}" PARENT_SCOPE)
endfunction()
include("${INSTALLER}")
''')
        destination = scratch / "installed toolchain"
        subprocess.run(["cmake", f"-DLEAN_PREFIX={scratch / 'lean'}", f"-DPREFIX={destination}",
                        f"-DINSTALLER={source / 'scripts/install-toolchain.cmake'}", "-P", str(driver)],
                       check=True, capture_output=True, text=True, timeout=15)
        actual = json.loads((destination / "lib/lean-beam/provenance.json").read_text(encoding="utf-8"))
        for key, value in expected.items():
            assert actual[key] == value, (key, value, actual[key])


if __name__ == "__main__":
    main()
