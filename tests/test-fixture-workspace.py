#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Workspace disposition preserves failures and only removes owned successful scratch trees."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / 'tests/lib/tmp-guards.sh'
# Match the helper's owned-path contract even when the OS default TMPDIR is elsewhere.


class FixtureWorkspaceTest(unittest.TestCase):
    def finish(self, path, status, *, prefix='beam-fixture-workspace', failed_cleanup=False):
        script = '''
set -eu
. "$1"
'''
        if failed_cleanup:
            script += 'beam_test_remove_owned_tmp_tree() { return 57; }\n'
        script += '''
trap 'fixture_status=$?; beam_test_finish_workspace "$fixture_status" "$2" "$4"; exit "$?"' EXIT
exit "$3"
'''
        return subprocess.run(['bash', '-c', script, 'workspace-test', str(HELPER), str(path),
                               str(status), prefix], cwd=ROOT, text=True, capture_output=True, timeout=5)

    def test_success_removes_owned_workspace(self):
        with tempfile.TemporaryDirectory(prefix='beam-fixture-workspace-', dir='/tmp') as directory:
            path = Path(directory) / 'case'
            path.mkdir()
            (path / 'evidence').write_text('source bytes')
            result = self.finish(path, 0)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(path.exists())

    def test_failure_keeps_original_bytes_and_exit_status(self):
        with tempfile.TemporaryDirectory(prefix='beam-fixture-workspace-', dir='/tmp') as directory:
            path = Path(directory)
            (path / 'evidence').write_bytes(b'original\x00bytes')
            result = self.finish(path, 23)
            self.assertEqual(result.returncode, 23)
            self.assertIn(str(path), result.stderr)
            self.assertEqual((path / 'evidence').read_bytes(), b'original\x00bytes')

    def test_failed_success_cleanup_is_not_reported_as_success(self):
        with tempfile.TemporaryDirectory(prefix='beam-fixture-workspace-', dir='/tmp') as directory:
            result = self.finish(directory, 0, failed_cleanup=True)
            self.assertEqual(result.returncode, 57)
            self.assertTrue(Path(directory).exists())

    def test_failed_case_does_not_attempt_destructive_cleanup(self):
        with tempfile.TemporaryDirectory(prefix='beam-fixture-workspace-', dir='/tmp') as directory:
            result = self.finish(directory, 23, failed_cleanup=True)
            self.assertEqual(result.returncode, 23)
            self.assertTrue(Path(directory).exists())

    def test_unowned_path_is_rejected_without_changes(self):
        with tempfile.TemporaryDirectory(prefix='unrelated-workspace-', dir='/tmp') as directory:
            path = Path(directory)
            (path / 'keep').write_text('keep')
            result = self.finish(path, 0)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('refusing to touch', result.stderr)
            self.assertEqual((path / 'keep').read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
