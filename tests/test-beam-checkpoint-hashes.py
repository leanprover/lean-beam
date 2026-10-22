#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""A checkpoint must invalidate output hashes before an unchanged consumer is built."""

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
CASES = ["save", "close-save", "save-module", "close-save-module",
         "hash-error", "close-hash-error"]
OUTPUT_FIELDS = ["olean", "ilean", "c", "oleanServer", "oleanPrivate", "ir", "irSig", "bc"]
OUTPUT_SUFFIXES = (".olean", ".olean.server", ".olean.private", ".ilean", ".c", ".ir", ".ir.sig", ".bc")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(paths):
    return {str(path): digest(path) for path in sorted(paths) if path.is_file()}


def family(project, name):
    build = project / ".lake/build"
    return [path for directory in [build / "lib/lean/Freshness", build / "ir/Freshness"]
            for path in directory.glob(name + ".*") if path.is_file()]


def publication_leftovers(project, name):
    build = project / ".lake/build"
    return sorted(str(path) for directory in [build / "lib/lean/Freshness", build / "ir/Freshness"]
                  for path in directory.iterdir()
                  if (path.name.startswith(name + ".") and
                      any(marker in path.name for marker in (".beam-backup-", ".beam-save-tmp-")))
                  or path.name.startswith(".beam-save-tmp-"))


def command(report, directory, args, *, check=True):
    env = dict(os.environ, BEAM_SESSION_ROOT=report["session_root"],
               LAKE_CACHE_DIR=report["lake_cache"])
    result = run_with_watchdog(args, cwd=directory, env=env, timeout=90)
    index = len(report["commands"])
    log = Path(report["evidence"]) / f"command-{index}"
    log.with_suffix(".stdout").write_text(result.stdout)
    log.with_suffix(".stderr").write_text(result.stderr)
    report["commands"].append({"cwd": str(directory), "argv": [str(x) for x in args],
                               "exit_code": result.returncode, "log": str(log)})
    if check:
        assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return result


def beam(report, project, wrapper, *args, check=True):
    return command(report, project, [wrapper, "--root", project, *args], check=check)


@contextmanager
def owner(report, project, wrapper):
    stdout = Path(report["evidence"]) / "owner.stdout"
    stderr = Path(report["evidence"]) / "owner.stderr"
    with stdout.open("w") as out, stderr.open("w") as err:
        process = subprocess.Popen([wrapper, "--root", project, "serve"],
                                   cwd=project, stdout=out, stderr=err,
                                   env=dict(os.environ, BEAM_SESSION_ROOT=report["session_root"],
                                            LAKE_CACHE_DIR=report["lake_cache"]))
        report["owner_pid"] = process.pid
        try:
            deadline = time.monotonic() + 60
            while "serving Beam session" not in stderr.read_text():
                assert process.poll() is None, stderr.read_text()
                assert time.monotonic() < deadline, stderr.read_text()
                time.sleep(0.05)
            yield process
        finally:
            failed = sys.exc_info()[0] is not None
            errors = []
            try:
                stopped = beam(report, project, wrapper, "stop", check=False)
                if stopped.returncode:
                    errors.append(f"stop exited {stopped.returncode}: {stopped.stderr}")
                process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired) as error:
                errors.append(str(error))
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=10)
            report["owner_exit"] = process.returncode
            if process.returncode != 0:
                errors.append(f"owner exited {process.returncode}")
            report["cleanup_errors"] = errors
            if not failed:
                assert not errors, errors


def mapped_runtime(owner_pid, lean, plugin):
    """Record only this owner's descendants; Linux samples are not shutdown evidence."""
    if not Path("/proc/self/maps").exists():
        return {"available": False}
    pending, seen, records = [owner_pid], set(), []
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        proc = Path("/proc") / str(pid)
        try:
            for task in (proc / "task").iterdir():
                pending.extend(int(p) for p in (task / "children").read_text().split())
            executable = (proc / "exe").resolve(strict=True)
            mappings = (proc / "maps").read_text().splitlines()
        except (FileNotFoundError, ProcessLookupError):
            continue
        for line in mappings:
            fields = line.split(maxsplit=5)
            if len(fields) == 6 and fields[5] == str(plugin):
                assert executable == lean, (pid, executable, lean)
                records.append({"pid": pid, "executable": str(executable), "plugin_map": line})
    assert records, "the owned Lean worker did not map the selected plugin"
    return {"available": True, "workers": records}


def check_case(base, case, installation, target, report):
    evidence = base / case
    evidence.mkdir()
    project = evidence / "project"
    (project / "Freshness").mkdir(parents=True)
    case_report = {"evidence": str(evidence), "session_root": str(evidence / "sessions"),
                   "lake_cache": str(evidence / "lake-cache"), "commands": [], "cleanup_errors": []}
    report["cases"][case] = case_report
    module = case.endswith("-module")
    public = "public " if module else ""
    prefix = "module\n\n" if module else ""
    original = (prefix + "namespace Freshness\n" + ("@[expose] " if module else "") +
                public + "def value : Nat := 7\n" +
                public + "theorem value_eq : value = 7 := rfl\nend Freshness\n")
    weakened = original.replace("value_eq : value = 7 := rfl", "value_eq : True := by trivial")
    provider = project / "Freshness/Provider.lean"
    provider.write_text(original)
    (project / "Freshness/Consumer.lean").write_text(
        "import Freshness.Provider\nexample : Freshness.value = 7 := Freshness.value_eq\n")
    (project / "lakefile.toml").write_text('name = "Freshness"\n[[lean_lib]]\nname = "Freshness"\n')
    (project / "lean-toolchain").write_text(target["toolchain"] + "\n")
    lean = Path(target["lean"]).resolve(strict=True)
    lake = lean.parent / ("lake.exe" if os.name == "nt" else "lake")
    wrapper = installation / "bin/lean-beam"
    command(case_report, project, [lake, "build", "Freshness.Consumer"])
    consumer_before = inventory([project / "Freshness/Consumer.lean", *family(project, "Consumer")])
    prior_outputs = [p for p in family(project, "Provider") if p.name.endswith(OUTPUT_SUFFIXES)]
    prior_bytes = inventory(prior_outputs)
    sidecars = [Path(str(path) + ".hash") for path in prior_outputs]
    assert sidecars and all(path.is_file() for path in sidecars), sidecars
    case_report["consumer_before"] = consumer_before
    case_report["provider_before"] = inventory(family(project, "Provider"))
    sentinels = [project / ".lake/build/lib/lean/Freshness/Provider.ltar.hash",
                 project / ".lake/build/lib/lean/Freshness/Unrelated.olean.hash"]
    for sentinel in sentinels:
        if not sentinel.exists():
            sentinel.write_text("0123456789abcdef")
    sentinel_before = inventory(sentinels)
    # Change only the provider source, before its first open in Beam.
    provider.write_text(weakened)
    blocked = case in ("hash-error", "close-hash-error")
    if blocked:
        # This failure fixture does not perform the consumer freshness experiment.
        obstruction = project / ".lake/build/lib/lean/Freshness/Provider.olean.hash"
        obstruction.rename(evidence / "prior-provider.olean.hash")
        obstruction.mkdir()
    operation = "close-save" if case.startswith("close-") else "save"
    with owner(case_report, project, wrapper) as process:
        synced = json.loads(beam(case_report, project, wrapper, "sync", "Freshness/Provider.lean").stdout)
        assert synced["ok"] and synced["result"]["readiness"]["saveReady"], synced
        case_report["mapped_runtime"] = mapped_runtime(process.pid, lean, installation / target["plugin"])
        result = beam(case_report, project, wrapper, operation, "Freshness/Provider.lean", check=False)
        response = json.loads(result.stdout)
        case_report["checkpoint"] = response
        # Observe publication cleanup before owner shutdown, without changing Lake's next verdict.
        leftovers = publication_leftovers(project, "Provider")
        case_report["publication_leftovers"] = leftovers
        assert not leftovers, ("checkpoint left owned publication files", leftovers)
        if blocked:
            assert result.returncode != 0 and not response["ok"], response
            assert response["error"]["code"] == "internalError", response
            assert inventory(prior_outputs) == prior_bytes, "hash failure replaced canonical artifact bytes"
        else:
            assert result.returncode == 0 and response["ok"], response
    case_report["consumer_before_verdict"] = inventory(
        [project / "Freshness/Consumer.lean", *family(project, "Consumer")])
    assert case_report["consumer_before_verdict"] == consumer_before, "checkpoint changed the consumer"
    assert inventory(sentinels) == sentinel_before, "checkpoint invalidated an unwritten output hash"
    if blocked:
        assert not (project / ".lake/build/lib/lean/Freshness/Provider.trace").exists()
        return
    saved = response["result"]["saved"] if operation == "close-save" else response["result"]
    paths = [Path(saved[key]) for key in OUTPUT_FIELDS if key in saved]
    case_report["provider_before_verdict"] = inventory(family(project, "Provider"))
    assert digest(Path(saved["olean"])) != prior_bytes[str(Path(saved["olean"]))]
    # No sidecar repair, direct elaboration, cleaning, forced build or rehash precedes this verdict.
    verdict = command(case_report, project, [lake, "build", "Freshness.Consumer"], check=False)
    case_report["first_incremental_exit"] = verdict.returncode
    assert verdict.returncode != 0, "unchanged consumer was falsely reused after the provider weakened"
    assert "type mismatch" in (verdict.stdout + verdict.stderr).lower(), (verdict.stdout, verdict.stderr)
    # Check the snapshot taken before Lake had a chance to recreate output hash caches.
    before_verdict = case_report["provider_before_verdict"]
    assert all(str(path) + ".hash" not in before_verdict for path in paths), before_verdict
    if module:
        assert all(key in saved for key in ["oleanServer", "oleanPrivate", "ir", "irSig"]), saved
    case_report["written_outputs"] = [str(path) for path in paths]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installation", type=Path, default=os.environ.get("BEAM_TEST_INSTALLATION"))
    parser.add_argument("--toolchain", default=(REPO / "lean-toolchain").read_text().strip())
    parser.add_argument("--case", choices=CASES)
    parser.add_argument("--keep", type=Path)
    args = parser.parse_args()
    if args.installation is None:
        parser.error("provide --installation or run tests/test-beam-slow.sh")
    installation = args.installation.resolve(strict=True)
    manifest = json.loads((installation / "manifest.json").read_text())
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
    assert manifest["sourceCommit"] == source, "test installation was not constructed from this source head"
    target, = [t for t in manifest["components"]["targets"] if t["toolchain"] == args.toolchain]
    paths = [installation / "manifest.json", installation / "bin/lean-beam",
             installation / manifest["components"]["frontends"]["cli"],
             installation / target["daemon"], installation / target["plugin"], Path(target["lean"])]
    identity = inventory(paths)
    lean_revision = subprocess.check_output([target["lean"], "--githash"], text=True).strip()
    assert lean_revision == target["compilerRevision"], (lean_revision, target)
    base = (args.keep.resolve() if args.keep else
            Path(tempfile.mkdtemp(prefix="beam-checkpoint-hashes-")).resolve())
    if args.keep:
        base.mkdir(parents=True, exist_ok=False)
    report = {"source_head": source, "installation": str(installation), "target": target,
              "native_identity": identity, "cases": {}, "ok": False}
    try:
        for case in [args.case] if args.case else CASES:
            check_case(base, case, installation, target, report)
        assert inventory(paths) == identity, "selected native runtime changed during the regression"
        report["ok"] = True
    except BaseException as error:
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        (base / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        if report["ok"] and not args.keep:
            shutil.rmtree(base)
        else:
            print(f"checkpoint hash evidence retained at {base}", flush=True)


if __name__ == "__main__":
    main()
