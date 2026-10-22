#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.
"""Directed regression for private preparation and broker-only canonical publication.

Build: lake build Beam.LSP:shared BeamPrivateSaveGate:shared beam-daemon-fixture
Run: python3 tests/test-private-save-publication.py --output .review/r2-run

The wait failure and pre-handler gate are injected. Both artifact publications use the unchanged
production handler. This experiment does not establish an ordinary OS wait failure, descendant
termination policy, or arbitrary interleaving/coherence property.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from mcp_test_util import shared_lib_name

REPO = Path(__file__).resolve().parent.parent


def live(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                            capture_output=True, text=True, check=False)
    state = result.stdout.strip()
    return bool(state) and not state.startswith("Z")


def stop_owned_group(proc):
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            break
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            continue


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--ordinary", action="store_true")
    parser.add_argument("--module", action="store_true")
    args = parser.parse_args()
    if os.name != "posix":
        raise SystemExit("This bounded investigation driver currently requires POSIX process groups.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    project = output / "project"
    project.mkdir()
    (project / "lean-toolchain").write_text((REPO / "lean-toolchain").read_text())
    prefix = Path(subprocess.check_output(["lean", "--print-prefix"], cwd=REPO, text=True).strip())
    production_plugin = REPO / ".lake" / "build" / "lib" / shared_lib_name()
    plugin = REPO / ".lake" / "build" / "lib" / shared_lib_name().replace("Beam_LSP", "BeamPrivateSaveGate")
    daemon = REPO / ".lake" / "build" / "bin" / "beam-daemon-fixture"
    missing = [str(path) for path in (production_plugin, plugin, daemon) if not path.is_file()]
    if missing:
        raise RuntimeError("Missing probe build artifacts: " + ", ".join(missing) +
                           "; run lake build Beam.LSP:shared BeamPrivateSaveGate:shared beam-daemon-fixture")
    # Lean plugins on POSIX leave imported-library symbols for the loader. Load the production
    # plugin first using Lake's normal server arguments; the broker appends the gate plugin.
    server_args = json.dumps([f"--plugin={production_plugin}"])
    (project / "lakefile.toml").write_text(
        'name = "Main"\nmoreGlobalServerArgs = ' + server_args + '\n[[lean_lib]]\nname = "Main"\n')
    command = [str(daemon), "--lean-cmd", str(prefix / "bin" / "lean"),
               "--lean-plugin", str(plugin), "private-publication-test", str(project)]
    started = time.monotonic()
    with (output / "fixture.stdout").open("w") as stdout, (output / "fixture.stderr").open("w") as stderr:
        proc = subprocess.Popen(command, cwd=REPO, stdout=stdout, stderr=stderr,
                                start_new_session=True,
                                env=dict(os.environ, BEAM_PRIVATE_EFFECT_GATE=str(output),
                                         BEAM_PRIVATE_ORDINARY="1" if args.ordinary else "0",
                                         BEAM_PRIVATE_MODULE="1" if args.module else "0"))
        verified_cleanup = False
        try:
            try:
                code = proc.wait(timeout=90)
            except subprocess.TimeoutExpired:
                (output / "release").touch()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    stop_owned_group(proc)
                raise RuntimeError("private publication experiment exceeded its outer bound; evidence is incomplete")
            if code:
                raise RuntimeError(f"private publication fixture exited {code}; inspect {output / 'fixture.stderr'}")
            report = json.loads((output / "observation.json").read_text())
            for field in ("replacementArtifacts", "afterOldCanonicalArtifacts", "oldPrivateArtifacts"):
                for artifact in report[field] or []:
                    artifact["sha256"] = hashlib.sha256(Path(artifact["copy"]).read_bytes()).hexdigest()
            worker = report["gateEntry"]["workerPid"]
            leader = report["oldBackendPid"]
            deadline = time.monotonic() + 5
            while (live(worker) or live(leader)) and time.monotonic() < deadline:
                time.sleep(.05)
            cleanup = {"leaderAlive": live(leader), "workerAlive": live(worker)}
            report["realOwnerCleanup"] = cleanup
            report["elapsedSeconds"] = round(time.monotonic() - started, 3)
            report["sourceCommit"] = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=REPO, text=True).strip()
            sources = ("Beam/Broker/Server.lean", "Beam/Broker/Publication.lean", "Beam/LSP/Save.lean",
                       "Beam/Broker/LakeSave.lean", "Beam/Broker/LakeHelper.lean",
                       "model/BeamModel/Publication.lean", "model/BeamModel/PublicationLaws.lean",
                       "lakefile.lean", "tests/lean/BeamTest/Broker/DaemonFixture.lean",
                       "tests/lean/BeamPrivateSaveGate.lean", "tests/lean/BeamTest/Broker/PrivatePublicationTest.lean",
                       "tests/test-private-save-publication.py")
            report["fixtureSourceSha256"] = {
                name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in sources}
            report["productionPluginSha256"] = hashlib.sha256(production_plugin.read_bytes()).hexdigest()
            report["gatePluginSha256"] = hashlib.sha256(plugin.read_bytes()).hexdigest()
            report["fixtureExecutableSha256"] = hashlib.sha256(daemon.read_bytes()).hexdigest()
            report["sourceStatus"] = subprocess.check_output(
                ["git", "status", "--short"], cwd=REPO, text=True).splitlines()
            report["evidenceLimit"] = (
                "Injected BackendProcess wait failure and one-shot pre-handler gate; original production "
                "save handler generates both artifact sets. This checks one selected "
                "schedule, not arbitrary publication coherence or crash atomicity.")
            (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
            if any(cleanup.values()):
                stop_owned_group(proc)
                raise RuntimeError(f"private publication experiment left a live owned process: {cleanup}")
            verified_cleanup = True
            print(json.dumps({key: report[key] for key in (
                "replacementFinishedWhileOldHeld", "replacementPublishedWhileOldHeld",
                "canonicalUnchangedAfterOldCompletion",
                "controlledFailedWaits", "controlledSignals", "realOwnerCleanup", "elapsedSeconds")}, indent=2))
            print(f"Regression evidence: {output / 'report.json'}")
        finally:
            (output / "release").touch()
            if not verified_cleanup:
                stop_owned_group(proc)


if __name__ == "__main__":
    main()
