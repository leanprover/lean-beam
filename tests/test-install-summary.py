#!/usr/bin/env python3
# Copyright (c) 2026 Lean FRO LLC. All rights reserved.
# Released under Apache 2.0 license as described in the file LICENSE.

"""Installer summaries describe this run without inspecting or rewriting client config."""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class InstallSummaryTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="beam-install-summary-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.codex = self.home / "codex"
        self.codex.mkdir()
        self.config = self.codex / "config.toml"
        self.config.write_text('[mcp_servers.lean-beam]\ncommand = "/existing/lean-beam-mcp"\n')

    def summary(self, actions="", selected_home=None):
        before = {p.relative_to(self.home): (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in self.home.rglob("*") if p.is_file()}
        result = subprocess.run([
            "bash", "-eu", "-c", """
. scripts/install-beam.sh
set_codex_home "$1"
bin_home="$HOME/bin"
""" + actions + "\nprint_agent_setup_summary\n", "installer-summary", str(selected_home or self.codex)],
            cwd=ROOT, env=dict(os.environ, HOME=str(self.home), CODEX_HOME=str(self.codex)),
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result)
        after = {p.relative_to(self.home): (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in self.home.rglob("*") if p.is_file()}
        self.assertEqual(before, after, "summary must not rewrite or create client configuration")
        self.assertIn("Agent Setup This Run", result.stderr)
        self.assertIn("only this run; existing client setup is not checked here", result.stderr)
        self.assertIn("optional; existing client setup may already be complete", result.stderr)
        return result.stderr

    def test_preexisting_registration_is_not_reported_absent(self):
        output = self.summary()
        self.assertIn("MCP: not registered this run", output)
        self.assertNotIn("MCP: not registered\n", output)
        self.assertIn("--codex --codex-mcp", output)

    def test_unrequested_registration_without_existing_config(self):
        self.config.unlink()
        output = self.summary()
        self.assertIn("MCP: not registered this run", output)

    def test_skipped_registration_does_not_claim_success(self):
        output = self.summary("prompt_mcp_registration_selection <<< 'none'\nregister_requested_mcp_servers")
        self.assertNotIn("MCP: registered this run", output)
        self.assertIn("MCP: not registered this run", output)

    def test_current_run_actions_and_manual_instructions_are_distinct(self):
        output = self.summary('''
installed_skill_targets=("Codex: fixture" "Claude Code: fixture" "Pi Agent: fixture"
                         "OpenCode: fixture" "Mistral Vibe: fixture")
registered_mcp_targets=("Codex: lean-beam" "Claude Code: lean-beam" "Mistral Vibe: lean-beam")
manual_mcp_targets=("OpenCode: lean-beam")
''')
        self.assertEqual(output.count("MCP: registered this run"), 3)
        self.assertEqual(output.count("skills: lean-beam installed this run"), 5)
        self.assertIn("MCP: opencode mcp add shown this run", output)
        self.assertIn("MCP: unsupported", output)
        self.assertNotIn("--codex-mcp", output)

    def test_mixed_client_actions_keep_rows_and_hints_independent(self):
        output = self.summary('''
installed_skill_targets=("Codex: fixture" "Pi Agent: fixture")
registered_mcp_targets=("Claude Code: lean-beam")
manual_mcp_targets=("OpenCode: lean-beam")
''')
        expected = {
            "Codex": "skills: lean-beam installed this run; MCP: not registered this run",
            "Claude Code": "skills: not installed this run; MCP: registered this run",
            "Pi Agent": "skills: lean-beam installed this run; MCP: unsupported",
            "OpenCode": "skills: not installed this run; MCP: opencode mcp add shown this run",
            "Mistral Vibe": "skills: not installed this run; MCP: not registered this run",
            "Codex MCP": "./scripts/install-beam.sh --codex-mcp",
            "Claude Lean skill": "./scripts/install-beam.sh --claude",
            "OpenCode Lean skill": "./scripts/install-beam.sh --opencode",
            "Mistral Vibe setup": "./scripts/install-beam.sh --vibe --vibe-mcp",
        }
        for label, value in expected.items():
            with self.subTest(label=label):
                self.assertRegex(output, rf"(?m)^ +{re.escape(label)} +{re.escape(value)}$")
        for absent_hint in ["Codex setup", "Claude Code MCP", "Pi Agent Lean skill", "OpenCode MCP", "all agents"]:
            with self.subTest(absent_hint=absent_hint):
                self.assertNotRegex(output, rf"(?m)^ +{re.escape(absent_hint)} +")

    def test_alternate_codex_home_does_not_infer_setup_from_default_home(self):
        alternate = self.home / "unrelated codex home"
        output = self.summary(selected_home=alternate)
        self.assertIn("retain any client-home overrides when rerunning a hint", output)
        self.assertIn("MCP: not registered this run", output)
        self.assertFalse(alternate.exists())


if __name__ == "__main__":
    unittest.main()
