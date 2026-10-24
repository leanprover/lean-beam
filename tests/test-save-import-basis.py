#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""A checkpoint is refused unless its loaded imports still match the files Lake will trust."""

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from lib.process_watchdog import run_with_watchdog

REPO = Path(__file__).resolve().parent.parent


class Case:
    def __init__(self, base, name, installation, target):
        self.root = base / name / "project"
        self.wrapper = installation / "bin" / ("lean-beam.exe" if os.name == "nt" else "lean-beam")
        lean = Path(target["lean"])
        self.lake = lean.parent / ("lake.exe" if os.name == "nt" else "lake")
        self.toolchain = target["toolchain"]
        self.env = dict(os.environ, LAKE_CACHE_DIR=str(base / name / "lake-cache"),
                        LAKE_ARTIFACT_CACHE="false")

    def write(self, files, root=None):
        for name, text in files.items():
            path = (root or self.root) / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def project(self, files, lakefile='name = "w"\ndefaultTargets = ["W"]\n[[lean_lib]]\nname = "W"\n'):
        self.write({"lean-toolchain": self.toolchain + "\n", "lakefile.toml": lakefile, **files})
        self.lake_run("build")

    def lake_run(self, *args, check=True, root=None):
        result = run_with_watchdog([self.lake, *args], cwd=root or self.root, env=self.env, timeout=300)
        if check:
            assert result.returncode == 0, (args, result.stdout, result.stderr)
        return result

    def beam(self, *args):
        result = run_with_watchdog([self.wrapper, "--root", self.root, *args], cwd=self.root,
                                   env=self.env, timeout=300)
        try:
            return json.loads(result.stdout)
        except ValueError:
            raise AssertionError((args, result.returncode, result.stdout, result.stderr))

    def ok(self, *args):
        response = self.beam(*args)
        assert response["ok"], (args, response)
        return response["result"]

    def refused(self, *args, changed=None):
        response = self.beam(*args)
        assert not response["ok"], (args, response)
        error = response["error"]
        assert error["code"] == "saveImportsChanged", error
        if changed is not None:
            assert set(changed) <= set(error["data"]["changedImports"]), error
        assert error["data"]["recoveryPlan"] == [f'lean-beam refresh "{args[-1]}"'], error
        return error

    def untrusted(self, module):
        assert self.lake_run("build", "--no-build", module, check=False).returncode != 0, module

    def trusted(self, module):
        self.lake_run("build", "--no-build", module)

    @contextmanager
    def owner(self, **env):
        log = self.root.parent / "owner.stderr"
        with log.open("w") as err:
            process = subprocess.Popen([self.wrapper, "--root", self.root, "serve"], cwd=self.root,
                                       env=dict(self.env, **env), stdout=subprocess.DEVNULL, stderr=err)
            try:
                deadline = time.monotonic() + 60
                while "serving Beam session" not in log.read_text():
                    assert process.poll() is None, log.read_text()
                    assert time.monotonic() < deadline, log.read_text()
                    time.sleep(0.05)
                yield
            finally:
                self.beam("stop")
                try:
                    process.wait(timeout=30)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)


def digest(paths):
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths if path.is_file()}


def external_rebuild(case):
    case.project({"W.lean": "import W.B\n",
                  "W/A.lean": "def double (n : Nat) : Nat := n + n\n",
                  "W/B.lean": "import W.A\n\ntheorem dz : double 1 = 2 := rfl\n"})
    with case.owner():
        case.ok("sync", "W/B.lean")
        case.write({"W/A.lean": "def double (n : Nat) : Nat := n + n + 1\n"})
        case.lake_run("build", "W.A")
        error = case.refused("save", "W/B.lean", changed=["W.A"])
        assert error["data"]["sync"]["readiness"]["saveReady"], error
        case.untrusted("W.B")
        refreshed = case.ok("refresh", "W/B.lean")
        assert not refreshed["readiness"]["saveReady"], refreshed
        case.write({"W/B.lean": "import W.A\n\ntheorem dz : double 1 = 3 := rfl\n"})
        case.ok("save", "W/B.lean")
        case.trusted("W.B")


def transitive_unchanged_olean(case):
    case.project({"W.lean": "import W.B\n",
                  "W/C.lean": "def c : Nat := 1\n",
                  "W/A.lean": "import W.C\n\ndef aa : Nat := 0\n",
                  "W/B.lean": "import W.A\n\ntheorem tc : c = 1 := rfl\n"})
    with case.owner():
        case.ok("sync", "W/B.lean")
        olean = case.root / ".lake/build/lib/lean/W/A.olean"
        before = olean.read_bytes()
        case.write({"W/C.lean": "def c : Nat := 2\n"})
        case.lake_run("build", "W.A")
        assert olean.read_bytes() == before, "direct import olean should stay unchanged"
        case.refused("save", "W/B.lean", changed=["W.C"])
        case.untrusted("W.B")


def legacy_private_body(case):
    case.project({"W.lean": "import W.A\n",
                  "W/C.lean": "module\n\npublic def value : Nat := 0\n",
                  "W/B.lean": "module\n\npublic import W.C\n",
                  "W/A.lean": "import W.B\n\ntheorem p : value = 0 := rfl\n"})
    with case.owner():
        case.ok("sync", "W/A.lean")
        b_trace = case.root / ".lake/build/lib/lean/W/B.trace"
        before = b_trace.read_bytes()
        case.write({"W/C.lean": "module\n\npublic def value : Nat := 1\n"})
        case.lake_run("build", "W.C", "W.B")
        assert b_trace.read_bytes() == before, "the direct module import's trace should stay unchanged"
        case.refused("save", "W/A.lean", changed=["W.C"])
        case.untrusted("W.A")


def split_namespace(case):
    dependency = case.root.parent / "dependency"
    case.write({"lean-toolchain": case.toolchain + "\n",
                "lakefile.toml": 'name = "dep"\n[[lean_lib]]\nname = "Remote"\nroots = ["Shared.Remote"]\n',
                "Shared/Remote.lean": "def remote : Nat := 1\n"}, root=dependency)
    case.project({"Shared/Local.lean": "def localValue : Nat := 0\n",
                  "App.lean": "import Shared.Local\nimport Shared.Remote\n\ntheorem q : localValue = 0 := rfl\n"},
                 lakefile='name = "app"\ndefaultTargets = ["Local", "App"]\n'
                          '[[require]]\nname = "dep"\npath = "../dependency"\n'
                          '[[lean_lib]]\nname = "Local"\nroots = ["Shared.Local"]\n'
                          '[[lean_lib]]\nname = "App"\n')
    with case.owner():
        case.ok("sync", "App.lean")
        case.write({"Shared/Local.lean": "def localValue : Nat := 1\n"})
        case.lake_run("build", "Shared.Local")
        case.refused("save", "App.lean", changed=["Shared.Local"])
        case.untrusted("App")


def rejected_close_save(case):
    case.project({"W.lean": "import W.B\n",
                  "W/A.lean": "def a : Nat := 1\n",
                  "W/B.lean": "import W.A\n\ntheorem ta : a = 1 := by\n  rfl\n"})
    outputs = [case.root / ".lake/build/lib/lean/W" / f"B.{ext}" for ext in ("olean", "ilean", "trace")]
    with case.owner():
        version = case.ok("sync", "W/B.lean")["version"]
        handle = case.ok("run-at-handle", "W/B.lean", str(version), "3", "2", "skip")["handle"]
        before = digest(outputs)
        case.write({"W/A.lean": "def a : Nat := 1\ndef a2 : Nat := 2\n"})
        case.lake_run("build", "W.A")
        case.refused("close-save", "W/B.lean", changed=["W.A"])
        assert digest(outputs) == before, "a refused close-save must keep the previous checkpoint"
        files = case.ok("open-files")["session"]["files"]
        assert any(f["path"] == "W/B.lean" for f in files), files
        continued = case.ok("run-with", "W/B.lean", json.dumps(handle), "rfl")
        assert continued["success"], continued


def beam_saved_dependency(case):
    case.project({"W.lean": "import W.B\n",
                  "W/A.lean": "def a : Nat := 1\n",
                  "W/B.lean": "import W.A\n\ntheorem ta : a = 1 := rfl\n"})
    with case.owner():
        case.ok("sync", "W/B.lean")
        case.write({"W/A.lean": "def a : Nat := 1\ndef a2 : Nat := 2\n"})
        case.ok("save", "W/A.lean")
        response = case.beam("save", "W/B.lean")
        assert response["error"]["code"] in ("syncBarrierIncomplete", "saveImportsChanged"), response
        case.ok("refresh", "W/B.lean")
        case.ok("save", "W/B.lean")
        case.trusted("W.B")


def unchanged_imports(case):
    case.project({"W.lean": "import W.B\n",
                  "W/A.lean": "def a : Nat := 1\n",
                  "W/B.lean": "import W.A\n\ntheorem ta : a = 1 := rfl\n"})
    with case.owner():
        for index in range(3):
            case.write({"W/B.lean": f"import W.A\n\ntheorem ta : a = 1 := rfl\ntheorem t{index} : a + {index} = {index + 1} := rfl\n"})
            case.ok("save", "W/B.lean")
        case.trusted("W.B")


def inherited_search_path(case):
    case.project({"W.lean": "import W.B\n",
                  "W/A.lean": "def a : Nat := 1\n",
                  "W/B.lean": "import W.A\n\ntheorem ta : a = 1 := rfl\n"})
    # As under `lake env lean-beam serve`: Lake prepends the same library directory again.
    with case.owner(LEAN_PATH=str(case.root / ".lake/build/lib/lean")):
        case.ok("save", "W/B.lean")
        case.ok("refresh", "W/B.lean")
        case.ok("save", "W/B.lean")
        case.trusted("W.B")


CASES = [external_rebuild, transitive_unchanged_olean, legacy_private_body, split_namespace,
         rejected_close_save, beam_saved_dependency, unchanged_imports, inherited_search_path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installation", type=Path, default=os.environ.get("BEAM_TEST_INSTALLATION"))
    parser.add_argument("--toolchain", default=(REPO / "lean-toolchain").read_text().strip())
    parser.add_argument("--keep", action="store_true", help="keep the temporary projects")
    args = parser.parse_args()
    if args.installation is None:
        parser.error("provide --installation or run tests/test-beam-slow.sh")
    installation = args.installation.resolve(strict=True)
    manifest = json.loads((installation / "manifest.json").read_text())
    target, = [t for t in manifest["components"]["targets"] if t["toolchain"] == args.toolchain]
    base = Path(tempfile.mkdtemp(prefix="beam-save-import-basis-")).resolve()
    try:
        for case in CASES:
            print(f"save import basis: {case.__name__}", flush=True)
            case(Case(base, case.__name__, installation, target))
    finally:
        if args.keep:
            print(f"kept {base}", file=sys.stderr)
        else:
            shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    main()
