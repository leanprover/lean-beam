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
                        GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
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

    def required(self, event, repo=None, name="pull_request", merge=None):
        return coverage.requires_macos(repo or self.root, name, event,
                                        merge or self.git("rev-parse", "HEAD"))[0]

    def test_regular_documentation(self):
        self.write("README.md", "updated\n")
        self.write("docs/Guide λ.md")
        self.write("skills/lean-beam/EXAMPLES.md")
        self.assertFalse(self.required(self.pull_request()))

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
        self.assertTrue(self.required(self.pull_request()))
        self.git("reset", "--hard", self.base)
        self.git("config", "core.filemode", "true")
        (self.root / "README.md").chmod(0o755)
        self.assertTrue(self.required(self.pull_request()))

    def test_control_characters_in_document_path(self):
        self.write("docs/line\nbreak.md")
        self.assertTrue(self.required(self.pull_request()))

    def test_empty_delta_retains_coverage(self):
        self.assertTrue(self.required(self.pull_request()))

    def test_main_manual_and_other_events(self):
        for name in ["push", "workflow_dispatch", "pull_request_target", "", None]:
            self.assertTrue(self.required({}, name=name))

    def test_missing_or_invalid_metadata(self):
        for event in [None, [], {}, {"pull_request": None}, {"pull_request": {"base": {}}}]:
            self.assertTrue(self.required(event))
        self.write("docs/New.md")
        event = self.pull_request()
        event["pull_request"]["base"]["sha"] = "--not-a-revision"
        self.assertTrue(self.required(event))

    def test_checkout_and_parent_mismatch(self):
        self.write("docs/New.md")
        event = self.pull_request()
        self.assertTrue(self.required(event, merge=self.base))
        event["pull_request"]["head"]["sha"] = self.base
        self.assertTrue(self.required(event))

    def test_creation_event_without_merge_revision(self):
        self.write("docs/New.md")
        event = self.pull_request()
        event["pull_request"]["merge_commit_sha"] = None
        self.assertFalse(self.required(event))
        self.assertTrue(coverage.requires_macos(self.root, "pull_request", event, None)[0])

    def test_missing_repository(self):
        self.write("docs/New.md")
        self.assertTrue(self.required(self.pull_request(), repo=self.root / "missing"))

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
        for contents, expected in [(json.dumps(event), "false"), ("invalid JSON", "true")]:
            event_file.write_text(contents)
            result = subprocess.run([sys.executable, str(script)], env=dict(
                self.env, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event_file),
                GITHUB_SHA=event["pull_request"]["merge_commit_sha"]),
                capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result)
            self.assertEqual(result.stdout, f"macos={expected}\n", result)


if __name__ == "__main__":
    unittest.main()
