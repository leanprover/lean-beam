#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Exercise macOS admission against actual PR-shaped Git histories and file modes."""

import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("ci_macos", ROOT / "scripts/ci-macos.py")
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)


class MacOSCoverageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="beam-ci-macos-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "repo with spaces"
        self.root.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_PARAMETERS="",
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        # Scope every Git subprocess, including the classifier and shallow clones. Automatic
        # maintenance and filesystem monitoring have no place in a temporary history fixture.
        settings = {"maintenance.auto": "false", "gc.auto": "0", "gc.autoDetach": "false",
                    "core.fsmonitor": "false"}
        self.env["GIT_CONFIG_COUNT"] = str(len(settings))
        for index, (key, value) in enumerate(settings.items()):
            self.env[f"GIT_CONFIG_KEY_{index}"] = key
            self.env[f"GIT_CONFIG_VALUE_{index}"] = value
        environment = patch.dict(os.environ, self.env)
        environment.start()
        self.addCleanup(environment.stop)
        self.git("init", "-q", "--object-format=sha1")
        for path in ["README.md", "docs/Old.md", "Beam/Probe.lean"]:
            self.write(path)
        self.base = self.commit()

    def git(self, *arguments):
        return subprocess.check_output(["git", "-c", "commit.gpgsign=false", *arguments],
                                       cwd=self.root, env=self.env, stderr=subprocess.PIPE,
                                       timeout=15).decode().strip()

    def write(self, path, text="fixture\n"):
        file = self.root / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text, encoding="utf-8")

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-qm", "fixture", "--allow-empty")
        return self.git("rev-parse", "HEAD")

    def pull_request(self):
        head = self.commit()
        merge = self.git("commit-tree", "HEAD^{tree}", "-p", self.base, "-p", head,
                         "-m", "synthetic PR merge")
        self.git("update-ref", "HEAD", merge)
        return {"pull_request": {"base": {"sha": self.base}, "head": {"sha": head},
                                 "merge_commit_sha": merge}}

    def profile(self, event, repo=None, name="pull_request", merge=None):
        return coverage.classify_macos(repo or self.root, name, event,
                                       merge or self.git("rev-parse", "HEAD"))[0]

    def required(self, event, **options):
        return self.profile(event, **options) != coverage.Profile.SKIP

    def test_regular_documentation(self):
        self.write("README.md", "updated\n")
        self.write("docs/Guide λ.md")
        self.write("skills/lean-beam/EXAMPLES.md")
        self.assertFalse(self.required(self.pull_request()))

    def test_fixture_git_does_not_start_automatic_services(self):
        # Even a repository requesting maintenance must remain owned by this fixture.
        self.git("config", "maintenance.auto", "true")
        self.git("config", "gc.auto", "0")
        trace = Path(self.temporary.name) / "git-trace.jsonl"
        self.env["GIT_TRACE2_EVENT"] = str(trace)
        self.commit()
        children = [event.get("argv", []) for line in trace.read_text().splitlines()
                    if (event := json.loads(line)).get("event") == "child_start"]
        self.assertFalse(any("maintenance" in command or "gc" in command
                             or "fsmonitor--daemon" in command for command in children), children)

    def test_verified_source_uses_platform_profile(self):
        for path in ["Beam/Probe.lean", "native/control_dir.c",
                     "scripts/install-beam.sh"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path, "changed\n")
                self.assertEqual(self.profile(self.pull_request()), coverage.Profile.PLATFORM)

    def test_ci_and_driver_changes_use_full_profile(self):
        for path in ["tests/test-probe.py", "tests/fixtures/data.json", ".github/workflows/ci.yml",
                     "scripts/ci-macos.py", "scripts/validate-defensive.sh", "scripts/check-links.sh",
                     "scripts/build-toolchain.cmake", "scripts/install-toolchain.cmake",
                     "scripts/toolchain-manifest.cmake", "lean-toolchain", "validated-lean-toolchains",
                     "compatible-lean-release-lines", "lake-manifest.json", "lakefile.toml", "lakefile.lean",
                     "tests/BeamTest/Probe.lean", "BeamTest/Probe.lean"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path, "changed\n")
                self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)

    def test_unknown_paths_and_metadata_use_full_profile(self):
        self.write("unknown.md")
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)
        self.assertEqual(self.profile({}), coverage.Profile.FULL)
        self.assertEqual(self.profile({}, name="push"), coverage.Profile.FULL)
        self.assertEqual(self.profile({}, name="workflow_dispatch"), coverage.Profile.FULL)

    @unittest.skipUnless(os.name == "posix", "requires POSIX file modes")
    def test_existing_executable_source_uses_platform_profile(self):
        self.write("scripts/probe.sh")
        (self.root / "scripts/probe.sh").chmod(0o755)
        self.base = self.commit()
        self.write("scripts/probe.sh", "updated\n")
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.PLATFORM)

    def test_markdown_deletion_and_rename(self):
        (self.root / "docs/Old.md").rename(self.root / "docs/New.md")
        (self.root / "README.md").unlink()
        self.assertFalse(self.required(self.pull_request()))

    def test_source_workflow_native_and_unknown_paths(self):
        for path in ["Beam/Probe.lean", "Beam/README.md", "native/README.md", "native/test.c",
                     ".github/workflows/notes.md", ".github/workflows/ci.yml", "scripts/test.sh",
                     "lean-toolchain", "unknown.md", "docs/data.json", "docs/Guide.MD"]:
            with self.subTest(path=path):
                self.git("reset", "--hard", self.base)
                self.write(path, "changed\n")
                self.assertTrue(self.required(self.pull_request()))

    def test_source_renamed_to_markdown(self):
        (self.root / "Beam/Probe.lean").rename(self.root / "docs/Probe.md")
        self.assertTrue(self.required(self.pull_request()))

    def test_source_deletion(self):
        (self.root / "Beam/Probe.lean").unlink()
        self.write("README.md", "updated\n")
        self.assertTrue(self.required(self.pull_request()))

    @unittest.skipUnless(os.name == "posix", "requires POSIX file modes and symlinks")
    def test_markdown_links_and_executables(self):
        (self.root / "docs/Link.md").symlink_to("../Beam/Probe.lean")
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)
        self.git("reset", "--hard", self.base)
        self.git("config", "core.filemode", "true")
        (self.root / "README.md").chmod(0o755)
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)

    def test_control_characters_in_document_path(self):
        self.write("docs/line\nbreak.md")
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)

    def test_empty_delta_retains_coverage(self):
        self.assertEqual(self.profile(self.pull_request()), coverage.Profile.FULL)

    def test_main_manual_and_other_events(self):
        for name in ["push", "workflow_dispatch", "pull_request_target", "", None]:
            self.assertEqual(self.profile({}, name=name), coverage.Profile.FULL)

    def test_missing_or_invalid_metadata(self):
        for event in [None, [], {}, {"pull_request": None}, {"pull_request": {"base": {}}}]:
            self.assertEqual(self.profile(event), coverage.Profile.FULL)
        self.write("docs/New.md")
        event = self.pull_request()
        event["pull_request"]["base"]["sha"] = "--not-a-revision"
        self.assertEqual(self.profile(event), coverage.Profile.FULL)

    def test_checkout_and_parent_mismatch(self):
        self.write("docs/New.md")
        event = self.pull_request()
        self.assertEqual(self.profile(event, merge=self.base), coverage.Profile.FULL)
        event["pull_request"]["head"]["sha"] = self.base
        self.assertEqual(self.profile(event), coverage.Profile.FULL)

    def test_creation_event_without_merge_revision(self):
        self.write("docs/New.md")
        event = self.pull_request()
        event["pull_request"]["merge_commit_sha"] = None
        self.assertFalse(self.required(event))
        self.assertEqual(coverage.classify_macos(self.root, "pull_request", event, None)[0],
                         coverage.Profile.FULL)

    def test_missing_repository(self):
        self.write("docs/New.md")
        self.assertEqual(self.profile(self.pull_request(), repo=self.root / "missing"),
                         coverage.Profile.FULL)

    def test_two_commit_checkout_depth(self):
        self.write("docs/New.md")
        event = self.pull_request()
        for depth in [1, 2]:
            clone = Path(self.temporary.name) / f"depth-{depth}"
            self.git("clone", "-q", f"--depth={depth}", self.root.as_uri(), str(clone))
            self.assertEqual(self.required(event, repo=clone), depth == 1)

    def test_cli_output_and_unreadable_metadata(self):
        script = self.root / "scripts/ci-macos.py"
        script.parent.mkdir()
        shutil.copy2(ROOT / "scripts/ci-macos.py", script)
        self.base = self.commit()
        self.write("README.md", "updated\n")
        event = self.pull_request()
        event_file = Path(self.temporary.name) / "event.json"
        for contents, expected in [(json.dumps(event), "skip"), ("invalid JSON", "full")]:
            event_file.write_text(contents)
            result = subprocess.run([sys.executable, str(script)], env=dict(
                self.env, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event_file),
                GITHUB_SHA=event["pull_request"]["merge_commit_sha"]),
                capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result)
            self.assertEqual(result.stdout, f"profile={expected}\n", result)


if __name__ == "__main__":
    unittest.main()
