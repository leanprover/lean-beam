#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Project SDK binding stays independent of the ambient build SDK; no Lean subprocesses."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / 'tests/lib/project-sdk.sh'


class ProjectSdkTest(unittest.TestCase):
    def check_binding(self, *, selection_status=0, marker=True, executable=True, tool='lake',
                      alias_project=False):
        with tempfile.TemporaryDirectory(prefix='beam-project-sdk-') as directory:
            root = Path(directory)
            project = root / 'project with spaces'
            project.mkdir()
            if alias_project:
                alias = root / 'project alias'
                alias.symlink_to(project, target_is_directory=True)
                project = alias
            if marker:
                (project / 'lean-toolchain').write_text('fixture-sdk\n')
            oracle = root / 'project SDK' / tool
            oracle.parent.mkdir()
            oracle.write_text('#!/bin/sh\nexit 0\n')
            oracle.chmod(0o755 if executable else 0o644)
            ambient = root / 'ambient-bin'
            ambient.mkdir()
            (ambient / tool).write_text('#!/bin/sh\nexit 99\n')
            (ambient / tool).chmod(0o755)
            elan = ambient / 'elan'
            receipt = root / 'selection.json'
            elan.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
Path(os.environ['SDK_RECEIPT']).write_text(json.dumps({
 'cwd':os.getcwd(), 'args':sys.argv[1:], 'override':os.environ.get('ELAN_TOOLCHAIN')}))
print(os.environ['SDK_ORACLE'])
raise SystemExit(int(os.environ['SDK_STATUS']))
''')
            elan.chmod(0o755)
            env = dict(os.environ, PATH=str(ambient)+os.pathsep+os.environ['PATH'],
                       ELAN_TOOLCHAIN='ambient-build-sdk', SDK_ORACLE=str(oracle),
                       SDK_RECEIPT=str(receipt), SDK_STATUS=str(selection_status))
            result = subprocess.run(['bash', '-c',
                'set -eu; . "$1"; beam_test_project_command "$2" "$3"; '
                '[ "$ELAN_TOOLCHAIN" = ambient-build-sdk ]',
                'binding-test', str(HELPER), str(project), tool], cwd=ROOT,
                env=env, text=True, capture_output=True, timeout=5)
            return result, json.loads(receipt.read_text()) if receipt.exists() else None, str(oracle), str(project.resolve())

    def test_project_context_wins_over_path_and_inherited_override(self):
        for tool in ['lean', 'lake']:
            with self.subTest(tool=tool):
                result, receipt, oracle, project = self.check_binding(tool=tool)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, oracle+'\n')
                self.assertEqual(receipt, {'cwd':project, 'args':['which',tool], 'override':None})

    @unittest.skipUnless(os.name == 'posix', 'fixture uses a directory symlink')
    def test_project_alias_selects_the_same_physical_context(self):
        result, receipt, oracle, project = self.check_binding(alias_project=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, oracle+'\n')
        self.assertEqual(receipt, {'cwd':project, 'args':['which','lake'], 'override':None})

    def test_selection_failure_does_not_fall_back_or_emit_partial_path(self):
        result, receipt, _, _ = self.check_binding(selection_status=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(result.stdout, '')
        self.assertIsNotNone(receipt)

    def test_missing_selector_fails_before_selection(self):
        result, receipt, _, _ = self.check_binding(marker=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('readable lean-toolchain', result.stderr)
        self.assertIsNone(receipt)

    def test_nonexecutable_selected_tool_is_an_error(self):
        result, _, _, _ = self.check_binding(executable=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('not executable', result.stderr)

    def test_only_named_sdk_tools_are_accepted(self):
        result, receipt, _, _ = self.check_binding(tool='other')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unsupported project SDK command', result.stderr)
        self.assertIsNone(receipt)


if __name__ == '__main__':
    unittest.main()
